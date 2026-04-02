function Export-HVTelemetry {
    <#
    .SYNOPSIS
        Exports structured JSON telemetry for a completed platform run.
        Output is suitable for ingestion by Elastic, Splunk, Azure Monitor, or any
        log aggregation system that accepts JSON events.
    .PARAMETER RunResult
        The PSCustomObject returned by Invoke-HVClusterPlatform or Invoke-HVClusterFleet.
    .PARAMETER OutputPath
        Directory to write the telemetry file. Defaults to .\Reports.
    .PARAMETER AppendToNDJSON
        If specified, appends a single JSON line to this NDJSON file instead of
        writing a dated file. Useful for log shippers (Filebeat, Fluentd).
    .OUTPUTS
        String: path to the written file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$RunResult,
        [string]$OutputPath     = '.\Reports',
        [string]$AppendToNDJSON = ''
    )

    if (-not (Test-Path $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    }

    $telemetryEvent = [ordered]@{
        schema_version    = '1.0'
        timestamp         = (Get-Date).ToString('o')
        host              = $env:COMPUTERNAME
        module            = 'HyperVClusterPlatform'
        module_version    = '21.0.1'
        cluster_name      = if ($RunResult.ClusterName) { $RunResult.ClusterName } elseif ($RunResult.TotalClusters) { 'Fleet' } else { $null }
        mode              = $RunResult.Mode
        drift_score       = $RunResult.DriftScore
        drift_details     = $RunResult.DriftDetails
        preflight_passed  = $RunResult.PreFlightPassed
        os_version        = if ($RunResult.OSProfile) { $RunResult.OSProfile.Version } else { $null }
        os_build          = if ($RunResult.OSProfile) { $RunResult.OSProfile.Build }   else { $null }
        log_path          = $RunResult.LogPath
        report_path       = $RunResult.ReportPath
        snapshot_path     = $RunResult.SnapshotPath
        health_score      = if ($RunResult.HealthScore) { $RunResult.HealthScore } else { $null }
        health_overall    = if ($RunResult.HealthOverall) { $RunResult.HealthOverall } else { $null }
    }

    $json = $telemetryEvent | ConvertTo-Json -Depth 5 -Compress:(-not [string]::IsNullOrEmpty($AppendToNDJSON))

    if ($AppendToNDJSON) {
        Add-Content -Path $AppendToNDJSON -Value $json -Encoding UTF8
        Write-HVLog -Message "Telemetry appended to NDJSON: $AppendToNDJSON" -Level 'INFO'
        return $AppendToNDJSON
    }
    else {
        $path = Join-Path $OutputPath ("Telemetry-{0}.json" -f (Get-Date -Format 'yyyyMMddHHmmss'))
        $json | Out-File -FilePath $path -Encoding UTF8
        Write-HVLog -Message "Telemetry exported: $path" -Level 'INFO'
        return $path
    }
}

function Get-HVDriftTrend {
    <#
    .SYNOPSIS
        Reads all Telemetry-*.json files in the given path and returns a time-ordered
        drift score trend array, suitable for rendering a Chart.js line chart.
    .PARAMETER TelemetryPath
        Directory containing Telemetry-*.json files. Defaults to .\Reports.
    .PARAMETER Last
        Return the N most recent data points. Default: 30.
    .OUTPUTS
        PSCustomObject[]: Timestamp, DriftScore, Mode, ClusterName.
    #>
    [CmdletBinding()]
    param(
        [string]$TelemetryPath = '.\Reports',
        [int]   $Last          = 30
    )

    $files = Get-ChildItem -Path $TelemetryPath -Filter 'Telemetry-*.json' -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending |
             Select-Object -First $Last

    if (-not $files) {
        Write-HVLog -Message "No telemetry files found in '$TelemetryPath'." -Level 'WARN'
        return @()
    }

    $trend = foreach ($f in ($files | Sort-Object LastWriteTime)) {
        try {
            $data = Get-Content $f.FullName -Raw | ConvertFrom-Json
            [PSCustomObject]@{
                Timestamp   = $data.timestamp
                DriftScore  = $data.drift_score
                HealthScore = $data.health_score
                Mode        = $data.mode
                ClusterName = $data.cluster_name
            }
        }
        catch {
            Write-HVLog -Message "Could not parse telemetry file '$($f.Name)': $($_.Exception.Message)" -Level 'WARN'
        }
    }

    return @($trend)
}
