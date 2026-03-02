@{
    RootModule        = 'HyperVClusterPlatform.psm1'
    ModuleVersion     = '8.0.0'
    GUID              = 'b5c96ad8-5ffb-4f70-9e3c-3e0ff1f31d1f'
    Author            = 'E. Black'
    CompanyName       = ''
    Copyright         = '(c) 2026 E. Black. All rights reserved.'
    Description       = 'Hyper-V Cluster deployment + compliance platform (Audit/Enforce/Remediate). Supports Windows Server 2022 and 2025.'
    PowerShellVersion = '5.1'

    # FailoverClusters is the built-in module — listed as required so Import-Module
    # gives a clear error if clustering isn't installed, rather than a cryptic one at runtime.
    RequiredModules   = @()    # Intentionally empty: FailoverClusters is validated at runtime by Test-HVPrerequisites

    FunctionsToExport = @('Invoke-HVClusterPlatform')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    FileList          = @(
        'HyperVClusterPlatform.psm1'
        'Public\Invoke-HVClusterPlatform.ps1'
        'Private\Logging.ps1'
        'Private\DesiredState.ps1'
        'Private\Preflight.ps1'
        'Private\NodeValidation.ps1'
        'Private\Snapshot.ps1'
        'Private\DriftEngine.ps1'
        'Private\ComplianceReport.ps1'
        'Private\Enforcement.ps1'
        'Private\Rollback.ps1'
        'Private\Configuration.ps1'
    )

    PrivateData = @{
        PSData = @{
            Tags         = @('Hyper-V','FailoverClusters','Compliance','Automation','DSC','WS2022','WS2025')
            LicenseUri   = 'https://github.com/eblackrps/Hyper-v_cluster_scaffold/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/eblackrps/Hyper-v_cluster_scaffold'
            ReleaseNotes = @'
v8.0.0 — Production hardening release:
  - BUGFIX: DriftEngine array comparison rewritten with Compare-Object (symmetric diff)
  - NEW: OS detection (WS2022 build 20348 / WS2025 build 26100) via Get-HVOSProfile
  - NEW: Pre-flight checks (admin, OS, features, domain, DNS) via Test-HVPrerequisites
  - NEW: Per-node WinRM + feature + domain validation via Test-HVNodeReadiness
  - NEW: File-based rotating log via Initialize-HVLogging / Write-HVLog
  - NEW: Full witness support — Disk, Cloud (Azure Blob), FileShare, None
  - NEW: Real rollback engine — removes cluster or added nodes based on snapshot diff
  - NEW: Snapshot captures ClusterExistedBefore flag for accurate rollback decisions
  - NEW: JSON config file support with environment overrides via Import-HVClusterConfig
  - NEW: Invoke-HVClusterPlatform gains ConfigFile, LogPath, SkipPreFlight, SkipNodeValidation params
  - NEW: 4 Pester test files with full mocking (DriftEngine, Preflight, Rollback, Configuration)
  - IMPROVED: ComplianceReport shows drift detail lines, OS version, and run mode
  - IMPROVED: CI pipelines — PSScriptAnalyzer lint + Pester run + manifest validation
'@
        }
    }
}
