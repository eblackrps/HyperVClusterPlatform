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

    foreach ($moduleName in ($commandSpecs | Select-Object -ExpandProperty Module -Unique)) {
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

    Write-DSCLog "Current: Cluster='$($cluster.Name)' Nodes=[$($currentNodes -join ',')] Witness=$currentWitness"

    return @{
        ClusterName    = $cluster.Name
        StaticAddress  = $StaticAddress
        Nodes          = $currentNodes
        WitnessType    = $currentWitness
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

    Write-DSCLog "Cluster is in desired state."
    return $true
}

function Set-TargetResource {
    <#
    .SYNOPSIS
        Applies the desired cluster configuration.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ClusterName,
        [Parameter(Mandatory)][string]$StaticAddress,
        [Parameter(Mandatory)][string[]]$Nodes,
        [ValidateSet('None','Disk','Cloud','Share')][string]$WitnessType = 'None',
        [ValidateSet('Present','Absent')][string]$Ensure = 'Present',
        [string]$ClusterIP                 = '',
        [string]$FileShareWitness          = '',
        [string]$CloudWitnessStorageAccount = '',
        [string]$CloudWitnessStorageKey     = ''
    )

    Write-DSCLog "Set-TargetResource: $ClusterName (Ensure=$Ensure)"

    # ── Ensure = Absent ───────────────────────────────────────────────────────
    if ($Ensure -eq 'Absent') {
        $cluster = Get-ClusterSafe
        if ($cluster) {
            Write-DSCLog "Removing cluster '$ClusterName'..." 'WARN'
            Remove-Cluster -Cluster $ClusterName -Force -CleanUpAD -ErrorAction Stop
            Write-DSCLog "Cluster removed."
        }
        return
    }

    # ── Ensure = Present ─────────────────────────────────────────────────────
    $cluster = Get-ClusterSafe

    # Create cluster if absent
    if (-not $cluster) {
        Write-DSCLog "Creating cluster '$ClusterName' at $StaticAddress with nodes [$($Nodes -join ',')]..." 'WARN'
        New-Cluster -Name $ClusterName -Node $Nodes -StaticAddress $StaticAddress -NoStorage -ErrorAction Stop
        Write-DSCLog "Cluster created."
    }
    else {
        Write-DSCLog "Cluster '$($cluster.Name)' exists."
        # Add missing nodes
        $current = Get-ClusterNodesSafe
        $toAdd   = $Nodes | Where-Object { $current -notcontains $_ }
        foreach ($n in $toAdd) {
            Write-DSCLog "Adding node '$n'..." 'WARN'
            Add-ClusterNode -Name $n -ErrorAction Stop
            Write-DSCLog "Node '$n' added."
        }
    }

    # Configure witness
    switch ($WitnessType) {
        'None'  { Set-ClusterQuorum -NodeMajority -ErrorAction Stop }
        'Disk'  {
            $disk = Get-ClusterAvailableDisk -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($disk) {
                $added = Add-ClusterDisk -InputObject $disk -PassThru -ErrorAction Stop
                Set-ClusterQuorum -NodeAndDiskMajority $added.Name -ErrorAction Stop
            }
        }
        'Share' {
            if ($FileShareWitness) {
                Set-ClusterQuorum -NodeAndFileShareMajority $FileShareWitness -ErrorAction Stop
            }
        }
        'Cloud' {
            if (-not $CloudWitnessStorageAccount -or -not $CloudWitnessStorageKey) {
                throw "WitnessType='Cloud' requires CloudWitnessStorageAccount and CloudWitnessStorageKey."
            }
            Set-ClusterQuorum -CloudWitness -AccountName $CloudWitnessStorageAccount -AccessKey $CloudWitnessStorageKey -ErrorAction Stop
        }
    }

    Write-DSCLog "Set-TargetResource complete."
}

Export-ModuleMember -Function Get-TargetResource, Test-TargetResource, Set-TargetResource
