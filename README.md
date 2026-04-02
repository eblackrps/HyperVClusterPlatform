# HyperVClusterPlatform

> **v21.0.1** — Production-hardened Hyper-V cluster automation for **Windows Server 2022** and **Windows Server 2025**

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
- **Multi-channel alerting** — email, Microsoft Teams webhook, Slack webhook, Windows Event Log
- **Secret management** — Microsoft.PowerShell.SecretManagement and Windows Credential Manager
- **Fleet orchestration** — multi-cluster parallel runs with aggregated HTML report
- **Live migration** — pre-flight readiness checks and orchestrated `Move-ClusterVirtualMachineRole`
- **Disaster recovery** — DR readiness snapshots and readiness scoring
- **Certification suite** — 10-domain compliance gate for production sign-off
- **Real rollback engine** — snapshot-based; removes what was created if enforcement fails
- **JSON telemetry** — structured metrics alongside every HTML report
- **File-based rotating logs** — timestamped, color-coded, persisted to disk
- **JSON config files** — environment profiles (Dev / Staging / Prod) with secret-name resolution
- **Full Pester test suite** — 127 mocked unit tests across 16 test files, no live cluster required
- **CI/CD workflows** — PSScriptAnalyzer lint + Pester + smoke validation + optional PSGallery publish on release tags

---

## Requirements

| Requirement | Detail |
|---|---|
| OS | Windows Server 2022 or 2025 |
| PowerShell | 5.1 or 7+ |
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
  HyperVClusterPlatform.psd1          # module manifest (v21.0.1)
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
    Update-ModuleVersion.ps1          # bumps .psd1 version from git tags
    New-Release.ps1                   # creates GitHub release via gh CLI
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
    -Mode        Audit

# Enforce — creates cluster, adds nodes, sets witness
Invoke-HVClusterPlatform `
    -ClusterName "ProdCluster" `
    -Nodes       @("NODE1","NODE2") `
    -ClusterIP   "10.10.10.10" `
    -WitnessType Disk `
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

See [`Config/cluster-config.example.json`](Config/cluster-config.example.json) for all available fields and the `Environments` override block.

---

## Fleet orchestration

```powershell
# Run against every cluster defined in a fleet config file
Invoke-HVClusterFleet -FleetConfigFile .\Config\fleet.json -Mode Audit

# Or pass an explicit list of per-cluster config files
Invoke-HVClusterFleet -ConfigFiles @('.\Config\site-a.json','.\Config\site-b.json') -Mode Enforce
```

`Invoke-HVClusterFleet` returns a fleet-level PSCustomObject and writes an HTML roll-up report to `Reports/`.

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
| `DriftScore` | int | 0 (compliant) to 100 (maximum drift) |
| `DriftDetails` | string[] | Per-check mismatch descriptions |
| `ReportPath` | string | Path to HTML compliance report |
| `SnapshotPath` | string | Path to pre-change JSON snapshot |
| `PreFlightPassed` | bool | Result of local pre-flight checks |
| `NodeValidationResults` | object[] | Per-node readiness results |
| `LogPath` | string | Active log file path |
| `OSProfile` | object | Version, Build, DisplayName |

---

## Running tests

Requires [Pester 5](https://pester.dev):

```powershell
Install-Module Pester -MinimumVersion 5.0 -Force -Scope CurrentUser
Invoke-Pester .\Tests -Output Detailed
```

All 127 tests use mocked cmdlets — no live Hyper-V cluster needed.

---

## Flags

| Parameter | Purpose |
|---|---|
| `-SkipPreFlight` | Skip local machine pre-flight checks (faster, less safe) |
| `-SkipNodeValidation` | Skip per-node WinRM + feature checks |
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

- **Rollback** uses `ClusterExistedBefore` from the snapshot to decide whether to destroy the cluster entirely or only remove nodes added during enforcement. It cannot guarantee a perfect rollback in all partial-failure scenarios — always review the log.
- **Cloud witness** requires an Azure Blob Storage account with LRS redundancy. Provide the storage account name and one of the two access keys.
- **Secrets** — never commit `Config/prod.json` or similar files containing real credentials. The `.gitignore` excludes them by pattern. Use `CloudWitnessStorageKeySecretName` and a registered SecretManagement vault instead.
- **DSC resource** (`DSC/HVClusterResource`) provides a functional `Get-/Test-/Set-TargetResource` implementation wired to the cluster automation engine.
- **Certification** — `Invoke-HVCertificationSuite` runs 10 compliance domains and requires all to pass before returning `Certified = $true`. Intended as a production go-live gate.

---

## License

This project is currently distributed under an explicit **all rights reserved** license in [`LICENSE`](LICENSE). If you want to open-source it later, replace that file and update the manifest metadata before publishing another release.
