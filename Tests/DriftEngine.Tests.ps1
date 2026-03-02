#Requires -Modules Pester
<#
.SYNOPSIS
    Unit tests for Get-HVDriftScore and Get-HVOSProfile.
    All cluster cmdlets are mocked — no live Hyper-V required.
#>

BeforeAll {
    # Dot-source private functions directly so we can test them in isolation.
    . "$PSScriptRoot\..\Private\Logging.ps1"
    . "$PSScriptRoot\..\Private\DriftEngine.ps1"

    # Stub Write-HVLog to suppress console noise during tests.
    Mock Write-HVLog { } -ModuleName ''
}

Describe "Get-HVDriftScore" {

    BeforeEach {
        $desired = [PSCustomObject]@{
            ClusterName = 'TestCluster'
            Nodes       = @('NODE1','NODE2')
            WitnessType = 'Disk'
        }
    }

    Context "Fully compliant state" {

        It "Returns Score=0 when everything matches" {
            $current = [PSCustomObject]@{
                ClusterName = 'TestCluster'
                Nodes       = @('NODE1','NODE2')
                WitnessType = 'NodeAndDiskMajority'
            }
            $result = Get-HVDriftScore -Desired $desired -Current $current
            $result.Score | Should -Be 0
        }

        It "Is order-insensitive for node arrays" {
            $current = [PSCustomObject]@{
                ClusterName = 'TestCluster'
                Nodes       = @('NODE2','NODE1')    # reversed
                WitnessType = 'NodeAndDiskMajority'
            }
            $result = Get-HVDriftScore -Desired $desired -Current $current
            $result.Score | Should -Be 0
        }
    }

    Context "Cluster name mismatch" {

        It "Adds 30 to score" {
            $current = [PSCustomObject]@{
                ClusterName = 'WrongCluster'
                Nodes       = @('NODE1','NODE2')
                WitnessType = 'NodeAndDiskMajority'
            }
            $result = Get-HVDriftScore -Desired $desired -Current $current
            $result.Score | Should -Be 30
        }
    }

    Context "Node membership mismatch" {

        It "Adds 30 when a node is missing" {
            $current = [PSCustomObject]@{
                ClusterName = 'TestCluster'
                Nodes       = @('NODE1')            # NODE2 missing
                WitnessType = 'NodeAndDiskMajority'
            }
            $result = Get-HVDriftScore -Desired $desired -Current $current
            $result.Score | Should -Be 30
        }

        It "Adds 30 when an unexpected node is present" {
            $current = [PSCustomObject]@{
                ClusterName = 'TestCluster'
                Nodes       = @('NODE1','NODE2','NODE3')   # extra node
                WitnessType = 'NodeAndDiskMajority'
            }
            $result = Get-HVDriftScore -Desired $desired -Current $current
            $result.Score | Should -Be 30
        }

        It "Array comparison bug is fixed (returns 30, not 0)" {
            # v7 bug: (@('A','B') -ne @('A','C')) returned @('B','C') which is truthy
            # v8 fix uses Compare-Object. This test would fail on the old code.
            $current = [PSCustomObject]@{
                ClusterName = 'TestCluster'
                Nodes       = @('NODE1','NODE3')    # NODE2 replaced by NODE3
                WitnessType = 'NodeAndDiskMajority'
            }
            $result = Get-HVDriftScore -Desired $desired -Current $current
            $result.Score | Should -Be 30
        }
    }

    Context "Witness mismatch" {

        It "Adds 40 when witness type doesn't match" {
            $current = [PSCustomObject]@{
                ClusterName = 'TestCluster'
                Nodes       = @('NODE1','NODE2')
                WitnessType = 'NodeMajority'        # None instead of Disk
            }
            $result = Get-HVDriftScore -Desired $desired -Current $current
            $result.Score | Should -Be 40
        }

        It "Accepts 'Disk' as alias for NodeAndDiskMajority" {
            $desiredDisk = [PSCustomObject]@{ ClusterName='TestCluster'; Nodes=@('NODE1','NODE2'); WitnessType='Disk' }
            $current     = [PSCustomObject]@{ ClusterName='TestCluster'; Nodes=@('NODE1','NODE2'); WitnessType='Disk' }
            $result = Get-HVDriftScore -Desired $desiredDisk -Current $current
            $result.Score | Should -Be 0
        }

        It "Accepts 'Cloud' witness variants" {
            $desiredCloud = [PSCustomObject]@{ ClusterName='TestCluster'; Nodes=@('NODE1','NODE2'); WitnessType='Cloud' }
            $current      = [PSCustomObject]@{ ClusterName='TestCluster'; Nodes=@('NODE1','NODE2'); WitnessType='CloudWitness' }
            $result = Get-HVDriftScore -Desired $desiredCloud -Current $current
            $result.Score | Should -Be 0
        }
    }

    Context "Combined drift" {

        It "Caps combined score at 100" {
            $current = [PSCustomObject]@{
                ClusterName = 'WrongCluster'        # +30
                Nodes       = @('NODEX','NODEY')    # +30
                WitnessType = 'NodeMajority'        # +40 → total 100
            }
            $result = Get-HVDriftScore -Desired $desired -Current $current
            $result.Score | Should -Be 100
        }

        It "Returns Details array with entries for each mismatch" {
            $current = [PSCustomObject]@{
                ClusterName = 'WrongCluster'
                Nodes       = @('NODEX')
                WitnessType = 'NodeMajority'
            }
            $result = Get-HVDriftScore -Desired $desired -Current $current
            $result.Details.Count | Should -BeGreaterThan 1
        }
    }

    Context "Null / missing current state" {

        It "Returns Score=100 when Current is null" {
            $result = Get-HVDriftScore -Desired $desired -Current $null
            $result.Score | Should -Be 100
        }
    }
}

Describe "Get-HVOSProfile" {

    It "Returns a PSCustomObject with expected properties" {
        Mock Get-CimInstance {
            [PSCustomObject]@{ BuildNumber = '26100'; Caption = 'Windows Server 2025 Datacenter' }
        }
        $profile = Get-HVOSProfile -ComputerName 'localhost'
        $profile.PSObject.Properties.Name | Should -Contain 'Version'
        $profile.PSObject.Properties.Name | Should -Contain 'Build'
        $profile.PSObject.Properties.Name | Should -Contain 'DisplayName'
    }

    It "Identifies WS2025 from build 26100" {
        Mock Get-CimInstance {
            [PSCustomObject]@{ BuildNumber = '26100'; Caption = 'Windows Server 2025' }
        }
        $profile = Get-HVOSProfile -ComputerName 'localhost'
        $profile.Version | Should -Be '2025'
    }

    It "Identifies WS2022 from build 20348" {
        Mock Get-CimInstance {
            [PSCustomObject]@{ BuildNumber = '20348'; Caption = 'Windows Server 2022' }
        }
        $profile = Get-HVOSProfile -ComputerName 'localhost'
        $profile.Version | Should -Be '2022'
    }

    It "Returns Unknown for unrecognized builds" {
        Mock Get-CimInstance {
            [PSCustomObject]@{ BuildNumber = '10000'; Caption = 'Some Old OS' }
        }
        $profile = Get-HVOSProfile -ComputerName 'localhost'
        $profile.Version | Should -Be 'Unknown'
    }

    It "Handles CimInstance failure gracefully" {
        Mock Get-CimInstance { throw "WinRM unavailable" }
        { Get-HVOSProfile -ComputerName 'unreachable' } | Should -Not -Throw
        $profile = Get-HVOSProfile -ComputerName 'unreachable'
        $profile.Version | Should -Be 'Unknown'
    }
}
