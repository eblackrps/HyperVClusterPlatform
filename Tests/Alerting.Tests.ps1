#Requires -Modules Pester
BeforeAll {
    . "$PSScriptRoot\_Stubs.ps1"
    . "$PSScriptRoot\..\Private\Logging.ps1"
    . "$PSScriptRoot\..\Private\HealthCheck.ps1"
    . "$PSScriptRoot\..\Private\Alerting.ps1"
    Mock Write-HVLog { }
    Mock Initialize-HVLogging { }
    Mock Send-HVMailMessage { }
    Mock Invoke-RestMethod { }
    Mock Write-EventLog { }
    Mock New-EventLog { }
    Mock Get-Cluster              { $null }
    Mock Get-ClusterNode          { @() }
    Mock Get-ClusterQuorum        { $null }
    Mock Get-ClusterGroup         { @() }
    Mock Get-ClusterSharedVolume  { @() }
    Mock Get-VM                   { @() }
}

Describe "Send-HVAlert" {
    Context "No channels configured" {
        It "Returns false for all channels when no params supplied" {
            $r = Send-HVAlert -Subject 'Test' -Body 'TestBody'
            $r.EmailSent       | Should -Be $false
            $r.TeamsSent       | Should -Be $false
            $r.SlackSent       | Should -Be $false
            $r.EventLogWritten | Should -Be $false
            $r.Errors.Count    | Should -Be 0
        }
    }

    Context "Email channel" {
        It "Sends email when SmtpServer, From, and To are provided" {
            $r = Send-HVAlert -Subject 'Test' -Body 'Body' `
                              -SmtpServer 'smtp.test.local' -EmailFrom 'hvp@test.local' `
                              -EmailTo @('admin@test.local')
            $r.EmailSent | Should -Be $true
            Should -Invoke Send-HVMailMessage -Times 1
        }

        It "Records error and EmailSent=false when Send-HVMailMessage throws" {
            Mock Send-HVMailMessage { throw 'SMTP unavailable' }
            $r = Send-HVAlert -Subject 'Test' -Body 'Body' `
                              -SmtpServer 'smtp.test.local' -EmailFrom 'hvp@test.local' `
                              -EmailTo @('admin@test.local')
            $r.EmailSent      | Should -Be $false
            $r.Errors.Count   | Should -BeGreaterThan 0
            $r.Errors[0]      | Should -Match 'SMTP'
        }
    }

    Context "Teams webhook" {
        It "Posts to Teams when TeamsWebhookUrl is supplied" {
            $r = Send-HVAlert -Subject 'Test' -Body 'Body' -TeamsWebhookUrl 'https://teams.webhook.test/v1'
            $r.TeamsSent | Should -Be $true
            Should -Invoke Invoke-RestMethod -Times 1
        }

        It "Records error on Teams failure" {
            Mock Invoke-RestMethod { throw 'Connection refused' }
            $r = Send-HVAlert -Subject 'Test' -Body 'Body' -TeamsWebhookUrl 'https://teams.webhook.test/v1'
            $r.TeamsSent    | Should -Be $false
            $r.Errors.Count | Should -BeGreaterThan 0
        }
    }

    Context "Slack webhook" {
        It "Posts to Slack when SlackWebhookUrl is supplied" {
            Mock Invoke-RestMethod { }
            $r = Send-HVAlert -Subject 'Test' -Body 'Body' -SlackWebhookUrl 'https://hooks.slack.test/T01/B01/key'
            $r.SlackSent | Should -Be $true
        }
    }

    Context "Event log" {
        It "Writes to event log when WriteEventLog is supplied" {
            # [System.Diagnostics.EventLog]::SourceExists cannot be mocked with Pester;
            # New-EventLog is mocked globally so the branch executes without error.
            $r = Send-HVAlert -Subject 'Test' -Body 'Body' -WriteEventLog
            # EventLogWritten=$true only if Write-EventLog succeeds (mocked globally)
            $r.EventLogWritten | Should -Be $true
            Should -Invoke Write-EventLog -Times 1
        }
    }

    Context "Severity parameter" {
        It "Accepts Info severity without error" {
            $r = Send-HVAlert -Subject 'Test' -Body 'Body' -Severity 'Info'
            $r | Should -Not -BeNullOrEmpty
        }

        It "Accepts Critical severity without error" {
            $r = Send-HVAlert -Subject 'Test' -Body 'Body' -Severity 'Critical'
            $r | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "Invoke-HVHealthAlertPolicy" {
    Context "Score above threshold" {
        It "Does not fire alert when health score is healthy" {
            Mock Get-HVClusterHealth {
                [PSCustomObject]@{
                    ClusterName = 'TestCluster'
                    Score       = 100
                    Overall     = 'Healthy'
                    Details     = @()
                    Nodes       = @()
                }
            }
            $r = Invoke-HVHealthAlertPolicy -AlertThreshold 80
            $r.AlertRequired | Should -Be $false
            $r.AlertAttempted | Should -Be $false
            $r.AlertDelivered | Should -Be $false
            $r.AlertFired | Should -Be $false
        }
    }

    Context "Score below threshold" {
        It "Fires alert when health score is below threshold" {
            Mock Get-HVClusterHealth {
                [PSCustomObject]@{
                    ClusterName = 'TestCluster'
                    Score       = 50
                    Overall     = 'Warning'
                    Details     = @('Node down')
                    Nodes       = @()
                }
            }
            Mock Send-HVAlert {
                [PSCustomObject]@{ EmailSent=$false; TeamsSent=$false; SlackSent=$false; EventLogWritten=$false; Errors=@() }
            }
            $r = Invoke-HVHealthAlertPolicy -AlertThreshold 80
            $r.AlertRequired | Should -Be $true
            $r.AlertAttempted | Should -Be $true
            $r.AlertDelivered | Should -Be $false
            $r.AlertFired | Should -Be $false
        }

        It "Uses Critical severity when score is below 50" {
            Mock Get-HVClusterHealth {
                [PSCustomObject]@{
                    ClusterName = 'TestCluster'
                    Score       = 30
                    Overall     = 'Critical'
                    Details     = @('Multiple nodes down')
                    Nodes       = @()
                }
            }
            Mock Send-HVAlert {
                [PSCustomObject]@{ EmailSent=$false; TeamsSent=$false; SlackSent=$false; EventLogWritten=$false; Errors=@() }
            }
            $result = Invoke-HVHealthAlertPolicy -AlertThreshold 80
            $result.AlertAttempted | Should -Be $true
            $result.AlertFired | Should -Be $false
            Should -Invoke Send-HVAlert -Times 1 -ParameterFilter { $Severity -eq 'Critical' }
        }

        It "Marks delivery when at least one alert channel succeeds" {
            Mock Get-HVClusterHealth {
                [PSCustomObject]@{
                    ClusterName = 'TestCluster'
                    Score       = 40
                    Overall     = 'Critical'
                    Details     = @('Node down')
                    Nodes       = @()
                }
            }
            Mock Send-HVAlert {
                [PSCustomObject]@{ EmailSent=$true; TeamsSent=$false; SlackSent=$false; EventLogWritten=$false; Errors=@() }
            }

            $result = Invoke-HVHealthAlertPolicy -AlertThreshold 80
            $result.AlertRequired | Should -Be $true
            $result.AlertAttempted | Should -Be $true
            $result.AlertDelivered | Should -Be $true
            $result.AlertFired | Should -Be $true
        }
    }
}
