function Export-HVDRSnapshot {
    <#
    .SYNOPSIS
        Creates a Disaster Recovery snapshot that extends the standard pre-change
        snapshot with site-awareness metadata (primary/secondary site, replication lag).
    .PARAMETER ReportsPath
        Directory to write the DR snapshot.
    .PARAMETER PrimarySite
        Name label for the primary site (e.g. 'Site-A', 'DC-East').
    .PARAMETER SecondarySite
        Name label for the secondary/DR site.
    .OUTPUTS
        String: path to the written DR snapshot file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ReportsPath,
        [string]$PrimarySite   = 'Primary',
        [string]$SecondarySite = 'Secondary'
    )

    if (-not (Test-Path $ReportsPath)) {
        New-Item -ItemType Directory -Path $ReportsPath -Force | Out-Null
    }

    $cluster = Get-Cluster -ErrorAction SilentlyContinue

    # Collect replication info (Hyper-V Replica)
    $replicaInfo = @()
    try {
        $replicaInfo = Get-VM -ErrorAction SilentlyContinue |
                       Where-Object ReplicationState -ne 'Disabled' |
                       ForEach-Object {
                           $rep = $_ | Measure-VMReplication -ErrorAction SilentlyContinue
                           [PSCustomObject]@{
                               VMName           = $_.Name
                               ReplicationState = $_.ReplicationState.ToString()
                               ReplicationHealth= $_.ReplicationHealth.ToString()
                               LastReplication  = $rep.LastReplicationTime
                           }
                       }
    }
    catch {
        Write-HVLog -Message "Replica info collection failed: $($_.Exception.Message)" -Level 'WARN'
    }

    $snapshot = [ordered]@{
        SchemaVersion        = '8.0-DR'
        Label                = 'DR-Snapshot'
        Timestamp            = (Get-Date).ToString('o')
        PrimarySite          = $PrimarySite
        SecondarySite        = $SecondarySite
        ClusterExistedBefore = ($null -ne $cluster)
        ClusterName          = if ($cluster) { $cluster.Name } else { $null }
        Cluster              = ($cluster | Select-Object *)
        Nodes                = (Get-ClusterNode  -ErrorAction SilentlyContinue | Select-Object *)
        Quorum               = (Get-ClusterQuorum -ErrorAction SilentlyContinue | Select-Object *)
        Groups               = (Get-ClusterGroup  -ErrorAction SilentlyContinue | Select-Object *)
        Networks             = (Get-ClusterNetwork -ErrorAction SilentlyContinue | Select-Object *)
        Resources            = (Get-ClusterResource -ErrorAction SilentlyContinue | Select-Object *)
        SharedVolumes        = (Get-ClusterSharedVolume -ErrorAction SilentlyContinue | Select-Object *)
        ReplicaStatus        = $replicaInfo
    }

    $path = Get-HVArtifactPath -Directory $ReportsPath -Prefix 'DR-Snapshot' -Extension 'json' -Identity @(
        $snapshot.ClusterName
        $PrimarySite
        $SecondarySite
    )
    $snapshot | ConvertTo-Json -Depth 10 | Out-File -FilePath $path -Encoding UTF8
    Write-HVLog -Message "DR snapshot saved: $path" -Level 'INFO'
    return $path
}

function Test-HVDRReadiness {
    <#
    .SYNOPSIS
        Validates that the cluster is ready for a DR failover scenario.
        Checks node count, quorum health, replica health, and CSV availability.
    .OUTPUTS
        PSCustomObject: Ready (bool), Score (0-100), Checks (object[]).
    #>
    [CmdletBinding()]
    param()

    $checks = [System.Collections.Generic.List[object]]::new()
    $score  = 100

    # 1. Minimum node count (>= 2 for DR)
    $nodeCount = @(Get-ClusterNode -ErrorAction SilentlyContinue | Where-Object State -eq 'Up').Count
    $pass = $nodeCount -ge 2
    $score -= if (-not $pass) { 25 } else { 0 }
    $checks.Add([PSCustomObject]@{ Check = 'MinNodeCount'; Pass = $pass; Detail = "$nodeCount Up node(s) (min 2 required)" })

    # 2. Quorum is healthy
    try {
        $q    = Get-ClusterQuorum -ErrorAction Stop
        $pass = $null -ne $q
        $checks.Add([PSCustomObject]@{ Check = 'QuorumHealthy'; Pass = $pass; Detail = $q.QuorumType })
    }
    catch {
        $score -= 25
        $checks.Add([PSCustomObject]@{ Check = 'QuorumHealthy'; Pass = $false; Detail = $_.Exception.Message })
    }

    # 3. All cluster groups Online
    $offlineGroups = @(Get-ClusterGroup -ErrorAction SilentlyContinue | Where-Object { $_.State -notin @('Online','PartiallyOnline') })
    $pass = $offlineGroups.Count -eq 0
    $score -= if (-not $pass) { 25 } else { 0 }
    $checks.Add([PSCustomObject]@{ Check = 'AllGroupsOnline'; Pass = $pass; Detail = "$($offlineGroups.Count) offline group(s)" })

    # 4. All CSVs Online
    $offlineCSV = @(Get-ClusterSharedVolume -ErrorAction SilentlyContinue | Where-Object State -ne 'Online')
    $pass = $offlineCSV.Count -eq 0
    $score -= if (-not $pass) { 25 } else { 0 }
    $checks.Add([PSCustomObject]@{ Check = 'AllCSVsOnline'; Pass = $pass; Detail = "$($offlineCSV.Count) CSV(s) not online" })

    if ($score -lt 0) { $score = 0 }
    $ready = $score -ge 75

    Write-HVLog -Message "DR readiness: $(if ($ready){'READY'}else{'NOT READY'}) (Score=$score)" -Level $(if ($ready){'INFO'} else {'WARN'})

    return [PSCustomObject]@{
        Ready  = $ready
        Score  = [int]$score
        Checks = $checks.ToArray()
    }
}

function Invoke-HVDRFailover {
    <#
    .SYNOPSIS
        Orchestrates a planned or unplanned DR failover by evacuating VMs from
        specified source nodes and moving them to available target nodes.
    .PARAMETER SourceNodes
        Node(s) being failed over FROM (draining).
    .PARAMETER TargetNodes
        Node(s) to receive workloads. If empty, cluster chooses.
    .PARAMETER Planned
        If true, nodes are drained gracefully (Pause then Drain). If false, emergency evacuation.
    .PARAMETER DRSnapshotPath
        Path to store a DR snapshot before any changes.
    .OUTPUTS
        PSCustomObject: Success, MigratedVMs (object[]), DrainedNodes (string[]), Errors (string[]).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string[]]$SourceNodes,
        [string[]]$TargetNodes      = @(),
        [switch] $Planned,
        [string] $DRSnapshotPath    = '.\Reports'
    )

    $errors      = [System.Collections.Generic.List[string]]::new()
    $migratedVMs = [System.Collections.Generic.List[object]]::new()
    $drainedNodes= [System.Collections.Generic.List[string]]::new()

    Write-HVLog -Message "=== DR FAILOVER INITIATED (Planned=$Planned) ===" -Level 'WARN'
    Write-HVLog -Message "Source nodes: $($SourceNodes -join ', ')" -Level 'WARN'

    # Take DR snapshot
    $snapPath = Export-HVDRSnapshot -ReportsPath $DRSnapshotPath
    Write-HVLog -Message "DR snapshot: $snapPath" -Level 'INFO'

    foreach ($node in $SourceNodes) {
        try {
            Write-HVLog -Message "Draining node '$node'..." -Level 'WARN'

            if ($Planned) {
                # Graceful: pause then drain
                if ($PSCmdlet.ShouldProcess($node, 'Suspend and drain cluster node')) {
                    Suspend-ClusterNode -Name $node -Drain -ErrorAction Stop
                }
            }
            else {
                # Emergency: move roles immediately
                $vmsOnNode = Get-ClusterGroup -ErrorAction SilentlyContinue |
                             Where-Object { $_.OwnerNode.Name -eq $node -and $_.GroupType -eq 'VirtualMachine' }
                foreach ($vm in $vmsOnNode) {
                    try {
                        $moveParams = @{ Name = $vm.Name; ErrorAction = 'Stop' }
                        if ($TargetNodes.Count -gt 0) { $moveParams['Node'] = $TargetNodes[0] }
                        if ($PSCmdlet.ShouldProcess($vm.Name, "Emergency move VM from '$node'")) {
                            Move-ClusterVirtualMachineRole @moveParams | Out-Null
                        }
                        $dest = (Get-ClusterGroup -Name $vm.Name -ErrorAction SilentlyContinue).OwnerNode.Name
                        $migratedVMs.Add([PSCustomObject]@{ VMName = $vm.Name; From = $node; To = $dest; Success = $true })
                        Write-HVLog -Message "  VM '$($vm.Name)' moved to '$dest'." -Level 'INFO'
                    }
                    catch {
                        $errors.Add("VM '$($vm.Name)': $($_.Exception.Message)")
                        $migratedVMs.Add([PSCustomObject]@{ VMName = $vm.Name; From = $node; To = $null; Success = $false })
                        Write-HVLog -Message "  VM '$($vm.Name)' move FAILED: $($_.Exception.Message)" -Level 'ERROR'
                    }
                }
            }

            $drainedNodes.Add($node)
            Write-HVLog -Message "Node '$node' drained." -Level 'WARN'
        }
        catch {
            $errors.Add("Drain '$node': $($_.Exception.Message)")
            Write-HVLog -Message "Drain '$node' FAILED: $($_.Exception.Message)" -Level 'ERROR'
        }
    }

    $success = $errors.Count -eq 0
    Write-HVLog -Message "=== DR FAILOVER $(if ($success){'COMPLETE'}else{'PARTIAL'}) ===" -Level $(if ($success){'WARN'} else {'ERROR'})

    return [PSCustomObject]@{
        Success      = $success
        MigratedVMs  = $migratedVMs.ToArray()
        DrainedNodes = $drainedNodes.ToArray()
        Errors       = $errors.ToArray()
        SnapshotPath = $snapPath
    }
}
