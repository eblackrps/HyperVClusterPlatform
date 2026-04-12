function Get-HVCSVState {
    <#
    .SYNOPSIS
        Returns current Cluster Shared Volume state including health, owner node, and path.
    .OUTPUTS
        PSCustomObject[]: Name, Path, OwnerNode, State, FriendlyName, SizeGB.
    #>
    [CmdletBinding()]
    param()

    try {
        $csvs = Get-ClusterSharedVolume -ErrorAction SilentlyContinue
        if (-not $csvs) {
            Write-HVLog -Message "No Cluster Shared Volumes found." -Level 'INFO'
            return @()
        }

        $result = foreach ($csv in $csvs) {
            $info = $csv | Get-ClusterSharedVolumeState -ErrorAction SilentlyContinue | Select-Object -First 1
            $sizeGB = $null
            try {
                $vol = $csv.SharedVolumeInfo | Select-Object -First 1
                if ($vol -and $vol.Partition) {
                    $sizeGB = [math]::Round($vol.Partition.Size / 1GB, 2)
                }
            } catch { Write-HVLog -Message "Could not read CSV partition info: $($_.Exception.Message)" -Level 'WARN' }

            [PSCustomObject]@{
                Name         = $csv.Name
                FriendlyName = $csv.Name -replace '^Cluster Disk\s*', 'CSV-'
                Path         = if ($info) { $info.VolumeFriendlyName } else { '' }
                OwnerNode    = $csv.OwnerNode.Name
                State        = $csv.State.ToString()
                StateDetail  = if ($info) { $info.StateInfo } else { '' }
                SizeGB       = $sizeGB
            }
        }

        Write-HVLog -Message "CSV state: $(@($result).Count) volumes found." -Level 'INFO'
        return @($result)
    }
    catch {
        Write-HVLog -Message "Get-HVCSVState failed: $($_.Exception.Message)" -Level 'ERROR'
        return @()
    }
}

function Add-HVClusterSharedVolume {
    <#
    .SYNOPSIS
        Adds an available cluster disk as a Cluster Shared Volume. Idempotent.
    .PARAMETER DiskName
        Name of the available cluster disk (e.g. 'Cluster Disk 2').
        If not specified, selects the first available disk.
    .PARAMETER FriendlyName
        Optional rename for the CSV after creation.
    .OUTPUTS
        PSCustomObject: Name, Added, AlreadyCSV, FriendlyName.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$DiskName,
        [string]$FriendlyName
    )

    try {
        # Check if already a CSV
        $existing = Get-ClusterSharedVolume -ErrorAction SilentlyContinue
        if ($DiskName -and ($existing | Where-Object Name -eq $DiskName)) {
            Write-HVLog -Message "Disk '$DiskName' is already a CSV. Skipping." -Level 'INFO'
            return [PSCustomObject]@{ Name = $DiskName; Added = $false; AlreadyCSV = $true; FriendlyName = $FriendlyName }
        }

        # Get target disk
        if ($DiskName) {
            $disk = Get-ClusterResource -Name $DiskName -ErrorAction SilentlyContinue
        }
        else {
            # Find first available disk not already in CSV
            $csvNames   = @($existing | Select-Object -ExpandProperty Name)
            $allDisks   = Get-ClusterResource -ErrorAction SilentlyContinue |
                          Where-Object { $_.ResourceType -eq 'Physical Disk' -and $csvNames -notcontains $_.Name }
            $disk = $allDisks | Select-Object -First 1
        }

        if (-not $disk) {
            throw "No suitable disk found to add as CSV."
        }

        $csvName = $disk.Name
        $added = $false
        if ($PSCmdlet.ShouldProcess($disk.Name, 'Add Cluster Shared Volume')) {
            Write-HVLog -Message "Adding '$($disk.Name)' as Cluster Shared Volume..." -Level 'WARN'
            $csv = Add-ClusterSharedVolume -Name $disk.Name -ErrorAction Stop
            Write-HVLog -Message "CSV added: '$($csv.Name)'." -Level 'INFO'
            $added = $true
            $csvName = $csv.Name

            if ($FriendlyName) {
                $csv.Name = $FriendlyName
                Write-HVLog -Message "CSV renamed to '$FriendlyName'." -Level 'INFO'
                $csvName = $FriendlyName
            }
        }

        return [PSCustomObject]@{ Name = $csvName; Added = $added; AlreadyCSV = $false; FriendlyName = $FriendlyName }
    }
    catch {
        Write-HVLog -Message "Add-HVClusterSharedVolume failed: $($_.Exception.Message)" -Level 'ERROR'
        throw
    }
}

function Get-HVStorageDrift {
    <#
    .SYNOPSIS
        Scores storage compliance drift. Checks required CSV count and minimum total capacity.
    .PARAMETER DesiredCSVCount
        Minimum number of CSVs that should exist. 0 = no requirement.
    .PARAMETER DesiredMinTotalGB
        Minimum total CSV storage in GB. 0 = no requirement.
    .OUTPUTS
        PSCustomObject: Score (0-100), Details (string[]), CSVState (object[]).
    #>
    [CmdletBinding()]
    param(
        [int]$DesiredCSVCount    = 0,
        [double]$DesiredMinTotalGB = 0
    )

    $score  = 0
    $detail = [System.Collections.Generic.List[string]]::new()

    $csvState = Get-HVCSVState
    $count    = @($csvState).Count
    $totalGB  = ($csvState | Measure-Object -Property SizeGB -Sum -ErrorAction SilentlyContinue).Sum

    if ($DesiredCSVCount -gt 0 -and $count -lt $DesiredCSVCount) {
        $score += 50
        $detail.Add("CSV count: $count found, $DesiredCSVCount required.")
    }

    if ($DesiredMinTotalGB -gt 0 -and $totalGB -lt $DesiredMinTotalGB) {
        $score += 50
        $detail.Add("Total CSV storage: $($totalGB)GB found, minimum ${DesiredMinTotalGB}GB required.")
    }

    # Check for any CSVs in non-Online state
    $unhealthy = @($csvState | Where-Object { $_.State -ne 'Online' })
    if ($unhealthy.Count -gt 0) {
        $score = [math]::Min(100, $score + 20)
        foreach ($u in $unhealthy) {
            $detail.Add("CSV '$($u.Name)' is $($u.State) (not Online).")
        }
    }

    if ($score -eq 0 -and $detail.Count -eq 0) {
        $detail.Add("Storage: $count CSV(s), ${totalGB}GB total - compliant.")
    }

    if ($score -gt 100) { $score = 100 }
    Write-HVLog -Message "Storage drift: $score/100 ($count CSVs, ${totalGB}GB)" -Level 'INFO'

    return [PSCustomObject]@{
        Score    = [int]$score
        Details  = $detail.ToArray()
        CSVState = $csvState
    }
}
