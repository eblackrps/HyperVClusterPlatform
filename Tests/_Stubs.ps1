# Tests/_Stubs.ps1
# Stub definitions for cmdlets that come from optional Windows Server modules
# (FailoverClusters, Hyper-V, ServerManager). These stubs let Pester create Mocks
# even when the modules are not installed on the test machine.
# Parameter declarations match what the production code actually passes.

function Test-PreferredWindowsCommandMissing {
    param(
        [Parameter(Mandatory)][string]$PreferredCommand
    )

    return (-not (Get-Command $PreferredCommand -ErrorAction SilentlyContinue))
}

# ── FailoverClusters ─────────────────────────────────────────────────────────
if (Test-PreferredWindowsCommandMissing 'FailoverClusters\Get-Cluster') { function Get-Cluster { [CmdletBinding()] param([string]$Name) } }
if (Test-PreferredWindowsCommandMissing 'FailoverClusters\Get-ClusterNode') { function Get-ClusterNode { [CmdletBinding()] param([string]$Name,[string]$Cluster) } }
if (Test-PreferredWindowsCommandMissing 'FailoverClusters\Get-ClusterQuorum') { function Get-ClusterQuorum { [CmdletBinding()] param([string]$Cluster) } }
if (Test-PreferredWindowsCommandMissing 'FailoverClusters\Get-ClusterGroup') { function Get-ClusterGroup { [CmdletBinding()] param([string]$Name,[string]$Cluster) } }
if (Test-PreferredWindowsCommandMissing 'FailoverClusters\Get-ClusterGroupProperty') { function Get-ClusterGroupProperty { [CmdletBinding()] param([string]$Name,[Parameter(ValueFromPipeline)]$InputObject) process { } } }
if (Test-PreferredWindowsCommandMissing 'FailoverClusters\Get-ClusterNetwork') { function Get-ClusterNetwork { [CmdletBinding()] param([string]$Cluster) } }
if (Test-PreferredWindowsCommandMissing 'FailoverClusters\Get-ClusterResource') { function Get-ClusterResource { [CmdletBinding()] param([string]$Name,[string]$Cluster) } }
if (Test-PreferredWindowsCommandMissing 'FailoverClusters\Get-ClusterSharedVolume') { function Get-ClusterSharedVolume { [CmdletBinding()] param([string]$Name,[string]$Cluster) } }
if (Test-PreferredWindowsCommandMissing 'FailoverClusters\Get-ClusterSharedVolumeState') { function Get-ClusterSharedVolumeState { [CmdletBinding()] param([Parameter(ValueFromPipeline)]$InputObject) process { } } }
if (Test-PreferredWindowsCommandMissing 'FailoverClusters\Add-ClusterSharedVolume') { function Add-ClusterSharedVolume { [CmdletBinding()] param([string]$Name) } }
if (Test-PreferredWindowsCommandMissing 'FailoverClusters\Add-ClusterDisk') { function Add-ClusterDisk { [CmdletBinding()] param($InputObject,[switch]$PassThru) } }
if (Test-PreferredWindowsCommandMissing 'FailoverClusters\Get-ClusterAvailableDisk') { function Get-ClusterAvailableDisk { [CmdletBinding()] param() } }
if (Test-PreferredWindowsCommandMissing 'FailoverClusters\New-Cluster') { function New-Cluster { [CmdletBinding()] param([string]$Name,[string[]]$Node,[string]$StaticAddress,[switch]$Force,[switch]$NoStorage) } }
if (Test-PreferredWindowsCommandMissing 'FailoverClusters\Add-ClusterNode') { function Add-ClusterNode { [CmdletBinding()] param([string]$Name,[switch]$NoStorage) } }
if (Test-PreferredWindowsCommandMissing 'FailoverClusters\Remove-Cluster') { function Remove-Cluster { [CmdletBinding()] param([string]$Cluster,[switch]$Force,[switch]$CleanUpAD) } }
if (Test-PreferredWindowsCommandMissing 'FailoverClusters\Remove-ClusterNode') { function Remove-ClusterNode { [CmdletBinding()] param([string]$Name,[string]$Cluster,[switch]$Force,[switch]$Wait) } }
if (Test-PreferredWindowsCommandMissing 'FailoverClusters\Set-ClusterQuorum') { function Set-ClusterQuorum { [CmdletBinding()] param([string]$Cluster,[switch]$NodeMajority,[string]$NodeAndDiskMajority,[string]$DiskWitness,[string]$NodeAndFileShareMajority,[string]$FileShareWitness,[switch]$CloudWitness,[string]$AccountName,[string]$AccessKey,[string]$Endpoint) } }
if (Test-PreferredWindowsCommandMissing 'FailoverClusters\Set-ClusterOwnerNode') { function Set-ClusterOwnerNode { [CmdletBinding()] param([string]$Group,[string[]]$Owners) } }
if (Test-PreferredWindowsCommandMissing 'FailoverClusters\Move-ClusterVirtualMachineRole') { function Move-ClusterVirtualMachineRole { [CmdletBinding()] param([string]$Name,[string]$Node) } }
if (Test-PreferredWindowsCommandMissing 'FailoverClusters\Suspend-ClusterNode') { function Suspend-ClusterNode { [CmdletBinding()] param([string]$Name,[switch]$Drain) } }

# ── Hyper-V ───────────────────────────────────────────────────────────────────
if (Test-PreferredWindowsCommandMissing 'Hyper-V\Get-VM') { function Get-VM { [CmdletBinding()] param([string]$Name,[string]$ComputerName) } }
if (Test-PreferredWindowsCommandMissing 'Hyper-V\Get-VMHost') { function Get-VMHost { [CmdletBinding()] param([string]$ComputerName) } }
if (Test-PreferredWindowsCommandMissing 'Hyper-V\Set-VMHost') { function Set-VMHost { [CmdletBinding()] param([string]$ComputerName,[bool]$VirtualMachineMigrationEnabled,[string]$VirtualMachineMigrationAuthenticationType,[int]$MaximumVirtualMachineMigrations) } }
if (-not (Get-Command Get-VMHostSupportedVersion -ErrorAction SilentlyContinue)) { function Get-VMHostSupportedVersion { [CmdletBinding()] param([string]$ComputerName) } }
if (Test-PreferredWindowsCommandMissing 'Hyper-V\Measure-VMReplication') { function Measure-VMReplication { [CmdletBinding()] param([string]$VMName,[string]$ComputerName) } }

# ── ServerManager ─────────────────────────────────────────────────────────────
if (-not (Get-Command Get-WindowsFeature       -ErrorAction SilentlyContinue)) { function Get-WindowsFeature       { [CmdletBinding()] param([string]$Name,[string]$ComputerName) } }
if (-not (Get-Command Install-WindowsFeature   -ErrorAction SilentlyContinue)) { function Install-WindowsFeature   { [CmdletBinding()] param([string]$Name,[switch]$IncludeManagementTools,[switch]$IncludeAllSubFeature) } }

# ── SecretManagement / CredentialManager ─────────────────────────────────────
if (-not (Get-Command Get-Secret               -ErrorAction SilentlyContinue)) { function Get-Secret               { [CmdletBinding()] param([string]$Name,[string]$Vault,[switch]$AsSecureString) } }
if (-not (Get-Command Get-StoredCredential     -ErrorAction SilentlyContinue)) { function Get-StoredCredential     { [CmdletBinding()] param([string]$Target) } }

# ── Networking ───────────────────────────────────────────────────────────────
if (-not (Get-Command Get-NetAdapter           -ErrorAction SilentlyContinue)) { function Get-NetAdapter           { [CmdletBinding()] param([string]$Name) } }
if (-not (Get-Command Get-NetAdapterBinding    -ErrorAction SilentlyContinue)) { function Get-NetAdapterBinding    { [CmdletBinding()] param([string]$Name) } }
if (-not (Get-Command Set-ClusterNetworkInterface -ErrorAction SilentlyContinue)) { function Set-ClusterNetworkInterface { [CmdletBinding()] param([string]$Name) } }

# ── Event Log ─────────────────────────────────────────────────────────────────
if (-not (Get-Command Write-EventLog           -ErrorAction SilentlyContinue)) { function Write-EventLog           { [CmdletBinding()] param([string]$LogName,[string]$Source,[string]$EntryType,[int]$EventId,[string]$Message) } }
if (-not (Get-Command New-EventLog             -ErrorAction SilentlyContinue)) { function New-EventLog             { [CmdletBinding()] param([string]$LogName,[string]$Source) } }
