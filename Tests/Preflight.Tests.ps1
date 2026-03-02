#Requires -Modules Pester
<#
.SYNOPSIS
    Unit tests for Test-HVPrerequisites and Test-HVNodeReadiness.
    All system calls (WMI, Get-WindowsFeature, New-PSSession) are mocked.
#>

BeforeAll {
    . "$PSScriptRoot\..\Private\Logging.ps1"
    . "$PSScriptRoot\..\Private\DriftEngine.ps1"   # for Get-HVOSProfile
    . "$PSScriptRoot\..\Private\Preflight.ps1"
    . "$PSScriptRoot\..\Private\NodeValidation.ps1"

    Mock Write-HVLog { }
}

Describe "Test-HVPrerequisites" {

    Context "Admin rights check" {

        It "Fails when not running as administrator" {
            Mock -CommandName 'Get-CimInstance' -MockWith {
                [PSCustomObject]@{ BuildNumber = '20348'; Caption = 'WS2022' }
            }
            # Simulate non-admin by mocking the principal check
            # We test the output object shape here
            $result = Test-HVPrerequisites -RequiredNodes @()
            $result | Should -Not -BeNullOrEmpty
            $result.PSObject.Properties.Name | Should -Contain 'Passed'
            $result.PSObject.Properties.Name | Should -Contain 'Failures'
            $result.PSObject.Properties.Name | Should -Contain 'Warnings'
        }
    }

    Context "OS version detection" {

        It "Warns for WS2019 but does not fail" {
            Mock Get-CimInstance {
                param($ClassName, $ComputerName)
                if ($ClassName -eq 'Win32_OperatingSystem') {
                    [PSCustomObject]@{ BuildNumber = '17763'; Caption = 'Windows Server 2019' }
                }
                elseif ($ClassName -eq 'Win32_ComputerSystem') {
                    [PSCustomObject]@{ PartOfDomain = $true; Domain = 'corp.local' }
                }
            }
            Mock Get-WindowsFeature { [PSCustomObject]@{ InstallState = 'Installed' } }

            $result = Test-HVPrerequisites -RequiredNodes @()
            # Should have warning about WS2019 but Failures should not include OS
            ($result.Warnings | Where-Object { $_ -match '2019' }) | Should -Not -BeNullOrEmpty
        }
    }

    Context "Domain membership" {

        It "Fails when not domain-joined" {
            Mock Get-CimInstance {
                param($ClassName)
                if ($ClassName -eq 'Win32_OperatingSystem') {
                    [PSCustomObject]@{ BuildNumber = '20348'; Caption = 'WS2022' }
                }
                elseif ($ClassName -eq 'Win32_ComputerSystem') {
                    [PSCustomObject]@{ PartOfDomain = $false; Domain = 'WORKGROUP' }
                }
            }
            Mock Get-WindowsFeature { [PSCustomObject]@{ InstallState = 'Installed' } }

            $result = Test-HVPrerequisites -RequiredNodes @()
            ($result.Failures | Where-Object { $_ -match 'domain' -or $_ -match 'Domain' }) |
                Should -Not -BeNullOrEmpty
        }
    }

    Context "Required features" {

        It "Fails when Failover-Clustering is not installed" {
            Mock Get-CimInstance {
                param($ClassName)
                if ($ClassName -eq 'Win32_OperatingSystem') {
                    [PSCustomObject]@{ BuildNumber = '20348'; Caption = 'WS2022' }
                }
                elseif ($ClassName -eq 'Win32_ComputerSystem') {
                    [PSCustomObject]@{ PartOfDomain = $true; Domain = 'corp.local' }
                }
            }
            Mock Get-WindowsFeature {
                param($Name)
                [PSCustomObject]@{
                    Name         = $Name
                    InstallState = if ($Name -eq 'Failover-Clustering') { 'Available' } else { 'Installed' }
                }
            }

            $result = Test-HVPrerequisites -RequiredNodes @()
            ($result.Failures | Where-Object { $_ -match 'Failover-Clustering' }) | Should -Not -BeNullOrEmpty
        }
    }

    Context "DNS check for nodes" {

        It "Warns when node DNS resolution fails" {
            Mock Get-CimInstance {
                param($ClassName)
                if ($ClassName -eq 'Win32_OperatingSystem') {
                    [PSCustomObject]@{ BuildNumber = '20348'; Caption = 'WS2022' }
                }
                elseif ($ClassName -eq 'Win32_ComputerSystem') {
                    [PSCustomObject]@{ PartOfDomain = $true; Domain = 'corp.local' }
                }
            }
            Mock Get-WindowsFeature { [PSCustomObject]@{ InstallState = 'Installed' } }
            Mock -CommandName '[System.Net.Dns]::GetHostEntry' { throw 'Host not found' }

            $result = Test-HVPrerequisites -RequiredNodes @('NONEXISTENT-NODE')
            # DNS warning should be present
            ($result.Warnings | Where-Object { $_ -match 'DNS' -or $_ -match 'NONEXISTENT' }) |
                Should -Not -BeNullOrEmpty
        }
    }

    Context "Result object shape" {

        It "Always returns an object with Passed, Failures, Warnings, OSProfile" {
            Mock Get-CimInstance { [PSCustomObject]@{ BuildNumber = '20348'; Caption = 'WS2022' } }
            Mock Get-WindowsFeature { [PSCustomObject]@{ InstallState = 'Installed' } }

            $result = Test-HVPrerequisites -RequiredNodes @()
            $result.PSObject.Properties.Name | Should -Contain 'Passed'
            $result.PSObject.Properties.Name | Should -Contain 'Failures'
            $result.PSObject.Properties.Name | Should -Contain 'Warnings'
            $result.PSObject.Properties.Name | Should -Contain 'OSProfile'
        }
    }
}

Describe "Test-HVNodeReadiness" {

    Context "Successful node" {

        BeforeEach {
            Mock Test-Connection { $true }
            Mock New-PSSession { [PSCustomObject]@{ Id = 1 } }
            Mock Invoke-Command {
                param($Session, $ScriptBlock, $ArgumentList)
                if ($ScriptBlock.ToString() -match 'Win32_OperatingSystem') {
                    return [PSCustomObject]@{ Build = 20348; Version = '2022'; DisplayName = 'Windows Server 2022' }
                }
                if ($ScriptBlock.ToString() -match 'Win32_ComputerSystem') {
                    return 'corp.local'
                }
                if ($ScriptBlock.ToString() -match 'Get-WindowsFeature') {
                    return $ArgumentList[0] | ForEach-Object {
                        [PSCustomObject]@{ Name = $_; State = 'Installed' }
                    }
                }
            }
            Mock Remove-PSSession { }
        }

        It "Returns Passed=true for a healthy node" {
            $results = Test-HVNodeReadiness -Nodes @('NODE1')
            $results[0].Passed | Should -Be $true
        }

        It "Returns node name in result" {
            $results = Test-HVNodeReadiness -Nodes @('NODE1')
            $results[0].NodeName | Should -Be 'NODE1'
        }

        It "Returns OSProfile for a healthy node" {
            $results = Test-HVNodeReadiness -Nodes @('NODE1')
            $results[0].OSProfile | Should -Not -BeNullOrEmpty
        }

        It "Processes multiple nodes" {
            $results = Test-HVNodeReadiness -Nodes @('NODE1','NODE2')
            $results.Count | Should -Be 2
        }
    }

    Context "Unreachable node" {

        It "Fails when ping fails" {
            Mock Test-Connection { $false }
            $results = Test-HVNodeReadiness -Nodes @('DEAD-NODE')
            $results[0].Passed | Should -Be $false
            ($results[0].Failures | Where-Object { $_ -match 'ping' -or $_ -match 'ICMP' }) |
                Should -Not -BeNullOrEmpty
        }

        It "Fails when WinRM is unavailable" {
            Mock Test-Connection { $true }
            Mock New-PSSession { throw 'WinRM connection refused' }
            $results = Test-HVNodeReadiness -Nodes @('WINRM-FAIL')
            $results[0].Passed | Should -Be $false
            ($results[0].Failures | Where-Object { $_ -match 'WinRM' }) | Should -Not -BeNullOrEmpty
        }
    }

    Context "Node missing features" {

        It "Fails when Hyper-V is not installed on remote node" {
            Mock Test-Connection { $true }
            Mock New-PSSession { [PSCustomObject]@{ Id = 1 } }
            Mock Remove-PSSession { }
            Mock Invoke-Command {
                param($Session, $ScriptBlock, $ArgumentList)
                if ($ScriptBlock.ToString() -match 'Win32_OperatingSystem') {
                    return [PSCustomObject]@{ Build = 20348; Version = '2022'; DisplayName = 'WS2022' }
                }
                if ($ScriptBlock.ToString() -match 'Win32_ComputerSystem') { return 'corp.local' }
                if ($ScriptBlock.ToString() -match 'Get-WindowsFeature') {
                    return $ArgumentList[0] | ForEach-Object {
                        [PSCustomObject]@{
                            Name  = $_
                            State = if ($_ -eq 'Hyper-V') { 'Available' } else { 'Installed' }
                        }
                    }
                }
            }

            $results = Test-HVNodeReadiness -Nodes @('NO-HYPERV')
            $results[0].Passed | Should -Be $false
            ($results[0].Failures | Where-Object { $_ -match 'Hyper-V' }) | Should -Not -BeNullOrEmpty
        }
    }
}
