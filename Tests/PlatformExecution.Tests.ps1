#Requires -Modules Pester

Import-Module "$PSScriptRoot\..\HyperVClusterPlatform.psd1" -Force

Describe "Invoke-HVClusterPlatform execution behavior" {
    InModuleScope HyperVClusterPlatform {
        BeforeEach {
            Mock Initialize-HVLogging { }
            Mock Write-HVLog { }
            Mock Get-HVGeneratedOperationId { 'op-test-001' }
            Mock Get-HVModuleVersion { '21.1.0' }
            Mock Get-HVLogPath { 'C:\Logs\HVCluster.log' }
            Mock Get-HVStructuredLogPath { 'C:\Logs\HVCluster.ndjson' }
            Mock Resolve-HVConfigSecrets { param($Config) $Config }
            Mock Test-HVPrerequisites {
                [PSCustomObject]@{
                    Passed            = $true
                    Failures          = @()
                    Warnings          = @()
                    OSProfile         = $null
                    ClusterValidation = $null
                }
            }
            Mock Test-HVNodeReadiness {
                @(
                    [PSCustomObject]@{
                        Passed    = $true
                        NodeName  = 'N1'
                        Failures  = @()
                        Warnings  = @()
                        OSProfile = $null
                    }
                )
            }
            Mock Get-HVOSProfile {
                [PSCustomObject]@{
                    Version     = '2025'
                    Build       = 26100
                    DisplayName = 'Windows Server 2025'
                }
            }
            Mock Get-HVDesiredState {
                [PSCustomObject]@{
                    ClusterName = 'ProdCluster'
                    Nodes       = @('N1')
                    WitnessType = 'None'
                }
            }
            Mock Get-HVClusterCurrentState {
                [PSCustomObject]@{
                    ClusterName = 'ProdCluster'
                    Nodes       = @('N1')
                    WitnessType = 'None'
                }
            }
            Mock Get-HVDriftScore {
                [PSCustomObject]@{
                    Score   = 0
                    Details = @()
                }
            }
            Mock Get-HVEnforcementPlan {
                [PSCustomObject]@{
                    Blocked        = $false
                    BlockedReason  = ''
                    RequiresChange = $false
                    Actions        = @()
                }
            }
            Mock Export-HVClusterSnapshot { 'C:\Reports\Snapshot.json' }
            Mock Export-HVComplianceReport { 'C:\Reports\Compliance.html' }
            Mock Export-HVTelemetry { 'C:\Reports\Telemetry.json' }
            Mock Invoke-HVEnforcement {
                [PSCustomObject]@{
                    Success        = $true
                    ClusterCreated = $false
                    AddedNodes     = @()
                    WitnessChanged = $false
                    JournalPath    = 'C:\Reports\Journal.json'
                    Plan           = [PSCustomObject]@{}
                }
            }
        }

        It "Keeps an explicit CLI Mode over the config Mode" {
            Mock Import-HVClusterConfig {
                [PSCustomObject]@{
                    ClusterName            = 'ProdCluster'
                    Nodes                  = @('N1')
                    ClusterIP              = '10.0.0.10'
                    WitnessType            = 'None'
                    Mode                   = 'Enforce'
                    SkipPreFlight          = $false
                    SkipNodeValidation     = $false
                    SkipClusterValidation  = $false
                    BreakGlass             = $false
                    PlanOnly               = $false
                    EmitTelemetry          = $false
                    SkipArtifactPersistence = $false
                    RetainArtifactCount    = 30
                }
            }

            $result = Invoke-HVClusterPlatform -ConfigFile 'C:\Config\prod.json' -Mode Audit -EmitTelemetry:$false -Confirm:$false
            $result.Mode | Should -Be 'Audit'
            $result.Status | Should -Be 'Compliant'
            Should -Not -Invoke Invoke-HVEnforcement
        }

        It "Marks cluster validation as skipped when preflight is skipped" {
            $result = Invoke-HVClusterPlatform -ClusterName 'ProdCluster' -Nodes @('N1') -ClusterIP '10.0.0.10' `
                -WitnessType None -Mode Audit -SkipPreFlight -EmitTelemetry:$false -Confirm:$false

            $result.ClusterValidationPassed | Should -Be $null
            $result.ClusterValidationStatus | Should -Be 'Skipped'
            Should -Not -Invoke Test-HVPrerequisites
        }

        It "Surfaces rollback details when enforcement fails after mutation starts" {
            Mock Get-HVDriftScore {
                [PSCustomObject]@{
                    Score   = 40
                    Details = @('Witness drift')
                }
            }
            Mock Get-HVEnforcementPlan {
                [PSCustomObject]@{
                    Blocked        = $false
                    BlockedReason  = ''
                    RequiresChange = $true
                    Actions        = @(
                        [PSCustomObject]@{
                            Action = 'SetWitness'
                            Target = 'Cluster Disk 3'
                        }
                    )
                }
            }
            Mock Invoke-HVEnforcement {
                $ex = [System.InvalidOperationException]::new('Simulated enforcement failure')
                $ex.Data['JournalPath'] = 'C:\Reports\Journal-ProdCluster.json'
                $ex.Data['RollbackStatus'] = 'Partial'
                $ex.Data['RollbackActions'] = @('Removed node N3')
                $ex.Data['RollbackErrors'] = @('Witness rollback requires manual validation')
                throw $ex
            }

            $result = Invoke-HVClusterPlatform -ClusterName 'ProdCluster' -Nodes @('N1') -ClusterIP '10.0.0.10' `
                -WitnessType None -Mode Enforce -EmitTelemetry:$false -Confirm:$false

            $result.Status | Should -Be 'Failed'
            $result.RollbackStatus | Should -Be 'Partial'
            $result.RollbackActions | Should -Contain 'Removed node N3'
            $result.RollbackErrors | Should -Contain 'Witness rollback requires manual validation'
            $result.JournalPath | Should -Be 'C:\Reports\Journal-ProdCluster.json'
        }
    }
}
