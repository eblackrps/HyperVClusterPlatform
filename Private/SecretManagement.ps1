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
        String (plaintext) or SecureString depending on -AsSecureString.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SecretName,
        [string]$VaultName,
        [switch]$AsSecureString,
        [switch]$AllowPrompt
    )

    # ── 1. SecretManagement module ───────────────────────────────────────────
    if (Get-Module -ListAvailable -Name 'Microsoft.PowerShell.SecretManagement' -ErrorAction SilentlyContinue) {
        try {
            $getParams = @{ Name = $SecretName; ErrorAction = 'Stop' }
            if ($VaultName) { $getParams['Vault'] = $VaultName }
            if ($AsSecureString) { $getParams['AsSecureString'] = $true }

            $secret = Get-Secret @getParams
            Write-HVLog -Message "Secret '$SecretName' retrieved from SecretManagement vault." -Level 'INFO'
            return $secret
        }
        catch {
            Write-HVLog -Message "SecretManagement lookup failed for '$SecretName': $($_.Exception.Message)" -Level 'WARN'
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
                Write-HVLog -Message "Secret '$SecretName' retrieved from Windows Credential Manager." -Level 'INFO'
                $plain = $cred.GetNetworkCredential().Password
                if ($AsSecureString) {
                    return ConvertTo-HVSecureString -PlainText $plain
                }
                return $plain
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
        if ($AsSecureString) { return $secure }
        return [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
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

    return [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString))
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
        [string]$VaultName
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
                    $plaintext = Get-HVSecret @getParams
                    $Config | Add-Member -NotePropertyName $targetProp -NotePropertyValue $plaintext -Force
                    Write-HVLog -Message "Resolved secret for '$targetProp' from '$secretName'." -Level 'INFO'
                    $resolved++
                }
                catch {
                    Write-HVLog -Message "Could not resolve secret '$secretName' for '$targetProp': $($_.Exception.Message)" -Level 'ERROR'
                }
            }
        }
    }

    Write-HVLog -Message "Secret resolution complete: $resolved secret(s) resolved." -Level 'INFO'
    return $Config
}
