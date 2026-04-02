# Changelog

All notable changes to HyperVClusterPlatform are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [21.0.1] — 2026-04-02

### Fixed
- **GitHub Actions activation**: moved the CI workflow into `.github/workflows/ci.yml` so GitHub executes lint, Pester, and smoke validation on pushes and pull requests.
- **GitHub-hosted Pester execution**: corrected the workflow to use `Run.PassThru` in the Pester configuration object so the test job runs cleanly on hosted runners and publishes artifacts reliably.
- **Workflow runtime currency**: updated GitHub Actions dependencies to `actions/checkout@v6` and `actions/upload-artifact@v7`.

### Changed
- **Module manifest**: Version bumped to `21.0.1`.
- **Release metadata**: README, roadmap, and in-module version banners now align with the current patch release.

---

## [21.0.0] — 2026-04-02

### Added
- **Public operational exports**: `Get-HVClusterHealth`, `Invoke-HVHealthAlertPolicy`, and `Invoke-HVCertificationSuite` are now supported exports alongside the main platform and fleet entry points.
- **`Tests/ComplianceReport.Tests.ps1`**: Regression coverage for HTML-encoded drift details so report output cannot duplicate entries or emit raw markup.
- **`LICENSE`** and **`PSScriptAnalyzerSettings.psd1`**: production repository metadata and lint settings aligned to the maintained code surface.

### Fixed
- **Command resolution hardening**: pinned FailoverClusters and Hyper-V cmdlets to the intended Windows modules so VMware PowerCLI command collisions no longer break cluster, rollback, or live-migration flows.
- **Secret-backed config loading**: preserved `*SecretName` properties through config import, resolved them during platform execution, and redacted sensitive override values in logs.
- **Compliance report safety**: drift details are now encoded exactly once in HTML output.
- **DSC cloud witness support**: `HVClusterResource` now supports Cloud witness credentials and can converge cloud quorum configurations.
- **Certification compliance scoring**: compliance checks now use the supplied or current witness type instead of hardcoding `None`.
- **Platform result shape**: `Invoke-HVClusterPlatform` now returns `ClusterName`, allowing fleet reporting and telemetry exports to retain identity.

### Changed
- **Module manifest**: Version bumped to `21.0.0`.
- **Fleet, telemetry, and release infrastructure**: CI now lint-checks maintained production code paths, generated local test output is no longer tracked, and release metadata reflects the hardened production name.

---

## [20.0.0] — 2026-03-02

### Added
- **`Invoke-HVCertificationSuite`** (`Private/CertificationSuite.ps1`): 10-domain production certification gate. Domains: ClusterCore, NodeHealth, NetworkConfig, StorageConfig, WitnessConfig, SecurityBaseline, DSCCompliance, TelemetryExport, LiveMigration, DisasterRecovery. Returns `Certified` (bool), `Domains` (array of per-domain results), `Score`, `ReportPath`, and `Timestamp`. Writes an HTML certification report.
- **`Tests/CertificationSuite.Tests.ps1`**: Unit tests for all-passing scenario, cluster-not-found, node membership mismatch, and result object shape.

### Changed
- **Module manifest**: Version bumped to `20.0.0`.

---

## [19.0.0] — 2026-03-02

### Added
- **`New-HVDRSnapshot`** / **`Test-HVDRReadiness`** (`Private/DisasterRecovery.ps1`): Disaster recovery support. `New-HVDRSnapshot` serialises cluster state (nodes, quorum, CSVs, resource groups) to a timestamped JSON file. `Test-HVDRReadiness` scores readiness against configurable minimum-node, quorum, and CSV requirements — returns `Ready` (bool), `Score`, `Checks`, and `Timestamp`.
- **`Tests/DisasterRecovery.Tests.ps1`**: Unit tests for snapshot creation and readiness scoring.

### Changed
- **Module manifest**: Version bumped to `19.0.0`.

---

## [18.0.0] — 2026-03-02

### Added
- **`Get-HVMigrationReadiness`** / **`Start-HVLiveMigration`** (`Private/LiveMigration.ps1`): Live migration support. `Get-HVMigrationReadiness` validates that each node is Up and that VM live migration is enabled on the Hyper-V host. `Start-HVLiveMigration` calls `Move-ClusterVirtualMachineRole` and returns `Success`, `VMName`, `TargetNode`, and `Message`.
- **`Tests/LiveMigration.Tests.ps1`**: Unit tests for readiness checks and successful/failed migration paths.

### Changed
- **Module manifest**: Version bumped to `18.0.0`.

---

## [17.0.0] — 2026-03-02

### Added
- **`Scripts/Update-ModuleVersion.ps1`**: Reads the latest git tag, increments the patch component, and writes the new `ModuleVersion` to `HyperVClusterPlatform.psd1`. Supports `-Major`, `-Minor`, `-Patch` switches and an explicit `-Version` override.
- **`Scripts/New-Release.ps1`**: Creates a GitHub release via the `gh` CLI. Auto-extracts the changelog entry for the current version from `CHANGELOG.md` as the release body. Creates the git tag if it does not already exist.
- **PSGallery publish job** added to `.github/workflows/ci.yml`: triggers on release tag push, calls `Publish-Module` with a PSGallery API key stored as a GitHub secret.

### Changed
- **Module manifest**: Version bumped to `17.0.0`.

---

## [16.0.0] — 2026-03-02

### Added
- **`Export-HVTelemetry`** (`Private/TelemetryExport.ps1`): Writes a structured JSON telemetry file alongside every HTML compliance report. Fields include cluster name, mode, drift score, node states, witness type, CSV count, quorum type, OS profile, and run timestamp. Compatible with Elastic, Splunk, and Azure Monitor ingest pipelines.
- **`ComplianceReport.ps1` v2**: Embeds Chart.js (CDN) drift trend line chart built from historical JSON snapshots in `Reports/`. Adds a per-check detail table (check name, weight, pass/fail, actual vs desired) and an executive summary section.

### Changed
- **Module manifest**: Version bumped to `16.0.0`.

---

## [15.0.0] — 2026-03-02

### Added
- **`Invoke-HVClusterFleet`** (`Public/Invoke-HVClusterFleet.ps1`): Multi-cluster fleet runner. Accepts a fleet config JSON file (`-FleetConfigFile`) or an explicit array of per-cluster config paths (`-ConfigFiles`). Runs each cluster sequentially (or in parallel with `-Parallel` on PS 7). Aggregates per-cluster drift scores, statuses, and errors into a fleet HTML roll-up report written to `Reports/`.
- **`Tests/Fleet.Tests.ps1`**: Unit tests for fleet-config-file and explicit-config-list parameter sets, fleet report generation, and per-cluster error handling.

### Changed
- **Module manifest**: Version bumped to `15.0.0`. Added `Invoke-HVClusterFleet` to `FunctionsToExport`.

---

## [14.0.0] — 2026-03-02

### Added
- **`Get-HVSecret`** (`Private/SecretManagement.ps1`): Retrieves secrets from a Microsoft.PowerShell.SecretManagement vault. Falls back to Windows Credential Manager (`Get-StoredCredential`) if the primary vault throws. Throws if no vault is available and `-AllowPrompt` is not set. Supports `-AsSecureString`.
- **`ConvertFrom-HVSecureString`**: Converts a `[SecureString]` to plaintext using `Marshal`.
- **`Resolve-HVConfigSecrets`**: Walks a config object, finds all properties ending in `SecretName`, resolves each via `Get-HVSecret`, and adds the resolved value under the base property name (e.g., `CloudWitnessStorageKeySecretName` → `CloudWitnessStorageKey`). Logs errors but continues on individual resolution failures.
- **`Tests/SecretManagement.Tests.ps1`**: Unit tests for vault availability, SecureString return, CredentialManager fallback, and secret resolution in config objects.

### Changed
- **Module manifest**: Version bumped to `14.0.0`.

---

## [13.0.0] — 2026-03-02

### Added
- **`Get-HVClusterHealth`** (`Private/HealthCheck.ps1`): Comprehensive cluster health assessment. Checks node Up/Down/Paused states, resource group Online/Offline states, Cluster Shared Volume health, and quorum configuration. Deducts points per problem (nodes: −20, resource groups: −10, CSVs: −15, quorum: −20). Returns `Overall` (Healthy/Warning/Critical), `Score` (0–100), `Nodes`, `Resources`, `CSVs`, `Quorum`, `VMs` (optional), `Details`, and `Timestamp`.
- **`Send-HVAlert`** (`Private/Alerting.ps1`): Multi-channel alert dispatcher. Supports email (`Send-MailMessage`), Microsoft Teams Adaptive Card webhook, Slack Incoming Webhook, and Windows Application Event Log. Returns `EmailSent`, `TeamsSent`, `SlackSent`, `EventLogWritten`, and `Errors`.
- **`Invoke-HVHealthAlertPolicy`**: Runs `Get-HVClusterHealth` and fires `Send-HVAlert` if the score is below a configurable threshold (default: 80). Uses `Critical` severity below 50, `Warning` otherwise.
- **`Tests/HealthCheck.Tests.ps1`**: Unit tests for no-cluster, all-healthy, and node-down scenarios.
- **`Tests/Alerting.Tests.ps1`**: Unit tests for all four alert channels, error capture, and severity parameter validation.

### Changed
- **Module manifest**: Version bumped to `13.0.0`.

---

## [12.0.0] — 2026-03-02

### Added
- **`Get-HVCSVState`** (`Private/StorageConfig.ps1`): Enumerates current Cluster Shared Volumes. Returns an array of objects with `Name`, `State`, `OwnerNode`, and `Healthy`.
- **`Get-HVStorageDrift`**: Compares current CSV state against desired constraints (`MinCSVCount`, `RequireAllOnline`). Returns `Score`, `Details`, and per-CSV health info.
- **`Tests/StorageConfig.Tests.ps1`**: Unit tests for empty CSV set, multi-CSV enumeration, drift scoring, and offline CSV detection.

### Changed
- **Module manifest**: Version bumped to `12.0.0`.

---

## [11.0.0] — 2026-03-02

### Changed
- **`DSC/HVClusterResource/HVClusterResource.psm1`**: Promoted from stub to full implementation. `Get-TargetResource` queries the live cluster state via FailoverClusters cmdlets and returns the schema properties. `Test-TargetResource` calls `Get-HVDriftScore` and returns `$false` if drift > 0. `Set-TargetResource` calls `Invoke-HVClusterPlatform -Mode Enforce` with the desired state parameters.
- **Module manifest**: Version bumped to `11.0.0`.

---

## [10.0.0] — 2026-03-02

### Added
- **`Get-HVVMPlacementState`** (`Private/VMPlacement.ps1`): Reads current VM cluster group preferred owners and anti-affinity group membership. Returns an array of VM placement objects with `Name`, `OwnerNode`, `PreferredOwners`, and `AntiAffinityGroup`.
- **`Get-HVVMPlacementDrift`**: Compares current VM placement against a desired placement policy (preferred owners per VM, anti-affinity rules). Returns `Score` and `Details`.
- **`Tests/VMPlacement.Tests.ps1`**: Unit tests for empty VM set, property shape, no-policy drift, missing VM drift, and correct placement.

### Changed
- **Module manifest**: Version bumped to `10.0.0`.

---

## [9.0.0] — 2026-03-02

### Added
- **`Get-HVNetworkProfile`** (`Private/NetworkConfig.ps1`): Discovers all network adapters on the local node via `Get-CimInstance Win32_NetworkAdapter`. Classifies each adapter as Management, LiveMigration, Storage, or Unclassified based on adapter name patterns. Returns an array of classified adapter objects with `Name`, `Role`, `InterfaceIndex`, and `MACAddress`.
- **`Get-HVNetworkDrift`**: Compares current network adapter classification against a desired network role map. Returns `Score` and `Details` for any role mismatches or missing adapters.
- **`Tests/NetworkConfig.Tests.ps1`**: Unit tests for adapter classification (Management, LiveMigration, Storage), adapter count, CIM failure handling, and drift scoring.

### Changed
- **Module manifest**: Version bumped to `9.0.0`.

---

## [8.0.0] — 2026-03-01

### Fixed
- **DriftEngine**: Array comparison rewritten using `Compare-Object` (symmetric diff). The v7 bug used `-ne` on arrays which filters matching elements rather than comparing arrays as sets — it could report 0 drift when node membership had changed.
- **DesiredState**: `Get-HVClusterCurrentState` now wraps `QuorumType.ToString()` to avoid null errors on unconfigured quorum.

### Added
- **`Get-HVOSProfile`** (`DriftEngine.ps1`): Detects Windows Server version from OS build number. Returns `Version` (`2022`|`2025`|`2019`|`Unknown`), `Build`, and `DisplayName`. Called automatically on every run.
- **`Test-HVPrerequisites`** (`Preflight.ps1`): Pre-flight checks on the local machine — admin rights, PowerShell version, OS version support, required Windows Features (Failover-Clustering, Hyper-V, RSAT-Clustering, etc.), domain membership, and DNS lookup for each node. Returns `Passed`, `Failures`, `Warnings`, `OSProfile`.
- **`Test-HVNodeReadiness`** (`NodeValidation.ps1`): Per-node validation over WinRM — ICMP ping, WinRM PSSession, OS version, domain membership, required Windows Features. Tested against all nodes before enforcement begins.
- **`Initialize-HVLogging`** / **`Get-HVLogPath`** (`Logging.ps1`): File-based rotating log. Files named `HVCluster-YYYYMMDD.log`, retained up to `MaxLogFiles` (default 10). `Write-HVLog` now color-codes console output (White/Yellow/Red) and appends to disk.
- **Full witness support** (`Enforcement.ps1`): Disk, Cloud (Azure Blob), File Share, and None. Each type checks if already configured and skips if correct.
- **`Add-HVMissingNodes`** (`Enforcement.ps1`): Idempotently adds nodes not currently in the cluster.
- **Real rollback engine** (`Rollback.ps1`): `Restore-HVClusterSnapshot` reads `ClusterExistedBefore` from the snapshot to determine rollback scope.
- **Snapshot `ClusterExistedBefore` flag** (`Snapshot.ps1`): Schema version `8.0`.
- **`Import-HVClusterConfig`** (`Configuration.ps1`): JSON config file loader with environment overrides and mandatory field validation.
- **`Config/cluster-config.example.json`**: Config file template.
- **Pester test suite** (5 files, fully mocked): `Cluster.Tests.ps1`, `DriftEngine.Tests.ps1`, `Preflight.Tests.ps1`, `Rollback.Tests.ps1`, `Configuration.Tests.ps1`.
- **CI/CD pipelines**: `.github/workflows/ci.yml` and `Pipelines/azure-pipeline.yml`.

### Changed
- **Module manifest** (`HyperVClusterPlatform.psd1`): Version bumped to `8.0.0`.

---

## [7.0.0] — 2026-02-23

### Added
- Initial platform foundation: Audit/Enforce/Remediate modes, drift scoring (basic), HTML report, pre-change snapshot hook, rollback stub, Pester stub, GitHub Actions and Azure Pipeline stubs, DSC resource skeleton.
