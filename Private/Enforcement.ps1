function Set-HVWitness {
    <#
    .SYNOPSIS
        Configures the cluster quorum witness based on the desired witness type.
        Supports: Disk, Cloud (Azure Blob), Share (file-share), None.
    .PARAMETER WitnessType
        One of: None | Disk | Cloud | Share
    .PARAMETER CloudWitnessStorageAccount
        Azure storage account name (required when WitnessType='Cloud').
    .PARAMETER CloudWitnessStorageKey
        Azure storage account access key (required when WitnessType='Cloud').
    .PARAMETER FileShareWitnessPath
        UNC path to the file share (required when WitnessType='Share').
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('None','Disk','Cloud','Share')][string]$WitnessType,
        [string]$CloudWitnessStorageAccount,
        [string]$CloudWitnessStorageKey,
        [string]$FileShareWitnessPath
    )

    $quorum = Get-ClusterQuorum -ErrorAction SilentlyContinue
    Write-HVLog -Message "Current quorum type: $($quorum.QuorumType)" -Level 'INFO'

    switch ($WitnessType) {

        'None' {
            Write-HVLog -Message "Setting quorum to NodeMajority (no witness)." -Level 'INFO'
            Set-ClusterQuorum -NodeMajority -ErrorAction Stop
        }

        'Disk' {
            $acceptable = @('NodeAndDiskMajority', 'Disk')
            if ($acceptable | Where-Object { $quorum.QuorumType -match $_ }) {
                Write-HVLog -Message "Disk witness already configured. Skipping." -Level 'INFO'
                return
            }
            Write-HVLog -Message "Configuring disk witness..." -Level 'WARN'
            $disk = Get-ClusterAvailableDisk -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $disk) {
                throw "No available disk found for disk witness. Ensure a shared disk is presented to all nodes and visible as available."
            }
            $added = Add-ClusterDisk -InputObject $disk -PassThru -ErrorAction Stop
            Set-ClusterQuorum -NodeAndDiskMajority $added.Name -ErrorAction Stop
            Write-HVLog -Message "Disk witness configured: $($added.Name)." -Level 'INFO'
        }

        'Cloud' {
            if (-not $CloudWitnessStorageAccount -or -not $CloudWitnessStorageKey) {
                throw "WitnessType='Cloud' requires -CloudWitnessStorageAccount and -CloudWitnessStorageKey."
            }
            $acceptable = @('Cloud', 'CloudWitness')
            if ($acceptable | Where-Object { $quorum.QuorumType -match $_ }) {
                Write-HVLog -Message "Cloud witness already configured. Skipping." -Level 'INFO'
                return
            }
            Write-HVLog -Message "Configuring Cloud witness (account: $CloudWitnessStorageAccount)..." -Level 'WARN'
            # Set-ClusterQuorum -CloudWitness is available on WS2016+
            Set-ClusterQuorum -CloudWitness -AccountName $CloudWitnessStorageAccount -AccessKey $CloudWitnessStorageKey -ErrorAction Stop
            Write-HVLog -Message "Cloud witness configured." -Level 'INFO'
        }

        'Share' {
            if (-not $FileShareWitnessPath) {
                throw "WitnessType='Share' requires -FileShareWitnessPath (UNC path e.g. \\\\fileserver\\witness)."
            }
            if (-not (Test-Path $FileShareWitnessPath -ErrorAction SilentlyContinue)) {
                throw "File share witness path not reachable: '$FileShareWitnessPath'."
            }
            $acceptable = @('NodeAndFileShareMajority', 'FileShareMajority', 'FileShare')
            if ($acceptable | Where-Object { $quorum.QuorumType -match $_ }) {
                Write-HVLog -Message "File share witness already configured. Skipping." -Level 'INFO'
                return
            }
            Write-HVLog -Message "Configuring file share witness: $FileShareWitnessPath" -Level 'WARN'
            Set-ClusterQuorum -NodeAndFileShareMajority $FileShareWitnessPath -ErrorAction Stop
            Write-HVLog -Message "File share witness configured." -Level 'INFO'
        }
    }
}

function Add-HVMissingNodes {
    <#
    .SYNOPSIS
        Adds any desired nodes that are not currently cluster members.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$DesiredNodes
    )

    $currentNodes = @(Get-ClusterNode -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    $toAdd = $DesiredNodes | Where-Object { $currentNodes -notcontains $_ }

    foreach ($node in $toAdd) {
        Write-HVLog -Message "Adding node '$node' to cluster..." -Level 'WARN'
        Add-ClusterNode -Name $node -ErrorAction Stop
        Write-HVLog -Message "Node '$node' added successfully." -Level 'INFO'
    }

    if (-not $toAdd) {
        Write-HVLog -Message "All desired nodes already present in cluster." -Level 'INFO'
    }
}

function Invoke-HVEnforcement {
    <#
    .SYNOPSIS
        Applies the desired cluster state. Creates the cluster if absent, adds missing nodes,
        and configures the witness. On failure, triggers the rollback engine.
    .PARAMETER Desired
        Desired state object from New-HVDesiredState.
    .PARAMETER ClusterIP
        Static IP for the cluster name object (CNO).
    .PARAMETER SnapshotPath
        Path to the pre-enforcement snapshot (used for rollback on failure).
    .PARAMETER CloudWitnessStorageAccount
        Azure storage account name (only for Cloud witness).
    .PARAMETER CloudWitnessStorageKey
        Azure storage account access key (only for Cloud witness).
    .PARAMETER FileShareWitnessPath
        UNC path (only for Share witness).
    .OUTPUTS
        $true on success. Throws on failure after attempting rollback.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Desired,
        [Parameter(Mandatory)][string]$ClusterIP,
        [Parameter(Mandatory)][string]$SnapshotPath,
        [string]$CloudWitnessStorageAccount,
        [string]$CloudWitnessStorageKey,
        [string]$FileShareWitnessPath
    )

    try {
        # --- Step 1: Create cluster if absent ---
        $existing = Get-Cluster -ErrorAction SilentlyContinue
        if (-not $existing) {
            Write-HVLog -Message "Cluster not found. Creating '$($Desired.ClusterName)' with nodes: $($Desired.Nodes -join ', ')..." -Level 'WARN'
            New-Cluster -Name $Desired.ClusterName -Node $Desired.Nodes -StaticAddress $ClusterIP -NoStorage -ErrorAction Stop
            Write-HVLog -Message "Cluster '$($Desired.ClusterName)' created." -Level 'INFO'
        }
        else {
            Write-HVLog -Message "Cluster '$($existing.Name)' exists. Checking node membership..." -Level 'INFO'
            # --- Step 2: Add any missing nodes ---
            Add-HVMissingNodes -DesiredNodes $Desired.Nodes
        }

        # --- Step 3: Configure witness ---
        $witnessParams = @{ WitnessType = $Desired.WitnessType }
        if ($CloudWitnessStorageAccount) { $witnessParams['CloudWitnessStorageAccount'] = $CloudWitnessStorageAccount }
        if ($CloudWitnessStorageKey)     { $witnessParams['CloudWitnessStorageKey']     = $CloudWitnessStorageKey     }
        if ($FileShareWitnessPath)       { $witnessParams['FileShareWitnessPath']       = $FileShareWitnessPath       }
        Set-HVWitness @witnessParams

        Write-HVLog -Message "Enforcement completed successfully." -Level 'INFO'
        return $true
    }
    catch {
        Write-HVLog -Message "Enforcement FAILED: $($_.Exception.Message)" -Level 'ERROR'
        Write-HVLog -Message "Attempting rollback using snapshot: $SnapshotPath" -Level 'WARN'
        try {
            Restore-HVClusterSnapshot -SnapshotPath $SnapshotPath
        }
        catch {
            Write-HVLog -Message "Rollback also failed: $($_.Exception.Message)" -Level 'ERROR'
        }
        throw
    }
}
