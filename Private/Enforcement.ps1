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

function Get-HVCurrentQuorumState {
    <#
    .SYNOPSIS
        Returns the current cluster quorum state in a normalized shape.
    #>
    [CmdletBinding()]
    param()

    $quorum = Get-ClusterQuorum -ErrorAction SilentlyContinue
    if (-not $quorum) {
        return [PSCustomObject]@{
            WitnessType     = 'None'
            WitnessResource = ''
            RawQuorumType   = 'Unknown'
        }
    }

    $resource = ''
    if ($quorum.PSObject.Properties.Name -contains 'QuorumResource' -and $null -ne $quorum.QuorumResource) {
        if ($quorum.QuorumResource -is [string]) {
            $resource = $quorum.QuorumResource
        }
        elseif ($quorum.QuorumResource.PSObject.Properties.Name -contains 'Name') {
            $resource = $quorum.QuorumResource.Name
        }
        else {
            $resource = [string]$quorum.QuorumResource
        }
    }

    return [PSCustomObject]@{
        WitnessType     = ConvertTo-HVWitnessType -QuorumType $quorum.QuorumType.ToString()
        WitnessResource = $resource
        RawQuorumType   = $quorum.QuorumType.ToString()
    }
}

function Get-HVChangeJournal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SnapshotPath,
        [Parameter(Mandatory)]$DesiredState
    )

    return [ordered]@{
        SchemaVersion = '1.0'
        Timestamp     = (Get-Date).ToString('o')
        SnapshotPath  = $SnapshotPath
        DesiredState  = $DesiredState
        Entries       = @()
    }
}

function Add-HVChangeJournalEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Journal,
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][hashtable]$Data
    )

    $Journal.Entries += [ordered]@{
        Timestamp = (Get-Date).ToString('o')
        Action    = $Action
        Data      = $Data
    }
}

function Save-HVChangeJournal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Journal,
        [Parameter(Mandatory)][string]$Path
    )

    $Journal | ConvertTo-Json -Depth 12 | Out-File -FilePath $Path -Encoding UTF8
    return $Path
}

function Get-HVEnforcementPlan {
    <#
    .SYNOPSIS
        Builds a human-readable cluster change plan.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Desired,
        [Parameter(Mandatory)][string]$ClusterIP,
        [string]$CloudWitnessStorageAccount,
        [string]$FileShareWitnessPath,
        [string]$WitnessDiskName
    )

    $actions = [System.Collections.Generic.List[object]]::new()
    $existing = Get-Cluster -ErrorAction SilentlyContinue

    if (-not $existing) {
        $actions.Add([PSCustomObject]@{
            Action  = 'CreateCluster'
            Target  = $Desired.ClusterName
            Summary = "Create cluster '$($Desired.ClusterName)' with static IP $ClusterIP."
        })
    }
    elseif ($existing.Name -ne $Desired.ClusterName) {
        return [PSCustomObject]@{
            Blocked       = $true
            BlockedReason = "Connected node belongs to cluster '$($existing.Name)', not '$($Desired.ClusterName)'."
            Actions       = @()
            RequiresChange = $false
        }
    }

    $currentNodes = @(Get-ClusterNode -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    $missingNodes = @($Desired.Nodes | Where-Object { $currentNodes -notcontains $_ })
    foreach ($node in $missingNodes) {
        $actions.Add([PSCustomObject]@{
            Action  = 'AddNode'
            Target  = $node
            Summary = "Add node '$node' to cluster '$($Desired.ClusterName)'."
        })
    }

    $currentQuorum = Get-HVCurrentQuorumState
    $desiredWitnessResource = switch ($Desired.WitnessType) {
        'Disk'  { $WitnessDiskName }
        'Share' { $FileShareWitnessPath }
        default { '' }
    }

    $witnessNeedsChange = ($currentQuorum.WitnessType -ne $Desired.WitnessType)
    if (-not $witnessNeedsChange -and $desiredWitnessResource -and $currentQuorum.WitnessResource) {
        $witnessNeedsChange = ($currentQuorum.WitnessResource -ne $desiredWitnessResource)
    }

    if ($witnessNeedsChange) {
        $target = switch ($Desired.WitnessType) {
            'Cloud' { $CloudWitnessStorageAccount }
            'Disk'  { $WitnessDiskName }
            'Share' { $FileShareWitnessPath }
            default { 'NodeMajority' }
        }

        $actions.Add([PSCustomObject]@{
            Action  = 'SetWitness'
            Target  = $target
            Summary = "Set witness type '$($Desired.WitnessType)' with target '$target'."
        })
    }

    return [PSCustomObject]@{
        Blocked        = $false
        BlockedReason  = ''
        Actions        = $actions.ToArray()
        RequiresChange = ($actions.Count -gt 0)
    }
}

function Set-HVWitness {
    <#
    .SYNOPSIS
        Configures the cluster quorum witness based on the desired witness type.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][ValidateSet('None','Disk','Cloud','Share')][string]$WitnessType,
        [string]$CloudWitnessStorageAccount,
        [string]$CloudWitnessStorageKey,
        [string]$FileShareWitnessPath,
        [string]$WitnessDiskName
    )

    $quorum = Get-HVCurrentQuorumState
    Write-HVLog -Message "Current quorum type: $($quorum.RawQuorumType)" -Level 'INFO'

    switch ($WitnessType) {
        'None' {
            if ($quorum.WitnessType -eq 'None') {
                Write-HVLog -Message 'Node majority is already configured. Skipping witness update.' -Level 'INFO'
                return [PSCustomObject]@{ Changed = $false; WitnessType = 'None'; WitnessResource = '' }
            }

            if ($PSCmdlet.ShouldProcess('cluster quorum', 'Set NodeMajority')) {
                Set-ClusterQuorum -NodeMajority -ErrorAction Stop
            }
            return [PSCustomObject]@{ Changed = $true; WitnessType = 'None'; WitnessResource = '' }
        }

        'Disk' {
            if ([string]::IsNullOrWhiteSpace($WitnessDiskName)) {
                throw "WitnessType='Disk' requires -WitnessDiskName for safe quorum targeting."
            }
            if ($quorum.WitnessType -eq 'Disk' -and $quorum.WitnessResource -eq $WitnessDiskName) {
                Write-HVLog -Message "Disk witness '$WitnessDiskName' already configured. Skipping." -Level 'INFO'
                return [PSCustomObject]@{ Changed = $false; WitnessType = 'Disk'; WitnessResource = $WitnessDiskName }
            }

            $disk = Get-ClusterAvailableDisk -ErrorAction SilentlyContinue |
                Where-Object {
                    ($_.PSObject.Properties.Name -contains 'Name' -and $_.Name -eq $WitnessDiskName) -or
                    ($_.PSObject.Properties.Name -contains 'ResourceName' -and $_.ResourceName -eq $WitnessDiskName)
                } |
                Select-Object -First 1

            $witnessResourceName = $WitnessDiskName
            if (-not $disk) {
                $disk = Get-ClusterResource -Name $WitnessDiskName -ErrorAction SilentlyContinue
                if (-not $disk) {
                    throw "Disk witness '$WitnessDiskName' was not found as an available disk or existing cluster resource."
                }
            }

            if ($PSCmdlet.ShouldProcess($WitnessDiskName, 'Configure disk witness')) {
                if ($disk.PSObject.Properties.Name -contains 'ResourceType' -and $disk.ResourceType -eq 'Physical Disk') {
                    $witnessResourceName = $disk.Name
                }
                else {
                    $added = Add-ClusterDisk -InputObject $disk -PassThru -ErrorAction Stop
                    $witnessResourceName = if ($added -and $added.PSObject.Properties.Name -contains 'Name') { $added.Name } else { $WitnessDiskName }
                }
                Set-ClusterQuorum -NodeAndDiskMajority $witnessResourceName -ErrorAction Stop
            }

            return [PSCustomObject]@{ Changed = $true; WitnessType = 'Disk'; WitnessResource = $witnessResourceName }
        }

        'Cloud' {
            if (-not $CloudWitnessStorageAccount -or -not $CloudWitnessStorageKey) {
                throw "WitnessType='Cloud' requires -CloudWitnessStorageAccount and -CloudWitnessStorageKey."
            }
            if ($quorum.WitnessType -eq 'Cloud') {
                Write-HVLog -Message 'Cloud witness already configured. Re-applying is skipped because the current account identity is not discoverable reliably.' -Level 'INFO'
                return [PSCustomObject]@{ Changed = $false; WitnessType = 'Cloud'; WitnessResource = $CloudWitnessStorageAccount }
            }

            if ($PSCmdlet.ShouldProcess($CloudWitnessStorageAccount, 'Configure cloud witness')) {
                Set-ClusterQuorum -CloudWitness -AccountName $CloudWitnessStorageAccount -AccessKey $CloudWitnessStorageKey -ErrorAction Stop
            }

            return [PSCustomObject]@{ Changed = $true; WitnessType = 'Cloud'; WitnessResource = $CloudWitnessStorageAccount }
        }

        'Share' {
            if (-not $FileShareWitnessPath) {
                throw "WitnessType='Share' requires -FileShareWitnessPath (UNC path like \\\\fileserver\\witness)."
            }
            if ($FileShareWitnessPath -notmatch '^\\\\') {
                throw "WitnessType='Share' requires a UNC path. Got '$FileShareWitnessPath'."
            }
            if (-not (Test-Path $FileShareWitnessPath -ErrorAction SilentlyContinue)) {
                throw "File share witness path not reachable: '$FileShareWitnessPath'."
            }
            if ($quorum.WitnessType -eq 'Share' -and $quorum.WitnessResource -eq $FileShareWitnessPath) {
                Write-HVLog -Message "File share witness '$FileShareWitnessPath' already configured. Skipping." -Level 'INFO'
                return [PSCustomObject]@{ Changed = $false; WitnessType = 'Share'; WitnessResource = $FileShareWitnessPath }
            }

            if ($PSCmdlet.ShouldProcess($FileShareWitnessPath, 'Configure file share witness')) {
                Set-ClusterQuorum -NodeAndFileShareMajority $FileShareWitnessPath -ErrorAction Stop
            }

            return [PSCustomObject]@{ Changed = $true; WitnessType = 'Share'; WitnessResource = $FileShareWitnessPath }
        }
    }
}

function Add-HVMissingNodes {
    <#
    .SYNOPSIS
        Adds any desired nodes that are not currently cluster members.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string[]]$DesiredNodes
    )

    $currentNodes = @(Get-ClusterNode -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    $toAdd = @($DesiredNodes | Where-Object { $currentNodes -notcontains $_ })
    $added = [System.Collections.Generic.List[string]]::new()

    foreach ($node in $toAdd) {
        if ($PSCmdlet.ShouldProcess($node, 'Add cluster node')) {
            Write-HVLog -Message "Adding node '$node' to cluster..." -Level 'WARN'
            Add-ClusterNode -Name $node -ErrorAction Stop
            Write-HVLog -Message "Node '$node' added successfully." -Level 'INFO'
            $added.Add($node)
        }
    }

    if ($toAdd.Count -eq 0) {
        Write-HVLog -Message 'All desired nodes already present in cluster.' -Level 'INFO'
    }

    return $added.ToArray()
}

function Invoke-HVEnforcement {
    <#
    .SYNOPSIS
        Applies the desired cluster state with change journaling and rollback.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]$Desired,
        [Parameter(Mandatory)][string]$ClusterIP,
        [Parameter(Mandatory)][string]$SnapshotPath,
        [string]$CloudWitnessStorageAccount,
        [string]$CloudWitnessStorageKey,
        [string]$FileShareWitnessPath,
        [string]$WitnessDiskName,
        [string]$JournalPath = ''
    )

    $plan = Get-HVEnforcementPlan -Desired $Desired -ClusterIP $ClusterIP `
        -CloudWitnessStorageAccount $CloudWitnessStorageAccount `
        -FileShareWitnessPath $FileShareWitnessPath `
        -WitnessDiskName $WitnessDiskName

    if ($plan.Blocked) {
        throw $plan.BlockedReason
    }

    if (-not $JournalPath) {
        $journalPath = Get-HVArtifactPath -Directory (Split-Path $SnapshotPath -Parent) -Prefix 'Journal' -Extension 'json' -Identity @(
            $Desired.ClusterName
            $Desired.WitnessType
        )
    }

    $journal = Get-HVChangeJournal -SnapshotPath $SnapshotPath -DesiredState $Desired
    Save-HVChangeJournal -Journal $journal -Path $JournalPath | Out-Null

    try {
        $existing = Get-Cluster -ErrorAction SilentlyContinue
        $clusterCreated = $false
        $addedNodes = @()

        if (-not $existing) {
            if ($PSCmdlet.ShouldProcess($Desired.ClusterName, "Create cluster with nodes [$($Desired.Nodes -join ', ')]")) {
                Write-HVLog -Message "Cluster not found. Creating '$($Desired.ClusterName)' with nodes: $($Desired.Nodes -join ', ')..." -Level 'WARN'
                New-Cluster -Name $Desired.ClusterName -Node $Desired.Nodes -StaticAddress $ClusterIP -NoStorage -ErrorAction Stop
                Write-HVLog -Message "Cluster '$($Desired.ClusterName)' created." -Level 'INFO'
                $clusterCreated = $true
                Add-HVChangeJournalEntry -Journal $journal -Action 'CreateCluster' -Data @{
                    ClusterName = $Desired.ClusterName
                    ClusterIP   = $ClusterIP
                }
                Save-HVChangeJournal -Journal $journal -Path $JournalPath | Out-Null
            }
        }
        elseif ($existing.Name -ne $Desired.ClusterName) {
            throw "Connected node belongs to cluster '$($existing.Name)', not '$($Desired.ClusterName)'. Refusing to modify the wrong cluster."
        }
        else {
            Write-HVLog -Message "Cluster '$($existing.Name)' exists. Checking node membership..." -Level 'INFO'
        }

        $addedNodes = Add-HVMissingNodes -DesiredNodes $Desired.Nodes -WhatIf:$WhatIfPreference
        foreach ($node in $addedNodes) {
            Add-HVChangeJournalEntry -Journal $journal -Action 'AddNode' -Data @{ NodeName = $node }
        }
        if ($addedNodes.Count -gt 0) {
            Save-HVChangeJournal -Journal $journal -Path $JournalPath | Out-Null
        }

        $beforeWitness = Get-HVCurrentQuorumState
        $witnessResult = Set-HVWitness -WitnessType $Desired.WitnessType `
            -CloudWitnessStorageAccount $CloudWitnessStorageAccount `
            -CloudWitnessStorageKey $CloudWitnessStorageKey `
            -FileShareWitnessPath $FileShareWitnessPath `
            -WitnessDiskName $WitnessDiskName `
            -WhatIf:$WhatIfPreference

        if ($witnessResult.Changed) {
            Add-HVChangeJournalEntry -Journal $journal -Action 'SetWitness' -Data @{
                PreviousType     = $beforeWitness.WitnessType
                PreviousResource = $beforeWitness.WitnessResource
                NewType          = $witnessResult.WitnessType
                NewResource      = $witnessResult.WitnessResource
                CloudAccount     = $CloudWitnessStorageAccount
                FileSharePath    = $FileShareWitnessPath
                WitnessDiskName  = $WitnessDiskName
            }
            Save-HVChangeJournal -Journal $journal -Path $JournalPath | Out-Null
        }

        Write-HVLog -Message "Enforcement completed successfully. JournalPath=$JournalPath" -Level 'INFO'
        return [PSCustomObject]@{
            Success        = $true
            ClusterCreated = $clusterCreated
            AddedNodes     = $addedNodes
            WitnessChanged = $witnessResult.Changed
            JournalPath    = $JournalPath
            Plan           = $plan
        }
    }
    catch {
        $originalMessage = $_.Exception.Message
        $originalException = $_.Exception

        Write-HVLog -Message "Enforcement FAILED: $originalMessage" -Level 'ERROR'
        Write-HVLog -Message "Attempting rollback using snapshot '$SnapshotPath' and journal '$JournalPath'." -Level 'WARN'
        $rollbackResult = $null
        $rollbackErrors = [System.Collections.Generic.List[string]]::new()
        $rollbackStatus = 'NotAttempted'
        try {
            $rollbackResult = Restore-HVClusterSnapshot -SnapshotPath $SnapshotPath -JournalPath $JournalPath -Force
            $rollbackErrors.AddRange(@($rollbackResult.Errors))
            if ($rollbackResult.Success) {
                $rollbackStatus = 'Succeeded'
            }
            elseif (@($rollbackResult.Actions).Count -gt 0) {
                $rollbackStatus = 'Partial'
            }
            else {
                $rollbackStatus = 'Failed'
            }
        }
        catch {
            Write-HVLog -Message "Rollback also failed: $($_.Exception.Message)" -Level 'ERROR'
            $rollbackErrors.Add($_.Exception.Message)
            $rollbackStatus = 'Failed'
        }

        $wrapped = [System.InvalidOperationException]::new($originalMessage, $originalException)
        $wrapped.Data['JournalPath'] = $JournalPath
        $wrapped.Data['RollbackStatus'] = $rollbackStatus
        $wrapped.Data['RollbackActions'] = if ($rollbackResult) { @($rollbackResult.Actions) } else { @() }
        $wrapped.Data['RollbackErrors'] = $rollbackErrors.ToArray()
        throw $wrapped
    }
}
