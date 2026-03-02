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

    # Start with top-level defaults
    $cfg = [ordered]@{
        ClusterName                  = $raw.ClusterName
        Nodes                        = $raw.Nodes
        ClusterIP                    = $raw.ClusterIP
        WitnessType                  = $raw.WitnessType
        Mode                         = if ($raw.Mode)         { $raw.Mode }         else { 'Audit' }
        ReportsPath                  = if ($raw.ReportsPath)  { $raw.ReportsPath }  else { '.\Reports' }
        LogPath                      = if ($raw.LogPath)      { $raw.LogPath }      else { '.\Logs' }
        SkipPreFlight                = if ($null -ne $raw.SkipPreFlight) { [bool]$raw.SkipPreFlight } else { $false }
        SkipNodeValidation           = if ($null -ne $raw.SkipNodeValidation) { [bool]$raw.SkipNodeValidation } else { $false }
        CloudWitnessStorageAccount   = $raw.CloudWitnessStorageAccount
        CloudWitnessStorageKey       = $raw.CloudWitnessStorageKey
        FileShareWitnessPath         = $raw.FileShareWitnessPath
    }

    # Apply environment-specific overrides
    if ($Environment -and $raw.Environments -and $raw.Environments.$Environment) {
        $envBlock = $raw.Environments.$Environment
        Write-HVLog -Message "Config: applying '$Environment' environment overrides." -Level 'INFO'
        foreach ($prop in $envBlock.PSObject.Properties) {
            if ($cfg.Contains($prop.Name)) {
                Write-HVLog -Message "Config override: $($prop.Name) = '$($prop.Value)'" -Level 'INFO'
                $cfg[$prop.Name] = $prop.Value
            }
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

    if ($cfg['WitnessType'] -eq 'Cloud' -and (-not $cfg['CloudWitnessStorageAccount'] -or -not $cfg['CloudWitnessStorageKey'])) {
        throw "Config validation error: WitnessType='Cloud' requires CloudWitnessStorageAccount and CloudWitnessStorageKey."
    }
    if ($cfg['WitnessType'] -eq 'Share' -and -not $cfg['FileShareWitnessPath']) {
        throw "Config validation error: WitnessType='Share' requires FileShareWitnessPath."
    }

    Write-HVLog -Message "Config loaded: ClusterName='$($cfg.ClusterName)' Nodes=[$($cfg.Nodes -join ',')] Mode='$($cfg.Mode)' Witness='$($cfg.WitnessType)'." -Level 'INFO'

    return [PSCustomObject]$cfg
}
