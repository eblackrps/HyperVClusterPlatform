function Restore-HVClusterSnapshot {
    <#
    .SYNOPSIS
        Attempts to restore cluster state toward what was captured in a pre-enforcement snapshot.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$SnapshotPath,
        [string]$JournalPath = '',
        [switch]$Force
    )

    $actions = [System.Collections.Generic.List[string]]::new()
    $errors  = [System.Collections.Generic.List[string]]::new()

    Write-HVLog -Message '=== ROLLBACK INITIATED ===' -Level 'WARN'
    Write-HVLog -Message "Snapshot: $SnapshotPath" -Level 'WARN'
    if ($JournalPath) {
        Write-HVLog -Message "Journal: $JournalPath" -Level 'WARN'
    }

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

    $journal = $null
    if ($JournalPath -and (Test-Path $JournalPath)) {
        try {
            $journal = Get-Content -Path $JournalPath -Raw -ErrorAction Stop | ConvertFrom-Json
        }
        catch {
            $errors.Add("Could not parse journal '$JournalPath': $($_.Exception.Message)")
        }
    }

    $clusterExistedBefore = [bool]$snap.ClusterExistedBefore
    Write-HVLog -Message "Snapshot timestamp: $($snap.Timestamp). ClusterExistedBefore: $clusterExistedBefore" -Level 'INFO'

    try {
        $currentCluster = Get-Cluster -ErrorAction SilentlyContinue

        if (-not $currentCluster) {
            Write-HVLog -Message 'No cluster currently exists. Nothing to roll back.' -Level 'INFO'
            $actions.Add('No cluster found; rollback complete.')
            return [PSCustomObject]@{ Success = $true; Actions = $actions.ToArray(); Errors = $errors.ToArray() }
        }

        if ($journal -and $journal.Entries) {
            foreach ($entry in @($journal.Entries | Sort-Object Timestamp -Descending)) {
                switch ($entry.Action) {
                    'SetWitness' {
                        $previousType = [string]$entry.Data.PreviousType
                        $previousResource = [string]$entry.Data.PreviousResource
                        try {
                            if ($previousType -eq 'None') {
                                if ($PSCmdlet.ShouldProcess('cluster quorum', 'Rollback to NodeMajority')) {
                                    Set-HVWitness -WitnessType None -WhatIf:$WhatIfPreference | Out-Null
                                }
                            }
                            elseif ($previousType -eq 'Disk') {
                                if ($PSCmdlet.ShouldProcess($previousResource, 'Rollback disk witness')) {
                                    Set-HVWitness -WitnessType Disk -WitnessDiskName $previousResource -WhatIf:$WhatIfPreference | Out-Null
                                }
                            }
                            elseif ($previousType -eq 'Share') {
                                $targetShare = if ($previousResource) { $previousResource } else { [string]$entry.Data.FileSharePath }
                                if ($PSCmdlet.ShouldProcess($targetShare, 'Rollback file share witness')) {
                                    Set-HVWitness -WitnessType Share -FileShareWitnessPath $targetShare -WhatIf:$WhatIfPreference | Out-Null
                                }
                            }
                            elseif ($previousType -eq 'Cloud') {
                                $accountName = [string]$entry.Data.CloudAccount
                                if (-not [string]::IsNullOrWhiteSpace($accountName)) {
                                    $actions.Add("Cloud witness was previously configured for account '$accountName'. Manual validation is recommended because the access key is not persisted in the journal.")
                                }
                                else {
                                    $actions.Add('Cloud witness was previously configured. Manual validation is recommended because the access key is not persisted in the journal.')
                                }
                            }
                            $actions.Add("Processed witness rollback for previous type '$previousType'.")
                        }
                        catch {
                            $err = "Failed to roll back witness: $($_.Exception.Message)"
                            $errors.Add($err)
                            Write-HVLog -Message $err -Level 'ERROR'
                        }
                    }

                    'AddNode' {
                        $nodeName = [string]$entry.Data.NodeName
                        try {
                            if ($PSCmdlet.ShouldProcess($nodeName, 'Remove cluster node added during failed enforcement')) {
                                Remove-ClusterNode -Name $nodeName -Force:$Force -ErrorAction Stop
                            }
                            $actions.Add("Removed node '$nodeName' from cluster.")
                        }
                        catch {
                            $err = "Failed to remove node '$nodeName': $($_.Exception.Message)"
                            $errors.Add($err)
                            Write-HVLog -Message $err -Level 'ERROR'
                        }
                    }

                    'CreateCluster' {
                        try {
                            if ($PSCmdlet.ShouldProcess($currentCluster.Name, 'Remove cluster created during failed enforcement')) {
                                Remove-Cluster -Cluster $currentCluster.Name -Force:$Force -CleanUpAD -ErrorAction Stop
                            }
                            $actions.Add("Removed cluster '$($currentCluster.Name)' (created during failed enforcement).")
                            $currentCluster = $null
                        }
                        catch {
                            $err = "Failed to remove cluster '$($currentCluster.Name)': $($_.Exception.Message)"
                            $errors.Add($err)
                            Write-HVLog -Message $err -Level 'ERROR'
                        }
                    }
                }
            }
        }
        elseif (-not $clusterExistedBefore) {
            if ($PSCmdlet.ShouldProcess($currentCluster.Name, 'Remove cluster created during failed enforcement')) {
                Remove-Cluster -Cluster $currentCluster.Name -Force:$Force -CleanUpAD -ErrorAction Stop
            }
            $actions.Add("Removed cluster '$($currentCluster.Name)' (did not exist in snapshot).")
            Write-HVLog -Message "Cluster '$($currentCluster.Name)' removed." -Level 'WARN'
        }
        else {
            $snapshotNodeNames = @()
            if ($snap.Nodes) {
                $snapshotNodeNames = @($snap.Nodes | ForEach-Object { $_.Name } | Where-Object { $_ })
            }

            $currentNodes = @(Get-ClusterNode -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
            $addedNodes = @($currentNodes | Where-Object { $snapshotNodeNames -notcontains $_ })

            foreach ($nodeName in $addedNodes) {
                try {
                    if ($PSCmdlet.ShouldProcess($nodeName, 'Remove cluster node absent from snapshot')) {
                        Remove-ClusterNode -Name $nodeName -Force:$Force -ErrorAction Stop
                    }
                    $actions.Add("Removed node '$nodeName' from cluster.")
                }
                catch {
                    $err = "Failed to remove node '$nodeName': $($_.Exception.Message)"
                    $errors.Add($err)
                    Write-HVLog -Message $err -Level 'ERROR'
                }
            }

            if ($addedNodes.Count -eq 0) {
                $actions.Add('No node changes to reverse.')
            }

            if ($snap.Quorum -and $snap.Quorum.QuorumType) {
                $actions.Add("Quorum type at snapshot: '$($snap.Quorum.QuorumType)' - verify manually.")
            }
        }
    }
    catch {
        $err = "Rollback error: $($_.Exception.Message)"
        $errors.Add($err)
        Write-HVLog -Message $err -Level 'ERROR'
    }

    $success = ($errors.Count -eq 0)
    $status = if ($success) { 'COMPLETE' } else { 'PARTIAL (see errors)' }
    Write-HVLog -Message "=== ROLLBACK $status - $($actions.Count) action(s), $($errors.Count) error(s) ===" -Level $(if ($success) { 'WARN' } else { 'ERROR' })

    return [PSCustomObject]@{
        Success = $success
        Actions = $actions.ToArray()
        Errors  = $errors.ToArray()
    }
}
