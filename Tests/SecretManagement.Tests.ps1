#Requires -Modules Pester
BeforeAll {
    . "$PSScriptRoot\_Stubs.ps1"
    . "$PSScriptRoot\..\Private\Logging.ps1"
    . "$PSScriptRoot\..\Private\SecretManagement.ps1"
    Mock Write-HVLog { }
}

Describe "Get-HVSecret" {
    Context "SecretManagement module unavailable, CredentialManager unavailable" {
        BeforeEach {
            Mock Get-Module { $null } -ParameterFilter { $Name -eq 'Microsoft.PowerShell.SecretManagement' }
            Mock Get-Module { $null } -ParameterFilter { $Name -eq 'CredentialManager' }
        }

        It "Throws when no vault is available and AllowPrompt is false" {
            { Get-HVSecret -SecretName 'MySecret' } | Should -Throw
        }
    }

    Context "SecretManagement module available" {
        BeforeEach {
            Mock Get-Module { [PSCustomObject]@{ Name = 'Microsoft.PowerShell.SecretManagement' } } `
                -ParameterFilter { $Name -eq 'Microsoft.PowerShell.SecretManagement' }
            Mock Get-Secret { 'plaintext-value' }
        }

        It "Returns secret value when SecretManagement is available" {
            $result = Get-HVSecret -SecretName 'MySecret'
            $result | Should -Be 'plaintext-value'
        }

        It "Returns SecureString when AsSecureString is specified" {
            Mock Get-Secret { ConvertTo-HVSecureString -PlainText 'secure-val' }
            $result = Get-HVSecret -SecretName 'MySecret' -AsSecureString
            $result | Should -BeOfType [System.Security.SecureString]
        }
    }

    Context "SecretManagement throws, falls back to CredentialManager" {
        BeforeEach {
            Mock Get-Module { [PSCustomObject]@{ Name = 'Microsoft.PowerShell.SecretManagement' } } `
                -ParameterFilter { $Name -eq 'Microsoft.PowerShell.SecretManagement' }
            Mock Get-Secret { throw 'Vault not found' }
            Mock Get-Module { [PSCustomObject]@{ Name = 'CredentialManager' } } `
                -ParameterFilter { $Name -eq 'CredentialManager' }
            Mock Get-StoredCredential {
                [PSCredential]::new('user', (ConvertTo-HVSecureString -PlainText 'fallback-value'))
            }
        }

        It "Returns value from Windows Credential Manager on fallback" {
            $result = Get-HVSecret -SecretName 'MySecret'
            $result | Should -Be 'fallback-value'
        }
    }
}

Describe "ConvertFrom-HVSecureString" {
    It "Converts SecureString to plaintext" {
        $secure = ConvertTo-HVSecureString -PlainText 'MyPlaintext'
        $result = ConvertFrom-HVSecureString -SecureString $secure
        $result | Should -Be 'MyPlaintext'
    }
}

Describe "Resolve-HVConfigSecrets" {
    Context "Config with SecretName properties" {
        It "Resolves CloudWitnessStorageKeySecretName to CloudWitnessStorageKey" {
            Mock Get-HVSecret { 'resolved-key' }
            $config = [PSCustomObject]@{
                ClusterName                       = 'Cluster1'
                CloudWitnessStorageKeySecretName  = 'MyStorageKey'
            }
            $result = Resolve-HVConfigSecrets -Config $config
            $result.CloudWitnessStorageKey | Should -Be 'resolved-key'
        }

        It "Handles multiple SecretName properties" {
            Mock Get-HVSecret { 'resolved' }
            $config = [PSCustomObject]@{
                PrimarySecretName   = 'SecA'
                SecondarySecretName = 'SecB'
            }
            $result = Resolve-HVConfigSecrets -Config $config
            $result.Primary   | Should -Be 'resolved'
            $result.Secondary | Should -Be 'resolved'
        }

        It "Returns original config when no SecretName properties exist" {
            $config = [PSCustomObject]@{ ClusterName = 'NoSecrets' }
            $result = Resolve-HVConfigSecrets -Config $config
            $result.ClusterName | Should -Be 'NoSecrets'
        }

        It "Logs error but continues when a secret cannot be resolved" {
            Mock Get-HVSecret { throw 'Secret not found' }
            $config = [PSCustomObject]@{ MissingSecretName = 'DoesNotExist' }
            { Resolve-HVConfigSecrets -Config $config } | Should -Not -Throw
        }
    }
}
