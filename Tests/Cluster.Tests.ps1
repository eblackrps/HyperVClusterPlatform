#Requires -Modules Pester
<#
.SYNOPSIS
    Module-load and public API smoke tests.
    These run without a live Hyper-V cluster (no real cmdlets called).
#>

BeforeAll {
    Import-Module "$PSScriptRoot\..\HyperVClusterPlatform.psd1" -Force
}

Describe "Module loads cleanly" {

    It "Exports Invoke-HVClusterPlatform" {
        (Get-Command -Module HyperVClusterPlatform -Name 'Invoke-HVClusterPlatform') | Should -Not -BeNullOrEmpty
    }

    It "Does NOT export private functions" {
        $exported = (Get-Command -Module HyperVClusterPlatform).Name
        $exported | Should -Not -Contain 'Write-HVLog'
        $exported | Should -Not -Contain 'Get-HVDriftScore'
        $exported | Should -Not -Contain 'New-HVClusterSnapshot'
    }

    It "Module version is 8.0.0" {
        (Get-Module HyperVClusterPlatform).Version.ToString() | Should -Be '8.0.0'
    }
}

Describe "Invoke-HVClusterPlatform parameter validation" {

    Context "Mandatory parameters enforced" {

        It "Throws when ClusterName is missing (Direct set)" {
            {
                Invoke-HVClusterPlatform -Nodes @('N1') -ClusterIP '1.2.3.4' -WitnessType None
            } | Should -Throw
        }

        It "Throws when WitnessType is invalid" {
            {
                Invoke-HVClusterPlatform -ClusterName 'C' -Nodes @('N1') `
                    -ClusterIP '1.2.3.4' -WitnessType 'BadValue'
            } | Should -Throw
        }

        It "Throws when Mode is invalid" {
            {
                Invoke-HVClusterPlatform -ClusterName 'C' -Nodes @('N1') `
                    -ClusterIP '1.2.3.4' -WitnessType None -Mode 'Destroy'
            } | Should -Throw
        }
    }
}
