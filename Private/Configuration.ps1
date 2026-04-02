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
        Mode               = 'Audit'
        ReportsPath        = '.\Reports'
        LogPath            = '.\Logs'
        SkipPreFlight      = $false
        SkipNodeValidation = $false
    }
    foreach ($key in $defaultValues.Keys) {
        if (-not $cfg.Contains($key) -or
            $null -eq $cfg[$key] -or
            ($cfg[$key] -is [string] -and [string]::IsNullOrWhiteSpace($cfg[$key]))) {
            $cfg[$key] = $defaultValues[$key]
        }
    }

    $cfg['SkipPreFlight'] = [bool]$cfg['SkipPreFlight']
    $cfg['SkipNodeValidation'] = [bool]$cfg['SkipNodeValidation']

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

    $validModes = @('Audit','Enforce','Remediate')
    if ($cfg['Mode'] -notin $validModes) {
        throw "Config validation error: Mode must be one of: $($validModes -join ', '). Got: '$($cfg['Mode'])'."
    }

    if ($cfg['WitnessType'] -eq 'Cloud' -and
        (-not (Test-HVConfigAnyValue -Config $cfg -Keys @('CloudWitnessStorageAccount','CloudWitnessStorageAccountSecretName')) -or
         -not (Test-HVConfigAnyValue -Config $cfg -Keys @('CloudWitnessStorageKey','CloudWitnessStorageKeySecretName')))) {
        throw "Config validation error: WitnessType='Cloud' requires CloudWitnessStorageAccount plus CloudWitnessStorageKey or CloudWitnessStorageKeySecretName."
    }
    if ($cfg['WitnessType'] -eq 'Share' -and -not (Test-HVConfigAnyValue -Config $cfg -Keys @('FileShareWitnessPath','FileShareWitnessPathSecretName'))) {
        throw "Config validation error: WitnessType='Share' requires FileShareWitnessPath."
    }

    Write-HVLog -Message "Config loaded: ClusterName='$($cfg.ClusterName)' Nodes=[$($cfg.Nodes -join ',')] Mode='$($cfg.Mode)' Witness='$($cfg.WitnessType)'." -Level 'INFO'

    return [PSCustomObject]$cfg
}
