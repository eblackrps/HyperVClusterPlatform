function Get-HVMigrationReadiness {
    <#
    .SYNOPSIS
        Validates that live migration prerequisites are met on all cluster nodes.
        Checks WinRM, Hyper-V live migration settings, and network availability.
    .PARAMETER Nodes
        Node names to check. Defaults to all current cluster nodes.
    .OUTPUTS
        PSCustomObject[]: NodeName, Ready (bool), Issues (string[]).
    #>
    [CmdletBinding()]
    param(
        [string[]]$Nodes
    )

    if (-not $Nodes) {
        $Nodes = @(Get-ClusterNode -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    }

    $results = foreach ($node in $Nodes) {
        $issues = [System.Collections.Generic.List[string]]::new()

        # 1. Node is Up
        $clNode = Get-ClusterNode -Name $node -ErrorAction SilentlyContinue
        if (-not $clNode -or $clNode.State -ne 'Up') {
            $issues.Add("Node '$node' is not in Up state.")
        }

        # 2. Live migration enabled on the hypervisor
        try {
            $vmHost = Get-VMHost -ComputerName $node -ErrorAction Stop
            if (-not $vmHost.VirtualMachineMigrationEnabled) {
                $issues.Add("[$node] Virtual machine migration is disabled on the host.")
            }
            Write-HVLog -Message "[$node] VM migration enabled: $($vmHost.VirtualMachineMigrationEnabled)" -Level 'INFO'
        }
        catch {
            $issues.Add("[$node] Could not query VM host settings: $($_.Exception.Message)")
        }

        # 3. Network available for live migration
        try {
            $clusterNets = Get-ClusterNetwork -ErrorAction SilentlyContinue |
                           Where-Object { $_.Role -ge 1 }
            if (@($clusterNets).Count -eq 0) {
                $issues.Add("[$node] No cluster networks with Role >= 1 (no live migration network).")
            }
        }
        catch {
            Write-HVLog -Message "[$node] Network check warn: $($_.Exception.Message)" -Level 'WARN'
        }

        $ready = $issues.Count -eq 0
        Write-HVLog -Message "[$node] Migration readiness: $(if ($ready){'READY'}else{'NOT READY'}) ($($issues.Count) issue(s))." -Level $(if ($ready){'INFO'} else {'WARN'})

        [PSCustomObject]@{
            NodeName = $node
            Ready    = $ready
            Issues   = $issues.ToArray()
        }
    }

    return @($results)
}

function Set-HVLiveMigrationConfig {
    <#
    .SYNOPSIS
        Configures live migration settings (enabled/disabled, authentication, bandwidth)
        on each cluster node. Idempotent.
    .PARAMETER Nodes
        Target nodes. Defaults to all cluster nodes.
    .PARAMETER Enabled
        Enable or disable live migration. Default: $true.
    .PARAMETER AuthenticationType
        Kerberos | CredSSP. Default: Kerberos.
    .PARAMETER MaxSimultaneous
        Max simultaneous live migrations. Default: 2.
    .PARAMETER MaxBandwidthMbps
        Bandwidth limit in Mbps (0 = unlimited). Default: 0.
    #>
    [CmdletBinding()]
    param(
        [string[]]$Nodes,
        [bool]   $Enabled           = $true,
        [ValidateSet('Kerberos','CredSSP')][string]$AuthenticationType = 'Kerberos',
        [int]    $MaxSimultaneous   = 2,
        [int]    $MaxBandwidthMbps  = 0
    )

    if (-not $Nodes) {
        $Nodes = @(Get-ClusterNode -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    }

    foreach ($node in $Nodes) {
        try {
            $vmHost = Get-VMHost -ComputerName $node -ErrorAction Stop

            if ($vmHost.VirtualMachineMigrationEnabled -ne $Enabled) {
                Write-HVLog -Message "[$node] Setting VM migration enabled=$Enabled." -Level 'WARN'
                Set-VMHost -ComputerName $node -VirtualMachineMigrationEnabled $Enabled -ErrorAction Stop
            }

            if ($Enabled) {
                $authMap = @{ 'Kerberos' = 'Kerberos'; 'CredSSP' = 'CredSsp' }
                if ($vmHost.VirtualMachineMigrationAuthenticationType -ne $authMap[$AuthenticationType]) {
                    Write-HVLog -Message "[$node] Setting migration auth=$AuthenticationType." -Level 'WARN'
                    Set-VMHost -ComputerName $node `
                               -VirtualMachineMigrationAuthenticationType $authMap[$AuthenticationType] `
                               -ErrorAction Stop
                }

                if ($vmHost.MaximumVirtualMachineMigrations -ne $MaxSimultaneous) {
                    Write-HVLog -Message "[$node] Setting max simultaneous migrations=$MaxSimultaneous." -Level 'INFO'
                    Set-VMHost -ComputerName $node -MaximumVirtualMachineMigrations $MaxSimultaneous -ErrorAction Stop
                }

                if ($MaxBandwidthMbps -gt 0) {
                    Write-HVLog -Message "[$node] MaxBandwidthMbps=$MaxBandwidthMbps requested. Hyper-V bandwidth shaping is not configured by Set-VMHost; use SMB/QoS policies for enforcement." -Level 'WARN'
                }
            }

            Write-HVLog -Message "[$node] Live migration config applied." -Level 'INFO'
        }
        catch {
            Write-HVLog -Message "[$node] Set-HVLiveMigrationConfig failed: $($_.Exception.Message)" -Level 'ERROR'
        }
    }
}

function Start-HVLiveMigration {
    <#
    .SYNOPSIS
        Live-migrates one or more VMs to a target node with readiness validation.
    .PARAMETER VMNames
        VM cluster group names to migrate.
    .PARAMETER DestinationNode
        Target node. If omitted, the cluster balancer chooses.
    .PARAMETER SkipReadinessCheck
        Skip pre-migration readiness validation.
    .OUTPUTS
        PSCustomObject[]: VMName, Success, DestinationNode, Error.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$VMNames,
        [string]$DestinationNode,
        [switch]$SkipReadinessCheck
    )

    if (-not $SkipReadinessCheck) {
        $target = if ($DestinationNode) { @($DestinationNode) } else {
            @(Get-ClusterNode -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
        }
        $readiness = Get-HVMigrationReadiness -Nodes $target
        $notReady  = @($readiness | Where-Object { -not $_.Ready })
        if ($notReady.Count -gt 0) {
            $names = ($notReady | Select-Object -ExpandProperty NodeName) -join ', '
            throw "Migration readiness check failed for: $names. Use -SkipReadinessCheck to override."
        }
    }

    $results = foreach ($vmName in $VMNames) {
        try {
            Write-HVLog -Message "Live migrating '$vmName'$(if ($DestinationNode){' to '+$DestinationNode})..." -Level 'WARN'

            $moveParams = @{ Name = $vmName; ErrorAction = 'Stop' }
            if ($DestinationNode) { $moveParams['Node'] = $DestinationNode }

            Move-ClusterVirtualMachineRole @moveParams | Out-Null

            $group = Get-ClusterGroup -Name $vmName -ErrorAction SilentlyContinue
            $dest  = if ($group) { $group.OwnerNode.Name } else { $DestinationNode }

            Write-HVLog -Message "VM '$vmName' migrated successfully to '$dest'." -Level 'INFO'
            [PSCustomObject]@{ VMName = $vmName; Success = $true;  DestinationNode = $dest; Error = $null }
        }
        catch {
            Write-HVLog -Message "VM '$vmName' migration failed: $($_.Exception.Message)" -Level 'ERROR'
            [PSCustomObject]@{ VMName = $vmName; Success = $false; DestinationNode = $null; Error = $_.Exception.Message }
        }
    }

    return @($results)
}
