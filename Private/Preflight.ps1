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
        [string]$OSVersionOverride = 'Auto'
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
    $requiredFeatures = @(
        'Failover-Clustering',
        'Hyper-V',
        'Hyper-V-PowerShell',
        'RSAT-Clustering',
        'RSAT-Clustering-PowerShell'
    )

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
        Passed   = $passed
        Failures = $failures.ToArray()
        Warnings = $warnings.ToArray()
        OSProfile = $osProfile
    }
}
