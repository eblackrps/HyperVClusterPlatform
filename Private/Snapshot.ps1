function New-HVClusterSnapshot {
    <#
    .SYNOPSIS
        Captures a comprehensive pre-change snapshot of the cluster state to JSON.
        The snapshot includes enough information for the rollback engine to determine
        what was created vs what already existed before enforcement ran.
    .PARAMETER ReportsPath
        Directory where snapshot JSON is written.
    .PARAMETER Label
        Optional descriptive label embedded in the filename (e.g., 'Pre-Enforce').
    .OUTPUTS
        String: full path to the written snapshot file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ReportsPath,
        [string]$Label = 'PreChange'
    )

    if (-not (Test-Path $ReportsPath)) {
        New-Item -ItemType Directory -Path $ReportsPath -Force | Out-Null
    }

    # Determine whether a cluster already exists at snapshot time.
    # This flag lets the rollback engine know if it created the cluster or found it.
    $clusterExistedBefore = $null -ne (Get-Cluster -ErrorAction SilentlyContinue)

    $snapshot = [ordered]@{
        SchemaVersion        = '8.0'
        Label                = $Label
        Timestamp            = (Get-Date).ToString('o')
        ClusterExistedBefore = $clusterExistedBefore
        Cluster              = (Get-Cluster      -ErrorAction SilentlyContinue | Select-Object *)
        Nodes                = (Get-ClusterNode  -ErrorAction SilentlyContinue | Select-Object *)
        Quorum               = (Get-ClusterQuorum -ErrorAction SilentlyContinue | Select-Object *)
        Groups               = (Get-ClusterGroup  -ErrorAction SilentlyContinue | Select-Object *)
        Networks             = (Get-ClusterNetwork -ErrorAction SilentlyContinue | Select-Object *)
        Resources            = (Get-ClusterResource -ErrorAction SilentlyContinue | Select-Object *)
        SharedVolumes        = (Get-ClusterSharedVolume -ErrorAction SilentlyContinue | Select-Object *)
    }

    $safeName = $Label -replace '[^\w\-]', '_'
    $path     = Join-Path $ReportsPath ("Snapshot-{0}-{1}.json" -f $safeName, (Get-Date -Format 'yyyyMMddHHmmss'))
    $snapshot | ConvertTo-Json -Depth 10 | Out-File -FilePath $path -Encoding UTF8
    Write-HVLog -Message "Snapshot saved: $path (ClusterExistedBefore=$clusterExistedBefore)" -Level 'INFO'
    return $path
}
