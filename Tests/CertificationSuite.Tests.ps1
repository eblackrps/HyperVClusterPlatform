#Requires -Modules Pester
BeforeAll {
    . "$PSScriptRoot\_Stubs.ps1"
    . "$PSScriptRoot\..\Private\Logging.ps1"
    . "$PSScriptRoot\..\Private\Configuration.ps1"
    . "$PSScriptRoot\..\Private\Snapshot.ps1"
    . "$PSScriptRoot\..\Private\DesiredState.ps1"
    . "$PSScriptRoot\..\Private\DriftEngine.ps1"
    . "$PSScriptRoot\..\Private\HealthCheck.ps1"
    . "$PSScriptRoot\..\Private\NetworkConfig.ps1"
    . "$PSScriptRoot\..\Private\StorageConfig.ps1"
    . "$PSScriptRoot\..\Private\VMPlacement.ps1"
    . "$PSScriptRoot\..\Private\LiveMigration.ps1"
    . "$PSScriptRoot\..\Private\DisasterRecovery.ps1"
    . "$PSScriptRoot\..\Private\CertificationSuite.ps1"

    Mock Write-HVLog { }
    Mock Initialize-HVLogging { }

    # Cluster infrastructure mocks — baseline all-healthy
    Mock Get-Cluster              { [PSCustomObject]@{ Name = 'ProdCluster' } }
    Mock Get-ClusterNode          { @(
        [PSCustomObject]@{ Name='N1'; State='Up' }
        [PSCustomObject]@{ Name='N2'; State='Up' }
    )}
    Mock Get-ClusterQuorum        { [PSCustomObject]@{ QuorumType='NodeAndDiskMajority' } }
    Mock Get-ClusterGroup         { @([PSCustomObject]@{Name='Core';State='Online'}) }
    Mock Get-ClusterNetwork       { @([PSCustomObject]@{Name='Net1';Role=3}) }
    Mock Get-ClusterSharedVolume  { @([PSCustomObject]@{Name='CSV1';State='Online';SharedVolumeInfo=@([PSCustomObject]@{Partition=[PSCustomObject]@{Size=107374182400;FreeSpace=53687091200}})}) }
    Mock Get-ClusterResource      { @() }
    Mock Get-VM                   { @() }
    Mock Get-VMHost               { [PSCustomObject]@{ VirtualMachineMigrationEnabled=$true } }
    Mock Get-Module {
        param([string[]]$Name, [switch]$ListAvailable)
        if ($ListAvailable -and $Name -contains 'Microsoft.PowerShell.SecretManagement') {
            return [PSCustomObject]@{ Name = 'Microsoft.PowerShell.SecretManagement'; Version = '1.1.0' }
        }
        return $null
    }
    Mock Get-HVDesiredState       { [PSCustomObject]@{ ClusterName='ProdCluster'; Nodes=@('N1','N2'); WitnessType='None' } }
    Mock Get-HVClusterCurrentState { [PSCustomObject]@{ ClusterName='ProdCluster'; Nodes=@('N1','N2'); WitnessType='None'; DomainName='test.local' } }
    Mock Get-HVDriftScore         { [PSCustomObject]@{ Score=0; Details=@() } }

    function New-CertificationConfigFile {
        $path = [System.IO.Path]::GetTempFileName() -replace '\.tmp$','.json'
        @{
            ClusterName = 'ProdCluster'
            Nodes = @('N1','N2')
            ClusterIP = '10.0.0.10'
            WitnessType = 'None'
            ApiTokenSecretName = 'ClusterApiToken'
        } | ConvertTo-Json -Depth 5 | Set-Content -Path $path -Encoding UTF8
        return $path
    }
}

Describe "Invoke-HVCertificationSuite" {
    Context "All-passing scenario" {
        It "Returns Certified=true when all domains pass" {
            $tmp = [System.IO.Path]::GetTempPath()
            $cfg = New-CertificationConfigFile
            $result = Invoke-HVCertificationSuite -ClusterName 'ProdCluster' -Nodes @('N1','N2') `
                                                   -ReportsPath $tmp -SkipLiveMigrationTest `
                                                   -DesiredNetworkRoleMap @{ Net1 = 3 } `
                                                   -DesiredCSVCount 1 -DesiredMinTotalGB 100 `
                                                   -ConfigFile $cfg -RequireSecretBackedConfig
            $result.Certified    | Should -Be $true
            $result.OverallScore | Should -BeGreaterThan 80
            Remove-Item (Join-Path $tmp 'Certification-*.html') -Force -ErrorAction SilentlyContinue
            Remove-Item $cfg -Force -ErrorAction SilentlyContinue
        }

        It "Returns a Domains array with 10 entries" {
            $tmp = [System.IO.Path]::GetTempPath()
            $cfg = New-CertificationConfigFile
            $result = Invoke-HVCertificationSuite -ClusterName 'ProdCluster' -Nodes @('N1','N2') `
                                                   -ReportsPath $tmp -SkipLiveMigrationTest `
                                                   -DesiredNetworkRoleMap @{ Net1 = 3 } `
                                                   -DesiredCSVCount 1 -DesiredMinTotalGB 100 `
                                                   -ConfigFile $cfg -RequireSecretBackedConfig
            $result.Domains.Count | Should -Be 10
            Remove-Item (Join-Path $tmp 'Certification-*.html') -Force -ErrorAction SilentlyContinue
            Remove-Item $cfg -Force -ErrorAction SilentlyContinue
        }

        It "Creates an HTML report file" {
            $tmp = [System.IO.Path]::GetTempPath()
            $cfg = New-CertificationConfigFile
            $result = Invoke-HVCertificationSuite -ClusterName 'ProdCluster' -Nodes @('N1','N2') `
                                                   -ReportsPath $tmp -SkipLiveMigrationTest `
                                                   -DesiredNetworkRoleMap @{ Net1 = 3 } `
                                                   -DesiredCSVCount 1 -DesiredMinTotalGB 100 `
                                                   -ConfigFile $cfg -RequireSecretBackedConfig
            Test-Path $result.ReportPath | Should -Be $true
            Remove-Item $result.ReportPath -Force -ErrorAction SilentlyContinue
            Remove-Item $cfg -Force -ErrorAction SilentlyContinue
        }
    }

    Context "Cluster not found" {
        It "Returns Certified=false when cluster does not exist" {
            Mock Get-Cluster { $null }
            $tmp = [System.IO.Path]::GetTempPath()
            $result = Invoke-HVCertificationSuite -ClusterName 'MissingCluster' -Nodes @('N1','N2') `
                                                   -ReportsPath $tmp -SkipLiveMigrationTest
            $result.Certified | Should -Be $false
            $clusterCoreDomain = $result.Domains | Where-Object Domain -eq 'ClusterCore'
            $clusterCoreDomain.Pass | Should -Be $false
            Remove-Item (Join-Path $tmp 'Certification-*.html') -Force -ErrorAction SilentlyContinue
        }
    }

    Context "Node membership mismatch" {
        It "ClusterCore domain fails when node list differs" {
            Mock Get-ClusterNode { @([PSCustomObject]@{Name='N1';State='Up'}) }
            $tmp = [System.IO.Path]::GetTempPath()
            $result = Invoke-HVCertificationSuite -ClusterName 'ProdCluster' -Nodes @('N1','N2') `
                                                   -ReportsPath $tmp -SkipLiveMigrationTest
            $clusterCoreDomain = $result.Domains | Where-Object Domain -eq 'ClusterCore'
            $clusterCoreDomain.Pass  | Should -Be $false
            $clusterCoreDomain.Score | Should -Be 50
            Remove-Item (Join-Path $tmp 'Certification-*.html') -Force -ErrorAction SilentlyContinue
        }
    }

    Context "Return object structure" {
        It "Contains expected top-level properties" {
            $tmp = [System.IO.Path]::GetTempPath()
            $cfg = New-CertificationConfigFile
            $result = Invoke-HVCertificationSuite -ClusterName 'ProdCluster' -Nodes @('N1','N2') `
                                                   -ReportsPath $tmp -SkipLiveMigrationTest `
                                                   -DesiredNetworkRoleMap @{ Net1 = 3 } `
                                                   -DesiredCSVCount 1 -DesiredMinTotalGB 100 `
                                                   -ConfigFile $cfg -RequireSecretBackedConfig
            $props = $result.PSObject.Properties.Name
            $props | Should -Contain 'Certified'
            $props | Should -Contain 'OverallScore'
            $props | Should -Contain 'Domains'
            $props | Should -Contain 'ReportPath'
            $props | Should -Contain 'Timestamp'
            Remove-Item (Join-Path $tmp 'Certification-*.html') -Force -ErrorAction SilentlyContinue
            Remove-Item $cfg -Force -ErrorAction SilentlyContinue
        }
    }

    Context "Missing evidence-based policy" {
        It "Fails the Network domain when no desired role policy is provided" {
            $tmp = [System.IO.Path]::GetTempPath()
            $result = Invoke-HVCertificationSuite -ClusterName 'ProdCluster' -Nodes @('N1','N2') `
                                                   -ReportsPath $tmp -SkipLiveMigrationTest
            $networkDomain = $result.Domains | Where-Object Domain -eq 'Network'
            $networkDomain.Pass | Should -Be $false
            Remove-Item (Join-Path $tmp 'Certification-*.html') -Force -ErrorAction SilentlyContinue
        }
    }
}
