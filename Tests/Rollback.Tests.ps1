#Requires -Modules Pester
<#
.SYNOPSIS
    Unit tests for Restore-HVClusterSnapshot (rollback engine).
    Uses temp files for snapshot fixtures; all cluster cmdlets are mocked.
#>

BeforeAll {
    . "$PSScriptRoot\..\Private\Logging.ps1"
    . "$PSScriptRoot\..\Private\Rollback.ps1"

    Mock Write-HVLog { }

    # Helper: write a minimal snapshot JSON to a temp file.
    function New-TestSnapshot {
        param([bool]$ClusterExistedBefore, [string[]]$NodeNames = @())
        $path = [System.IO.Path]::GetTempFileName()
        $snap = @{
            SchemaVersion        = '8.0'
            Timestamp            = (Get-Date).ToString('o')
            ClusterExistedBefore = $ClusterExistedBefore
            Nodes                = $NodeNames | ForEach-Object { @{ Name = $_ } }
            Quorum               = @{ QuorumType = 'NodeAndDiskMajority' }
        }
        $snap | ConvertTo-Json -Depth 5 | Set-Content -Path $path -Encoding UTF8
        return $path
    }
}

AfterAll {
    # Temp files cleaned up automatically by OS.
}

Describe "Restore-HVClusterSnapshot" {

    Context "Snapshot file issues" {

        It "Throws when snapshot file does not exist" {
            { Restore-HVClusterSnapshot -SnapshotPath 'C:\nonexistent\snapshot.json' -Force } |
                Should -Throw
        }

        It "Throws when snapshot is invalid JSON" {
            $bad = [System.IO.Path]::GetTempFileName()
            Set-Content -Path $bad -Value 'NOT { valid json }'
            { Restore-HVClusterSnapshot -SnapshotPath $bad -Force } | Should -Throw
            Remove-Item $bad -Force
        }
    }

    Context "No cluster currently exists" {

        It "Returns Success=true with no actions when cluster already gone" {
            Mock Get-Cluster { $null }
            $snap = New-TestSnapshot -ClusterExistedBefore $false
            $result = Restore-HVClusterSnapshot -SnapshotPath $snap -Force
            $result.Success | Should -Be $true
            Remove-Item $snap -Force
        }
    }

    Context "Cluster was created by this run (ClusterExistedBefore=false)" {

        It "Calls Remove-Cluster to destroy the cluster" {
            $clusterObj = [PSCustomObject]@{ Name = 'TestCluster' }
            Mock Get-Cluster { $clusterObj }
            Mock Remove-Cluster { }

            $snap = New-TestSnapshot -ClusterExistedBefore $false
            $result = Restore-HVClusterSnapshot -SnapshotPath $snap -Force
            Should -Invoke Remove-Cluster -Times 1
            $result.Success | Should -Be $true
            Remove-Item $snap -Force
        }

        It "Records the removal in Actions" {
            $clusterObj = [PSCustomObject]@{ Name = 'TestCluster' }
            Mock Get-Cluster { $clusterObj }
            Mock Remove-Cluster { }

            $snap = New-TestSnapshot -ClusterExistedBefore $false
            $result = Restore-HVClusterSnapshot -SnapshotPath $snap -Force
            ($result.Actions | Where-Object { $_ -match 'Removed cluster' }) | Should -Not -BeNullOrEmpty
            Remove-Item $snap -Force
        }
    }

    Context "Cluster existed before (ClusterExistedBefore=true)" {

        It "Does NOT call Remove-Cluster" {
            $clusterObj = [PSCustomObject]@{ Name = 'TestCluster' }
            Mock Get-Cluster { $clusterObj }
            Mock Get-ClusterNode { @([PSCustomObject]@{ Name = 'NODE1' }, [PSCustomObject]@{ Name = 'NODE2' }) }
            Mock Remove-Cluster { }

            # Snapshot had NODE1 only; NODE2 was added during run
            $snap = New-TestSnapshot -ClusterExistedBefore $true -NodeNames @('NODE1')
            Restore-HVClusterSnapshot -SnapshotPath $snap -Force | Out-Null
            Should -Invoke Remove-Cluster -Times 0
            Remove-Item $snap -Force
        }

        It "Calls Remove-ClusterNode for nodes added during enforcement" {
            $clusterObj = [PSCustomObject]@{ Name = 'TestCluster' }
            Mock Get-Cluster { $clusterObj }
            Mock Get-ClusterNode { @([PSCustomObject]@{ Name='NODE1' }, [PSCustomObject]@{ Name='NODE2' }) }
            Mock Remove-ClusterNode { }

            $snap = New-TestSnapshot -ClusterExistedBefore $true -NodeNames @('NODE1')
            Restore-HVClusterSnapshot -SnapshotPath $snap -Force | Out-Null
            Should -Invoke Remove-ClusterNode -Times 1 -ParameterFilter { $Name -eq 'NODE2' }
            Remove-Item $snap -Force
        }

        It "Does not remove nodes that were in the snapshot" {
            $clusterObj = [PSCustomObject]@{ Name = 'TestCluster' }
            Mock Get-Cluster { $clusterObj }
            Mock Get-ClusterNode { @([PSCustomObject]@{ Name='NODE1' }, [PSCustomObject]@{ Name='NODE2' }) }
            Mock Remove-ClusterNode { }

            # Both nodes were in the snapshot — nothing to remove
            $snap = New-TestSnapshot -ClusterExistedBefore $true -NodeNames @('NODE1','NODE2')
            $result = Restore-HVClusterSnapshot -SnapshotPath $snap -Force
            Should -Invoke Remove-ClusterNode -Times 0
            ($result.Actions | Where-Object { $_ -match 'No node changes' }) | Should -Not -BeNullOrEmpty
            Remove-Item $snap -Force
        }
    }

    Context "Result object shape" {

        It "Always returns Success, Actions, Errors properties" {
            Mock Get-Cluster { $null }
            $snap   = New-TestSnapshot -ClusterExistedBefore $false
            $result = Restore-HVClusterSnapshot -SnapshotPath $snap -Force
            $result.PSObject.Properties.Name | Should -Contain 'Success'
            $result.PSObject.Properties.Name | Should -Contain 'Actions'
            $result.PSObject.Properties.Name | Should -Contain 'Errors'
            Remove-Item $snap -Force
        }
    }
}
