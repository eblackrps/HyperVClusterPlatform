#Requires -Modules Pester
BeforeAll {
    . "$PSScriptRoot\_Stubs.ps1"
    . "$PSScriptRoot\..\Private\Logging.ps1"
    . "$PSScriptRoot\..\Private\Snapshot.ps1"
    . "$PSScriptRoot\..\Private\DisasterRecovery.ps1"
    Mock Write-HVLog { }
    Mock Get-Cluster              { $null }
    Mock Get-ClusterNode          { @() }
    Mock Get-ClusterQuorum        { $null }
    Mock Get-ClusterGroup         { @() }
    Mock Get-ClusterNetwork       { @() }
    Mock Get-ClusterResource      { @() }
    Mock Get-ClusterSharedVolume  { @() }
    Mock Get-VM                   { @() }
}

Describe "Export-HVDRSnapshot" {
    It "Creates a JSON file" {
        $tmp = [System.IO.Path]::GetTempPath()
        $path = Export-HVDRSnapshot -ReportsPath $tmp -PrimarySite 'SiteA' -SecondarySite 'SiteB'
        Test-Path $path | Should -Be $true
        Remove-Item $path -Force
    }
    It "Snapshot contains required fields" {
        $tmp  = [System.IO.Path]::GetTempPath()
        $path = Export-HVDRSnapshot -ReportsPath $tmp
        $data = Get-Content $path -Raw | ConvertFrom-Json
        $data.PSObject.Properties.Name | Should -Contain 'SchemaVersion'
        $data.PSObject.Properties.Name | Should -Contain 'PrimarySite'
        $data.PSObject.Properties.Name | Should -Contain 'ClusterExistedBefore'
        Remove-Item $path -Force
    }
}

Describe "Test-HVDRReadiness" {
    Context "Insufficient nodes" {
        It "Fails MinNodeCount check when no nodes are Up" {
            Mock Get-ClusterNode          { @() }
            Mock Get-ClusterQuorum        { [PSCustomObject]@{ QuorumType='NodeMajority' } }
            Mock Get-ClusterGroup         { @() }
            Mock Get-ClusterSharedVolume  { @() }
            $result = Test-HVDRReadiness
            $failedCheck = $result.Checks | Where-Object Check -eq 'MinNodeCount'
            $failedCheck.Pass | Should -Be $false
        }
    }

    Context "All checks pass" {
        It "Returns Ready=true with 2+ Up nodes, quorum, online groups and CSVs" {
            Mock Get-ClusterNode          { @([PSCustomObject]@{State='Up'}, [PSCustomObject]@{State='Up'}) }
            Mock Get-ClusterQuorum        { [PSCustomObject]@{ QuorumType='NodeAndDiskMajority' } }
            Mock Get-ClusterGroup         { @([PSCustomObject]@{Name='Core'; State='Online'}) }
            Mock Get-ClusterSharedVolume  { @([PSCustomObject]@{Name='CSV1'; State='Online'}) }
            $result = Test-HVDRReadiness
            $result.Ready | Should -Be $true
        }
    }
}
