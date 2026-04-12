# DSC Resource: HVClusterResource
# Full implementation of Get/Test/Set-TargetResource for Hyper-V failover clusters.
# Supports: Windows Server 2022 (build 20348+) and Windows Server 2025 (build 26100+).

#region Helpers

function Write-DSCLog {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [DSC][$Level] $Message"
    Write-Verbose $line
}

function Initialize-HVDSCCommandAliases {
    $commandSpecs = @(
        @{ Name = 'Add-ClusterDisk';          Module = 'FailoverClusters' }
        @{ Name = 'Add-ClusterNode';          Module = 'FailoverClusters' }
        @{ Name = 'Get-Cluster';              Module = 'FailoverClusters' }
        @{ Name = 'Get-ClusterAvailableDisk'; Module = 'FailoverClusters' }
        @{ Name = 'Get-ClusterNode';          Module = 'FailoverClusters' }
        @{ Name = 'Get-ClusterQuorum';        Module = 'FailoverClusters' }
        @{ Name = 'New-Cluster';              Module = 'FailoverClusters' }
        @{ Name = 'Remove-Cluster';           Module = 'FailoverClusters' }
        @{ Name = 'Set-ClusterQuorum';        Module = 'FailoverClusters' }
    )

    foreach ($moduleName in ($commandSpecs | ForEach-Object { $_['Module'] } | Select-Object -Unique)) {
        if (-not (Get-Module -Name $moduleName) -and (Get-Module -ListAvailable -Name $moduleName)) {
            try {
                Import-Module $moduleName -ErrorAction Stop | Out-Null
            }
            catch {
                Write-DSCLog "Could not import preferred module '$moduleName': $($_.Exception.Message)" 'WARN'
            }
        }
    }

    foreach ($commandSpec in $commandSpecs) {
        $qualified = '{0}\{1}' -f $commandSpec.Module, $commandSpec.Name
        if (Get-Command $qualified -ErrorAction SilentlyContinue) {
            Set-Alias -Name $commandSpec.Name -Value $qualified -Scope Script -Force
        }
    }
}

function Get-ClusterSafe {
    Get-Cluster -ErrorAction SilentlyContinue
}

function Get-ClusterNodesSafe {
    @(Get-ClusterNode -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
}

function Get-WitnessType {
    try {
        $q = Get-ClusterQuorum -ErrorAction Stop
        $t = $q.QuorumType.ToString()
        switch ($true) {
            ($t -match 'Disk')      { return 'Disk' }
            ($t -match 'Cloud')     { return 'Cloud' }
            ($t -match 'FileShare') { return 'Share' }
            default                  { return 'None' }
        }
    }
    catch { return 'None' }
}

function Get-WitnessResource {
    try {
        $q = Get-ClusterQuorum -ErrorAction Stop
        if ($q.PSObject.Properties.Name -contains 'QuorumResource' -and $null -ne $q.QuorumResource) {
            if ($q.QuorumResource -is [string]) {
                return $q.QuorumResource
            }
            if ($q.QuorumResource.PSObject.Properties.Name -contains 'Name') {
                return $q.QuorumResource.Name
            }
            return [string]$q.QuorumResource
        }
        return ''
    }
    catch {
        return ''
    }
}

function Import-HVPlatformModule {
    $manifestPath = Join-Path $PSScriptRoot '..\..\HyperVClusterPlatform.psd1'
    if (-not (Test-Path $manifestPath)) {
        throw "Could not locate HyperVClusterPlatform manifest at '$manifestPath'."
    }

    Import-Module $manifestPath -Force -ErrorAction Stop | Out-Null
    return $manifestPath
}

#endregion

Initialize-HVDSCCommandAliases

function Get-TargetResource {
    <#
    .SYNOPSIS
        Returns the current cluster state for DSC compliance comparison.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Hashtable])]
    param(
        [Parameter(Mandatory)][string]$ClusterName,
        [Parameter(Mandatory)][string]$StaticAddress,
        [Parameter(Mandatory)][string[]]$Nodes,
        [ValidateSet('None','Disk','Cloud','Share')][string]$WitnessType = 'None',
        [ValidateSet('Present','Absent')][string]$Ensure = 'Present',
        [string]$ClusterIP                 = '',
        [string]$WitnessDiskName           = '',
        [string]$FileShareWitness          = '',
        [string]$CloudWitnessStorageAccount = '',
        [string]$CloudWitnessStorageKey     = ''
    )

    Write-DSCLog "Get-TargetResource: $ClusterName"

    $cluster = Get-ClusterSafe
    if (-not $cluster) {
        Write-DSCLog "No cluster found — returning Absent."
        return @{
            ClusterName    = $ClusterName
            StaticAddress  = $StaticAddress
            Nodes          = @()
            WitnessType    = 'None'
            Ensure         = 'Absent'
        }
    }

    $currentNodes   = Get-ClusterNodesSafe
    $currentWitness = Get-WitnessType
    $currentWitnessResource = Get-WitnessResource

    Write-DSCLog "Current: Cluster='$($cluster.Name)' Nodes=[$($currentNodes -join ',')] Witness=$currentWitness Resource='$currentWitnessResource'"

    return @{
        ClusterName    = $cluster.Name
        StaticAddress  = $StaticAddress
        Nodes          = $currentNodes
        WitnessType    = $currentWitness
        WitnessResource = $currentWitnessResource
        Ensure         = 'Present'
    }
}

function Test-TargetResource {
    <#
    .SYNOPSIS
        Returns $true if the cluster is in the desired state; $false if Set is needed.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$ClusterName,
        [Parameter(Mandatory)][string]$StaticAddress,
        [Parameter(Mandatory)][string[]]$Nodes,
        [ValidateSet('None','Disk','Cloud','Share')][string]$WitnessType = 'None',
        [ValidateSet('Present','Absent')][string]$Ensure = 'Present',
        [string]$ClusterIP                 = '',
        [string]$WitnessDiskName           = '',
        [string]$FileShareWitness          = '',
        [string]$CloudWitnessStorageAccount = '',
        [string]$CloudWitnessStorageKey     = ''
    )

    Write-DSCLog "Test-TargetResource: $ClusterName"
    $current = Get-TargetResource @PSBoundParameters

    # Ensure = Absent: just check cluster non-existence
    if ($Ensure -eq 'Absent') {
        $result = $current.Ensure -eq 'Absent'
        Write-DSCLog "Ensure=Absent check: $result"
        return $result
    }

    # Cluster must exist
    if ($current.Ensure -ne 'Present') {
        Write-DSCLog "Cluster absent — Set required."
        return $false
    }

    # Cluster name must match
    if ($current.ClusterName -ne $ClusterName) {
        Write-DSCLog "ClusterName mismatch — Set required."
        return $false
    }

    # Node membership (symmetric diff)
    $diff = Compare-Object -ReferenceObject  ($Nodes | Sort-Object) `
                           -DifferenceObject ($current.Nodes | Sort-Object) `
                           -ErrorAction SilentlyContinue
    if ($diff) {
        Write-DSCLog "Node membership mismatch — Set required."
        return $false
    }

    # Witness type
    if ($current.WitnessType -ne $WitnessType) {
        Write-DSCLog "WitnessType mismatch (desired=$WitnessType, current=$($current.WitnessType)) — Set required."
        return $false
    }

    if ($WitnessType -eq 'Disk' -and $WitnessDiskName -and $current.WitnessResource -ne $WitnessDiskName) {
        Write-DSCLog "Witness resource mismatch (desired disk='$WitnessDiskName', current='$($current.WitnessResource)') - Set required."
        return $false
    }

    if ($WitnessType -eq 'Share' -and $FileShareWitness -and $current.WitnessResource -ne $FileShareWitness) {
        Write-DSCLog "Witness resource mismatch (desired share='$FileShareWitness', current='$($current.WitnessResource)') - Set required."
        return $false
    }

    Write-DSCLog "Cluster is in desired state."
    return $true
}

function Set-TargetResource {
    <#
    .SYNOPSIS
        Applies the desired cluster configuration.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$ClusterName,
        [Parameter(Mandatory)][string]$StaticAddress,
        [Parameter(Mandatory)][string[]]$Nodes,
        [ValidateSet('None','Disk','Cloud','Share')][string]$WitnessType = 'None',
        [ValidateSet('Present','Absent')][string]$Ensure = 'Present',
        [string]$ClusterIP                 = '',
        [string]$WitnessDiskName           = '',
        [string]$FileShareWitness          = '',
        [string]$CloudWitnessStorageAccount = '',
        [string]$CloudWitnessStorageKey     = ''
    )

    Write-DSCLog "Set-TargetResource: $ClusterName (Ensure=$Ensure)"

    # ── Ensure = Absent ───────────────────────────────────────────────────────
    if ($Ensure -eq 'Absent') {
        $cluster = Get-ClusterSafe
        if ($cluster) {
            if ($PSCmdlet.ShouldProcess($ClusterName, 'Remove cluster')) {
                Write-DSCLog "Removing cluster '$ClusterName'..." 'WARN'
                Remove-Cluster -Cluster $ClusterName -Force -CleanUpAD -ErrorAction Stop
                Write-DSCLog "Cluster removed."
            }
        }
        return
    }

    # ── Ensure = Present ─────────────────────────────────────────────────────
    $null = Import-HVPlatformModule
    $effectiveClusterIP = if ($ClusterIP) { $ClusterIP } else { $StaticAddress }
    $reportsPath = Join-Path $env:ProgramData 'HyperVClusterPlatform\Reports'
    $logPath = Join-Path $env:ProgramData 'HyperVClusterPlatform\Logs'

    $platformParams = @{
        ClusterName          = $ClusterName
        Nodes                = $Nodes
        ClusterIP            = $effectiveClusterIP
        WitnessType          = $WitnessType
        Mode                 = 'Enforce'
        ReportsPath          = $reportsPath
        LogPath              = $logPath
    }
    if ($WitnessDiskName) { $platformParams['WitnessDiskName'] = $WitnessDiskName }
    if ($FileShareWitness) { $platformParams['FileShareWitnessPath'] = $FileShareWitness }
    if ($CloudWitnessStorageAccount) { $platformParams['CloudWitnessStorageAccount'] = $CloudWitnessStorageAccount }
    if ($CloudWitnessStorageKey) { $platformParams['CloudWitnessStorageKey'] = $CloudWitnessStorageKey }

    if ($PSCmdlet.ShouldProcess($ClusterName, 'Apply cluster state via Invoke-HVClusterPlatform')) {
        Invoke-HVClusterPlatform @platformParams | Out-Null
    }

    Write-DSCLog "Set-TargetResource complete."
}

Export-ModuleMember -Function Get-TargetResource, Test-TargetResource, Set-TargetResource
