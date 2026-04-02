function Test-HVNodeReadiness {
    <#
    .SYNOPSIS
        Validates each cluster node for: ICMP reachability, WinRM connectivity,
        required Windows Features, domain membership, and OS version compatibility.
    .PARAMETER Nodes
        Array of node hostnames or IP addresses.
    .PARAMETER RequiredFeatures
        Override the default list of required Windows features to check remotely.
    .OUTPUTS
        PSCustomObject[]: One result per node with Passed, NodeName, Failures, Warnings, OSProfile.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Nodes,
        [string[]]$RequiredFeatures = @(
            'Failover-Clustering',
            'Hyper-V',
            'Hyper-V-PowerShell',
            'RSAT-Clustering',
            'RSAT-Clustering-PowerShell'
        )
    )

    $results = [System.Collections.Generic.List[object]]::new()

    foreach ($node in $Nodes) {
        $failures = [System.Collections.Generic.List[string]]::new()
        $warnings = [System.Collections.Generic.List[string]]::new()
        $osProfile = $null

        Write-HVLog -Message "Node validation starting for '$node'..." -Level 'INFO'

        # 1. ICMP reachability
        $pingOk = Test-Connection -ComputerName $node -Count 2 -Quiet -ErrorAction SilentlyContinue
        if (-not $pingOk) {
            $failures.Add("[$node] ICMP ping failed. Node may be offline or blocking ping.")
            Write-HVLog -Message "[$node] Ping FAILED." -Level 'ERROR'
        }
        else {
            Write-HVLog -Message "[$node] Ping OK." -Level 'INFO'
        }

        # 2. WinRM connectivity
        try {
            $session = New-PSSession -ComputerName $node -ErrorAction Stop
            Write-HVLog -Message "[$node] WinRM/PSSession OK." -Level 'INFO'

            # 3. OS version (requires WinRM)
            try {
                $osProfile = Invoke-Command -Session $session -ScriptBlock {
                    $os    = Get-CimInstance Win32_OperatingSystem
                    $build = [int]$os.BuildNumber
                    switch ($true) {
                        ($build -ge 26100) { [PSCustomObject]@{ Build=$build; Version='2025'; DisplayName='Windows Server 2025' }; break }
                        ($build -ge 20348) { [PSCustomObject]@{ Build=$build; Version='2022'; DisplayName='Windows Server 2022' }; break }
                        ($build -ge 17763) { [PSCustomObject]@{ Build=$build; Version='2019'; DisplayName='Windows Server 2019' }; break }
                        default             { [PSCustomObject]@{ Build=$build; Version='Unknown'; DisplayName=$os.Caption } }
                    }
                } -ErrorAction Stop
                Write-HVLog -Message "[$node] OS: $($osProfile.DisplayName) (Build $($osProfile.Build))." -Level 'INFO'
                if ($osProfile.Version -eq 'Unknown') {
                    $failures.Add("[$node] Unsupported OS: $($osProfile.DisplayName).")
                }
            }
            catch {
                $warnings.Add("[$node] Could not detect OS via WinRM: $($_.Exception.Message)")
            }

            # 4. Domain membership (requires WinRM)
            try {
                $domain = Invoke-Command -Session $session -ScriptBlock {
                    (Get-CimInstance Win32_ComputerSystem).Domain
                } -ErrorAction Stop
                if ($domain -and $domain -ne 'WORKGROUP') {
                    Write-HVLog -Message "[$node] Domain: '$domain'." -Level 'INFO'
                }
                else {
                    $failures.Add("[$node] Not domain-joined. Failover Clustering requires AD.")
                }
            }
            catch {
                $warnings.Add("[$node] Could not verify domain membership: $($_.Exception.Message)")
            }

            # 5. Required Windows Features (requires WinRM)
            try {
                $remoteFeatures = Invoke-Command -Session $session -ArgumentList @(,$RequiredFeatures) -ScriptBlock {
                    param($features)
                    foreach ($f in $features) {
                        $result = Get-WindowsFeature -Name $f -ErrorAction SilentlyContinue
                        [PSCustomObject]@{ Name = $f; State = if ($result) { $result.InstallState } else { 'NotFound' } }
                    }
                } -ErrorAction Stop

                foreach ($rf in $remoteFeatures) {
                    if ($rf.State -eq 'Installed') {
                        Write-HVLog -Message "[$node] Feature '$($rf.Name)': Installed." -Level 'INFO'
                    }
                    elseif ($rf.State -eq 'InstallPending') {
                        $warnings.Add("[$node] Feature '$($rf.Name)' pending reboot.")
                    }
                    else {
                        $failures.Add("[$node] Feature '$($rf.Name)' NOT installed (State: $($rf.State)).")
                    }
                }
            }
            catch {
                $warnings.Add("[$node] Could not check features remotely: $($_.Exception.Message)")
            }

            try {
                Remove-PSSession -Session $session -ErrorAction SilentlyContinue
            }
            catch {
                Write-HVLog -Message "[$node] Could not remove PSSession cleanly: $($_.Exception.Message)" -Level 'WARN'
            }
        }
        catch {
            $failures.Add("[$node] WinRM connection failed: $($_.Exception.Message). Ensure WinRM is enabled and firewall allows it.")
            Write-HVLog -Message "[$node] WinRM FAILED: $($_.Exception.Message)" -Level 'ERROR'
        }

        $passed = $failures.Count -eq 0
        $status  = if ($passed) { 'PASS' } else { 'FAIL' }
        Write-HVLog -Message "[$node] Readiness: $status ($($failures.Count) failure(s), $($warnings.Count) warning(s))." -Level $(if ($passed) { 'INFO' } else { 'ERROR' })

        $results.Add([PSCustomObject]@{
            NodeName  = $node
            Passed    = $passed
            Failures  = $failures.ToArray()
            Warnings  = $warnings.ToArray()
            OSProfile = $osProfile
        })
    }

    return $results.ToArray()
}
