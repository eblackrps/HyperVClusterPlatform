function Get-HVClusterHealth {
    <#
    .SYNOPSIS
        Performs a comprehensive health assessment of the running cluster.
        Returns structured health data suitable for alerting, reporting, and monitoring.
    .PARAMETER IncludeVMs
        Include per-VM health status in the result.
    .OUTPUTS
        PSCustomObject: Overall (Healthy|Warning|Critical), Score (0-100),
        Nodes, Resources, CSVs, Quorum, VMs (if -IncludeVMs), Timestamp, Details.
    #>
    [CmdletBinding()]
    param(
        [switch]$IncludeVMs
    )

    $issues  = [System.Collections.Generic.List[string]]::new()
    $score   = 100   # start healthy, deduct per problem

    Write-HVLog -Message "Starting cluster health assessment..." -Level 'INFO'

    # ── Cluster reachable ────────────────────────────────────────────────────
    $cluster = Get-Cluster -ErrorAction SilentlyContinue
    if (-not $cluster) {
        return [PSCustomObject]@{
            Overall   = 'Critical'
            Score     = 0
            Details   = @('No cluster found on this node.')
            Timestamp = (Get-Date).ToString('o')
        }
    }

    # ── Node health ──────────────────────────────────────────────────────────
    $nodeResults = [System.Collections.Generic.List[object]]::new()
    try {
        $nodes = Get-ClusterNode -ErrorAction Stop
        foreach ($node in $nodes) {
            $nodeState = $node.State.ToString()
            $healthy   = $nodeState -eq 'Up'
            if (-not $healthy) {
                $issues.Add("Node '$($node.Name)' is $nodeState.")
                $score -= 20
            }
            $nodeResults.Add([PSCustomObject]@{
                Name    = $node.Name
                State   = $nodeState
                Healthy = $healthy
            })
        }
    }
    catch {
        $issues.Add("Could not query cluster nodes: $($_.Exception.Message)")
        $score -= 20
    }

    # ── Resource group health ────────────────────────────────────────────────
    $resResults = [System.Collections.Generic.List[object]]::new()
    try {
        $groups = Get-ClusterGroup -ErrorAction Stop
        foreach ($g in $groups) {
            $healthy = $g.State -in @('Online', 'PartiallyOnline')
            if (-not $healthy) {
                $issues.Add("Resource group '$($g.Name)' is $($g.State).")
                $score -= 10
            }
            $resResults.Add([PSCustomObject]@{
                Name      = $g.Name
                Type      = $g.GroupType.ToString()
                State     = $g.State.ToString()
                OwnerNode = $g.OwnerNode.Name
                Healthy   = $healthy
            })
        }
    }
    catch {
        $issues.Add("Could not query resource groups: $($_.Exception.Message)")
        $score -= 10
    }

    # ── CSV health ───────────────────────────────────────────────────────────
    $csvResults = [System.Collections.Generic.List[object]]::new()
    try {
        $csvs = Get-ClusterSharedVolume -ErrorAction SilentlyContinue
        foreach ($csv in $csvs) {
            $healthy = $csv.State -eq 'Online'
            if (-not $healthy) {
                $issues.Add("CSV '$($csv.Name)' is $($csv.State).")
                $score -= 15
            }
            $csvResults.Add([PSCustomObject]@{
                Name      = $csv.Name
                State     = $csv.State.ToString()
                OwnerNode = $csv.OwnerNode.Name
                Healthy   = $healthy
            })
        }
    }
    catch {
        Write-HVLog -Message "CSV health query failed: $($_.Exception.Message)" -Level 'WARN'
    }

    # ── Quorum health ────────────────────────────────────────────────────────
    $quorumResult = $null
    try {
        $q = Get-ClusterQuorum -ErrorAction Stop
        $quorumResult = [PSCustomObject]@{
            Type    = $q.QuorumType.ToString()
            Witness = $q.QuorumResource
            Healthy = $true
        }
        Write-HVLog -Message "Quorum: $($q.QuorumType)." -Level 'INFO'
    }
    catch {
        $issues.Add("Could not query quorum: $($_.Exception.Message)")
        $score -= 20
        $quorumResult = [PSCustomObject]@{ Type = 'Unknown'; Witness = $null; Healthy = $false }
    }

    # ── VM health (optional) ─────────────────────────────────────────────────
    $vmResults = @()
    if ($IncludeVMs) {
        try {
            $vmGroups = Get-ClusterGroup -ErrorAction SilentlyContinue |
                        Where-Object GroupType -eq 'VirtualMachine'
            $vmResults = foreach ($vm in $vmGroups) {
                $healthy = $vm.State -eq 'Online'
                if (-not $healthy) {
                    $issues.Add("VM '$($vm.Name)' is $($vm.State).")
                    $score -= 5
                }
                [PSCustomObject]@{
                    Name      = $vm.Name
                    State     = $vm.State.ToString()
                    OwnerNode = $vm.OwnerNode.Name
                    Healthy   = $healthy
                }
            }
        }
        catch {
            Write-HVLog -Message "VM health query failed: $($_.Exception.Message)" -Level 'WARN'
        }
    }

    if ($score -lt 0) { $score = 0 }

    $overall = switch ($true) {
        ($score -ge 80) { 'Healthy'; break }
        ($score -ge 50) { 'Warning'; break }
        default          { 'Critical' }
    }

    Write-HVLog -Message "Cluster health: $overall (Score=$score, Issues=$($issues.Count))" -Level $(if ($overall -eq 'Healthy') { 'INFO' } elseif ($overall -eq 'Warning') { 'WARN' } else { 'ERROR' })

    return [PSCustomObject]@{
        ClusterName = $cluster.Name
        Overall     = $overall
        Score       = [int]$score
        Nodes       = $nodeResults.ToArray()
        Resources   = $resResults.ToArray()
        CSVs        = $csvResults.ToArray()
        Quorum      = $quorumResult
        VMs         = $vmResults
        Details     = $issues.ToArray()
        Timestamp   = (Get-Date).ToString('o')
    }
}
