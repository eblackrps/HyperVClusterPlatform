function Get-HVNetworkProfile {
    <#
    .SYNOPSIS
        Discovers and classifies network adapters on a cluster node.
        Returns a structured profile with each adapter's detected role.
    .DESCRIPTION
        Classification heuristics (in priority order):
          1. If adapter name contains 'mgmt','management','prod' -> Management
          2. If adapter name contains 'live','migration','lm'   -> LiveMigration
          3. If adapter name contains 'storage','iscsi','smb','csv' -> Storage
          4. If adapter name contains 'heartbeat','hb','cluster' -> Heartbeat
          5. Remaining adapters with valid IPs -> Unclassified
    .PARAMETER ComputerName
        Node to query. Defaults to local machine.
    .OUTPUTS
        PSCustomObject[]: one entry per adapter with Name, IPAddress, Role, Speed, MACAddress.
    #>
    [CmdletBinding()]
    param(
        [string]$ComputerName = $env:COMPUTERNAME
    )

    try {
        $adapters = Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration `
                        -ComputerName $ComputerName -ErrorAction Stop |
                    Where-Object { $_.IPEnabled -eq $true }

        $adapterNames = Get-CimInstance -ClassName Win32_NetworkAdapter `
                            -ComputerName $ComputerName -ErrorAction SilentlyContinue |
                        Where-Object { $_.NetEnabled -eq $true }

        $results = foreach ($a in $adapters) {
            $name = ($adapterNames | Where-Object Index -eq $a.Index).NetConnectionID
            if (-not $name) { $name = $a.Description }

            $nameLower = $name.ToLower()
            $role = switch ($true) {
                ($nameLower -match 'mgmt|management|prod|production') { 'Management' }
                ($nameLower -match 'live|migration|lm\b')             { 'LiveMigration' }
                ($nameLower -match 'storage|iscsi|smb|csv|san')       { 'Storage' }
                ($nameLower -match 'heartbeat|hb\b|cluster')          { 'Heartbeat' }
                default                                                { 'Unclassified' }
            }

            [PSCustomObject]@{
                ComputerName = $ComputerName
                AdapterName  = $name
                IPAddress    = ($a.IPAddress | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1)
                SubnetMask   = ($a.IPSubnet  | Select-Object -First 1)
                MACAddress   = $a.MACAddress
                Role         = $role
                Description  = $a.Description
            }
        }

        Write-HVLog -Message "[$ComputerName] Network profile: $($results.Count) IP-enabled adapters discovered." -Level 'INFO'
        return @($results)
    }
    catch {
        Write-HVLog -Message "[$ComputerName] Network profile discovery failed: $($_.Exception.Message)" -Level 'WARN'
        return @()
    }
}

function Set-HVClusterNetworkRoles {
    <#
    .SYNOPSIS
        Assigns cluster network roles (AllowClusterCommunication, LiveMigration, etc.)
        based on adapter name classification.
    .PARAMETER ClusterNetworkRoleMap
        Hashtable mapping cluster network names to desired roles:
          0 = Do not allow cluster network communication
          1 = Allow cluster network communication
          3 = Allow cluster network communication and client connectivity
        Example: @{ 'Cluster Network 1' = 1; 'Cluster Network 2' = 3 }
    .PARAMETER LiveMigrationNetworks
        Array of cluster network names to prefer for Live Migration (in priority order).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [hashtable]$ClusterNetworkRoleMap   = @{},
        [string[]] $LiveMigrationNetworks   = @()
    )

    try {
        $clusterNets = Get-ClusterNetwork -ErrorAction Stop

        foreach ($net in $clusterNets) {
            if ($ClusterNetworkRoleMap.ContainsKey($net.Name)) {
                $desired = $ClusterNetworkRoleMap[$net.Name]
                if ($net.Role -ne $desired) {
                    if ($PSCmdlet.ShouldProcess($net.Name, "Set cluster network role to $desired")) {
                        Write-HVLog -Message "Network '$($net.Name)': setting Role=$desired (was $($net.Role))." -Level 'WARN'
                        $net.Role = $desired
                    }
                }
                else {
                    Write-HVLog -Message "Network '$($net.Name)': Role=$desired already set." -Level 'INFO'
                }
            }
        }

        # Configure Live Migration network preference order
        if ($LiveMigrationNetworks.Count -gt 0) {
            Write-HVLog -Message "Configuring Live Migration network preference order..." -Level 'INFO'
            $priority = 1
            foreach ($netName in $LiveMigrationNetworks) {
                $net = $clusterNets | Where-Object Name -eq $netName
                if ($net) {
                    if ($PSCmdlet.ShouldProcess($netName, "Set live migration network priority to $priority")) {
                        $net.Metric = $priority
                        Write-HVLog -Message "  LM priority $priority -> '$netName'" -Level 'INFO'
                    }
                    $priority++
                }
                else {
                    Write-HVLog -Message "  LM network '$netName' not found in cluster." -Level 'WARN'
                }
            }
        }

        Write-HVLog -Message "Cluster network roles configured." -Level 'INFO'
        return $true
    }
    catch {
        Write-HVLog -Message "Set-HVClusterNetworkRoles failed: $($_.Exception.Message)" -Level 'ERROR'
        throw
    }
}

function Get-HVNetworkDrift {
    <#
    .SYNOPSIS
        Compares desired network role configuration against live cluster state.
    .PARAMETER DesiredRoleMap
        Hashtable of cluster network name -> desired Role integer.
    .OUTPUTS
        PSCustomObject: Score (0-100), Details (string[]), Networks (object[]).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$DesiredRoleMap
    )

    $score   = 0
    $detail  = [System.Collections.Generic.List[string]]::new()
    $netList = [System.Collections.Generic.List[object]]::new()

    try {
        $clusterNets = Get-ClusterNetwork -ErrorAction SilentlyContinue
        if (-not $clusterNets) {
            return [PSCustomObject]@{ Score = 100; Details = @('No cluster networks found.'); Networks = @() }
        }

        $perNetWeight = [math]::Min(20, [math]::Floor(100 / [math]::Max($DesiredRoleMap.Count, 1)))

        foreach ($kvp in $DesiredRoleMap.GetEnumerator()) {
            $net = $clusterNets | Where-Object Name -eq $kvp.Key
            if (-not $net) {
                $score += $perNetWeight
                $detail.Add("Cluster network '$($kvp.Key)' not found.")
                continue
            }
            if ($net.Role -ne $kvp.Value) {
                $score += $perNetWeight
                $detail.Add("Network '$($kvp.Key)': desired Role=$($kvp.Value), actual=$($net.Role).")
            }
            $netList.Add([PSCustomObject]@{ Name = $net.Name; Role = $net.Role; Desired = $kvp.Value; Compliant = ($net.Role -eq $kvp.Value) })
        }

        if ($score -gt 100) { $score = 100 }
        Write-HVLog -Message "Network drift score: $score/100" -Level 'INFO'

        return [PSCustomObject]@{
            Score    = [int]$score
            Details  = $detail.ToArray()
            Networks = $netList.ToArray()
        }
    }
    catch {
        Write-HVLog -Message "Get-HVNetworkDrift failed: $($_.Exception.Message)" -Level 'ERROR'
        return [PSCustomObject]@{ Score = 100; Details = @($_.Exception.Message); Networks = @() }
    }
}
