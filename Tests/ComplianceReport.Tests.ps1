#Requires -Modules Pester
BeforeAll {
    . "$PSScriptRoot\..\Private\Logging.ps1"
    . "$PSScriptRoot\..\Private\ComplianceReport.ps1"
    Mock Write-HVLog { }
}

Describe "New-HVComplianceReport" {
    It "HTML-encodes drift details without duplicating them" {
        $tmp = [System.IO.Path]::GetTempPath()
        $reportPath = New-HVComplianceReport `
            -DriftResult ([PSCustomObject]@{ Score = 40; Details = @('<b>unsafe</b>') }) `
            -ReportsPath $tmp `
            -ClusterName 'ProdCluster' `
            -Mode 'Audit'

        $content = Get-Content $reportPath -Raw
        $content | Should -Match '&lt;b&gt;unsafe&lt;/b&gt;'
        $content | Should -Not -Match '<li><b>unsafe</b></li>'
        ([regex]::Matches($content, '&lt;b&gt;unsafe&lt;/b&gt;')).Count | Should -Be 1

        Remove-Item $reportPath -Force -ErrorAction SilentlyContinue
    }
}
