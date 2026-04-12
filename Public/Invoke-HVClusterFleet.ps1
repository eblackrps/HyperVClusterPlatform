function Invoke-HVClusterFleet {
    <#
    .SYNOPSIS
        Runs Invoke-HVClusterPlatform against multiple clusters.
    #>
    [CmdletBinding(DefaultParameterSetName = 'FleetFile', SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(ParameterSetName = 'FleetFile', Mandatory)][string]$FleetConfigFile,
        [Parameter(ParameterSetName = 'ConfigList', Mandatory)][string[]]$ConfigFiles,
        [ValidateSet('Audit','Enforce','Remediate')][string]$Mode = 'Audit',
        [string]$Environment = '',
        [string]$ReportsPath = '.\Reports',
        [string]$LogPath = '.\Logs',
        [switch]$Parallel,
        [switch]$SkipPreFlight,
        [switch]$SkipNodeValidation,
        [switch]$SkipClusterValidation,
        [switch]$BreakGlass,
        [switch]$PlanOnly,
        [switch]$SkipArtifactPersistence,
        [Nullable[bool]]$EmitTelemetry = $null,
        [int]$RetainArtifactCount = 0
    )

    $moduleVersion = Get-HVModuleVersion
    $operationId = Get-HVGeneratedOperationId
    $tempFiles = [System.Collections.Generic.List[string]]::new()
    $tempRoot = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'HyperVClusterPlatform', $operationId)

    if ($RetainArtifactCount -le 0) { $RetainArtifactCount = 30 }
    if (-not $EmitTelemetry.HasValue) { $EmitTelemetry = $true }

    Initialize-HVLogging -LogPath $LogPath -OperationId $operationId
    Write-HVLog -Message "=== HyperVClusterPlatform Fleet v$moduleVersion - Mode=$Mode ===" -Level 'INFO'

    try {
        if ($PSCmdlet.ParameterSetName -eq 'FleetFile') {
            if (-not (Test-Path $FleetConfigFile)) {
                throw "Fleet config file not found: '$FleetConfigFile'."
            }

            $fleet = Get-Content $FleetConfigFile -Raw | ConvertFrom-Json
            $rawList = @($fleet.Clusters)
            if ($rawList.Count -eq 0) {
                throw "Fleet config 'Clusters' array is empty."
            }

            $ConfigFiles = foreach ($item in $rawList) {
                if ($item -is [string]) {
                    $base = Split-Path $FleetConfigFile -Parent
                    Join-Path $base $item
                }
                else {
                    if (-not (Test-Path $tempRoot)) {
                        New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
                    }
                    $tmp = Get-HVArtifactPath -Directory $tempRoot -Prefix 'InlineFleetConfig' -Extension 'json' -Identity @(
                        [string]$item.ClusterName
                    )
                    $item | ConvertTo-Json -Depth 8 | Set-Content -Path $tmp -Encoding UTF8
                    $tempFiles.Add($tmp)
                    $tmp
                }
            }
        }

        Write-HVLog -Message "Fleet: $($ConfigFiles.Count) cluster config(s) to process." -Level 'INFO'

        $commonParams = @{
            Mode                  = $Mode
            ReportsPath           = $ReportsPath
            LogPath               = $LogPath
            SkipPreFlight         = $SkipPreFlight
            SkipNodeValidation    = $SkipNodeValidation
            SkipClusterValidation = $SkipClusterValidation
            BreakGlass            = $BreakGlass
            PlanOnly              = $PlanOnly
            SkipArtifactPersistence = $SkipArtifactPersistence
            EmitTelemetry         = $EmitTelemetry
            RetainArtifactCount   = $RetainArtifactCount
        }
        if ($Environment) { $commonParams['Environment'] = $Environment }

        $shouldRunFleet = $true
        if ($WhatIfPreference -or $ConfirmPreference -ne 'None') {
            try {
                $shouldRunFleet = $PSCmdlet.ShouldProcess("fleet of $($ConfigFiles.Count) cluster(s)", 'Execute fleet run')
            }
            catch {
                Write-HVLog -Message "Fleet ShouldProcess evaluation could not complete: $($_.Exception.Message)" -Level 'WARN'
                $shouldRunFleet = -not $WhatIfPreference
            }
        }

        if (-not $shouldRunFleet) {
            return [PSCustomObject]@{
                Mode                = $Mode
                Status              = 'Previewed'
                OperationId         = $operationId
                TotalClusters       = $ConfigFiles.Count
                SucceededClusters   = 0
                DriftedClusters     = 0
                FailedClusters      = 0
                CompliantClusters   = 0
                AverageDriftScore   = 0
                Results             = @()
                FleetReportPath     = $null
                Timestamp           = (Get-Date).ToString('o')
            }
        }

        if ($Parallel -and $PSVersionTable.PSVersion.Major -ge 7 -and -not $PlanOnly -and -not $WhatIfPreference) {
            Write-HVLog -Message 'Running clusters in parallel (PS7+ detected).' -Level 'INFO'
            $results = $ConfigFiles | ForEach-Object -Parallel {
                $cf = $_
                $cp = $using:commonParams
                Import-Module (Join-Path $using:PSScriptRoot '..\HyperVClusterPlatform.psd1') -Force -ErrorAction SilentlyContinue
                try {
                    Invoke-HVClusterPlatform -ConfigFile $cf @cp
                }
                catch {
                    [PSCustomObject]@{
                        ClusterName   = $cf
                        DriftScore    = 100
                        Mode          = $cp.Mode
                        Status        = 'Failed'
                        DriftDetails  = @($_.Exception.Message)
                        PreFlightPassed = $false
                        ReportPath    = $null
                        SnapshotPath  = $null
                    }
                }
            } -ThrottleLimit 4
        }
        else {
            if ($Parallel -and $PSVersionTable.PSVersion.Major -lt 7) {
                Write-HVLog -Message '-Parallel requires PowerShell 7+. Running sequentially.' -Level 'WARN'
            }
            $results = foreach ($cf in $ConfigFiles) {
                try {
                    Invoke-HVClusterPlatform -ConfigFile $cf @commonParams
                }
                catch {
                    Write-HVLog -Message "Cluster config '$cf' failed: $($_.Exception.Message)" -Level 'ERROR'
                    [PSCustomObject]@{
                        ClusterName     = $cf
                        DriftScore      = 100
                        Mode            = $Mode
                        Status          = 'Failed'
                        DriftDetails    = @($_.Exception.Message)
                        PreFlightPassed = $false
                        ReportPath      = $null
                        SnapshotPath    = $null
                    }
                }
            }
        }

        $resultsArr = @($results)
        $compliant = @($resultsArr | Where-Object { $_.Status -eq 'Compliant' -or $_.Status -eq 'Succeeded' }).Count
        $drifted = @($resultsArr | Where-Object { $_.Status -in @('NonCompliant','DriftRemaining','Planned','Previewed') }).Count
        $failed = @($resultsArr | Where-Object { $_.Status -like 'Failed*' -or $_.Status -eq 'Blocked' }).Count
        $succeeded = @($resultsArr | Where-Object { $_.Status -eq 'Succeeded' }).Count
        $avgDrift = [math]::Round((($resultsArr | Measure-Object -Property DriftScore -Average).Average), 1)

        Write-HVLog -Message "Fleet complete: total=$($resultsArr.Count) succeeded=$succeeded compliant=$compliant drifted=$drifted failed=$failed avg_drift=$avgDrift." -Level 'INFO'

        $fleetReport = $null
        if (-not $SkipArtifactPersistence) {
            if (-not (Test-Path $ReportsPath)) { New-Item -ItemType Directory -Path $ReportsPath -Force | Out-Null }

            $encode = [System.Net.WebUtility]
            $rows = $resultsArr | ForEach-Object {
                $status = if ($_.Status) { $_.Status } else { 'Unknown' }
                $cssClass = switch ($status) {
                    'Succeeded'   { 'good' }
                    'Compliant'   { 'good' }
                    'NonCompliant' { 'warn' }
                    'DriftRemaining' { 'warn' }
                    'Planned'     { 'warn' }
                    'Previewed'   { 'warn' }
                    default       { 'bad' }
                }

                $clusterNameValue = if ($_.ClusterName) { $_.ClusterName } else { 'Unknown' }
                $clusterName = $encode::HtmlEncode([string]$clusterNameValue)
                $modeText = $encode::HtmlEncode([string]$_.Mode)
                $statusText = $encode::HtmlEncode([string]$status)
                $reportLink = if ($_.ReportPath) {
                    $fileName = $encode::HtmlEncode([System.IO.Path]::GetFileName($_.ReportPath))
                    "<a href='$fileName'>View</a>"
                }
                else {
                    '-'
                }

                "<tr><td>$clusterName</td><td class='$cssClass'>$($_.DriftScore)/100</td><td>$modeText</td><td>$statusText</td><td>$reportLink</td></tr>"
            }

            $fleetHtml = @"
<!DOCTYPE html><html lang='en'><head><meta charset='UTF-8'><title>Fleet Report</title>
<style>
body{font-family:Segoe UI,Arial;margin:32px;background:#f5f5f5}
.card{background:#fff;padding:24px;border-radius:8px;box-shadow:0 1px 4px rgba(0,0,0,.15);max-width:860px}
table{width:100%;border-collapse:collapse;margin-top:16px}
th{background:#333;color:#fff;padding:8px 12px;text-align:left}
td{padding:8px 12px;border-bottom:1px solid #eee}
.good{color:#2d7a2d;font-weight:bold}.warn{color:#b86e00;font-weight:bold}.bad{color:#c0392b;font-weight:bold}
</style></head><body>
<div class='card'>
<h1>HyperV Cluster Fleet Report</h1>
<p><strong>Generated:</strong> $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') &nbsp;|&nbsp;
   <strong>Mode:</strong> $Mode &nbsp;|&nbsp;
   <strong>Total:</strong> $($resultsArr.Count) &nbsp;|&nbsp;
   <strong>Avg Drift:</strong> $avgDrift</p>
<table><tr><th>Cluster</th><th>Drift Score</th><th>Mode</th><th>Status</th><th>Report</th></tr>
$($rows -join "`n")
</table></div></body></html>
"@

            $fleetReport = Get-HVArtifactPath -Directory $ReportsPath -Prefix 'Fleet' -Extension 'html' -Identity @(
                $Mode
            )
            $fleetHtml | Out-File -FilePath $fleetReport -Encoding UTF8
            Invoke-HVArtifactRetention -Path $ReportsPath -Filter 'Fleet-*.html' -MaxFiles $RetainArtifactCount
            Write-HVLog -Message "Fleet report: $fleetReport" -Level 'INFO'
        }

        $fleetResult = [PSCustomObject]@{
            Mode              = $Mode
            Status            = if ($failed -gt 0) {
                'Failed'
            }
            elseif ($PlanOnly) {
                'Planned'
            }
            elseif ($Mode -eq 'Audit') {
                if ($drifted -gt 0) { 'NonCompliant' } else { 'Compliant' }
            }
            elseif ($drifted -gt 0) {
                'DriftRemaining'
            }
            else {
                'Succeeded'
            }
            OperationId       = $operationId
            TotalClusters     = $resultsArr.Count
            SucceededClusters = $succeeded
            DriftedClusters   = $drifted
            FailedClusters    = $failed
            CompliantClusters = $compliant
            AverageDriftScore = $avgDrift
            Results           = $resultsArr
            FleetReportPath   = $fleetReport
            Timestamp         = (Get-Date).ToString('o')
            LogPath           = Get-HVLogPath
            StructuredLogPath = Get-HVStructuredLogPath
        }

        if ($EmitTelemetry -and -not $SkipArtifactPersistence) {
            try {
                $fleetResult | Add-Member -NotePropertyName TelemetryPath -NotePropertyValue (
                    Export-HVTelemetry -RunResult $fleetResult -OutputPath $ReportsPath -MaxArtifactsToKeep $RetainArtifactCount
                ) -Force
            }
            catch {
                Write-HVLog -Message "Fleet telemetry export failed: $($_.Exception.Message)" -Level 'WARN'
            }
        }

        return $fleetResult
    }
    finally {
        foreach ($tempFile in $tempFiles) {
            Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
