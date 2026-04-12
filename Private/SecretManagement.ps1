function Test-HVSecretSensitiveName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    return ($Name -match '(?i)(secret|key|password|token|credential)')
}

function Get-HVSecret {
    <#
    .SYNOPSIS
        Retrieves a secret from a Microsoft.PowerShell.SecretManagement vault.
        Falls back to Windows Credential Manager if SecretManagement is unavailable.
    .DESCRIPTION
        Priority order:
          1. Microsoft.PowerShell.SecretManagement (if module is installed + vault is registered)
          2. Windows Credential Manager via cmdkey / Get-StoredCredential
          3. Prompt the user interactively (if -AllowPrompt)
    .PARAMETER SecretName
        Name of the secret in the vault.
    .PARAMETER VaultName
        Optional vault name. If omitted, searches all registered vaults.
    .PARAMETER AllowPrompt
        If true, prompts the user for the secret when all vaults fail.
    .OUTPUTS
        SecureString by default. Use -AsPlainText only when a downstream API
        requires plaintext and no secure alternative exists.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SecretName,
        [string]$VaultName,
        [switch]$AsPlainText,
        [switch]$AllowPrompt
    )

    # ── 1. SecretManagement module ───────────────────────────────────────────
    if (Get-Module -ListAvailable -Name 'Microsoft.PowerShell.SecretManagement' -ErrorAction SilentlyContinue) {
        try {
            $getParams = @{ Name = $SecretName; ErrorAction = 'Stop' }
            if ($VaultName) { $getParams['Vault'] = $VaultName }
            if (-not $AsPlainText) { $getParams['AsSecureString'] = $true }

            $secret = Get-Secret @getParams
            Write-HVLog -Message 'Secret retrieved from SecretManagement vault.' -Level 'INFO'
            if ($AsPlainText) {
                if ($secret -is [System.Security.SecureString]) {
                    return ConvertFrom-HVSecureString -SecureString $secret
                }
                return [string]$secret
            }
            if ($secret -is [System.Security.SecureString]) {
                return $secret
            }
            return ConvertTo-HVSecureString -PlainText ([string]$secret)
        }
        catch {
            Write-HVLog -Message "SecretManagement lookup failed: $($_.Exception.Message)" -Level 'WARN'
        }
    }
    else {
        Write-HVLog -Message "Microsoft.PowerShell.SecretManagement not installed. Trying Windows Credential Manager." -Level 'WARN'
    }

    # ── 2. Windows Credential Manager ───────────────────────────────────────
    try {
        # Use cmdkey to list and match, then retrieve via CredentialManager module if available
        if (Get-Module -ListAvailable -Name 'CredentialManager' -ErrorAction SilentlyContinue) {
            $cred = Get-StoredCredential -Target $SecretName -ErrorAction Stop
            if ($cred) {
                Write-HVLog -Message 'Secret retrieved from Windows Credential Manager.' -Level 'INFO'
                $plain = $cred.GetNetworkCredential().Password
                if ($AsPlainText) {
                    return $plain
                }
                return ConvertTo-HVSecureString -PlainText $plain
            }
        }
    }
    catch {
        Write-HVLog -Message "Windows Credential Manager lookup failed: $($_.Exception.Message)" -Level 'WARN'
    }

    # ── 3. Interactive prompt (if allowed) ──────────────────────────────────
    if ($AllowPrompt) {
        Write-HVLog -Message "Prompting user for secret '$SecretName'." -Level 'WARN'
        $secure = Read-Host -Prompt "Enter value for secret '$SecretName'" -AsSecureString
        if (-not $AsPlainText) { return $secure }
        return ConvertFrom-HVSecureString -SecureString $secure
    }

    throw "Secret '$SecretName' could not be retrieved from any available vault."
}

function ConvertTo-HVSecureString {
    <#
    .SYNOPSIS
        Converts plaintext retrieved from an external secret store to SecureString
        without using ConvertTo-SecureString -AsPlainText.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PlainText)

    $secureString = [System.Security.SecureString]::new()
    foreach ($char in $PlainText.ToCharArray()) {
        $secureString.AppendChar($char)
    }
    $secureString.MakeReadOnly()
    return $secureString
}

function ConvertFrom-HVSecureString {
    <#
    .SYNOPSIS
        Converts a SecureString to plaintext. Use sparingly — only where an API
        requires a string (e.g., Azure Storage key parameter).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Security.SecureString]$SecureString)

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

function Resolve-HVConfigSecrets {
    <#
    .SYNOPSIS
        Resolves secret references in a config object loaded by Import-HVClusterConfig.
        Any property ending in 'SecretName' is resolved via Get-HVSecret and the
        plaintext value is stored in the corresponding property (without 'SecretName' suffix).
    .PARAMETER Config
        Config object from Import-HVClusterConfig.
    .PARAMETER VaultName
        Optional vault override.
    .OUTPUTS
        The same config object with secrets resolved.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [string]$VaultName,
        [switch]$ThrowOnError
    )

    $resolved = 0

    foreach ($prop in @($Config.PSObject.Properties)) {
        if ($prop.Name -like '*SecretName') {
            $secretName   = $prop.Value
            $targetProp   = $prop.Name -replace 'SecretName$', ''
            if ($secretName) {
                try {
                    $getParams = @{ SecretName = $secretName }
                    if ($VaultName) { $getParams['VaultName'] = $VaultName }
                    if (Test-HVSecretSensitiveName -Name $targetProp) {
                        $resolvedSecret = Get-HVSecret @getParams
                    }
                    else {
                        $resolvedSecret = Get-HVSecret @getParams -AsPlainText
                    }
                    $Config | Add-Member -NotePropertyName $targetProp -NotePropertyValue $resolvedSecret -Force
                    Write-HVLog -Message "Resolved secret for '$targetProp'." -Level 'INFO'
                    $resolved++
                }
                catch {
                    Write-HVLog -Message "Could not resolve secret for '$targetProp': $($_.Exception.Message)" -Level 'ERROR'
                    if ($ThrowOnError) {
                        throw
                    }
                }
            }
        }
    }

    Write-HVLog -Message "Secret resolution complete: $resolved secret(s) resolved." -Level 'INFO'
    return $Config
}
