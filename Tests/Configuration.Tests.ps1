#Requires -Modules Pester
<#
.SYNOPSIS
    Unit tests for Import-HVClusterConfig (JSON config file support).
#>

BeforeAll {
    . "$PSScriptRoot\..\Private\Logging.ps1"
    . "$PSScriptRoot\..\Private\Configuration.ps1"

    Mock Write-HVLog { }

    # Helper: write a minimal valid config JSON to a temp file.
    function New-TestConfig {
        param([hashtable]$Overrides = @{})
        $base = @{
            ClusterName  = 'TestCluster'
            Nodes        = @('NODE1','NODE2')
            ClusterIP    = '10.0.0.10'
            WitnessType  = 'Disk'
            Mode         = 'Audit'
        }
        foreach ($k in $Overrides.Keys) { $base[$k] = $Overrides[$k] }
        $path = [System.IO.Path]::GetTempFileName() -replace '\.tmp$','.json'
        $base | ConvertTo-Json | Set-Content -Path $path -Encoding UTF8
        return $path
    }
}

Describe "Import-HVClusterConfig" {

    Context "File not found" {

        It "Throws when config file does not exist" {
            { Import-HVClusterConfig -ConfigPath 'C:\nonexistent\config.json' } | Should -Throw
        }
    }

    Context "Invalid JSON" {

        It "Throws on malformed JSON" {
            $bad = [System.IO.Path]::GetTempFileName() -replace '\.tmp$','.json'
            Set-Content $bad 'NOT { json }'
            { Import-HVClusterConfig -ConfigPath $bad } | Should -Throw
            Remove-Item $bad -Force
        }
    }

    Context "Valid minimal config" {

        It "Returns an object with all required fields" {
            $cfg = New-TestConfig
            $result = Import-HVClusterConfig -ConfigPath $cfg
            $result.ClusterName | Should -Be 'TestCluster'
            $result.Nodes       | Should -Contain 'NODE1'
            $result.ClusterIP   | Should -Be '10.0.0.10'
            $result.WitnessType | Should -Be 'Disk'
            Remove-Item $cfg -Force
        }

        It "Defaults Mode to 'Audit' when not specified" {
            $cfg = New-TestConfig -Overrides @{ Mode = $null }
            # Remove Mode key entirely
            $json = Get-Content $cfg | ConvertFrom-Json
            $json.PSObject.Properties.Remove('Mode')
            $json | ConvertTo-Json | Set-Content $cfg
            $result = Import-HVClusterConfig -ConfigPath $cfg
            $result.Mode | Should -Be 'Audit'
            Remove-Item $cfg -Force
        }
    }

    Context "Validation failures" {

        It "Throws when ClusterName is missing" {
            $cfg = New-TestConfig -Overrides @{ ClusterName = '' }
            { Import-HVClusterConfig -ConfigPath $cfg } | Should -Throw
            Remove-Item $cfg -Force
        }

        It "Throws when WitnessType is invalid" {
            $cfg = New-TestConfig -Overrides @{ WitnessType = 'USB' }
            { Import-HVClusterConfig -ConfigPath $cfg } | Should -Throw
            Remove-Item $cfg -Force
        }

        It "Throws when Cloud witness lacks storage account" {
            $cfg = New-TestConfig -Overrides @{ WitnessType = 'Cloud' }
            { Import-HVClusterConfig -ConfigPath $cfg } | Should -Throw
            Remove-Item $cfg -Force
        }

        It "Throws when Share witness lacks file share path" {
            $cfg = New-TestConfig -Overrides @{ WitnessType = 'Share' }
            { Import-HVClusterConfig -ConfigPath $cfg } | Should -Throw
            Remove-Item $cfg -Force
        }
    }

    Context "Environment overrides" {

        It "Applies environment-specific Mode override" {
            $base = @{
                ClusterName  = 'TestCluster'
                Nodes        = @('NODE1','NODE2')
                ClusterIP    = '10.0.0.10'
                WitnessType  = 'Disk'
                Mode         = 'Audit'
                Environments = @{
                    Prod = @{ Mode = 'Enforce' }
                }
            }
            $path = [System.IO.Path]::GetTempFileName() -replace '\.tmp$','.json'
            $base | ConvertTo-Json -Depth 5 | Set-Content $path
            $result = Import-HVClusterConfig -ConfigPath $path -Environment 'Prod'
            $result.Mode | Should -Be 'Enforce'
            Remove-Item $path -Force
        }

        It "Ignores unknown environment names gracefully" {
            $cfg = New-TestConfig
            $result = Import-HVClusterConfig -ConfigPath $cfg -Environment 'NonExistent'
            $result.Mode | Should -Be 'Audit'   # default unchanged
            Remove-Item $cfg -Force
        }
    }
}
