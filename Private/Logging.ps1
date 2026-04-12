# Module-scoped log state. Set by Initialize-HVLogging or defaulted at first Write-HVLog call.
$script:HVLogFile = $null
$script:HVStructuredLogFile = $null
$script:HVOperationId = $null
$script:HVModuleVersion = $null

function Get-HVModuleVersion {
    <#
    .SYNOPSIS
        Returns the version declared in the module manifest.
    #>
    if ($script:HVModuleVersion) {
        return $script:HVModuleVersion
    }

    $manifestPath = Join-Path $PSScriptRoot '..\HyperVClusterPlatform.psd1'
    try {
        $manifest = Test-ModuleManifest -Path $manifestPath -ErrorAction Stop
        $script:HVModuleVersion = $manifest.Version.ToString()
    }
    catch {
        $script:HVModuleVersion = '0.0.0'
    }

    return $script:HVModuleVersion
}

function Get-HVGeneratedOperationId {
    <#
    .SYNOPSIS
        Generates a run correlation identifier.
    #>
    return ([guid]::NewGuid()).ToString()
}

function Get-HVOperationId {
    <#
    .SYNOPSIS
        Returns the current run correlation identifier.
    #>
    return $script:HVOperationId
}

function ConvertTo-HVArtifactToken {
    <#
    .SYNOPSIS
        Normalizes user-supplied values into safe filename segments.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Value)

    $token = ($Value -replace '[^A-Za-z0-9._-]', '_').Trim('_')
    if ([string]::IsNullOrWhiteSpace($token)) {
        return 'unnamed'
    }

    return $token
}

function Get-HVArtifactPath {
    <#
    .SYNOPSIS
        Builds a unique artifact path for reports, snapshots, journals, and telemetry.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$Prefix,
        [Parameter(Mandatory)][string]$Extension,
        [string[]]$Identity = @()
    )

    $tokens = [System.Collections.Generic.List[string]]::new()
    $tokens.Add((ConvertTo-HVArtifactToken -Value $Prefix))

    foreach ($item in @($Identity | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })) {
        $tokens.Add((ConvertTo-HVArtifactToken -Value ([string]$item)))
    }

    $operationId = Get-HVOperationId
    if ([string]::IsNullOrWhiteSpace($operationId)) {
        $operationId = Get-HVGeneratedOperationId
    }

    $shortOperationId = ((ConvertTo-HVArtifactToken -Value $operationId) -replace '-', '')
    if ($shortOperationId.Length -gt 12) {
        $shortOperationId = $shortOperationId.Substring(0, 12)
    }

    $tokens.Add($shortOperationId)
    $tokens.Add((Get-Date -Format 'yyyyMMddHHmmssfff'))
    $tokens.Add(([guid]::NewGuid().ToString('N')).Substring(0, 8))

    $fileName = '{0}.{1}' -f ($tokens -join '-'), ($Extension.TrimStart('.'))
    return (Join-Path $Directory $fileName)
}

function Invoke-HVArtifactRetention {
    <#
    .SYNOPSIS
        Retains only the N most recent files matching a pattern.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Filter,
        [int]$MaxFiles = 30
    )

    if ($MaxFiles -lt 1 -or -not (Test-Path $Path)) {
        return
    }

    $stale = Get-ChildItem -Path $Path -Filter $Filter -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip $MaxFiles

    foreach ($item in $stale) {
        Remove-Item -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue
    }
}

function Initialize-HVLogging {
    <#
    .SYNOPSIS
        Configures file-based logging for the module. Call once before other functions.
    .PARAMETER LogPath
        Directory where log files are written. Created if it does not exist.
    .PARAMETER MaxLogFiles
        Maximum number of rotated log files to retain. Default: 10.
    .PARAMETER OperationId
        Optional caller-supplied run correlation identifier.
    .PARAMETER EnableStructuredLog
        Also write NDJSON structured events alongside the text log.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LogPath,
        [int]$MaxLogFiles = 10,
        [string]$OperationId = '',
        [bool]$EnableStructuredLog = $true
    )

    if (-not (Test-Path $LogPath)) {
        New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
    }

    $script:HVLogFile = Join-Path $LogPath ("HVCluster-{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
    $script:HVStructuredLogFile = if ($EnableStructuredLog) {
        Join-Path $LogPath ("HVCluster-{0}.ndjson" -f (Get-Date -Format 'yyyyMMdd'))
    }
    else {
        $null
    }
    $script:HVOperationId = if ([string]::IsNullOrWhiteSpace($OperationId)) { Get-HVGeneratedOperationId } else { $OperationId }

    # Rotate: keep only the N most recent log files
    Invoke-HVArtifactRetention -Path $LogPath -Filter 'HVCluster-*.log' -MaxFiles $MaxLogFiles
    Invoke-HVArtifactRetention -Path $LogPath -Filter 'HVCluster-*.ndjson' -MaxFiles $MaxLogFiles

    Write-HVLog -Message "Logging initialized. OperationId=$($script:HVOperationId) LogFile=$($script:HVLogFile)" -Level 'INFO'
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
        [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO',
        [hashtable]$Data = @{}
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $operationId = if ($script:HVOperationId) { $script:HVOperationId } else { 'no-op' }
    $line      = "$timestamp [$operationId] [$Level] $Message"

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

    if ($script:HVStructuredLogFile) {
        try {
            $record = [ordered]@{
                timestamp      = (Get-Date).ToString('o')
                operation_id   = $operationId
                level          = $Level
                message        = $Message
                module         = 'HyperVClusterPlatform'
                module_version = Get-HVModuleVersion
                data           = $Data
            }
            Add-Content -Path $script:HVStructuredLogFile -Value ($record | ConvertTo-Json -Depth 8 -Compress) -Encoding UTF8 -ErrorAction Stop
        }
        catch {
            Write-Host "$timestamp [WARN] Could not write structured log: $($_.Exception.Message)" -ForegroundColor Yellow
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

function Get-HVStructuredLogPath {
    <#
    .SYNOPSIS
        Returns the current structured log path, or $null if disabled.
    #>
    return $script:HVStructuredLogFile
}
