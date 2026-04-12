function Get-HVVMPlacementState {
    <#
    .SYNOPSIS
        Reads current VM placement state: preferred owners and anti-affinity groups.
    .OUTPUTS
        PSCustomObject: VMs (object[]), AntiAffinityGroups (object[]).
    #>
    [CmdletBinding()]
    param()

    try {
        $vms = Get-ClusterGroup -ErrorAction SilentlyContinue |
               Where-Object GroupType -eq 'VirtualMachine'

        $vmList = foreach ($vm in $vms) {
            $owners = @($vm.PreferredOwner | Select-Object -ExpandProperty Name -ErrorAction SilentlyContinue)
            [PSCustomObject]@{
                VMName          = $vm.Name
                CurrentOwner    = $vm.OwnerNode.Name
                PreferredOwners = $owners
                State           = $vm.State.ToString()
            }
        }

        # Anti-affinity groups are stored as cluster group properties
        $aaGroups = [System.Collections.Generic.List[object]]::new()
        try {
            $groups = Get-ClusterGroup -ErrorAction SilentlyContinue
            $aaProperty = 'AntiAffinityClassNames'
            foreach ($g in $groups) {
                $prop = $g | Get-ClusterGroupProperty -ErrorAction SilentlyContinue |
                            Where-Object Name -eq $aaProperty
                if ($prop -and $prop.Value) {
                    $aaGroups.Add([PSCustomObject]@{
                        GroupName          = $g.Name
                        AntiAffinityClass  = $prop.Value
                    })
                }
            }
        }
        catch {
            Write-HVLog -Message "Could not read anti-affinity groups: $($_.Exception.Message)" -Level 'WARN'
        }

        Write-HVLog -Message "VM placement: $(@($vmList).Count) VMs, $($aaGroups.Count) AA groups." -Level 'INFO'

        return [PSCustomObject]@{
            VMs                = @($vmList)
            AntiAffinityGroups = $aaGroups.ToArray()
        }
    }
    catch {
        Write-HVLog -Message "Get-HVVMPlacementState failed: $($_.Exception.Message)" -Level 'ERROR'
        return [PSCustomObject]@{ VMs = @(); AntiAffinityGroups = @() }
    }
}

function Set-HVVMPreferredOwner {
    <#
    .SYNOPSIS
        Idempotently sets preferred owners for one or more VM cluster groups.
    .PARAMETER VMPreferredOwners
        Hashtable of VMName -> string[] of preferred owner node names.
        Example: @{ 'VM01' = @('NODE1','NODE2'); 'VM02' = @('NODE2','NODE1') }
    .OUTPUTS
        PSCustomObject[]: result per VM — VMName, Changed, Owners.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][hashtable]$VMPreferredOwners
    )

    $results = [System.Collections.Generic.List[object]]::new()

    foreach ($kvp in $VMPreferredOwners.GetEnumerator()) {
        $vmName   = $kvp.Key
        $desired  = @($kvp.Value)

        try {
            $group = Get-ClusterGroup -Name $vmName -ErrorAction Stop
            $currentOwners = @($group.PreferredOwner |
                               Select-Object -ExpandProperty Name -ErrorAction SilentlyContinue)

            $diff = Compare-Object -ReferenceObject ($desired | Sort-Object) `
                                   -DifferenceObject ($currentOwners | Sort-Object) `
                                   -ErrorAction SilentlyContinue

            if ($diff) {
                if ($PSCmdlet.ShouldProcess($vmName, 'Set preferred owners')) {
                    Write-HVLog -Message "VM '$vmName': setting preferred owners to [$($desired -join ',')]." -Level 'WARN'
                    $nodes = $desired | ForEach-Object { Get-ClusterNode -Name $_ -ErrorAction Stop }
                    Set-ClusterOwnerNode -Group $vmName -Owners $nodes -ErrorAction Stop
                    $results.Add([PSCustomObject]@{ VMName = $vmName; Changed = $true; Owners = $desired })
                    Write-HVLog -Message "VM '$vmName': preferred owners updated." -Level 'INFO'
                }
                else {
                    $results.Add([PSCustomObject]@{ VMName = $vmName; Changed = $false; Owners = $desired })
                }
            }
            else {
                Write-HVLog -Message "VM '$vmName': preferred owners already correct." -Level 'INFO'
                $results.Add([PSCustomObject]@{ VMName = $vmName; Changed = $false; Owners = $desired })
            }
        }
        catch {
            Write-HVLog -Message "VM '$vmName': failed to set preferred owners: $($_.Exception.Message)" -Level 'ERROR'
            $results.Add([PSCustomObject]@{ VMName = $vmName; Changed = $false; Error = $_.Exception.Message })
        }
    }

    return $results.ToArray()
}

function New-HVAntiAffinityGroup {
    <#
    .SYNOPSIS
        Creates or updates anti-affinity class assignments so paired VMs are
        kept on separate nodes by the cluster balancer.
    .PARAMETER GroupName
        Shared anti-affinity class label (e.g. 'Tier1-VMs').
    .PARAMETER VMNames
        Array of VM cluster group names to assign to the class.
    .OUTPUTS
        PSCustomObject: GroupName, VMNames, Changed.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]  $GroupName,
        [Parameter(Mandatory)][string[]]$VMNames
    )

    $changed = $false

    foreach ($vmName in $VMNames) {
        try {
            $group = Get-ClusterGroup -Name $vmName -ErrorAction Stop
            $current = ($group | Get-ClusterGroupProperty -ErrorAction SilentlyContinue |
                        Where-Object Name -eq 'AntiAffinityClassNames').Value

            if ($current -ne $GroupName) {
                if ($PSCmdlet.ShouldProcess($vmName, "Assign anti-affinity class '$GroupName'")) {
                    Write-HVLog -Message "VM '$vmName': assigning anti-affinity class '$GroupName'." -Level 'WARN'
                    (Get-ClusterGroup -Name $vmName).AntiAffinityClassNames = $GroupName
                    $changed = $true
                    Write-HVLog -Message "VM '$vmName': anti-affinity class set." -Level 'INFO'
                }
            }
            else {
                Write-HVLog -Message "VM '$vmName': anti-affinity class '$GroupName' already set." -Level 'INFO'
            }
        }
        catch {
            Write-HVLog -Message "VM '$vmName': anti-affinity assignment failed: $($_.Exception.Message)" -Level 'ERROR'
        }
    }

    return [PSCustomObject]@{
        GroupName = $GroupName
        VMNames   = $VMNames
        Changed   = $changed
    }
}

function Get-HVVMPlacementDrift {
    <#
    .SYNOPSIS
        Scores drift between desired VM placement policy and current state.
    .PARAMETER DesiredPreferredOwners
        Hashtable of VMName -> string[] desired preferred owners.
    .PARAMETER DesiredAntiAffinityGroups
        Hashtable of GroupName -> string[] VM names in the group.
    .OUTPUTS
        PSCustomObject: Score (0-100), Details (string[]).
    #>
    [CmdletBinding()]
    param(
        [hashtable]$DesiredPreferredOwners    = @{},
        [hashtable]$DesiredAntiAffinityGroups = @{}
    )

    $score  = 0
    $detail = [System.Collections.Generic.List[string]]::new()
    $total  = $DesiredPreferredOwners.Count + $DesiredAntiAffinityGroups.Count
    if ($total -eq 0) {
        return [PSCustomObject]@{ Score = 0; Details = @('No desired placement policy specified.') }
    }
    $perItem = [math]::Min(25, [math]::Floor(100 / $total))

    # Check preferred owners
    foreach ($kvp in $DesiredPreferredOwners.GetEnumerator()) {
        try {
            $group   = Get-ClusterGroup -Name $kvp.Key -ErrorAction Stop
            $current = @($group.PreferredOwner |
                         Select-Object -ExpandProperty Name -ErrorAction SilentlyContinue | Sort-Object)
            $desired = @($kvp.Value | Sort-Object)
            $diff    = Compare-Object $desired $current -ErrorAction SilentlyContinue
            if ($diff) {
                $score += $perItem
                $detail.Add("VM '$($kvp.Key)': preferred owners mismatch (desired=[$($desired -join ',')] current=[$($current -join ',')]).")
            }
        }
        catch {
            $score += $perItem
            $detail.Add("VM '$($kvp.Key)': not found in cluster.")
        }
    }

    # Check anti-affinity groups
    foreach ($kvp in $DesiredAntiAffinityGroups.GetEnumerator()) {
        foreach ($vmName in $kvp.Value) {
            try {
                $group   = Get-ClusterGroup -Name $vmName -ErrorAction Stop
                $current = ($group | Get-ClusterGroupProperty -ErrorAction SilentlyContinue |
                            Where-Object Name -eq 'AntiAffinityClassNames').Value
                if ($current -ne $kvp.Key) {
                    $score += [math]::Floor($perItem / [math]::Max($kvp.Value.Count, 1))
                    $detail.Add("VM '$vmName': anti-affinity class should be '$($kvp.Key)', got '$current'.")
                }
            }
            catch {
                $score += [math]::Floor($perItem / [math]::Max($kvp.Value.Count, 1))
                $detail.Add("VM '$vmName': not found while checking anti-affinity.")
            }
        }
    }

    if ($score -gt 100) { $score = 100 }
    Write-HVLog -Message "VM placement drift: $score/100" -Level 'INFO'

    return [PSCustomObject]@{
        Score   = [int]$score
        Details = $detail.ToArray()
    }
}
