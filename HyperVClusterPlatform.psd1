@{
    RootModule        = 'HyperVClusterPlatform.psm1'
    ModuleVersion     = '21.0.1'
    GUID              = 'b5c96ad8-5ffb-4f70-9e3c-3e0ff1f31d1f'
    Author            = 'E. Black'
    CompanyName       = ''
    Copyright         = '(c) 2026 E. Black. All rights reserved.'
    Description       = 'Hyper-V Cluster deployment, compliance, and fleet management platform (Audit/Enforce/Remediate). Supports Windows Server 2022 and 2025. Includes network automation, VM placement, storage, health monitoring, alerting, secret management, fleet orchestration, live migration, DR, and production certification.'
    PowerShellVersion = '5.1'

    # FailoverClusters and Hyper-V are validated at runtime by Test-HVPrerequisites.
    RequiredModules   = @()

    FunctionsToExport = @(
        'Invoke-HVClusterPlatform'
        'Invoke-HVClusterFleet'
        'Get-HVClusterHealth'
        'Invoke-HVHealthAlertPolicy'
        'Invoke-HVCertificationSuite'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    FileList          = @(
        'HyperVClusterPlatform.psm1'
        'Public\Invoke-HVClusterPlatform.ps1'
        'Public\Invoke-HVClusterFleet.ps1'
        'Private\Logging.ps1'
        'Private\CommandAliases.ps1'
        'Private\DesiredState.ps1'
        'Private\Preflight.ps1'
        'Private\NodeValidation.ps1'
        'Private\Snapshot.ps1'
        'Private\DriftEngine.ps1'
        'Private\ComplianceReport.ps1'
        'Private\Enforcement.ps1'
        'Private\Rollback.ps1'
        'Private\Configuration.ps1'
        'Private\NetworkConfig.ps1'
        'Private\VMPlacement.ps1'
        'Private\StorageConfig.ps1'
        'Private\HealthCheck.ps1'
        'Private\Alerting.ps1'
        'Private\SecretManagement.ps1'
        'Private\TelemetryExport.ps1'
        'Private\LiveMigration.ps1'
        'Private\DisasterRecovery.ps1'
        'Private\CertificationSuite.ps1'
    )

    PrivateData = @{
        PSData = @{
            Tags         = @('Hyper-V','FailoverClusters','Compliance','Automation','DSC',
                             'WS2022','WS2025','LiveMigration','DisasterRecovery','FleetManagement',
                             'HealthMonitoring','SecretManagement','Certification')
            LicenseUri   = 'https://github.com/eblackrps/HyperVClusterPlatform/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/eblackrps/HyperVClusterPlatform'
            ReleaseNotes = @'
v21.0.1 — Release alignment patch:
  - Activated GitHub Actions CI from `.github/workflows/ci.yml`
  - Corrected hosted-runner Pester configuration and artifact publishing behavior
  - Refreshed workflow actions to current supported major versions
  - Aligned README, roadmap, and module metadata with the released patch version
'@
        }
    }
}
