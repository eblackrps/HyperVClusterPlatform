# Changelog

All notable changes to HyperVClusterPlatform are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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
- **Full witness support** (`Enforcement.ps1`):
  - `Disk` — picks first available disk, adds to cluster, calls `Set-ClusterQuorum -NodeAndDiskMajority`.
  - `Cloud` — calls `Set-ClusterQuorum -CloudWitness` with storage account name and key. Requires `CloudWitnessStorageAccount` and `CloudWitnessStorageKey`.
  - `Share` — validates UNC path is reachable, calls `Set-ClusterQuorum -NodeAndFileShareMajority`.
  - `None` — sets `NodeMajority`.
  - Each type checks if already configured and skips if correct.
- **`Add-HVMissingNodes`** (`Enforcement.ps1`): Idempotently adds nodes not currently in the cluster, skipping nodes that are already members.
- **Real rollback engine** (`Rollback.ps1`): `Restore-HVClusterSnapshot` reads `ClusterExistedBefore` from the snapshot to determine rollback scope. If the cluster was created by this run, calls `Remove-Cluster`. If it pre-existed, removes only nodes added during enforcement (diff vs snapshot node list). Returns `Success`, `Actions`, `Errors`.
- **Snapshot `ClusterExistedBefore` flag** (`Snapshot.ps1`): Pre-change snapshot now records whether a cluster existed before enforcement started. Also captures `Resources`, `SharedVolumes`, and a `Label` field. Schema version `8.0`.
- **`Import-HVClusterConfig`** (`Configuration.ps1`): Loads cluster parameters from a JSON file. Supports `Environments` block for per-environment overrides. Validates all mandatory fields and witness-specific requirements. Returns a merged `PSCustomObject`.
- **`Config/cluster-config.example.json`**: Config file template with inline comments, Dev/Staging/Prod environment examples.
- **`Invoke-HVClusterPlatform`** new parameters: `ConfigFile`, `Environment`, `LogPath`, `SkipPreFlight`, `SkipNodeValidation`, `CloudWitnessStorageAccount`, `CloudWitnessStorageKey`, `FileShareWitnessPath`. Uses `DefaultParameterSetName = 'Direct'` / `'ConfigFile'`.
- **Pester test suite** (4 files, fully mocked — no live cluster):
  - `Tests/Cluster.Tests.ps1` — module load, export, version, parameter validation
  - `Tests/DriftEngine.Tests.ps1` — drift score correctness, OS detection, edge cases
  - `Tests/Preflight.Tests.ps1` — pre-flight and node validation scenarios
  - `Tests/Rollback.Tests.ps1` — rollback engine with snapshot fixtures
  - `Tests/Configuration.Tests.ps1` — config file loading, validation, env overrides
- **CI/CD pipelines** (3-stage lint → test → validate):
  - `Pipelines/github-actions.yml`: PSScriptAnalyzer → Pester (with XML + coverage artifacts) → module smoke test
  - `Pipelines/azure-pipeline.yml`: Same three stages as ADO pipeline with `PublishTestResults@2`

### Changed
- **`ComplianceReport`**: Now accepts a `DriftResult` object (with `.Score` and `.Details`) instead of a bare int. Renders drift detail lines in the HTML. Shows OS version and run mode. Styled with Segoe UI, colored score badge.
- **`DesiredState`**: `WitnessType` validator updated to include `'Share'` alongside `None|Disk|Cloud`.
- **Module manifest** (`HyperVClusterPlatform.psd1`): Version bumped to `8.0.0`. Tags updated for WS2022/WS2025. `FileList` populated. `VariablesToExport = @()` (was `'*'`).
- **`.gitignore`**: Added `Logs/`, `Config/prod*.json`, `Config/*-secret*.json`, `TestResults.xml`, `coverage.xml`.

---

## [7.0.0] — 2026-02-23

### Added
- Initial scaffold: Audit/Enforce/Remediate modes, drift scoring (basic), HTML report, pre-change snapshot hook, rollback stub, Pester stub, GitHub Actions and Azure Pipeline stubs, DSC resource skeleton.
