function Test-HVFeatureQueryCapability {
    <#
    .SYNOPSIS
        Returns whether Windows feature discovery is available in the current engine.
    #>
    [CmdletBinding()]
    param()

    $command = Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue
    if ($command) {
        return [PSCustomObject]@{
            Supported = $true
            Message   = 'Get-WindowsFeature is available.'
        }
    }

    $engine = "$($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)"
    return [PSCustomObject]@{
        Supported = $false
        Message   = "Get-WindowsFeature is unavailable in the current engine ($engine). Use Windows PowerShell 5.1 or install ServerManager compatibility support before running cluster validation."
    }
}

function Test-HVClusterValidation {
    <#
    .SYNOPSIS
        Runs Test-Cluster against the requested nodes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Nodes,
        [string]$ClusterName = ''
    )

    $failures = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $reportPath = $null

    $testClusterCommand = Get-Command Test-Cluster -ErrorAction SilentlyContinue
    if (-not $testClusterCommand) {
        $failures.Add('Test-Cluster is unavailable. Install/import the FailoverClusters module before enforcement runs.')
        return [PSCustomObject]@{
            Passed     = $false
            Failures   = $failures.ToArray()
            Warnings   = $warnings.ToArray()
            ReportPath = $reportPath
        }
    }

    try {
        $validation = Test-Cluster -Node $Nodes -ErrorAction Stop
        if ($validation -is [array]) {
            $failedItems = @($validation | Where-Object {
                ($_.PSObject.Properties.Name -contains 'Succeeded' -and -not $_.Succeeded) -or
                ($_.PSObject.Properties.Name -contains 'Success' -and -not $_.Success)
            })
            if ($failedItems.Count -gt 0) {
                foreach ($item in $failedItems) {
                    $failures.Add([string]$item)
                }
            }
        }
        elseif ($validation.PSObject.Properties.Name -contains 'Succeeded' -and -not $validation.Succeeded) {
            $failures.Add("Test-Cluster reported failure for '$ClusterName'.")
        }

        if ($validation.PSObject.Properties.Name -contains 'ReportPath') {
            $reportPath = $validation.ReportPath
        }
        elseif ($validation.PSObject.Properties.Name -contains 'Report') {
            $reportPath = $validation.Report
        }
    }
    catch {
        $failures.Add("Test-Cluster failed: $($_.Exception.Message)")
    }

    return [PSCustomObject]@{
        Passed     = ($failures.Count -eq 0)
        Failures   = $failures.ToArray()
        Warnings   = $warnings.ToArray()
        ReportPath = $reportPath
    }
}

function Test-HVPrerequisites {
    <#
    .SYNOPSIS
        Runs pre-flight checks on the local machine before cluster operations begin.
        Validates admin rights, OS version, PowerShell version, required Windows Features,
        and basic environment sanity. Supports WS2022 and WS2025.
    .PARAMETER RequiredNodes
        Node names to validate are at minimum reachable via DNS/ping (lightweight check).
        Full per-node WinRM + feature checks are handled by Test-HVNodeReadiness.
    .PARAMETER OSVersionOverride
        Force a specific OS version string ('2022'|'2025') instead of auto-detecting.
    .OUTPUTS
        PSCustomObject: Passed (bool), Failures (string[]), Warnings (string[]).
    #>
    [CmdletBinding()]
    param(
        [string[]]$RequiredNodes = @(),
        [ValidateSet('Auto','2022','2025')]
        [string]$OSVersionOverride = 'Auto',
        [ValidateSet('Audit','Enforce','Remediate')]
        [string]$Mode = 'Audit',
        [switch]$SkipClusterValidation,
        [switch]$BreakGlass,
        [string]$TargetClusterName = ''
    )

    $failures = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()

    # 1. Administrator rights
    $currentPrincipal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        $failures.Add('Script must be run as Administrator.')
    }
    else {
        Write-HVLog -Message 'Pre-flight: Administrator rights confirmed.' -Level 'INFO'
    }

    # 2. PowerShell version
    $psVer = $PSVersionTable.PSVersion
    if ($psVer.Major -lt 5 -or ($psVer.Major -eq 5 -and $psVer.Minor -lt 1)) {
        $failures.Add("PowerShell 5.1+ required. Current: $($psVer.ToString())")
    }
    else {
        Write-HVLog -Message "Pre-flight: PowerShell $($psVer.ToString()) OK." -Level 'INFO'
    }

    # 3. OS version
    $osProfile = Get-HVOSProfile
    if ($OSVersionOverride -ne 'Auto') {
        Write-HVLog -Message "Pre-flight: OS version override='$OSVersionOverride' (detected '$($osProfile.Version)')." -Level 'WARN'
    }
    if ($osProfile.Version -eq 'Unknown') {
        $failures.Add("Unsupported OS: $($osProfile.DisplayName). Supported: Windows Server 2022, 2025.")
    }
    elseif ($osProfile.Version -eq '2019') {
        $warnings.Add("Windows Server 2019 detected. Module is validated for WS2022/WS2025; some features may differ.")
    }
    else {
        Write-HVLog -Message "Pre-flight: OS '$($osProfile.DisplayName)' is supported." -Level 'INFO'
    }

    # 4. Required Windows Features
    $featureCapability = Test-HVFeatureQueryCapability
    if (-not $featureCapability.Supported) {
        $failures.Add($featureCapability.Message)
    }

    $requiredFeatures = @(
        'Failover-Clustering',
        'Hyper-V',
        'Hyper-V-PowerShell',
        'RSAT-Clustering',
        'RSAT-Clustering-PowerShell'
    )

    if ($featureCapability.Supported) {
        foreach ($feature in $requiredFeatures) {
            try {
                $f = Get-WindowsFeature -Name $feature -ErrorAction Stop
                if ($f.InstallState -eq 'Installed') {
                    Write-HVLog -Message "Pre-flight: Feature '$feature' installed." -Level 'INFO'
                }
                elseif ($f.InstallState -eq 'InstallPending') {
                    $warnings.Add("Feature '$feature' install is pending (reboot required).")
                }
                else {
                    $failures.Add("Required Windows Feature not installed: '$feature'. Run: Install-WindowsFeature -Name $feature -IncludeManagementTools")
                }
            }
            catch {
                $warnings.Add("Could not query feature '$feature': $($_.Exception.Message)")
            }
        }
    }

    # 5. Domain membership
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        if ($cs.PartOfDomain) {
            Write-HVLog -Message "Pre-flight: Domain membership confirmed ('$($cs.Domain)')." -Level 'INFO'
        }
        else {
            $failures.Add('Machine is not domain-joined. Failover Clustering requires Active Directory.')
        }
    }
    catch {
        $warnings.Add("Could not verify domain membership: $($_.Exception.Message)")
    }

    # 6. Lightweight DNS check on required nodes
    foreach ($node in $RequiredNodes) {
        try {
            $null = [System.Net.Dns]::GetHostEntry($node)
            Write-HVLog -Message "Pre-flight: DNS resolved '$node'." -Level 'INFO'
        }
        catch {
            $warnings.Add("DNS resolution failed for node '$node'. Verify DNS/hostname.")
        }
    }

    $clusterValidation = $null
    if (-not $SkipClusterValidation -and $RequiredNodes.Count -gt 0) {
        $clusterValidation = Test-HVClusterValidation -Nodes $RequiredNodes -ClusterName $TargetClusterName
        foreach ($warning in $clusterValidation.Warnings) {
            $warnings.Add($warning)
        }
        if (-not $clusterValidation.Passed) {
            if ($Mode -in @('Enforce','Remediate') -and -not $BreakGlass) {
                foreach ($failure in $clusterValidation.Failures) {
                    $failures.Add($failure)
                }
            }
            else {
                foreach ($failure in $clusterValidation.Failures) {
                    $warnings.Add("Cluster validation warning: $failure")
                }
            }
        }
        elseif ($clusterValidation.ReportPath) {
            Write-HVLog -Message "Pre-flight: Test-Cluster report available at '$($clusterValidation.ReportPath)'." -Level 'INFO'
        }
    }
    elseif ($SkipClusterValidation) {
        $warnings.Add('Cluster validation skipped by request.')
    }

    $passed = $failures.Count -eq 0

    if ($passed) {
        Write-HVLog -Message "Pre-flight: All checks PASSED ($($warnings.Count) warning(s))." -Level 'INFO'
    }
    else {
        Write-HVLog -Message "Pre-flight: FAILED with $($failures.Count) error(s) and $($warnings.Count) warning(s)." -Level 'ERROR'
        foreach ($f in $failures) { Write-HVLog -Message "  FAIL: $f" -Level 'ERROR' }
    }
    foreach ($w in $warnings) { Write-HVLog -Message "  WARN: $w" -Level 'WARN' }

    return [PSCustomObject]@{
        Passed            = $passed
        Failures          = $failures.ToArray()
        Warnings          = $warnings.ToArray()
        OSProfile         = $osProfile
        ClusterValidation = $clusterValidation
    }
}
