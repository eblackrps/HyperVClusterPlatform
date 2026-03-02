function Restore-HVClusterSnapshot {
    <#
    .SYNOPSIS
        Attempts to restore cluster state toward what was captured in a pre-enforcement snapshot.
        The engine uses the snapshot's ClusterExistedBefore flag to decide how aggressive rollback is:

        - ClusterExistedBefore = $false  -> The cluster was created by this run. Destroy it.
        - ClusterExistedBefore = $true   -> The cluster existed. Remove only nodes that were
                                            added during enforcement (diff vs snapshot node list).

        WARNING: Rollback cannot always be perfect (e.g., if cluster creation partially succeeded
        and distributed state exists). This engine takes best-effort action and logs each step.
    .PARAMETER SnapshotPath
        Path to the JSON snapshot file produced by New-HVClusterSnapshot.
    .PARAMETER Force
        Skip confirmation prompts. Needed in automated/unattended contexts.
    .OUTPUTS
        PSCustomObject: Success (bool), Actions (string[]), Errors (string[]).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SnapshotPath,
        [switch]$Force
    )

    $actions = [System.Collections.Generic.List[string]]::new()
    $errors  = [System.Collections.Generic.List[string]]::new()

    Write-HVLog -Message "=== ROLLBACK INITIATED ===" -Level 'WARN'
    Write-HVLog -Message "Snapshot: $SnapshotPath" -Level 'WARN'

    if (-not (Test-Path $SnapshotPath)) {
        $msg = "Snapshot file not found: '$SnapshotPath'. Manual recovery required."
        Write-HVLog -Message $msg -Level 'ERROR'
        throw $msg
    }

    try {
        $snap = Get-Content -Path $SnapshotPath -Raw -ErrorAction Stop | ConvertFrom-Json
    }
    catch {
        $msg = "Failed to parse snapshot file: $($_.Exception.Message)"
        Write-HVLog -Message $msg -Level 'ERROR'
        throw $msg
    }

    $clusterExistedBefore = [bool]$snap.ClusterExistedBefore

    Write-HVLog -Message "Snapshot timestamp: $($snap.Timestamp). ClusterExistedBefore: $clusterExistedBefore" -Level 'INFO'

    try {
        $currentCluster = Get-Cluster -ErrorAction SilentlyContinue

        if (-not $currentCluster) {
            Write-HVLog -Message "No cluster currently exists. Nothing to roll back." -Level 'INFO'
            $actions.Add("No cluster found; rollback complete.")
            return [PSCustomObject]@{ Success = $true; Actions = $actions.ToArray(); Errors = $errors.ToArray() }
        }

        if (-not $clusterExistedBefore) {
            # Cluster was CREATED by this run — destroy it entirely
            Write-HVLog -Message "Cluster '$($currentCluster.Name)' was created by this run. Removing cluster..." -Level 'WARN'
            Remove-Cluster -Cluster $currentCluster.Name -Force:$Force -CleanUpAD -ErrorAction Stop
            $actions.Add("Removed cluster '$($currentCluster.Name)' (did not exist in snapshot).")
            Write-HVLog -Message "Cluster removed." -Level 'WARN'
        }
        else {
            # Cluster existed before — only remove nodes that were added during enforcement
            $snapshotNodeNames = @()
            if ($snap.Nodes) {
                $snapshotNodeNames = @($snap.Nodes | ForEach-Object { $_.Name } | Where-Object { $_ })
            }

            $currentNodes = @(Get-ClusterNode -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
            $addedNodes   = $currentNodes | Where-Object { $snapshotNodeNames -notcontains $_ }

            if ($addedNodes) {
                foreach ($n in $addedNodes) {
                    Write-HVLog -Message "Removing node '$n' (not present in snapshot)..." -Level 'WARN'
                    try {
                        Remove-ClusterNode -Name $n -Force:$Force -ErrorAction Stop
                        $actions.Add("Removed node '$n' from cluster.")
                        Write-HVLog -Message "Node '$n' removed." -Level 'WARN'
                    }
                    catch {
                        $err = "Failed to remove node '$n': $($_.Exception.Message)"
                        $errors.Add($err)
                        Write-HVLog -Message $err -Level 'ERROR'
                    }
                }
            }
            else {
                Write-HVLog -Message "No nodes were added during enforcement; no node removal needed." -Level 'INFO'
                $actions.Add("No node changes to reverse.")
            }

            # Attempt to restore quorum setting
            if ($snap.Quorum -and $snap.Quorum.QuorumType) {
                Write-HVLog -Message "Quorum was '$($snap.Quorum.QuorumType)' before enforcement. Manual review recommended." -Level 'WARN'
                $actions.Add("Quorum type at snapshot: '$($snap.Quorum.QuorumType)' — verify manually.")
            }
        }
    }
    catch {
        $err = "Rollback error: $($_.Exception.Message)"
        $errors.Add($err)
        Write-HVLog -Message $err -Level 'ERROR'
    }

    $success = $errors.Count -eq 0
    $status  = if ($success) { 'COMPLETE' } else { 'PARTIAL (see errors)' }
    Write-HVLog -Message "=== ROLLBACK $status — $($actions.Count) action(s), $($errors.Count) error(s) ===" -Level $(if ($success) { 'WARN' } else { 'ERROR' })

    return [PSCustomObject]@{
        Success = $success
        Actions = $actions.ToArray()
        Errors  = $errors.ToArray()
    }
}
