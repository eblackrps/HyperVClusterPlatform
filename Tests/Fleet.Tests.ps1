#Requires -Modules Pester
BeforeAll {
    . "$PSScriptRoot\_Stubs.ps1"
    . "$PSScriptRoot\..\Private\Logging.ps1"
    . "$PSScriptRoot\..\Private\TelemetryExport.ps1"
    . "$PSScriptRoot\..\Public\Invoke-HVClusterPlatform.ps1"
    . "$PSScriptRoot\..\Public\Invoke-HVClusterFleet.ps1"
    Mock Write-HVLog { }
    Mock Initialize-HVLogging { }
    Mock Export-HVTelemetry { 'C:\telemetry\fleet.json' }
}

Describe "Invoke-HVClusterFleet" {
    Context "FleetFile parameter set" {
        It "Throws when fleet config file does not exist" {
            { Invoke-HVClusterFleet -FleetConfigFile 'C:\DoesNotExist\fleet.json' } | Should -Throw
        }

        It "Processes clusters from a fleet config file" {
            # Write a temporary fleet config
            $tmpDir = [System.IO.Path]::GetTempPath()

            # Write two minimal cluster config files
            $c1 = Join-Path $tmpDir 'fleet-c1.json'
            $c2 = Join-Path $tmpDir 'fleet-c2.json'
            '{"ClusterName":"C1","Nodes":["N1"],"ClusterIP":"10.0.0.1","WitnessType":"None"}' | Set-Content $c1
            '{"ClusterName":"C2","Nodes":["N2"],"ClusterIP":"10.0.0.2","WitnessType":"None"}' | Set-Content $c2

            $fleet = Join-Path $tmpDir 'fleet.json'
            (@{ Clusters = @('fleet-c1.json','fleet-c2.json') } | ConvertTo-Json) | Set-Content $fleet

            Mock Invoke-HVClusterPlatform {
                [PSCustomObject]@{
                    ClusterName     = 'MockCluster'
                    DriftScore      = 0
                    Mode            = 'Audit'
                    Status          = 'Compliant'
                    DriftDetails    = @()
                    PreFlightPassed = $true
                    ReportPath      = $null
                    SnapshotPath    = $null
                }
            }

            $result = Invoke-HVClusterFleet -FleetConfigFile $fleet -Mode Audit -ReportsPath $tmpDir -LogPath $tmpDir -EmitTelemetry:$false
            $result.Status            | Should -Be 'Compliant'
            $result.TotalClusters     | Should -Be 2
            $result.CompliantClusters | Should -Be 2
            $result.FailedClusters    | Should -Be 0
            $result.AverageDriftScore | Should -Be 0

            Remove-Item $c1,$c2,$fleet -Force -ErrorAction SilentlyContinue
            Remove-Item (Join-Path $tmpDir 'Fleet-*.html') -Force -ErrorAction SilentlyContinue
        }
    }

    Context "ConfigList parameter set" {
        It "Accepts an explicit list of config files" {
            $tmpDir = [System.IO.Path]::GetTempPath()
            $c1 = Join-Path $tmpDir 'list-c1.json'
            '{"ClusterName":"C1","Nodes":["N1"],"ClusterIP":"10.0.0.1","WitnessType":"None"}' | Set-Content $c1

            Mock Invoke-HVClusterPlatform {
                [PSCustomObject]@{
                    ClusterName     = 'MockCluster'
                    DriftScore      = 10
                    Mode            = 'Audit'
                    Status          = 'NonCompliant'
                    DriftDetails    = @('Minor drift')
                    PreFlightPassed = $true
                    ReportPath      = $null
                    SnapshotPath    = $null
                }
            }

            $result = Invoke-HVClusterFleet -ConfigFiles @($c1) -Mode Audit -ReportsPath $tmpDir -LogPath $tmpDir -EmitTelemetry:$false
            $result.Status            | Should -Be 'NonCompliant'
            $result.TotalClusters     | Should -Be 1
            $result.DriftedClusters   | Should -Be 1
            $result.FailedClusters    | Should -Be 0
            $result.CompliantClusters | Should -Be 0

            Remove-Item $c1 -Force -ErrorAction SilentlyContinue
            Remove-Item (Join-Path $tmpDir 'Fleet-*.html') -Force -ErrorAction SilentlyContinue
        }
    }

    Context "Fleet report" {
        It "Creates a fleet HTML report file" {
            $tmpDir = [System.IO.Path]::GetTempPath()
            $c1 = Join-Path $tmpDir 'rpt-c1.json'
            '{"ClusterName":"C1","Nodes":["N1"],"ClusterIP":"10.0.0.1","WitnessType":"None"}' | Set-Content $c1

            Mock Invoke-HVClusterPlatform {
                [PSCustomObject]@{
                    ClusterName     = 'C1'
                    DriftScore      = 0
                    Mode            = 'Audit'
                    Status          = 'Compliant'
                    DriftDetails    = @()
                    PreFlightPassed = $true
                    ReportPath      = $null
                    SnapshotPath    = $null
                }
            }

            $result = Invoke-HVClusterFleet -ConfigFiles @($c1) -ReportsPath $tmpDir -LogPath $tmpDir -EmitTelemetry:$false
            Test-Path $result.FleetReportPath | Should -Be $true

            Remove-Item $c1 -Force -ErrorAction SilentlyContinue
            Remove-Item $result.FleetReportPath -Force -ErrorAction SilentlyContinue
        }
    }

    Context "Error handling" {
        It "Returns DriftScore=100 for a cluster that throws" {
            $tmpDir = [System.IO.Path]::GetTempPath()
            $c1 = Join-Path $tmpDir 'err-c1.json'
            '{"ClusterName":"C1","Nodes":["N1"],"ClusterIP":"10.0.0.1","WitnessType":"None"}' | Set-Content $c1

            Mock Invoke-HVClusterPlatform { throw 'Cluster unreachable' }

            $result = Invoke-HVClusterFleet -ConfigFiles @($c1) -ReportsPath $tmpDir -LogPath $tmpDir -EmitTelemetry:$false
            $result.Results[0].DriftScore | Should -Be 100
            $result.FailedClusters | Should -Be 1

            Remove-Item $c1 -Force -ErrorAction SilentlyContinue
            Remove-Item (Join-Path $tmpDir 'Fleet-*.html') -Force -ErrorAction SilentlyContinue
        }

        It "Deletes temporary inline config files after processing" {
            $tmpDir = [System.IO.Path]::GetTempPath()
            $fleet = Join-Path $tmpDir 'fleet-inline.json'
            @'
{
  "Clusters": [
    {
      "ClusterName": "InlineCluster",
      "Nodes": [ "N1" ],
      "ClusterIP": "10.0.0.9",
      "WitnessType": "None"
    }
  ]
}
'@ | Set-Content $fleet

            Mock Invoke-HVClusterPlatform {
                param($ConfigFile)
                $script:InlineFleetConfigPath = $ConfigFile
                [PSCustomObject]@{
                    ClusterName     = 'InlineCluster'
                    DriftScore      = 0
                    Mode            = 'Audit'
                    Status          = 'Compliant'
                    DriftDetails    = @()
                    PreFlightPassed = $true
                    ReportPath      = $null
                    SnapshotPath    = $null
                }
            }

            $null = Invoke-HVClusterFleet -FleetConfigFile $fleet -ReportsPath $tmpDir -LogPath $tmpDir -EmitTelemetry:$false
            $script:InlineFleetConfigPath | Should -Match 'HyperVClusterPlatform'
            Test-Path $script:InlineFleetConfigPath | Should -Be $false

            Remove-Item $fleet -Force -ErrorAction SilentlyContinue
            Remove-Item (Join-Path $tmpDir 'Fleet-*.html') -Force -ErrorAction SilentlyContinue
        }
    }
}
