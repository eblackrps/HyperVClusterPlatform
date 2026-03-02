function Invoke-HVClusterPlatform {
    <#
    .SYNOPSIS
        Main entry point for the HyperVClusterPlatform module.
        Supports Audit, Enforce, and Remediate modes for Hyper-V failover cluster lifecycle.
        Compatible with Windows Server 2022 and Windows Server 2025.

    .DESCRIPTION
        Execution flow:
          1. Load config file (optional) and merge with direct parameters.
          2. Initialize file-based logging.
          3. Detect OS version profile (WS2022 / WS2025).
          4. Run pre-flight checks: admin rights, OS version, features, domain membership.
          5. Validate per-node readiness: WinRM, features, domain.
          6. Build desired state object.
          7. Capture pre-change snapshot (JSON).
          8. Read current cluster state and compute drift score.
          9. Generate compliance HTML report.
         10. Enforce / Remediate: create cluster, add nodes, configure witness.
         11. Re-assess drift post-enforcement and generate updated report.

    .PARAMETER ClusterName
        Desired name for the cluster (becomes the CNO in Active Directory).

    .PARAMETER Nodes
        Array of node hostnames that should be cluster members.

    .PARAMETER ClusterIP
        Static IP address assigned to the cluster name object.

    .PARAMETER WitnessType
        Quorum witness type: None | Disk | Cloud | Share.

    .PARAMETER Mode
        Audit (read-only, default) | Enforce (apply changes) | Remediate (alias for Enforce).

    .PARAMETER ReportsPath
        Directory for HTML reports and JSON snapshots. Default: <ModuleRoot>\..\Reports

    .PARAMETER LogPath
        Directory for rotating .log files. Default: <ModuleRoot>\..\Logs

    .PARAMETER ConfigFile
        Optional path to a JSON config file. File values are defaults; CLI params override them.

    .PARAMETER Environment
        Environment name for the config file's 'Environments' block (e.g. Prod, Staging).

    .PARAMETER SkipPreFlight
        Skip local machine pre-flight checks (admin, OS, features, domain).

    .PARAMETER SkipNodeValidation
        Skip per-node WinRM / feature / domain validation (faster, less safe).

    .PARAMETER CloudWitnessStorageAccount
        Azure storage account name. Required when WitnessType='Cloud'.

    .PARAMETER CloudWitnessStorageKey
        Azure storage account access key. Required when WitnessType='Cloud'.

    .PARAMETER FileShareWitnessPath
        UNC path to a file share. Required when WitnessType='Share'.

    .EXAMPLE
        Invoke-HVClusterPlatform -ClusterName "ProdCluster" -Nodes @("NODE1","NODE2") `
            -ClusterIP "10.10.10.10" -WitnessType Disk -Mode Audit

    .EXAMPLE
        Invoke-HVClusterPlatform -ClusterName "ProdCluster" -Nodes @("NODE1","NODE2","NODE3") `
            -ClusterIP "10.10.10.10" -WitnessType Cloud -Mode Enforce `
            -CloudWitnessStorageAccount "mystorageacct" -CloudWitnessStorageKey "base64key=="

    .EXAMPLE
        Invoke-HVClusterPlatform -ConfigFile .\Config\prod.json -Environment Prod -Mode Enforce

    .OUTPUTS
        PSCustomObject with: Mode, DriftScore, DriftDetails, ReportPath, SnapshotPath,
        PreFlightPassed, NodeValidationResults, LogPath, OSProfile.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Direct')]
    param(
        [Parameter(ParameterSetName = 'Direct',     Mandatory)][string]$ClusterName,
        [Parameter(ParameterSetName = 'Direct',     Mandatory)][string[]]$Nodes,
        [Parameter(ParameterSetName = 'Direct',     Mandatory)][string]$ClusterIP,
        [Parameter(ParameterSetName = 'Direct',     Mandatory)]
        [Parameter(ParameterSetName = 'ConfigFile')]
        [ValidateSet('None','Disk','Cloud','Share')][string]$WitnessType,

        [Parameter(ParameterSetName = 'ConfigFile', Mandatory)][string]$ConfigFile,
        [Parameter(ParameterSetName = 'ConfigFile')][string]$Environment = '',

        [ValidateSet('Audit','Enforce','Remediate')][string]$Mode        = 'Audit',
        [string]$ReportsPath                  = '',
        [string]$LogPath                      = '',
        [string]$CloudWitnessStorageAccount   = '',
        [string]$CloudWitnessStorageKey       = '',
        [string]$FileShareWitnessPath         = '',
        [switch]$SkipPreFlight,
        [switch]$SkipNodeValidation
    )

    # ── 0. Load and merge config file ──────────────────────────────────────────
    if ($ConfigFile) {
        $cfg = Import-HVClusterConfig -ConfigPath $ConfigFile -Environment $Environment
        if (-not $ClusterName)  { $ClusterName  = $cfg.ClusterName  }
        if (-not $Nodes)        { $Nodes        = $cfg.Nodes        }
        if (-not $ClusterIP)    { $ClusterIP    = $cfg.ClusterIP    }
        if (-not $WitnessType)  { $WitnessType  = $cfg.WitnessType  }
        if ($Mode -eq 'Audit' -and $cfg.Mode)  { $Mode = $cfg.Mode  }
        if (-not $ReportsPath -and $cfg.ReportsPath) { $ReportsPath = $cfg.ReportsPath }
        if (-not $LogPath     -and $cfg.LogPath)     { $LogPath     = $cfg.LogPath     }
        if (-not $CloudWitnessStorageAccount -and $cfg.CloudWitnessStorageAccount) { $CloudWitnessStorageAccount = $cfg.CloudWitnessStorageAccount }
        if (-not $CloudWitnessStorageKey     -and $cfg.CloudWitnessStorageKey)     { $CloudWitnessStorageKey     = $cfg.CloudWitnessStorageKey     }
        if (-not $FileShareWitnessPath       -and $cfg.FileShareWitnessPath)       { $FileShareWitnessPath       = $cfg.FileShareWitnessPath       }
        if (-not $SkipPreFlight.IsPresent    -and $cfg.SkipPreFlight)  { $SkipPreFlight     = [switch]$true }
        if (-not $SkipNodeValidation.IsPresent -and $cfg.SkipNodeValidation) { $SkipNodeValidation = [switch]$true }
    }

    if (-not $ReportsPath) { $ReportsPath = Join-Path $PSScriptRoot '..\Reports' }
    if (-not $LogPath)     { $LogPath     = Join-Path $PSScriptRoot '..\Logs'    }

    # ── 1. Initialize logging ──────────────────────────────────────────────────
    Initialize-HVLogging -LogPath $LogPath

    Write-HVLog -Message "=== HyperVClusterPlatform v8.0.0 ===" -Level 'INFO'
    Write-HVLog -Message "Mode=$Mode  Cluster=$ClusterName  Witness=$WitnessType  Nodes=[$($Nodes -join ',')]" -Level 'INFO'

    $result = [ordered]@{
        Mode                  = $Mode
        DriftScore            = 100
        DriftDetails          = @()
        ReportPath            = $null
        SnapshotPath          = $null
        PreFlightPassed       = $true
        NodeValidationResults = @()
        LogPath               = $null
        OSProfile             = $null
    }

    # ── 2. OS detection ────────────────────────────────────────────────────────
    $osProfile        = Get-HVOSProfile
    $result.OSProfile = $osProfile

    # ── 3. Pre-flight checks ───────────────────────────────────────────────────
    if (-not $SkipPreFlight) {
        $pf = Test-HVPrerequisites -RequiredNodes $Nodes
        $result.PreFlightPassed = $pf.Passed
        if (-not $pf.Passed) {
            Write-HVLog -Message "Pre-flight FAILED. Aborting run." -Level 'ERROR'
            $result.DriftDetails = $pf.Failures
            $result.LogPath      = Get-HVLogPath
            return [PSCustomObject]$result
        }
    }
    else {
        Write-HVLog -Message "Pre-flight checks skipped (-SkipPreFlight)." -Level 'WARN'
    }

    # ── 4. Node validation ─────────────────────────────────────────────────────
    if (-not $SkipNodeValidation) {
        $nodeResults                  = Test-HVNodeReadiness -Nodes $Nodes
        $result.NodeValidationResults = $nodeResults
        $failedNodes = @($nodeResults | Where-Object { -not $_.Passed })
        if ($failedNodes.Count -gt 0) {
            $failedNames = ($failedNodes | Select-Object -ExpandProperty NodeName) -join ', '
            Write-HVLog -Message "Node validation FAILED for: $failedNames. Aborting." -Level 'ERROR'
            $result.DriftDetails = @("Node validation failed for: $failedNames")
            $result.LogPath      = Get-HVLogPath
            return [PSCustomObject]$result
        }
    }
    else {
        Write-HVLog -Message "Node validation skipped (-SkipNodeValidation)." -Level 'WARN'
    }

    # ── 5. Build desired state ─────────────────────────────────────────────────
    $desired = New-HVDesiredState -ClusterName $ClusterName -Nodes $Nodes -WitnessType $WitnessType

    # ── 6. Pre-change snapshot ─────────────────────────────────────────────────
    $snapshotPath        = New-HVClusterSnapshot -ReportsPath $ReportsPath -Label 'Pre-Enforce'
    $result.SnapshotPath = $snapshotPath

    # ── 7. Drift assessment ────────────────────────────────────────────────────
    $current     = Get-HVClusterCurrentState
    $driftResult = if ($current) {
        Get-HVDriftScore -Desired $desired -Current $current
    }
    else {
        [PSCustomObject]@{ Score = 100; Details = @('No cluster found on this node.') }
    }

    $result.DriftScore   = $driftResult.Score
    $result.DriftDetails = $driftResult.Details

    Write-HVLog -Message "Drift score: $($driftResult.Score)/100" -Level 'INFO'

    # ── 8. Compliance report ───────────────────────────────────────────────────
    $reportPath      = New-HVComplianceReport -DriftResult $driftResult -ReportsPath $ReportsPath `
                           -ClusterName $ClusterName -Mode $Mode -OSProfile $osProfile
    $result.ReportPath = $reportPath
    $result.LogPath    = Get-HVLogPath

    # ── 9. Audit-only path ─────────────────────────────────────────────────────
    if ($Mode -eq 'Audit') {
        Write-HVLog -Message "Audit complete. No changes made." -Level 'INFO'
        return [PSCustomObject]$result
    }

    # ── 10. Already compliant? ─────────────────────────────────────────────────
    if ($driftResult.Score -eq 0) {
        Write-HVLog -Message "Cluster is fully compliant. Enforcement not needed." -Level 'INFO'
        return [PSCustomObject]$result
    }

    # ── 11. Enforce / Remediate ────────────────────────────────────────────────
    $enfParams = @{
        Desired      = $desired
        ClusterIP    = $ClusterIP
        SnapshotPath = $snapshotPath
    }
    if ($CloudWitnessStorageAccount) { $enfParams['CloudWitnessStorageAccount'] = $CloudWitnessStorageAccount }
    if ($CloudWitnessStorageKey)     { $enfParams['CloudWitnessStorageKey']     = $CloudWitnessStorageKey     }
    if ($FileShareWitnessPath)       { $enfParams['FileShareWitnessPath']       = $FileShareWitnessPath       }

    Invoke-HVEnforcement @enfParams | Out-Null

    # ── 12. Post-enforcement drift re-assessment ───────────────────────────────
    $current2     = Get-HVClusterCurrentState
    $driftResult2 = if ($current2) {
        Get-HVDriftScore -Desired $desired -Current $current2
    }
    else {
        [PSCustomObject]@{ Score = 100; Details = @('Cluster not found after enforcement.') }
    }

    $reportPath2          = New-HVComplianceReport -DriftResult $driftResult2 -ReportsPath $ReportsPath `
                                -ClusterName $ClusterName -Mode "$Mode (Post-Enforce)" -OSProfile $osProfile
    $result.DriftScore    = $driftResult2.Score
    $result.DriftDetails  = $driftResult2.Details
    $result.ReportPath    = $reportPath2
    $result.LogPath       = Get-HVLogPath

    Write-HVLog -Message "Post-enforcement drift: $($driftResult2.Score)/100" -Level 'INFO'
    Write-HVLog -Message "=== Run complete ===" -Level 'INFO'

    return [PSCustomObject]$result
}
