function ConvertTo-HVWitnessType {
    [CmdletBinding()]
    param([string]$QuorumType)

    switch -Regex ($QuorumType) {
        'Disk'      { return 'Disk' }
        'Cloud'     { return 'Cloud' }
        'FileShare' { return 'Share' }
        'Share'     { return 'Share' }
        default     { return 'None' }
    }
}

function Get-HVDesiredState {
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
        [Parameter(Mandatory)][ValidateSet('None','Disk','Cloud','Share')][string]$WitnessType,
        [string]$WitnessDiskName = '',
        [string]$FileShareWitnessPath = ''
    )

    $witnessResource = switch ($WitnessType) {
        'Disk'  { $WitnessDiskName }
        'Share' { $FileShareWitnessPath }
        default { '' }
    }

    return [PSCustomObject]@{
        ClusterName = $ClusterName
        Nodes       = $Nodes
        WitnessType = $WitnessType
        WitnessResource = $witnessResource
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

    $witnessResource = ''
    if ($quorum) {
        if ($quorum.PSObject.Properties.Name -contains 'QuorumResource' -and $null -ne $quorum.QuorumResource) {
            if ($quorum.QuorumResource -is [string]) {
                $witnessResource = $quorum.QuorumResource
            }
            elseif ($quorum.QuorumResource.PSObject.Properties.Name -contains 'Name') {
                $witnessResource = $quorum.QuorumResource.Name
            }
            else {
                $witnessResource = [string]$quorum.QuorumResource
            }
        }
        elseif ($quorum.PSObject.Properties.Name -contains 'Resource' -and $null -ne $quorum.Resource) {
            $witnessResource = [string]$quorum.Resource
        }
    }

    return [PSCustomObject]@{
        ClusterName = $cluster.Name
        Nodes       = @(Get-ClusterNode -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
        WitnessType = if ($quorum) { $quorum.QuorumType.ToString() } else { 'Unknown' }
        WitnessResource = $witnessResource
    }
}
