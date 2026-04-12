# HyperVClusterPlatform

> Production-hardened Hyper-V cluster automation for **Windows Server 2022** and **Windows Server 2025**

A PowerShell module for fully automated Hyper-V failover cluster deployment, compliance management, health monitoring, and fleet orchestration:

- **Audit / Enforce / Remediate** modes
- **Pre-flight checks** — admin rights, OS version, Windows Features, domain membership, DNS
- **Node validation** — per-node WinRM, feature, and domain checks before any changes
- **OS detection** — WS2019, WS2022 (build 20348), and WS2025 (build 26100) aware
- **Drift scoring** — 0–100 compliance score with detailed mismatch reporting
- **Network automation** — adapter classification, Live Migration network assignment
- **VM placement** — preferred owner policies and anti-affinity group enforcement
- **Storage automation** — Cluster Shared Volume enumeration and drift detection
- **Full witness support** — Disk, Cloud (Azure Blob), File Share, or None
- **Health monitoring** — node/resource/quorum/CSV health with 0–100 score
- **Multi-channel alerting** — SMTP email, Microsoft Teams webhook, Slack webhook, Windows Event Log
- **Secret management** — Microsoft.PowerShell.SecretManagement and Windows Credential Manager
- **Fleet orchestration** — multi-cluster parallel runs with aggregated HTML report
- **Live migration** — pre-flight readiness checks and orchestrated `Move-ClusterVirtualMachineRole`
- **Disaster recovery** — DR readiness snapshots and readiness scoring
- **Certification suite** — 10-domain compliance gate for production sign-off
- **Change-journal rollback** — records mutating actions and replays compensating steps with snapshot fallback
- **JSON telemetry** — structured metrics alongside every HTML report
- **File-based rotating logs** — timestamped, color-coded, persisted to disk
- **JSON config files** — environment profiles (Dev / Staging / Prod) with secret-name resolution
- **Full mocked Pester test suite** — operational, safety, release, and metadata coverage with no live cluster required
- **CI/CD workflows** — lint + `pwsh`/Windows PowerShell validation + manifest smoke + optional PSGallery publish on release tags

---

## Requirements

| Requirement | Detail |
|---|---|
| OS | Windows Server 2022 or 2025 for supported cluster operations; Windows Server 2019 is detected and allowed with warnings for audit/pre-flight compatibility checks |
| PowerShell | Windows PowerShell 5.1 or PowerShell 7+ |
| Windows Features | Failover-Clustering, Hyper-V, Hyper-V-PowerShell, RSAT-Clustering, RSAT-Clustering-PowerShell |
| Domain | Active Directory domain membership required for cluster CNO |
| Privileges | Must run as Administrator |

---

## Supported commands

- `Invoke-HVClusterPlatform`
- `Invoke-HVClusterFleet`
- `Get-HVClusterHealth`
- `Invoke-HVHealthAlertPolicy`
- `Invoke-HVCertificationSuite`

---

## Folder layout

```
  HyperVClusterPlatform/
  HyperVClusterPlatform.psd1          # module manifest
  HyperVClusterPlatform.psm1          # loader: dot-sources Public + Private
  README.md
  CHANGELOG.md
  ROADMAP.md
  LICENSE
  PSScriptAnalyzerSettings.psd1
  .gitignore
  Public/
    Invoke-HVClusterPlatform.ps1      # single-cluster entry point
    Invoke-HVClusterFleet.ps1         # multi-cluster fleet runner
  Private/
    CommandAliases.ps1                # pins cmdlets to FailoverClusters / Hyper-V
    Logging.ps1                       # file logging + rotation
    DesiredState.ps1                  # desired state builder + live state reader
    Preflight.ps1                     # local machine pre-flight checks
    NodeValidation.ps1                # per-node WinRM + feature + domain checks
    Snapshot.ps1                      # pre-change JSON snapshot
    DriftEngine.ps1                   # OS detection + 0-100 drift scoring
    ComplianceReport.ps1              # HTML compliance report generator
    Enforcement.ps1                   # cluster creation, node join, witness config
    Rollback.ps1                      # snapshot-diff rollback engine
    Configuration.ps1                 # JSON config file loader
    NetworkConfig.ps1                 # adapter classification + network drift
    VMPlacement.ps1                   # VM preferred-owner + anti-affinity
    StorageConfig.ps1                 # CSV state + storage drift
    HealthCheck.ps1                   # cluster health (node/resource/quorum/CSV)
    Alerting.ps1                      # email / Teams / Slack / Event Log alerts
    SecretManagement.ps1              # SecretManagement vault + CredentialManager
    LiveMigration.ps1                 # live migration readiness + execution
    DisasterRecovery.ps1              # DR snapshot + readiness scoring
    CertificationSuite.ps1            # 10-domain production certification gate
    TelemetryExport.ps1               # JSON telemetry output
  Config/
    cluster-config.example.json       # config template (copy and fill in)
  DSC/
    HVClusterResource/                # DSC resource (Get-/Test-/Set-TargetResource)
      HVClusterResource.psm1
      HVClusterResource.schema.mof
  Scripts/
    Update-ModuleVersion.ps1          # updates the manifest version
    New-Release.ps1                   # validates, packages, tags, and creates a GitHub release
  Tests/
    _Stubs.ps1                        # cmdlet stubs for optional Windows modules
    Cluster.Tests.ps1                 # module load + public API tests
    DriftEngine.Tests.ps1             # drift score + OS detection unit tests
    Preflight.Tests.ps1               # pre-flight + node validation unit tests
    Rollback.Tests.ps1                # rollback engine unit tests
    Configuration.Tests.ps1          # config file loader unit tests
    ComplianceReport.Tests.ps1       # HTML encoding regression tests
    NetworkConfig.Tests.ps1           # adapter classification + drift tests
    VMPlacement.Tests.ps1             # VM placement + drift tests
    StorageConfig.Tests.ps1           # CSV state + storage drift tests
    HealthCheck.Tests.ps1             # cluster health scoring tests
    Alerting.Tests.ps1                # multi-channel alert dispatch tests
    SecretManagement.Tests.ps1        # vault + credential manager tests
    Fleet.Tests.ps1                   # multi-cluster fleet tests
    LiveMigration.Tests.ps1           # live migration readiness tests
    DisasterRecovery.Tests.ps1        # DR snapshot + readiness tests
    CertificationSuite.Tests.ps1      # certification gate tests
  .github/
    workflows/
      ci.yml                          # lint + test + smoke + optional PSGallery publish on v* tags
  Pipelines/
    azure-pipeline.yml                # lint + test + manifest (3 stages)
  Reports/                            # runtime output — gitignored
  Logs/                               # rotating log files — gitignored
```

---

## Quick start (inline parameters)

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
Import-Module .\HyperVClusterPlatform.psd1 -Force

# Audit — read-only, no changes
Invoke-HVClusterPlatform `
    -ClusterName "ProdCluster" `
    -Nodes       @("NODE1","NODE2") `
    -ClusterIP   "10.10.10.10" `
    -WitnessType Disk `
    -WitnessDiskName "Cluster Disk 3" `
    -Mode        Audit

# Enforce — creates cluster, adds nodes, sets witness
Invoke-HVClusterPlatform `
    -ClusterName "ProdCluster" `
    -Nodes       @("NODE1","NODE2") `
    -ClusterIP   "10.10.10.10" `
    -WitnessType Disk `
    -WitnessDiskName "Cluster Disk 3" `
    -Mode        Enforce

# Enforce with Cloud witness
Invoke-HVClusterPlatform `
    -ClusterName                 "ProdCluster" `
    -Nodes                       @("NODE1","NODE2","NODE3") `
    -ClusterIP                   "10.10.10.10" `
    -WitnessType                 Cloud `
    -Mode                        Enforce `
    -CloudWitnessStorageAccount  "myaccount" `
    -CloudWitnessStorageKey      "base64key=="

# Enforce with File Share witness
Invoke-HVClusterPlatform `
    -ClusterName          "ProdCluster" `
    -Nodes                @("NODE1","NODE2") `
    -ClusterIP            "10.10.10.10" `
    -WitnessType          Share `
    -Mode                 Enforce `
    -FileShareWitnessPath "\\fileserver\witness"
```

---

## Quick start (JSON config file)

```powershell
# Copy the example, fill in your values
Copy-Item .\Config\cluster-config.example.json .\Config\prod.json

# Edit prod.json with real values, then run:
Invoke-HVClusterPlatform -ConfigFile .\Config\prod.json -Environment Prod -Mode Enforce
```

Use `PlanOnly`, `-WhatIf`, or `-Confirm` to preview cluster changes before a maintenance window.
See [`Config/cluster-config.example.json`](Config/cluster-config.example.json) for witness targeting, break-glass, telemetry, and retention fields.

---

## Fleet orchestration

```powershell
# Run against every cluster defined in a fleet config file
Invoke-HVClusterFleet -FleetConfigFile .\Config\fleet.json -Mode Audit

# Or pass an explicit list of per-cluster config files
Invoke-HVClusterFleet -ConfigFiles @('.\Config\site-a.json','.\Config\site-b.json') -Mode Enforce
```

`Invoke-HVClusterFleet` returns a fleet-level PSCustomObject and writes an HTML roll-up report to `Reports/`.
Audit fleet runs return `Compliant` or `NonCompliant`; mutating runs return `Succeeded`, `DriftRemaining`, `Planned`, or `Failed`.

---

## Health monitoring

```powershell
# On-demand health check
Get-HVClusterHealth -IncludeVMs

# Policy-based alerting: fire alert if health score < 80
Invoke-HVHealthAlertPolicy -AlertThreshold 80 -AlertParams @{
    SmtpServer      = 'smtp.corp.local'
    EmailFrom       = 'cluster@corp.local'
    EmailTo         = @('ops@corp.local')
    TeamsWebhookUrl = 'https://outlook.office.com/webhook/...'
}
```

---

## Output object (`Invoke-HVClusterPlatform`)

| Property | Type | Description |
|---|---|---|
| `ClusterName` | string | Target cluster name used for the run |
| `Mode` | string | Audit / Enforce / Remediate |
| `Status` | string | `Compliant`, `NonCompliant`, `Succeeded`, `DriftRemaining`, `Planned`, `Previewed`, `Blocked`, `FailedPreFlight`, `FailedNodeValidation`, or `Failed` |
| `OperationId` | string | Correlation ID shared across text logs, structured logs, and telemetry |
| `DriftScore` | int | 0 (compliant) to 100 (maximum drift) |
| `DriftDetails` | string[] | Per-check mismatch descriptions |
| `Plan` | object | Structured change plan generated before enforcement |
| `ReportPath` | string | Path to HTML compliance report |
| `SnapshotPath` | string | Path to pre-change JSON snapshot |
| `JournalPath` | string | Path to the persisted change journal used for rollback |
| `PreFlightPassed` | bool | Result of local pre-flight checks |
| `ClusterValidationPassed` | bool? | Result of `Test-Cluster` gating when enabled; `$null` when skipped or not run |
| `ClusterValidationStatus` | string | `Passed`, `Failed`, `Skipped`, or `NotRun` |
| `ClusterValidationReport` | string | `Test-Cluster` report path when available |
| `NodeValidationResults` | object[] | Per-node readiness results |
| `RollbackStatus` | string | `NotNeeded`, `Succeeded`, `Partial`, or `Failed` |
| `RollbackActions` | string[] | Ordered rollback actions performed after an enforcement failure |
| `RollbackErrors` | string[] | Rollback errors that still require operator follow-up |
| `LogPath` | string | Active log file path |
| `StructuredLogPath` | string | NDJSON log path for machine-readable correlation |
| `TelemetryPath` | string | JSON telemetry artifact emitted for the run |
| `OSProfile` | object | Version, Build, DisplayName |

---

## Running tests

Requires [Pester 5](https://pester.dev):

```powershell
Install-Module Pester -MinimumVersion 5.0 -Force -Scope CurrentUser
Invoke-Pester .\Tests -Output Detailed
```

The test suite uses mocked cmdlets and isolated temp artifacts, so it runs without a live Hyper-V cluster.

---

## Flags

| Parameter | Purpose |
|---|---|
| `-SkipPreFlight` | Skip local machine pre-flight checks (faster, less safe) |
| `-SkipNodeValidation` | Skip per-node WinRM + feature checks |
| `-SkipClusterValidation` | Skip `Test-Cluster`; blocked for Enforce/Remediate unless `-BreakGlass` is set |
| `-BreakGlass` | Explicitly acknowledge unsafe skip flags during mutating runs |
| `-PlanOnly` | Return the computed change plan without mutating the cluster |
| `-EmitTelemetry` | Enable or disable JSON telemetry export for the run |
| `-RetainArtifactCount` | Keep only the newest N reports, snapshots, telemetry files, and logs |
| `-SkipArtifactPersistence` | Audit-only mode that avoids writing reports/snapshots/telemetry to disk |
| `-LogPath` | Override log directory |
| `-ReportsPath` | Override reports directory |

---

## Install as a module

```powershell
$dest = "$home\Documents\PowerShell\Modules\HyperVClusterPlatform"
Copy-Item .\* $dest -Recurse -Force
Import-Module HyperVClusterPlatform -Force
Get-Command -Module HyperVClusterPlatform
```

---

## Notes

- **Rollback** uses both the pre-change snapshot and the persisted change journal. Cluster creation, node addition, and witness changes are reversed automatically where possible, but operators should still review the run log before declaring recovery complete.
- **Alert policy semantics** — `Invoke-HVHealthAlertPolicy` returns `AlertRequired`, `AlertAttempted`, `AlertDelivered`, and `AlertFired` so dashboards can distinguish threshold breaches from actual delivery.
- **Cloud witness** requires an Azure Blob Storage account with LRS redundancy. Provide the storage account name and one of the two access keys.
- **Secrets** — never commit `Config/prod.json` or similar files containing real credentials. The `.gitignore` excludes them by pattern. Use `CloudWitnessStorageKeySecretName` and a registered SecretManagement vault instead.
- **PowerShell engine compatibility** — Windows PowerShell 5.1 and PowerShell 7 are both validated in CI. `Invoke-HVClusterFleet -Parallel` requires PowerShell 7; Windows PowerShell 5.1 falls back to sequential execution.
- **DSC resource** (`DSC/HVClusterResource`) delegates Ensure=Present enforcement to `Invoke-HVClusterPlatform` so quorum safety, rollback journaling, and guardrails stay aligned.
- **Certification** — `Invoke-HVCertificationSuite` runs 10 compliance domains and now expects evidence-backed desired policy inputs for network, storage, placement, and secrets hygiene before returning `Certified = $true`.
- **GitHub releases** — the release process now produces a versioned ZIP package asset alongside the tagged GitHub release. PSGallery publication continues to flow from the release-tag CI job when the repository secret is configured.

---

## License

This project is currently distributed under an explicit **all rights reserved** license in [`LICENSE`](LICENSE). If you want to open-source it later, replace that file and update the manifest metadata before publishing another release.
