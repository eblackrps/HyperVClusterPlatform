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

        It "Returns a SecureString by default when SecretManagement is available" {
            $result = Get-HVSecret -SecretName 'MySecret'
            $result | Should -BeOfType [System.Security.SecureString]
            ConvertFrom-HVSecureString -SecureString $result | Should -Be 'plaintext-value'
        }

        It "Returns plaintext when AsPlainText is specified" {
            $result = Get-HVSecret -SecretName 'MySecret' -AsPlainText
            $result | Should -Be 'plaintext-value'
        }

        It "Does not log the raw secret name when retrieval succeeds" {
            $null = Get-HVSecret -SecretName 'MySecret'
            Should -Invoke Write-HVLog -Times 1 -ParameterFilter {
                $Message -eq 'Secret retrieved from SecretManagement vault.'
            }
            Should -Not -Invoke Write-HVLog -ParameterFilter {
                $Message -match 'MySecret'
            }
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

        It "Returns a SecureString from Windows Credential Manager by default" {
            $result = Get-HVSecret -SecretName 'MySecret'
            $result | Should -BeOfType [System.Security.SecureString]
            ConvertFrom-HVSecureString -SecureString $result | Should -Be 'fallback-value'
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
            Mock Get-HVSecret { ConvertTo-HVSecureString -PlainText 'resolved-key' }
            $config = [PSCustomObject]@{
                ClusterName                       = 'Cluster1'
                CloudWitnessStorageKeySecretName  = 'MyStorageKey'
            }
            $result = Resolve-HVConfigSecrets -Config $config
            $result.CloudWitnessStorageKey | Should -BeOfType [System.Security.SecureString]
            ConvertFrom-HVSecureString -SecureString $result.CloudWitnessStorageKey | Should -Be 'resolved-key'
            Should -Invoke Write-HVLog -Times 1 -ParameterFilter {
                $Message -eq "Resolved secret for 'CloudWitnessStorageKey'."
            }
            Should -Not -Invoke Write-HVLog -ParameterFilter {
                $Message -match 'MyStorageKey'
            }
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

        It "Throws when ThrowOnError is specified" {
            Mock Get-HVSecret { throw 'Secret not found' }
            $config = [PSCustomObject]@{ MissingSecretName = 'DoesNotExist' }
            { Resolve-HVConfigSecrets -Config $config -ThrowOnError } | Should -Throw
        }
    }
}
