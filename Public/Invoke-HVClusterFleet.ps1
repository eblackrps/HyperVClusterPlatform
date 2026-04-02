function Invoke-HVClusterFleet {
    <#
    .SYNOPSIS
        Runs Invoke-HVClusterPlatform against multiple clusters defined in a fleet
        config file or an array of config file paths. Supports parallel execution on PS7+.

    .DESCRIPTION
        Fleet execution flow:
          1. Load fleet config from JSON or accept explicit config file paths.
          2. For each cluster: call Invoke-HVClusterPlatform with its config.
          3. Aggregate all results into a fleet-level summary.
          4. Generate a combined fleet compliance HTML report.
          5. Return structured fleet result object.

    .PARAMETER FleetConfigFile
        Path to a fleet JSON file containing a top-level 'Clusters' array,
        each element being a path to a cluster config file or an inline config object.

    .PARAMETER ConfigFiles
        Array of individual cluster config file paths (alternative to FleetConfigFile).

    .PARAMETER Mode
        Run mode applied to all clusters: Audit (default) | Enforce | Remediate.

    .PARAMETER Environment
        Environment name applied to all cluster configs.

    .PARAMETER ReportsPath
        Directory for fleet reports and per-cluster outputs.

    .PARAMETER LogPath
        Directory for log files.

    .PARAMETER Parallel
        Run clusters in parallel using ForEach-Object -Parallel (requires PowerShell 7+).

    .PARAMETER SkipPreFlight
        Skip pre-flight checks on all clusters.

    .PARAMETER SkipNodeValidation
        Skip per-node WinRM validation on all clusters.

    .OUTPUTS
        PSCustomObject: Mode, TotalClusters, CompliantClusters, FailedClusters,
        AverageDriftScore, Results (object[]), FleetReportPath, Timestamp.

    .EXAMPLE
        Invoke-HVClusterFleet -FleetConfigFile .\Config\fleet.json -Mode Audit

    .EXAMPLE
        Invoke-HVClusterFleet -ConfigFiles @('.\Config\prod1.json','.\Config\prod2.json') -Mode Enforce -Parallel
    #>
    [CmdletBinding(DefaultParameterSetName = 'FleetFile')]
    param(
        [Parameter(ParameterSetName = 'FleetFile', Mandatory)]
        [string]$FleetConfigFile,

        [Parameter(ParameterSetName = 'ConfigList', Mandatory)]
        [string[]]$ConfigFiles,

        [ValidateSet('Audit','Enforce','Remediate')][string]$Mode          = 'Audit',
        [string]$Environment  = '',
        [string]$ReportsPath  = '.\Reports',
        [string]$LogPath      = '.\Logs',
        [switch]$Parallel,
        [switch]$SkipPreFlight,
        [switch]$SkipNodeValidation
    )

    Initialize-HVLogging -LogPath $LogPath
    Write-HVLog -Message "=== HyperVClusterPlatform Fleet v21.0.0 — Mode=$Mode ===" -Level 'INFO'

    # ── Resolve config file list ───────────────────────────────────────────────
    if ($PSCmdlet.ParameterSetName -eq 'FleetFile') {
        if (-not (Test-Path $FleetConfigFile)) {
            throw "Fleet config file not found: '$FleetConfigFile'."
        }
        try {
            $fleet    = Get-Content $FleetConfigFile -Raw | ConvertFrom-Json
            $rawList  = @($fleet.Clusters)
            if ($rawList.Count -eq 0) { throw "Fleet config 'Clusters' array is empty." }

            $ConfigFiles = foreach ($item in $rawList) {
                if ($item -is [string]) {
                    # Relative paths resolved from fleet config's directory
                    $base = Split-Path $FleetConfigFile -Parent
                    Join-Path $base $item
                }
                else {
                    # Inline object: write to temp file and use that
                    $tmp = [System.IO.Path]::GetTempFileName() -replace '\.tmp$','.json'
                    $item | ConvertTo-Json -Depth 5 | Set-Content $tmp
                    $tmp
                }
            }
        }
        catch {
            throw "Failed to parse fleet config '$FleetConfigFile': $($_.Exception.Message)"
        }
    }

    Write-HVLog -Message "Fleet: $($ConfigFiles.Count) cluster config(s) to process." -Level 'INFO'

    # ── Execute per cluster ────────────────────────────────────────────────────
    $commonParams = @{
        Mode               = $Mode
        ReportsPath        = $ReportsPath
        LogPath            = $LogPath
        SkipPreFlight      = $SkipPreFlight
        SkipNodeValidation = $SkipNodeValidation
    }
    if ($Environment) { $commonParams['Environment'] = $Environment }

    if ($Parallel -and $PSVersionTable.PSVersion.Major -ge 7) {
        Write-HVLog -Message "Running clusters in parallel (PS7+ detected)." -Level 'INFO'
        $results = $ConfigFiles | ForEach-Object -Parallel {
            $cf   = $_
            $cp   = $using:commonParams
            Import-Module (Join-Path $using:PSScriptRoot '..\HyperVClusterPlatform.psd1') -Force -ErrorAction SilentlyContinue
            try {
                Invoke-HVClusterPlatform -ConfigFile $cf @cp
            }
            catch {
                [PSCustomObject]@{ ClusterName = $cf; DriftScore = 100; Mode = $cp.Mode;
                    DriftDetails = @($_.Exception.Message); PreFlightPassed = $false;
                    ReportPath = $null; SnapshotPath = $null }
            }
        } -ThrottleLimit 4
    }
    else {
        if ($Parallel) { Write-HVLog -Message "-Parallel requires PowerShell 7+. Running sequentially." -Level 'WARN' }
        $results = foreach ($cf in $ConfigFiles) {
            try {
                Invoke-HVClusterPlatform -ConfigFile $cf @commonParams
            }
            catch {
                Write-HVLog -Message "Cluster config '$cf' failed: $($_.Exception.Message)" -Level 'ERROR'
                [PSCustomObject]@{ ClusterName = $cf; DriftScore = 100; Mode = $Mode;
                    DriftDetails = @($_.Exception.Message); PreFlightPassed = $false;
                    ReportPath = $null; SnapshotPath = $null }
            }
        }
    }

    $resultsArr     = @($results)
    $compliant      = @($resultsArr | Where-Object DriftScore -eq 0).Count
    $failed         = @($resultsArr | Where-Object { $_.DriftScore -gt 0 }).Count
    $avgDrift       = [math]::Round(($resultsArr | Measure-Object -Property DriftScore -Average).Average, 1)

    Write-HVLog -Message "Fleet complete: $($resultsArr.Count) clusters, $compliant compliant, $failed drifted, avg drift $avgDrift." -Level 'INFO'

    # ── Fleet HTML report ──────────────────────────────────────────────────────
    if (-not (Test-Path $ReportsPath)) { New-Item -ItemType Directory -Path $ReportsPath -Force | Out-Null }

    $rows = $resultsArr | ForEach-Object {
        $sc = if ($_.DriftScore -eq 0) { 'good' } elseif ($_.DriftScore -lt 50) { 'warn' } else { 'bad' }
        $cn = if ($_.ClusterName) { $_.ClusterName } else { 'Unknown' }
        "<tr><td>$cn</td><td class='$sc'>$($_.DriftScore)/100</td><td>$($_.Mode)</td><td>$(if ($_.ReportPath){'<a href='+[System.IO.Path]::GetFileName($_.ReportPath)+'>View</a>'}else{'-'})</td></tr>"
    }

    $fleetHtml = @"
<!DOCTYPE html><html lang='en'><head><meta charset='UTF-8'><title>Fleet Report</title>
<style>
body{font-family:Segoe UI,Arial;margin:32px;background:#f5f5f5}
.card{background:#fff;padding:24px;border-radius:8px;box-shadow:0 1px 4px rgba(0,0,0,.15);max-width:760px}
table{width:100%;border-collapse:collapse;margin-top:16px}
th{background:#333;color:#fff;padding:8px 12px;text-align:left}
td{padding:8px 12px;border-bottom:1px solid #eee}
.good{color:#2d7a2d;font-weight:bold}.warn{color:#b86e00;font-weight:bold}.bad{color:#c0392b;font-weight:bold}
</style></head><body>
<div class='card'>
<h1>HyperV Cluster Fleet Report</h1>
<p><strong>Generated:</strong> $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') &nbsp;|&nbsp;
   <strong>Mode:</strong> $Mode &nbsp;|&nbsp;
   <strong>Clusters:</strong> $($resultsArr.Count) &nbsp;|&nbsp;
   <strong>Avg Drift:</strong> $avgDrift</p>
<table><tr><th>Cluster</th><th>Drift Score</th><th>Mode</th><th>Report</th></tr>
$($rows -join "`n")
</table></div></body></html>
"@

    $fleetReport = Join-Path $ReportsPath ("Fleet-{0}.html" -f (Get-Date -Format 'yyyyMMddHHmmss'))
    $fleetHtml | Out-File -FilePath $fleetReport -Encoding UTF8
    Write-HVLog -Message "Fleet report: $fleetReport" -Level 'INFO'

    return [PSCustomObject]@{
        Mode               = $Mode
        TotalClusters      = $resultsArr.Count
        CompliantClusters  = $compliant
        FailedClusters     = $failed
        AverageDriftScore  = $avgDrift
        Results            = $resultsArr
        FleetReportPath    = $fleetReport
        Timestamp          = (Get-Date).ToString('o')
    }
}
