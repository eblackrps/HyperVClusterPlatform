# HyperVClusterPlatform

> **v8.0.0** — Production-hardened Hyper-V cluster automation for **Windows Server 2022** and **Windows Server 2025**

A PowerShell module for fully automated Hyper-V failover cluster deployment and compliance management:

- **Audit / Enforce / Remediate** modes
- **Pre-flight checks** — admin rights, OS version, Windows Features, domain membership, DNS
- **Node validation** — per-node WinRM, feature, and domain checks before any changes
- **OS detection** — WS2022 (build 20348) and WS2025 (build 26100) aware
- **Drift scoring** — 0–100 compliance score with detailed mismatch reporting
- **Full witness support** — Disk, Cloud (Azure Blob), File Share, or None
- **Real rollback engine** — snapshot-based; removes what was created if enforcement fails
- **File-based rotating logs** — timestamped, color-coded, persisted to disk
- **JSON config files** — environment profiles (Dev / Staging / Prod)
- **Full Pester test suite** — mocked unit tests, no live cluster required
- **CI/CD pipelines** — PSScriptAnalyzer lint + Pester + manifest validation

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

## Folder layout

```
HyperVClusterPlatform/
  HyperVClusterPlatform.psd1          # module manifest (v8.0.0)
  HyperVClusterPlatform.psm1          # loader: dot-sources Public + Private
  README.md
  CHANGELOG.md
  ROADMAP.md
  .gitignore
  Public/
    Invoke-HVClusterPlatform.ps1      # ONLY public entry point
  Private/
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
  Config/
    cluster-config.example.json       # config template (copy and fill in)
  DSC/
    HVClusterResource/                # DSC resource skeleton
      HVClusterResource.psm1
      HVClusterResource.schema.mof
  Tests/
    Cluster.Tests.ps1                 # module load + public API tests
    DriftEngine.Tests.ps1             # drift score + OS detection unit tests
    Preflight.Tests.ps1               # pre-flight + node validation unit tests
    Rollback.Tests.ps1                # rollback engine unit tests
    Configuration.Tests.ps1          # config file loader unit tests
  Pipelines/
    github-actions.yml                # lint + test + smoke (3 jobs)
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

## Output object

`Invoke-HVClusterPlatform` returns a `PSCustomObject` with:

| Property | Type | Description |
|---|---|---|
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

All tests use mocked cmdlets — no live Hyper-V cluster needed.

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
- **DSC resource** (`DSC/HVClusterResource`) is a skeleton. `Get-/Test-/Set-TargetResource` are implemented as stubs for you to extend.
- **Secrets** — never commit `Config/prod.json` or similar files containing real credentials. The `.gitignore` excludes them by pattern.
