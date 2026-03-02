\
# DSC Resource Skeleton: HVClusterResource

function Get-TargetResource {
    param(
        [Parameter(Mandatory)][string]$ClusterName,
        [Parameter(Mandatory)][string[]]$Nodes
    )

    $cluster = Get-Cluster -ErrorAction SilentlyContinue
    if (-not $cluster) {
        return @{ ClusterName = $ClusterName; Nodes = $Nodes; Ensure = 'Absent' }
    }

    return @{
        ClusterName = $cluster.Name
        Nodes       = (Get-ClusterNode | Select-Object -ExpandProperty Name)
        Ensure      = 'Present'
    }
}

function Test-TargetResource {
    param(
        [Parameter(Mandatory)][string]$ClusterName,
        [Parameter(Mandatory)][string[]]$Nodes,
        [ValidateSet('Present','Absent')][string]$Ensure = 'Present'
    )

    $current = Get-TargetResource -ClusterName $ClusterName -Nodes $Nodes

    if ($Ensure -eq 'Absent') { return ($current.Ensure -eq 'Absent') }

    return ($current.Ensure -eq 'Present' -and $current.ClusterName -eq $ClusterName)
}

function Set-TargetResource {
    param(
        [Parameter(Mandatory)][string]$ClusterName,
        [Parameter(Mandatory)][string[]]$Nodes,
        [ValidateSet('Present','Absent')][string]$Ensure = 'Present'
    )

    if ($Ensure -eq 'Absent') {
        throw "Removal not implemented in scaffold."
    }

    if (-not (Get-Cluster -ErrorAction SilentlyContinue)) {
        New-Cluster -Name $ClusterName -Node $Nodes -NoStorage
    }
}

Export-ModuleMember -Function *-TargetResource
