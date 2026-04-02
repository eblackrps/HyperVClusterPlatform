function New-HVComplianceReport {
    <#
    .SYNOPSIS
        Generates an HTML compliance report with drift score, status, and drift detail lines.
    .PARAMETER DriftResult
        PSCustomObject from Get-HVDriftScore with .Score (int) and .Details (string[]).
    .PARAMETER ReportsPath
        Directory where the HTML file is written. Created if absent.
    .PARAMETER ClusterName
        Display name embedded in the report.
    .PARAMETER Mode
        The run mode (Audit / Enforce / Remediate) shown in the report.
    .PARAMETER OSProfile
        OSProfile object from Get-HVOSProfile — shown in the report.
    .OUTPUTS
        String: full path to the generated HTML file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$DriftResult,
        [Parameter(Mandatory)][string]$ReportsPath,
        [string]$ClusterName = '',
        [string]$Mode        = '',
        $OSProfile           = $null
    )

    # Support both legacy int score and new PSCustomObject
    if ($DriftResult -is [int] -or $DriftResult -is [double]) {
        $score  = [int]$DriftResult
        $detail = @()
    }
    else {
        $score  = [int]$DriftResult.Score
        $detail = @($DriftResult.Details)
    }

    $status   = if ($score -eq 0) { 'Compliant' } elseif ($score -lt 50) { 'Minor Drift' } else { 'Critical Drift' }
    $cssClass = if ($score -eq 0) { 'good'       } elseif ($score -lt 50) { 'warn'        } else { 'bad'            }
    $osText   = if ($OSProfile)   { "$($OSProfile.DisplayName) (Build $($OSProfile.Build))" } else { 'N/A' }
    $encode   = [System.Net.WebUtility]

    $detailRows = if ($detail -and $detail.Count -gt 0) {
        $detail | ForEach-Object { "<li>$($encode::HtmlEncode([string]$_))</li>" }
    }
    else {
        @('<li>No drift detected.</li>')
    }
    $detailHtml = $detailRows -join "`n"

    $clusterText = $encode::HtmlEncode([string]$ClusterName)
    $modeText    = $encode::HtmlEncode([string]$Mode)
    $osText      = $encode::HtmlEncode([string]$osText)
    $generated   = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>HyperV Cluster Compliance Report</title>
  <style>
    body       { font-family: Segoe UI, Arial, sans-serif; margin: 32px; background: #f5f5f5; }
    h1         { color: #333; }
    .card      { background: #fff; padding: 24px; border-radius: 8px; box-shadow: 0 1px 4px rgba(0,0,0,.15); max-width: 680px; }
    .meta      { color: #666; font-size: .9em; margin-bottom: 16px; }
    .score     { font-size: 2.5em; font-weight: bold; }
    .good      { color: #2d7a2d; }
    .warn      { color: #b86e00; }
    .bad       { color: #c0392b; }
    .badge     { display:inline-block; padding:3px 10px; border-radius:12px; color:#fff; font-size:.85em; }
    .badge.good{ background:#2d7a2d; }
    .badge.warn{ background:#b86e00; }
    .badge.bad { background:#c0392b; }
    ul         { margin: 8px 0 0 0; padding-left: 20px; }
    li         { margin-bottom: 4px; }
    hr         { border: none; border-top: 1px solid #e0e0e0; margin: 16px 0; }
  </style>
</head>
<body>
  <h1>Hyper-V Cluster Compliance Report</h1>
  <div class="card">
    <div class="meta">
      <strong>Cluster:</strong> $clusterText &nbsp;|&nbsp;
      <strong>Mode:</strong> $modeText &nbsp;|&nbsp;
      <strong>OS:</strong> $osText<br>
      <strong>Generated:</strong> $generated
    </div>
    <hr>
    <p><span class="score $cssClass">$score / 100</span> &nbsp; <span class="badge $cssClass">$status</span></p>
    <p><strong>Drift Detail:</strong></p>
    <ul>
$detailHtml
    </ul>
  </div>
</body>
</html>
"@

    if (-not (Test-Path $ReportsPath)) {
        New-Item -ItemType Directory -Path $ReportsPath -Force | Out-Null
    }

    $path = Join-Path $ReportsPath ("Compliance-{0}.html" -f (Get-Date -Format 'yyyyMMddHHmmss'))
    $html | Out-File -FilePath $path -Encoding UTF8
    Write-HVLog -Message "Compliance report: $path (Score=$score, Status=$status)" -Level 'INFO'
    return $path
}
