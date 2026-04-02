# Roadmap

Fifteen completed development rounds delivering a fully production-ready HyperVClusterPlatform.
Each round represents a discrete, shippable improvement.

---

## Round 15 — v21.0.1 ✅ RELEASED

Release alignment and CI activation:
- Moved the GitHub Actions workflow into `.github/workflows/ci.yml` so remote CI is active
- Corrected hosted-runner Pester configuration and artifact publishing
- Refreshed workflow dependencies to current supported action versions
- Aligned manifest, README, and release metadata with the published patch version

---

## Round 14 — v21.0.0 ✅ RELEASED

Production hardening and release cleanup:
- Pinned FailoverClusters and Hyper-V command resolution to the Windows modules used by the platform
- Fixed end-to-end secret-backed config loading and redacted sensitive override logging
- Added Cloud witness support to the DSC resource
- Corrected certification witness handling and compliance report HTML encoding
- Promoted health, alert policy, and certification commands into the supported public export surface
- Added production-focused lint settings, a repository license file, and removed tracked generated test output

---

## Round 1 — v8.0.0 ✅ RELEASED

Core hardening and automation foundations:
- OS detection (WS2019 / WS2022 / WS2025)
- Pre-flight checks (admin, OS, features, domain, DNS)
- Per-node WinRM + feature validation
- File-based rotating logs
- Full witness support (Disk / Cloud / FileShare / None)
- Real rollback engine (snapshot-diff based)
- JSON config files with environment overrides
- Comprehensive mocked Pester test suite (5 files)
- CI: PSScriptAnalyzer lint + Pester + manifest validation

---

## Round 2 — v9.0.0 ✅ RELEASED

Network automation — adapter classification and Live Migration network assignment:
- `Private/NetworkConfig.ps1`
  - Discover all adapters on each node via `Win32_NetworkAdapter`
  - Classify as: Management, LiveMigration, Storage, Unclassified
  - Network drift scoring (+score per role mismatch or missing adapter)
- `Tests/NetworkConfig.Tests.ps1` (mocked)

---

## Round 3 — v10.0.0 ✅ RELEASED

VM placement and preferred-owner policies:
- `Private/VMPlacement.ps1`
  - `Get-HVVMPlacementState` — reads current preferred owners from cluster groups
  - `Get-HVVMPlacementDrift` — scores drift against desired placement policy
- `Tests/VMPlacement.Tests.ps1`

---

## Round 4 — v11.0.0 ✅ RELEASED

Full DSC resource implementation:
- `DSC/HVClusterResource/HVClusterResource.psm1` — full `Get-`, `Test-`, `Set-TargetResource`
  - `Get`: queries live cluster state
  - `Test`: calls `Get-HVDriftScore`, returns `$false` if drift > 0
  - `Set`: calls `Invoke-HVClusterPlatform -Mode Enforce`

---

## Round 5 — v12.0.0 ✅ RELEASED

Cluster Shared Volumes and storage automation:
- `Private/StorageConfig.ps1`
  - `Get-HVCSVState` — enumerates current CSVs with state and owner
  - `Get-HVStorageDrift` — scores drift against MinCSVCount and RequireAllOnline constraints
- `Tests/StorageConfig.Tests.ps1`

---

## Round 6 — v13.0.0 ✅ RELEASED

Health monitoring and multi-channel alerting:
- `Private/HealthCheck.ps1`
  - `Get-HVClusterHealth` — node/resource/CSV/quorum health, 0–100 score
- `Private/Alerting.ps1`
  - `Send-HVAlert` — email, Teams Adaptive Card, Slack webhook, Windows Event Log
  - `Invoke-HVHealthAlertPolicy` — policy-based health check + alert dispatch
- `Tests/HealthCheck.Tests.ps1`, `Tests/Alerting.Tests.ps1`

---

## Round 7 — v14.0.0 ✅ RELEASED

Secret management integration — eliminate cleartext credentials from config files:
- `Private/SecretManagement.ps1`
  - `Get-HVSecret` — SecretManagement vault with CredentialManager fallback
  - `ConvertFrom-HVSecureString` — SecureString to plaintext
  - `Resolve-HVConfigSecrets` — resolves `*SecretName` config properties at load time
- `Tests/SecretManagement.Tests.ps1`

---

## Round 8 — v15.0.0 ✅ RELEASED

Multi-cluster fleet orchestration:
- `Public/Invoke-HVClusterFleet.ps1`
- `-FleetConfigFile` or `-ConfigFiles` parameter sets
  - Sequential or `-Parallel` (PS 7) execution
  - Fleet HTML roll-up report with per-cluster drift scores
- `Tests/Fleet.Tests.ps1`

---

## Round 9 — v16.0.0 ✅ RELEASED

Enhanced reporting and JSON telemetry:
- `Private/TelemetryExport.ps1`
  - `Export-HVTelemetry` — structured JSON metrics file per run
  - Compatible with Elastic, Splunk, Azure Monitor
- `Private/ComplianceReport.ps1` v2
  - Chart.js drift trend line chart (reads historical snapshots)
  - Per-check detail table and executive summary section

---

## Round 10 — v17.0.0 ✅ RELEASED

PSGallery publish and auto-versioning CI:
- `Scripts/Update-ModuleVersion.ps1` — bumps `.psd1` version from git tags
- `Scripts/New-Release.ps1` — creates GitHub release via `gh` CLI with auto-extracted changelog body
- PSGallery publish job in `.github/workflows/ci.yml` (triggered on release tag push)

---

## Round 11 — v18.0.0 ✅ RELEASED

Live migration orchestration:
- `Private/LiveMigration.ps1`
  - `Get-HVMigrationReadiness` — validates node state + VM migration enabled on Hyper-V host
  - `Start-HVLiveMigration` — orchestrates `Move-ClusterVirtualMachineRole`
- `Tests/LiveMigration.Tests.ps1`

---

## Round 12 — v19.0.0 ✅ RELEASED

Disaster recovery snapshots and readiness scoring:
- `Private/DisasterRecovery.ps1`
  - `New-HVDRSnapshot` — full cluster state snapshot (nodes, quorum, CSVs, resource groups)
  - `Test-HVDRReadiness` — scores readiness against MinNodeCount, quorum, and CSV requirements
- `Tests/DisasterRecovery.Tests.ps1`

---

## Round 13 — v20.0.0 ✅ RELEASED

Production certification suite — 10-domain compliance gate:
- `Private/CertificationSuite.ps1`
  - `Invoke-HVCertificationSuite` — runs ClusterCore, NodeHealth, NetworkConfig, StorageConfig,
    WitnessConfig, SecurityBaseline, DSCCompliance, TelemetryExport, LiveMigration, DisasterRecovery
  - Returns `Certified` (bool), per-domain results, overall score, and HTML report path
- `Tests/CertificationSuite.Tests.ps1`
- Module version: **20.0.0** — 121 tests passing, 0 failures

---

## Legend

| Status | Meaning |
|---|---|
| ✅ RELEASED | Shipped in a tagged release |
| 🔄 IN PROGRESS | Active development |
| 📋 PLANNED | Scoped, not started |
