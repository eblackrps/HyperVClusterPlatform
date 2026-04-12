#Requires -Modules Pester

. "$PSScriptRoot\_Stubs.ps1"
Import-Module "$PSScriptRoot\..\HyperVClusterPlatform.psd1" -Force

Describe "Artifact naming" {
    InModuleScope HyperVClusterPlatform {
        BeforeEach {
            Mock Write-HVLog { }
            function Get-Cluster { $null }
            function Get-ClusterNode { @() }
            function Get-ClusterQuorum { $null }
            function Get-ClusterGroup { @() }
            function Get-ClusterNetwork { @() }
            function Get-ClusterResource { @() }
            function Get-ClusterSharedVolume { @() }
            Initialize-HVLogging -LogPath $TestDrive -OperationId 'artifact-op-001' -EnableStructuredLog:$false
        }

        It "Creates unique compliance report names that include cluster and mode" {
            $first = Export-HVComplianceReport -DriftResult ([PSCustomObject]@{ Score = 0; Details = @() }) `
                -ReportsPath $TestDrive -ClusterName 'ProdCluster' -Mode 'Audit'
            $second = Export-HVComplianceReport -DriftResult ([PSCustomObject]@{ Score = 0; Details = @() }) `
                -ReportsPath $TestDrive -ClusterName 'ProdCluster' -Mode 'Audit'

            (Split-Path $first -Leaf) | Should -Match '^Compliance-ProdCluster-Audit-'
            $first | Should -Not -Be $second
        }

        It "Creates snapshot names that include cluster and label" {
            $path = Export-HVClusterSnapshot -ReportsPath $TestDrive -Label 'Pre-Enforce' -ClusterName 'ProdCluster'
            (Split-Path $path -Leaf) | Should -Match '^Snapshot-ProdCluster-Pre-Enforce-'
        }

        It "Creates telemetry names that include cluster and mode" {
            $path = Export-HVTelemetry -RunResult ([PSCustomObject]@{
                ClusterName       = 'ProdCluster'
                Mode              = 'Audit'
                Status            = 'Compliant'
                OperationId       = 'artifact-op-001'
                DriftScore        = 0
                DriftDetails      = @()
                PreFlightPassed   = $true
                OSProfile         = $null
                LogPath           = $null
                StructuredLogPath = $null
                ReportPath        = $null
                SnapshotPath      = $null
                JournalPath       = $null
            }) -OutputPath $TestDrive

            (Split-Path $path -Leaf) | Should -Match '^Telemetry-ProdCluster-Audit-'
        }
    }
}
