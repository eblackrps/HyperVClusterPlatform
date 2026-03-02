# Roadmap

Ten planned development rounds to make HyperVClusterPlatform fully production-ready.
Each round represents a discrete, shippable improvement. Items within a round are scoped to ship together.

---

## Round 1 — v8.0.0 ✅ RELEASED

Core hardening and automation foundations:
- OS detection (WS2022 / WS2025)
- Pre-flight checks (admin, OS, features, domain, DNS)
- Per-node WinRM + feature validation
- File-based rotating logs
- Full witness support (Disk / Cloud / FileShare / None)
- Real rollback engine (snapshot-diff based)
- JSON config files with environment overrides
- Comprehensive mocked Pester test suite (4 files)
- CI: PSScriptAnalyzer lint + Pester + manifest validation

---

## Round 2 — v9.0.0 — Network Automation

Automate cluster network role assignment and Live Migration network preferences.

**Planned additions:**
- `Private/NetworkConfig.ps1`
  - Discover all adapters on each node (via CIM `Win32_NetworkAdapter`)
  - Classify as: Management, LiveMigration, Storage (iSCSI/SMB), Heartbeat
  - Assign `ClusterNetwork` roles (cluster use, live migration preference order, excluded)
  - VLAN ID detection and reporting
- `Desired state` extension: `LiveMigrationNetworks`, `StorageNetworks`, `ManagementNetwork`
- Drift scoring extended for network role mismatches (+20 per misconfigured network)
- Tests: `Tests/NetworkConfig.Tests.ps1` (mocked)
- Snapshot: capture `ClusterNetworkInterface` detail

---

## Round 3 — v10.0.0 — VM Placement & Preferred Owner Policies

Automate VM anti-affinity groups and preferred-owner placement rules.

**Planned additions:**
- `Private/VMPlacement.ps1`
  - `Get-HVVMPlacementState` — reads current preferred owners and anti-affinity groups
  - `Set-HVVMPreferredOwner` — idempotently sets preferred owners per VM
  - `New-HVAntiAffinityGroup` — creates anti-affinity groups for HA VM pairs
- Drift scoring extended: preferred owner mismatches, missing anti-affinity groups
- Tests: `Tests/VMPlacement.Tests.ps1`

---

## Round 4 — v11.0.0 — Full DSC Resource Implementation

Complete the DSC resource skeleton into a functional, testable resource.

**Planned additions:**
- `DSC/HVClusterResource/HVClusterResource.psm1` — full `Get-`, `Test-`, `Set-TargetResource`
  - `Get`: returns current cluster state matching schema properties
  - `Test`: compares current vs desired, returns $true/$false
  - `Set`: calls `New-Cluster` / `Add-ClusterNode` / witness config as needed
- `DSC/HVClusterResource/HVClusterConfig.ps1` — example composite configuration
- MOF compilation example in `DSC/README.md`
- Pester tests for DSC resource functions

---

## Round 5 — v12.0.0 — Cluster Shared Volumes & Storage

Automate CSV creation and assignment for VM storage.

**Planned additions:**
- `Private/StorageConfig.ps1`
  - `Get-HVCSVState` — enumerates current CSVs
  - `Add-HVClusterSharedVolume` — adds available disk as CSV, idempotent
  - `Set-HVCSVFriendlyName` — applies naming policy
- Desired state extension: `ClusterSharedVolumes` (count, minimum size)
- Drift: missing CSVs, undersized volumes
- Tests: `Tests/StorageConfig.Tests.ps1`

---

## Round 6 — v13.0.0 — Health Monitoring & Alerting

Post-deployment ongoing health checks with configurable alerting.

**Planned additions:**
- `Private/HealthCheck.ps1`
  - `Get-HVClusterHealth` — checks node state (Up/Down/Paused), resource groups, quorum health, CSV health
  - Returns structured health object, not just drift score
- `Private/Alerting.ps1`
  - `Send-HVAlert` — email via `Send-MailMessage` or webhook (Teams/Slack) for health events
  - Configurable thresholds in config JSON (`AlertOnDriftAbove`, `AlertWebhookUrl`)
- Windows Event Log integration: write structured events to `HyperVClusterPlatform` source
- Scheduled task example in `Docs/ScheduledTask.md`

---

## Round 7 — v14.0.0 — Secret Management Integration

Eliminate cleartext credentials from config files.

**Planned additions:**
- `Private/SecretManagement.ps1`
  - `Get-HVSecret` — retrieves credentials from Microsoft.PowerShell.SecretManagement vaults
  - Support: Windows Credential Manager, Azure Key Vault, HashiCorp Vault (via registered extensions)
- Config file: replace `CloudWitnessStorageKey` plain value with `CloudWitnessStorageKeySecretName`
- `Import-HVClusterConfig` extended to resolve secret references at load time
- Tests: `Tests/SecretManagement.Tests.ps1` (mocked)
- Docs: `Docs/SecretManagement.md`

---

## Round 8 — v15.0.0 — Multi-Cluster Orchestration

Manage multiple clusters from a single config and runner.

**Planned additions:**
- `Public/Invoke-HVClusterFleet.ps1` — accepts an array of cluster config objects or a fleet config file
  - Runs each cluster in sequence (or parallel with `-Parallel` switch using `ForEach-Object -Parallel` on PS7)
  - Aggregates results into a fleet-level compliance report
- Fleet config JSON schema: top-level `Clusters[]` array
- Fleet HTML report: sortable table of all clusters with drift scores
- Tests: `Tests/Fleet.Tests.ps1`

---

## Round 9 — v16.0.0 — Enhanced Reporting & Observability

Rich HTML report with trend charts and JSON telemetry export.

**Planned additions:**
- `Private/ComplianceReport.ps1` v2:
  - Embed Chart.js (CDN) drift trend line chart (reads historical snapshots)
  - Per-check detail table (check name, weight, pass/fail, actual vs desired)
  - Executive summary section (last 30-day trend)
- JSON telemetry output alongside HTML (`Report-YYYYMMDDHHMMSS.json`)
- `Private/TelemetryExport.ps1` — structured metrics for ingestion by Elastic, Splunk, or Azure Monitor

---

## Round 10 — v17.0.0 — PSGallery Publish + Auto-Versioning

Automate versioning and publish to PowerShell Gallery.

**Planned additions:**
- `Scripts/Update-ModuleVersion.ps1` — bumps `ModuleVersion` in `.psd1` based on git tags or input
- CI enhancement: auto-bump patch version on every main merge
- `Pipelines/github-actions.yml` publish job: `Publish-Module` to PSGallery on release tag push
- `Pipelines/azure-pipeline.yml` publish stage: identical, uses ADO service connection for PSGallery API key
- `Scripts/New-Release.ps1` — creates GitHub release via `gh` CLI with changelog body auto-extracted from `CHANGELOG.md`
- Signed module support: code signing certificate integration in publish pipeline

---

## Legend

| Status | Meaning |
|---|---|
| ✅ RELEASED | Shipped in a tagged release |
| 🔄 IN PROGRESS | Active development |
| 📋 PLANNED | Scoped, not started |
