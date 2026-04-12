function ConvertTo-HVPlainTextValue {
    [CmdletBinding()]
    param($Value)

    if ($Value -is [System.Security.SecureString]) {
        return ConvertFrom-HVSecureString -SecureString $Value
    }

    return [string]$Value
}

function Invoke-HVClusterPlatform {
    <#
    .SYNOPSIS
        Main entry point for the HyperVClusterPlatform module.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Direct', SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(ParameterSetName = 'Direct', Mandatory)][string]$ClusterName,
        [Parameter(ParameterSetName = 'Direct', Mandatory)][string[]]$Nodes,
        [Parameter(ParameterSetName = 'Direct', Mandatory)][string]$ClusterIP,
        [Parameter(ParameterSetName = 'Direct', Mandatory)]
        [Parameter(ParameterSetName = 'ConfigFile')]
        [ValidateSet('None','Disk','Cloud','Share')][string]$WitnessType,

        [Parameter(ParameterSetName = 'ConfigFile', Mandatory)][string]$ConfigFile,
        [Parameter(ParameterSetName = 'ConfigFile')][string]$Environment = '',

        [ValidateSet('Audit','Enforce','Remediate')][string]$Mode = 'Audit',
        [string]$ReportsPath = '',
        [string]$LogPath = '',
        [string]$CloudWitnessStorageAccount = '',
        $CloudWitnessStorageKey = '',
        [string]$FileShareWitnessPath = '',
        [string]$WitnessDiskName = '',
        [switch]$SkipPreFlight,
        [switch]$SkipNodeValidation,
        [switch]$SkipClusterValidation,
        [switch]$BreakGlass,
        [switch]$PlanOnly,
        [switch]$SkipArtifactPersistence,
        [Nullable[bool]]$EmitTelemetry = $null,
        [int]$RetainArtifactCount = 0
    )

    $startedAt = Get-Date
    $operationId = Get-HVGeneratedOperationId
    $moduleVersion = Get-HVModuleVersion
    $modeWasExplicit = $PSBoundParameters.ContainsKey('Mode')

    if ($ConfigFile) {
        $cfg = Import-HVClusterConfig -ConfigPath $ConfigFile -Environment $Environment
        if (Get-Command Resolve-HVConfigSecrets -ErrorAction SilentlyContinue) {
            $cfg = Resolve-HVConfigSecrets -Config $cfg -ThrowOnError
        }

        if (-not $ClusterName) { $ClusterName = $cfg.ClusterName }
        if (-not $Nodes) { $Nodes = $cfg.Nodes }
        if (-not $ClusterIP) { $ClusterIP = $cfg.ClusterIP }
        if (-not $WitnessType) { $WitnessType = $cfg.WitnessType }
        if (-not $modeWasExplicit -and $cfg.Mode) { $Mode = $cfg.Mode }
        if (-not $ReportsPath -and $cfg.ReportsPath) { $ReportsPath = $cfg.ReportsPath }
        if (-not $LogPath -and $cfg.LogPath) { $LogPath = $cfg.LogPath }
        if (-not $CloudWitnessStorageAccount -and $cfg.CloudWitnessStorageAccount) { $CloudWitnessStorageAccount = $cfg.CloudWitnessStorageAccount }
        if (-not $CloudWitnessStorageKey -and $cfg.CloudWitnessStorageKey) { $CloudWitnessStorageKey = $cfg.CloudWitnessStorageKey }
        if (-not $FileShareWitnessPath -and $cfg.FileShareWitnessPath) { $FileShareWitnessPath = $cfg.FileShareWitnessPath }
        if (-not $WitnessDiskName -and $cfg.WitnessDiskName) { $WitnessDiskName = $cfg.WitnessDiskName }
        if (-not $SkipPreFlight.IsPresent -and $cfg.SkipPreFlight) { $SkipPreFlight = [switch]$true }
        if (-not $SkipNodeValidation.IsPresent -and $cfg.SkipNodeValidation) { $SkipNodeValidation = [switch]$true }
        if (-not $SkipClusterValidation.IsPresent -and $cfg.SkipClusterValidation) { $SkipClusterValidation = [switch]$true }
        if (-not $BreakGlass.IsPresent -and $cfg.BreakGlass) { $BreakGlass = [switch]$true }
        if (-not $PlanOnly.IsPresent -and $cfg.PlanOnly) { $PlanOnly = [switch]$true }
        if (-not $SkipArtifactPersistence.IsPresent -and $cfg.SkipArtifactPersistence) { $SkipArtifactPersistence = [switch]$true }
        if ($RetainArtifactCount -le 0 -and $cfg.RetainArtifactCount) { $RetainArtifactCount = [int]$cfg.RetainArtifactCount }
        if (-not $EmitTelemetry.HasValue -and $cfg.PSObject.Properties.Name -contains 'EmitTelemetry') {
            $EmitTelemetry = [bool]$cfg.EmitTelemetry
        }
    }

    if (-not $ReportsPath) { $ReportsPath = Join-Path $PSScriptRoot '..\Reports' }
    if (-not $LogPath) { $LogPath = Join-Path $PSScriptRoot '..\Logs' }
    if ($RetainArtifactCount -le 0) { $RetainArtifactCount = 30 }
    if (-not $EmitTelemetry.HasValue) { $EmitTelemetry = $true }

    if ($SkipArtifactPersistence -and $Mode -in @('Enforce','Remediate')) {
        throw 'SkipArtifactPersistence is only supported for Audit mode because rollback requires a snapshot.'
    }

    Initialize-HVLogging -LogPath $LogPath -OperationId $operationId

    $result = [ordered]@{
        ClusterName             = $ClusterName
        Mode                    = $Mode
        Status                  = 'Started'
        OperationId             = $operationId
        StartedAt               = $startedAt.ToString('o')
        CompletedAt             = $null
        DriftScore              = 100
        DriftDetails            = @()
        ReportPath              = $null
        SnapshotPath            = $null
        JournalPath             = $null
        TelemetryPath           = $null
        PreFlightPassed         = $true
        ClusterValidationPassed = $null
        ClusterValidationStatus = 'NotRun'
        ClusterValidationReport = $null
        NodeValidationResults   = @()
        LogPath                 = $null
        StructuredLogPath       = $null
        OSProfile               = $null
        Plan                    = $null
        RollbackStatus          = 'NotNeeded'
        RollbackActions         = @()
        RollbackErrors          = @()
    }

    try {
        Write-HVLog -Message "=== HyperVClusterPlatform v$moduleVersion ===" -Level 'INFO'
        Write-HVLog -Message "Mode=$Mode Cluster=$ClusterName Witness=$WitnessType Nodes=[$($Nodes -join ',')]" -Level 'INFO'

        do {
            if ($Mode -in @('Enforce','Remediate')) {
                $unsafeSkips = @('SkipPreFlight','SkipNodeValidation','SkipClusterValidation') |
                    Where-Object { (Get-Variable -Name $_ -ValueOnly) }
                if ($unsafeSkips.Count -gt 0 -and -not $BreakGlass) {
                    throw "Unsafe skip flags [$($unsafeSkips -join ', ')] require -BreakGlass for Enforce/Remediate runs."
                }
            }

            $osProfile = Get-HVOSProfile
            $result.OSProfile = $osProfile

            if (-not $SkipPreFlight) {
                $pf = Test-HVPrerequisites -RequiredNodes $Nodes -Mode $Mode `
                    -SkipClusterValidation:$SkipClusterValidation `
                    -BreakGlass:$BreakGlass `
                    -TargetClusterName $ClusterName
                $result.PreFlightPassed = $pf.Passed
                if ($pf.ClusterValidation) {
                    $result.ClusterValidationPassed = $pf.ClusterValidation.Passed
                    $result.ClusterValidationStatus = if ($pf.ClusterValidation.Passed) { 'Passed' } else { 'Failed' }
                    $result.ClusterValidationReport = $pf.ClusterValidation.ReportPath
                }
                elseif ($SkipClusterValidation) {
                    $result.ClusterValidationStatus = 'Skipped'
                }
                if (-not $pf.Passed) {
                    $result.Status = 'FailedPreFlight'
                    $result.DriftDetails = $pf.Failures
                    break
                }
            }
            else {
                Write-HVLog -Message 'Pre-flight checks skipped (-SkipPreFlight).' -Level 'WARN'
                $result.ClusterValidationPassed = $null
                $result.ClusterValidationStatus = 'Skipped'
            }

            if (-not $SkipNodeValidation) {
                $nodeResults = Test-HVNodeReadiness -Nodes $Nodes
                $result.NodeValidationResults = $nodeResults
                $failedNodes = @($nodeResults | Where-Object { -not $_.Passed })
                if ($failedNodes.Count -gt 0) {
                    $failedNames = ($failedNodes | Select-Object -ExpandProperty NodeName) -join ', '
                    Write-HVLog -Message "Node validation FAILED for: $failedNames. Aborting." -Level 'ERROR'
                    $result.Status = 'FailedNodeValidation'
                    $result.DriftDetails = @("Node validation failed for: $failedNames")
                    break
                }
            }
            else {
                Write-HVLog -Message 'Node validation skipped (-SkipNodeValidation).' -Level 'WARN'
            }

            if ($WitnessType -eq 'Cloud' -and -not [string]::IsNullOrWhiteSpace($CloudWitnessStorageKey)) {
                $CloudWitnessStorageKey = if ($CloudWitnessStorageKey -is [System.Security.SecureString]) {
                    $CloudWitnessStorageKey
                }
                else {
                    ConvertTo-HVSecureString -PlainText ([string]$CloudWitnessStorageKey)
                }
            }

            if ($WitnessType -eq 'Cloud' -and (-not $CloudWitnessStorageAccount -or -not $CloudWitnessStorageKey)) {
                throw "WitnessType='Cloud' requires CloudWitnessStorageAccount plus CloudWitnessStorageKey or CloudWitnessStorageKeySecretName."
            }
            if ($WitnessType -eq 'Disk' -and [string]::IsNullOrWhiteSpace($WitnessDiskName)) {
                throw "WitnessType='Disk' requires WitnessDiskName for safe quorum targeting."
            }
            if ($WitnessType -eq 'Share' -and [string]::IsNullOrWhiteSpace($FileShareWitnessPath)) {
                throw "WitnessType='Share' requires FileShareWitnessPath."
            }

            $desired = Get-HVDesiredState -ClusterName $ClusterName -Nodes $Nodes -WitnessType $WitnessType `
                -WitnessDiskName $WitnessDiskName -FileShareWitnessPath $FileShareWitnessPath

            $current = Get-HVClusterCurrentState
            $driftResult = if ($current) {
                Get-HVDriftScore -Desired $desired -Current $current
            }
            else {
                [PSCustomObject]@{ Score = 100; Details = @('No cluster found on this node.') }
            }

            $result.DriftScore = $driftResult.Score
            $result.DriftDetails = $driftResult.Details
            $result.Plan = Get-HVEnforcementPlan -Desired $desired -ClusterIP $ClusterIP `
                -CloudWitnessStorageAccount $CloudWitnessStorageAccount `
                -FileShareWitnessPath $FileShareWitnessPath `
                -WitnessDiskName $WitnessDiskName

            if (-not $SkipArtifactPersistence) {
                $result.SnapshotPath = Export-HVClusterSnapshot -ReportsPath $ReportsPath -Label 'Pre-Enforce' -ClusterName $ClusterName -MaxArtifactsToKeep $RetainArtifactCount
                $result.ReportPath = Export-HVComplianceReport -DriftResult $driftResult -ReportsPath $ReportsPath `
                    -ClusterName $ClusterName -Mode $Mode -OSProfile $osProfile -MaxArtifactsToKeep $RetainArtifactCount
            }

            if ($Mode -eq 'Audit') {
                $result.Status = if ($driftResult.Score -eq 0) { 'Compliant' } else { 'NonCompliant' }
                if ($PlanOnly) { $result.Status = 'Planned' }
                break
            }

            if ($result.Plan.Blocked) {
                $result.Status = 'Blocked'
                $result.DriftDetails = @($result.DriftDetails + $result.Plan.BlockedReason | Where-Object { $_ })
                break
            }

            if (-not $result.Plan.RequiresChange) {
                Write-HVLog -Message 'Cluster is fully compliant. Enforcement not needed.' -Level 'INFO'
                $result.Status = 'Compliant'
                break
            }

            if ($PlanOnly) {
                Write-HVLog -Message 'PlanOnly requested. Returning change plan without making changes.' -Level 'INFO'
                $result.Status = 'Planned'
                break
            }

            if (-not $PSCmdlet.ShouldProcess($ClusterName, 'Apply planned Hyper-V cluster changes')) {
                $result.Status = 'Previewed'
                break
            }

            $enforcement = Invoke-HVEnforcement -Desired $desired -ClusterIP $ClusterIP -SnapshotPath $result.SnapshotPath `
                -CloudWitnessStorageAccount $CloudWitnessStorageAccount `
                -CloudWitnessStorageKey (ConvertTo-HVPlainTextValue -Value $CloudWitnessStorageKey) `
                -FileShareWitnessPath $FileShareWitnessPath `
                -WitnessDiskName $WitnessDiskName

            $result.JournalPath = $enforcement.JournalPath

            $current2 = Get-HVClusterCurrentState
            $driftResult2 = if ($current2) {
                Get-HVDriftScore -Desired $desired -Current $current2
            }
            else {
                [PSCustomObject]@{ Score = 100; Details = @('Cluster not found after enforcement.') }
            }

            if (-not $SkipArtifactPersistence) {
                $result.ReportPath = Export-HVComplianceReport -DriftResult $driftResult2 -ReportsPath $ReportsPath `
                    -ClusterName $ClusterName -Mode "$Mode (Post-Enforce)" -OSProfile $osProfile -MaxArtifactsToKeep $RetainArtifactCount
            }

            $result.DriftScore = $driftResult2.Score
            $result.DriftDetails = $driftResult2.Details
            $result.Status = if ($driftResult2.Score -eq 0) { 'Succeeded' } else { 'DriftRemaining' }
            Write-HVLog -Message "Post-enforcement drift: $($driftResult2.Score)/100" -Level 'INFO'
        } while ($false)
    }
    catch {
        Write-HVLog -Message "Platform run FAILED: $($_.Exception.Message)" -Level 'ERROR'
        $result.Status = 'Failed'
        $result.DriftDetails = @($result.DriftDetails + $_.Exception.Message | Where-Object { $_ })

        if ($_.Exception.Data.Contains('JournalPath')) {
            $result.JournalPath = [string]$_.Exception.Data['JournalPath']
        }
        if ($_.Exception.Data.Contains('RollbackStatus')) {
            $result.RollbackStatus = [string]$_.Exception.Data['RollbackStatus']
        }
        if ($_.Exception.Data.Contains('RollbackActions')) {
            $result.RollbackActions = @($_.Exception.Data['RollbackActions'])
        }
        if ($_.Exception.Data.Contains('RollbackErrors')) {
            $result.RollbackErrors = @($_.Exception.Data['RollbackErrors'])
        }
    }
    finally {
        $result.CompletedAt = (Get-Date).ToString('o')
        $result.LogPath = Get-HVLogPath
        $result.StructuredLogPath = Get-HVStructuredLogPath

        if ($EmitTelemetry -and -not $SkipArtifactPersistence) {
            try {
                $result.TelemetryPath = Export-HVTelemetry -RunResult ([PSCustomObject]$result) -OutputPath $ReportsPath -MaxArtifactsToKeep $RetainArtifactCount
            }
            catch {
                Write-HVLog -Message "Telemetry export failed: $($_.Exception.Message)" -Level 'WARN'
            }
        }

        Write-HVLog -Message "=== Run complete. Status=$($result.Status) ===" -Level 'INFO'
    }

    return [PSCustomObject]$result
}
