function Get-HVOSProfile {
    <#
    .SYNOPSIS
        Detects the Windows Server version on a local or remote node.
    .OUTPUTS
        PSCustomObject: Build, Version ('2022'|'2025'|'2019'|'Unknown'), DisplayName.
    #>
    [CmdletBinding()]
    param(
        [string]$ComputerName = $env:COMPUTERNAME
    )

    try {
        $os    = Get-CimInstance -ClassName Win32_OperatingSystem -ComputerName $ComputerName -ErrorAction Stop
        $build = [int]$os.BuildNumber

        $osProfile = switch ($true) {
            ($build -ge 26100) { [PSCustomObject]@{ Build = $build; Version = '2025'; DisplayName = 'Windows Server 2025' }; break }
            ($build -ge 20348) { [PSCustomObject]@{ Build = $build; Version = '2022'; DisplayName = 'Windows Server 2022' }; break }
            ($build -ge 17763) { [PSCustomObject]@{ Build = $build; Version = '2019'; DisplayName = 'Windows Server 2019' }; break }
            default             { [PSCustomObject]@{ Build = $build; Version = 'Unknown'; DisplayName = $os.Caption } }
        }

        Write-HVLog -Message "OS Profile [$ComputerName]: $($osProfile.DisplayName) (Build $build)" -Level 'INFO'
        return $osProfile
    }
    catch {
        Write-HVLog -Message "OS detection failed for '$ComputerName': $($_.Exception.Message)" -Level 'WARN'
        return [PSCustomObject]@{ Build = 0; Version = 'Unknown'; DisplayName = 'Detection failed' }
    }
}

function Get-HVDriftScore {
    <#
    .SYNOPSIS
        Computes a 0-100 drift score comparing desired vs current cluster state.
        0 = fully compliant. 100 = maximum drift.
    .OUTPUTS
        PSCustomObject: Score (int), Details (string[]).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Desired,
        [Parameter(Mandatory)][AllowNull()]$Current
    )

    if (-not $Current) {
        return [PSCustomObject]@{ Score = 100; Details = @('No current cluster state found.') }
    }

    $score  = 0
    $detail = [System.Collections.Generic.List[string]]::new()

    # --- Cluster name (weight: 30) ---
    if ($Desired.ClusterName -ne $Current.ClusterName) {
        $score += 30
        $detail.Add("ClusterName mismatch: desired='$($Desired.ClusterName)' current='$($Current.ClusterName)'")
    }

    # --- Node membership (weight: 30) ---
    # v7 BUG FIX: -ne on arrays filters elements, not compare arrays.
    # Use Compare-Object for a true symmetric-difference check.
    $desiredNodes = @($Desired.Nodes | Sort-Object)
    $currentNodes = @($Current.Nodes  | Sort-Object)
    $nodeDiff = Compare-Object -ReferenceObject $desiredNodes -DifferenceObject $currentNodes -ErrorAction SilentlyContinue
    if ($nodeDiff) {
        $score += 30
        $missing = ($nodeDiff | Where-Object SideIndicator -eq '<=' | Select-Object -ExpandProperty InputObject) -join ', '
        $extra   = ($nodeDiff | Where-Object SideIndicator -eq '=>' | Select-Object -ExpandProperty InputObject) -join ', '
        if ($missing) { $detail.Add("Nodes missing from cluster: $missing") }
        if ($extra)   { $detail.Add("Unexpected nodes in cluster: $extra") }
    }

    # --- Witness / quorum type (weight: 40) ---
    # Map desired type to the strings Get-ClusterQuorum returns on WS2022/2025.
    $witnessMap = @{
        'None'  = @('NodeMajority', 'NoWitness')
        'Disk'  = @('NodeAndDiskMajority', 'Disk')
        'Cloud' = @('Cloud', 'CloudWitness')
        'Share' = @('NodeAndFileShareMajority', 'FileShareMajority', 'FileShare')
    }
    $acceptable = $witnessMap[$Desired.WitnessType]
    if ($acceptable) {
        $matched = $acceptable | Where-Object { $Current.WitnessType -match $_ }
        if (-not $matched) {
            $score += 40
            $detail.Add("WitnessType mismatch: desired='$($Desired.WitnessType)' current='$($Current.WitnessType)'")
        }
    }

    if ($Desired.WitnessResource -and $Current.WitnessResource -and
        ($Desired.WitnessType -in @('Disk','Share')) -and
        ($Desired.WitnessResource -ne $Current.WitnessResource)) {
        $score = [math]::Min(100, $score + 20)
        $detail.Add("Witness resource mismatch: desired='$($Desired.WitnessResource)' current='$($Current.WitnessResource)'")
    }

    if ($score -gt 100) { $score = 100 }

    return [PSCustomObject]@{
        Score   = [int]$score
        Details = $detail.ToArray()
    }
}
