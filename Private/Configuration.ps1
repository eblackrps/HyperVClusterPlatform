function Test-HVConfigCommentKey {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    return ($Name -eq 'Environments' -or $Name.StartsWith('_'))
}

function Test-HVSensitiveConfigKey {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    return ($Name -match '(?i)(secret|key|password|token|credential)')
}

function Test-HVConfigAnyValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string[]]$Keys
    )

    foreach ($key in $Keys) {
        if ($Config.Contains($key)) {
            $value = $Config[$key]
            if ($null -ne $value -and (-not ($value -is [string]) -or -not [string]::IsNullOrWhiteSpace($value))) {
                return $true
            }
        }
    }

    return $false
}

function Test-HVValidIPv4Address {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Value)

    $ipAddress = $null
    if (-not [System.Net.IPAddress]::TryParse($Value, [ref]$ipAddress)) {
        return $false
    }

    return ($ipAddress.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork)
}

function Test-HVProdEnvironment {
    [CmdletBinding()]
    param([string]$Environment)

    return ($Environment -match '^(?i)(prod|production)$')
}

function Get-HVNormalizedNodeList {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Nodes)

    return @(
        $Nodes |
            ForEach-Object { [string]$_ } |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

function Import-HVClusterConfig {
    <#
    .SYNOPSIS
        Loads cluster parameters from a JSON configuration file and returns a validated
        configuration object. Supports environment-specific overrides (Dev/Staging/Prod).
    .PARAMETER ConfigPath
        Path to the JSON configuration file. See Config/cluster-config.example.json.
    .PARAMETER Environment
        Optional environment name. If the JSON contains an 'Environments' block with a
        matching key, those values overlay the top-level defaults.
    .OUTPUTS
        PSCustomObject with all cluster parameters.  Throws on validation failure.
    .EXAMPLE
        $cfg = Import-HVClusterConfig -ConfigPath .\Config\prod.json -Environment Prod
        Invoke-HVClusterPlatform @cfg
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [string]$Environment = ''
    )

    if (-not (Test-Path $ConfigPath)) {
        throw "Config file not found: '$ConfigPath'."
    }

    try {
        $raw = Get-Content -Path $ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json
    }
    catch {
        throw "Failed to parse config file '$ConfigPath': $($_.Exception.Message)"
    }

    $cfg = [ordered]@{}
    foreach ($prop in $raw.PSObject.Properties) {
        if (Test-HVConfigCommentKey -Name $prop.Name) {
            continue
        }
        $cfg[$prop.Name] = $prop.Value
    }

    $defaultValues = [ordered]@{
        Mode                   = 'Audit'
        ReportsPath            = '.\Reports'
        LogPath                = '.\Logs'
        SkipPreFlight          = $false
        SkipNodeValidation     = $false
        SkipClusterValidation  = $false
        BreakGlass             = $false
        PlanOnly               = $false
        EmitTelemetry          = $true
        SkipArtifactPersistence = $false
        RetainArtifactCount    = 30
    }
    foreach ($key in $defaultValues.Keys) {
        if (-not $cfg.Contains($key) -or
            $null -eq $cfg[$key] -or
            ($cfg[$key] -is [string] -and [string]::IsNullOrWhiteSpace($cfg[$key]))) {
            $cfg[$key] = $defaultValues[$key]
        }
    }

    $cfg['Nodes'] = Get-HVNormalizedNodeList -Nodes @($cfg['Nodes'])
    $cfg['SkipPreFlight'] = [bool]$cfg['SkipPreFlight']
    $cfg['SkipNodeValidation'] = [bool]$cfg['SkipNodeValidation']
    $cfg['SkipClusterValidation'] = [bool]$cfg['SkipClusterValidation']
    $cfg['BreakGlass'] = [bool]$cfg['BreakGlass']
    $cfg['PlanOnly'] = [bool]$cfg['PlanOnly']
    $cfg['EmitTelemetry'] = [bool]$cfg['EmitTelemetry']
    $cfg['SkipArtifactPersistence'] = [bool]$cfg['SkipArtifactPersistence']
    $cfg['RetainArtifactCount'] = [int]$cfg['RetainArtifactCount']

    # Apply environment-specific overrides
    if ($Environment -and $raw.Environments -and $raw.Environments.$Environment) {
        $envBlock = $raw.Environments.$Environment
        Write-HVLog -Message "Config: applying '$Environment' environment overrides." -Level 'INFO'
        foreach ($prop in $envBlock.PSObject.Properties) {
            if (Test-HVConfigCommentKey -Name $prop.Name) {
                continue
            }
            $cfg[$prop.Name] = $prop.Value

            $displayValue = if (Test-HVSensitiveConfigKey -Name $prop.Name) {
                '<redacted>'
            }
            elseif ($prop.Value -is [System.Array]) {
                '[' + (($prop.Value | ForEach-Object { "$_" }) -join ', ') + ']'
            }
            elseif ($null -eq $prop.Value) {
                '<null>'
            }
            else {
                "$($prop.Value)"
            }

            Write-HVLog -Message "Config override: $($prop.Name) = '$displayValue'" -Level 'INFO'
        }
    }

    $cfg['Nodes'] = Get-HVNormalizedNodeList -Nodes @($cfg['Nodes'])
    $cfg['SkipPreFlight'] = [bool]$cfg['SkipPreFlight']
    $cfg['SkipNodeValidation'] = [bool]$cfg['SkipNodeValidation']
    $cfg['SkipClusterValidation'] = [bool]$cfg['SkipClusterValidation']
    $cfg['BreakGlass'] = [bool]$cfg['BreakGlass']
    $cfg['PlanOnly'] = [bool]$cfg['PlanOnly']
    $cfg['EmitTelemetry'] = [bool]$cfg['EmitTelemetry']
    $cfg['SkipArtifactPersistence'] = [bool]$cfg['SkipArtifactPersistence']
    $cfg['RetainArtifactCount'] = [int]$cfg['RetainArtifactCount']

    # Validate mandatory fields
    $required = @('ClusterName','Nodes','ClusterIP','WitnessType')
    foreach ($field in $required) {
        if (-not $cfg[$field]) {
            throw "Config validation error: '$field' is required but missing or empty in '$ConfigPath'."
        }
    }

    $validWitness = @('None','Disk','Cloud','Share')
    if ($cfg['WitnessType'] -notin $validWitness) {
        throw "Config validation error: WitnessType must be one of: $($validWitness -join ', '). Got: '$($cfg['WitnessType'])'."
    }

    if (-not (Test-HVValidIPv4Address -Value ([string]$cfg['ClusterIP']))) {
        throw "Config validation error: ClusterIP '$($cfg['ClusterIP'])' is not a valid IPv4 address."
    }

    $duplicateNodes = @($cfg['Nodes'] | Group-Object | Where-Object Count -gt 1 | Select-Object -ExpandProperty Name)
    if ($duplicateNodes.Count -gt 0) {
        throw "Config validation error: duplicate node names found: $($duplicateNodes -join ', ')."
    }

    $validModes = @('Audit','Enforce','Remediate')
    if ($cfg['Mode'] -notin $validModes) {
        throw "Config validation error: Mode must be one of: $($validModes -join ', '). Got: '$($cfg['Mode'])'."
    }

    if ($cfg['WitnessType'] -eq 'Disk' -and -not (Test-HVConfigAnyValue -Config $cfg -Keys @('WitnessDiskName'))) {
        throw "Config validation error: WitnessType='Disk' requires WitnessDiskName for safe quorum targeting."
    }

    if ($cfg['WitnessType'] -eq 'Cloud' -and
        (-not (Test-HVConfigAnyValue -Config $cfg -Keys @('CloudWitnessStorageAccount','CloudWitnessStorageAccountSecretName')) -or
         -not (Test-HVConfigAnyValue -Config $cfg -Keys @('CloudWitnessStorageKey','CloudWitnessStorageKeySecretName')))) {
        throw "Config validation error: WitnessType='Cloud' requires CloudWitnessStorageAccount plus CloudWitnessStorageKey or CloudWitnessStorageKeySecretName."
    }
    if ($cfg['WitnessType'] -eq 'Share' -and -not (Test-HVConfigAnyValue -Config $cfg -Keys @('FileShareWitnessPath','FileShareWitnessPathSecretName'))) {
        throw "Config validation error: WitnessType='Share' requires FileShareWitnessPath."
    }
    if ($cfg['WitnessType'] -eq 'Share' -and $cfg['FileShareWitnessPath'] -and ([string]$cfg['FileShareWitnessPath'] -notmatch '^\\\\')) {
        throw "Config validation error: FileShareWitnessPath must be a UNC path."
    }
    if ($cfg['WitnessType'] -ne 'Cloud' -and
        (Test-HVConfigAnyValue -Config $cfg -Keys @('CloudWitnessStorageAccount','CloudWitnessStorageKey','CloudWitnessStorageKeySecretName'))) {
        throw "Config validation error: Cloud witness settings are present while WitnessType is '$($cfg['WitnessType'])'."
    }
    if ($cfg['WitnessType'] -ne 'Share' -and
        (Test-HVConfigAnyValue -Config $cfg -Keys @('FileShareWitnessPath','FileShareWitnessPathSecretName'))) {
        throw "Config validation error: File share witness settings are present while WitnessType is '$($cfg['WitnessType'])'."
    }
    if ($cfg['WitnessType'] -ne 'Disk' -and
        (Test-HVConfigAnyValue -Config $cfg -Keys @('WitnessDiskName'))) {
        throw "Config validation error: WitnessDiskName is present while WitnessType is '$($cfg['WitnessType'])'."
    }

    $skipFlags = @('SkipPreFlight','SkipNodeValidation','SkipClusterValidation') | Where-Object { $cfg[$_] }
    if ($cfg['Mode'] -in @('Enforce','Remediate') -and $skipFlags.Count -gt 0 -and -not $cfg['BreakGlass']) {
        throw "Config validation error: skip safety flags [$($skipFlags -join ', ')] require BreakGlass=true for Enforce/Remediate runs."
    }
    if (Test-HVProdEnvironment -Environment $Environment) {
        if ($skipFlags.Count -gt 0 -and -not $cfg['BreakGlass']) {
            throw "Config validation error: production environment '$Environment' cannot use skip safety flags without BreakGlass=true."
        }
    }
    if ($cfg['SkipArtifactPersistence'] -and $cfg['Mode'] -in @('Enforce','Remediate')) {
        throw "Config validation error: SkipArtifactPersistence is only supported for Audit mode."
    }
    if ($cfg['RetainArtifactCount'] -lt 1) {
        throw "Config validation error: RetainArtifactCount must be >= 1."
    }

    Write-HVLog -Message "Config loaded: ClusterName='$($cfg.ClusterName)' Nodes=[$($cfg.Nodes -join ',')] Mode='$($cfg.Mode)' Witness='$($cfg.WitnessType)'." -Level 'INFO'

    return [PSCustomObject]$cfg
}
