function New-HVDesiredState {
    <#
    .SYNOPSIS
        Constructs the desired cluster state object used by the drift engine and enforcement.
    .PARAMETER WitnessType
        One of: None | Disk | Cloud | Share
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ClusterName,
        [Parameter(Mandatory)][string[]]$Nodes,
        [Parameter(Mandatory)][ValidateSet('None','Disk','Cloud','Share')][string]$WitnessType
    )

    return [PSCustomObject]@{
        ClusterName = $ClusterName
        Nodes       = $Nodes
        WitnessType = $WitnessType
    }
}

function Get-HVClusterCurrentState {
    <#
    .SYNOPSIS
        Reads the live cluster state from the Failover Clustering subsystem.
        Returns $null if no cluster is found (treated as 100% drift).
    .OUTPUTS
        PSCustomObject: ClusterName, Nodes (string[]), WitnessType (string), or $null.
    #>
    [CmdletBinding()]
    param()

    $cluster = Get-Cluster -ErrorAction SilentlyContinue
    if (-not $cluster) {
        Write-HVLog -Message "No active cluster found on this node." -Level 'WARN'
        return $null
    }

    $quorum = Get-ClusterQuorum -ErrorAction SilentlyContinue

    return [PSCustomObject]@{
        ClusterName = $cluster.Name
        Nodes       = @(Get-ClusterNode -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
        WitnessType = if ($quorum) { $quorum.QuorumType.ToString() } else { 'Unknown' }
    }
}
