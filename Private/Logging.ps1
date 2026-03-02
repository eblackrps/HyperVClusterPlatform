# Module-scoped log file path. Set by Initialize-HVLogging or defaulted at first Write-HVLog call.
$script:HVLogFile = $null

function Initialize-HVLogging {
    <#
    .SYNOPSIS
        Configures file-based logging for the module. Call once before other functions.
    .PARAMETER LogPath
        Directory where log files are written. Created if it does not exist.
    .PARAMETER MaxLogFiles
        Maximum number of rotated log files to retain. Default: 10.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LogPath,
        [int]$MaxLogFiles = 10
    )

    if (-not (Test-Path $LogPath)) {
        New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
    }

    $script:HVLogFile = Join-Path $LogPath ("HVCluster-{0}.log" -f (Get-Date -Format 'yyyyMMdd'))

    # Rotate: keep only the N most recent log files
    $existing = Get-ChildItem -Path $LogPath -Filter 'HVCluster-*.log' |
                Sort-Object LastWriteTime -Descending |
                Select-Object -Skip $MaxLogFiles
    foreach ($old in $existing) {
        Remove-Item -Path $old.FullName -Force -ErrorAction SilentlyContinue
    }

    Write-HVLog -Message "Logging initialized. Log file: $($script:HVLogFile)" -Level 'INFO'
}

function Write-HVLog {
    <#
    .SYNOPSIS
        Writes a structured, timestamped log entry to the console and optionally to a log file.
    .PARAMETER Message
        The log message text.
    .PARAMETER Level
        Severity: INFO (default), WARN, or ERROR.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line      = "$timestamp [$Level] $Message"

    # Console output with color coding
    $color = switch ($Level) {
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red'    }
        default { 'White'  }
    }
    Write-Host $line -ForegroundColor $color

    # File output (if initialized, auto-flush per line for resilience)
    if ($script:HVLogFile) {
        try {
            Add-Content -Path $script:HVLogFile -Value $line -Encoding UTF8 -ErrorAction Stop
        }
        catch {
            Write-Host "$timestamp [WARN] Could not write to log file: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

function Get-HVLogPath {
    <#
    .SYNOPSIS
        Returns the current log file path, or $null if logging has not been initialized.
    #>
    return $script:HVLogFile
}
