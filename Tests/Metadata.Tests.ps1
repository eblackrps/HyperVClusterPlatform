#Requires -Modules Pester

Describe "Release metadata" {
    BeforeAll {
        $manifest = Import-PowerShellDataFile -Path "$PSScriptRoot\..\HyperVClusterPlatform.psd1"
        $changelog = Get-Content "$PSScriptRoot\..\CHANGELOG.md" -Raw
        $roadmap = Get-Content "$PSScriptRoot\..\ROADMAP.md" -Raw
        $readme = Get-Content "$PSScriptRoot\..\README.md" -Raw
    }

    It "Keeps the top changelog entry aligned with the manifest version" {
        $topVersion = ([regex]::Match($changelog, '^## \[(?<Version>[^\]]+)\]', [System.Text.RegularExpressions.RegexOptions]::Multiline)).Groups['Version'].Value
        $topVersion | Should -Be $manifest.ModuleVersion
    }

    It "Keeps the roadmap latest released round aligned with the manifest version" {
        $roadmapVersion = ([regex]::Match($roadmap, '^## Round \d+ .*?v(?<Version>\d+\.\d+\.\d+)', [System.Text.RegularExpressions.RegexOptions]::Multiline)).Groups['Version'].Value
        $roadmapVersion | Should -Be $manifest.ModuleVersion
    }

    It "Mentions the current version in manifest release notes" {
        $manifest.PrivateData.PSData.ReleaseNotes | Should -Match ([regex]::Escape($manifest.ModuleVersion))
    }

    It "Documents the current cluster validation and rollback result fields in the README" {
        $readme | Should -Match '\| `ClusterValidationStatus` \|'
        $readme | Should -Match '\| `RollbackStatus` \|'
    }
}
