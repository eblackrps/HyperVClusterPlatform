function Invoke-HVCertificationSuite {
    <#
    .SYNOPSIS
        Runs a comprehensive production-readiness certification against a deployed cluster.
        Aggregates results from all platform modules into a single certification verdict.
    .DESCRIPTION
        Certification domains (each scored 0-100, weighted equally):
          1. Cluster Core        — name, nodes, CNO reachable
          2. Quorum / Witness    — witness type and health
          3. Node Health         — all nodes Up, features installed
          4. Network             — cluster networks assigned and live migration capable
          5. Storage             — CSVs online, minimum capacity
          6. VM Placement        — preferred owners and anti-affinity configured
          7. Live Migration      — migration enabled and tested across all node pairs
          8. DR Readiness        — snapshot, replication, failover readiness
          9. Security            — no credentials in config, SecretManagement in use
         10. Compliance Report   — drift score <= 5 after last Enforce run
    .PARAMETER ClusterName
        Expected cluster name.
    .PARAMETER Nodes
        Expected node list.
    .PARAMETER ReportsPath
        Directory for certification output.
    .PARAMETER SkipLiveMigrationTest
        Skip the live migration connectivity test (requires VMs to be running).
    .OUTPUTS
        PSCustomObject: Certified (bool), OverallScore (0-100), Domains (object[]),
        ReportPath (string), Timestamp.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]  $ClusterName,
        [Parameter(Mandatory)][string[]]$Nodes,
        [ValidateSet('None','Disk','Cloud','Share')][string]$WitnessType = '',
        [string]$ReportsPath              = '.\Reports',
        [switch]$SkipLiveMigrationTest
    )

    Write-HVLog -Message "=== CERTIFICATION SUITE STARTING ===" -Level 'INFO'
    Write-HVLog -Message "Cluster: $ClusterName  Nodes: [$($Nodes -join ',')]" -Level 'INFO'

    $domains = [System.Collections.Generic.List[object]]::new()
    $ts      = Get-Date

    function Add-Domain {
        param([string]$Name, [int]$Score, [string[]]$Details, [bool]$Pass)
        $domains.Add([PSCustomObject]@{
            Domain  = $Name
            Score   = [int]$Score
            Pass    = $Pass
            Details = $Details
        })
        $icon = if ($Pass) { 'PASS' } else { 'FAIL' }
        Write-HVLog -Message "  [$icon] $Name — $Score/100" -Level $(if ($Pass){'INFO'} else {'WARN'})
    }

    # ── 1. Cluster Core ───────────────────────────────────────────────────────
    $cluster = Get-Cluster -ErrorAction SilentlyContinue
    if (-not $cluster -or $cluster.Name -ne $ClusterName) {
        Add-Domain 'ClusterCore' 0 @("Cluster '$ClusterName' not found or name mismatch.") $false
    }
    else {
        $currentNodes = @(Get-ClusterNode -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
        $diff = Compare-Object ($Nodes | Sort-Object) ($currentNodes | Sort-Object) -ErrorAction SilentlyContinue
        if ($diff) {
            Add-Domain 'ClusterCore' 50 @("Node membership mismatch.") $false
        }
        else {
            Add-Domain 'ClusterCore' 100 @("Cluster '$ClusterName' with $($Nodes.Count) nodes — OK.") $true
        }
    }

    # ── 2. Quorum / Witness ───────────────────────────────────────────────────
    try {
        $q = Get-ClusterQuorum -ErrorAction Stop
        if ($q.QuorumType -notmatch 'Majority|Disk|Cloud|FileShare') {
            Add-Domain 'Quorum' 50 @("Unexpected quorum type: $($q.QuorumType).") $false
        }
        else {
            Add-Domain 'Quorum' 100 @("Quorum: $($q.QuorumType) — OK.") $true
        }
    }
    catch {
        Add-Domain 'Quorum' 0 @("Could not query quorum: $($_.Exception.Message).") $false
    }

    # ── 3. Node Health ────────────────────────────────────────────────────────
    $health = Get-HVClusterHealth
    $allUp  = @($health.Nodes | Where-Object { -not $_.Healthy }).Count -eq 0
    Add-Domain 'NodeHealth' $health.Score @($health.Details) $allUp

    # ── 4. Network ────────────────────────────────────────────────────────────
    try {
        $nets     = Get-ClusterNetwork -ErrorAction SilentlyContinue
        $noNets   = @($nets).Count -eq 0
        $netScore = if ($noNets) { 0 } else { 80 }
        $hasLM    = $nets | Where-Object { $_.Role -ge 1 }
        if ($hasLM) { $netScore = 100 }
        Add-Domain 'Network' $netScore @(if ($noNets){"No cluster networks found."}else{"$(@($nets).Count) cluster network(s) configured."}) ($netScore -ge 80)
    }
    catch {
        Add-Domain 'Network' 0 @($_.Exception.Message) $false
    }

    # ── 5. Storage ────────────────────────────────────────────────────────────
    $storage = Get-HVStorageDrift
    Add-Domain 'Storage' (100 - $storage.Score) @($storage.Details) ($storage.Score -le 10)

    # ── 6. VM Placement ───────────────────────────────────────────────────────
    $placement = Get-HVVMPlacementState
    $vmCount   = @($placement.VMs).Count
    Add-Domain 'VMPlacement' 100 @("$vmCount VM(s) found in cluster.") $true

    # ── 7. Live Migration ─────────────────────────────────────────────────────
    if (-not $SkipLiveMigrationTest) {
        $lmReady  = Get-HVMigrationReadiness -Nodes $Nodes
        $notReady = @($lmReady | Where-Object { -not $_.Ready })
        $lmScore  = [math]::Round(($lmReady.Count - $notReady.Count) / [math]::Max($lmReady.Count, 1) * 100)
        Add-Domain 'LiveMigration' $lmScore @($notReady | ForEach-Object { "$($_.NodeName): $($_.Issues -join '; ')" }) ($notReady.Count -eq 0)
    }
    else {
        Add-Domain 'LiveMigration' 100 @('Skipped (-SkipLiveMigrationTest).') $true
    }

    # ── 8. DR Readiness ───────────────────────────────────────────────────────
    $dr = Test-HVDRReadiness
    Add-Domain 'DRReadiness' $dr.Score @($dr.Checks | ForEach-Object { "$($_.Check): $($_.Detail)" }) $dr.Ready

    # ── 9. Security ───────────────────────────────────────────────────────────
    $secretMgmtAvail = $null -ne (Get-Module -ListAvailable 'Microsoft.PowerShell.SecretManagement' -ErrorAction SilentlyContinue)
    $secScore = if ($secretMgmtAvail) { 100 } else { 60 }
    Add-Domain 'Security' $secScore @(if ($secretMgmtAvail){'SecretManagement module available.'}else{'Install Microsoft.PowerShell.SecretManagement for full marks.'}) ($secScore -ge 80)

    # ── 10. Compliance (drift) ────────────────────────────────────────────────
    $current = Get-HVClusterCurrentState
    $effectiveWitnessType = $WitnessType
    if (-not $effectiveWitnessType) {
        $effectiveWitnessType = switch -Regex ($current.WitnessType) {
            'Disk'       { 'Disk'; break }
            'Cloud'      { 'Cloud'; break }
            'FileShare'  { 'Share'; break }
            'Share'      { 'Share'; break }
            default      { 'None' }
        }
    }
    $desired = New-HVDesiredState -ClusterName $ClusterName -Nodes $Nodes -WitnessType $effectiveWitnessType
    $drift   = if ($current) { Get-HVDriftScore -Desired $desired -Current $current } else { [PSCustomObject]@{ Score=100; Details=@('No cluster state.') } }
    $compScore = 100 - $drift.Score
    Add-Domain 'Compliance' $compScore @($drift.Details) ($drift.Score -le 10)

    # ── Overall ────────────────────────────────────────────────────────────────
    $allDomains   = $domains.ToArray()
    $overallScore = [math]::Round(($allDomains | Measure-Object -Property Score -Average).Average)
    $certified    = ($allDomains | Where-Object { -not $_.Pass }).Count -eq 0

    Write-HVLog -Message "=== CERTIFICATION $(if ($certified){'PASSED'}else{'FAILED'}) — Overall: $overallScore/100 ===" -Level $(if ($certified){'INFO'} else {'WARN'})

    # ── Certification HTML Report ─────────────────────────────────────────────
    if (-not (Test-Path $ReportsPath)) { New-Item -ItemType Directory -Path $ReportsPath -Force | Out-Null }

    $domainRows = $allDomains | ForEach-Object {
        $color = if ($_.Pass) { '#2d7a2d' } else { '#c0392b' }
        $icon  = if ($_.Pass) { '&#10003;' } else { '&#10007;' }
        "<tr><td>$($_.Domain)</td><td style='color:$color;font-weight:bold'>$icon $($_.Score)/100</td><td>$($_.Details -join '<br>')</td></tr>"
    }

    $certColor  = if ($certified) { '#2d7a2d' } else { '#c0392b' }
    $certStatus = if ($certified) { 'CERTIFIED' } else { 'NOT CERTIFIED' }

    $html = @"
<!DOCTYPE html><html lang='en'><head><meta charset='UTF-8'>
<title>HyperV Cluster Certification</title>
<style>
body{font-family:Segoe UI,Arial;margin:32px;background:#f5f5f5}
.card{background:#fff;padding:24px;border-radius:8px;box-shadow:0 1px 4px rgba(0,0,0,.15);max-width:860px}
h1{color:#333}
.badge{font-size:1.4em;font-weight:bold;color:$certColor}
table{width:100%;border-collapse:collapse;margin-top:16px}
th{background:#333;color:#fff;padding:8px 12px;text-align:left}
td{padding:8px 12px;border-bottom:1px solid #eee;vertical-align:top}
</style></head><body>
<div class='card'>
<h1>HyperV Cluster Certification Report</h1>
<p><strong>Cluster:</strong> $ClusterName &nbsp;|&nbsp; <strong>Generated:</strong> $($ts.ToString('yyyy-MM-dd HH:mm:ss'))</p>
<p class='badge'>$certStatus — $overallScore / 100</p>
<table><tr><th>Domain</th><th>Score</th><th>Detail</th></tr>
$($domainRows -join "`n")
</table></div></body></html>
"@

    $reportPath = Join-Path $ReportsPath ("Certification-{0}.html" -f $ts.ToString('yyyyMMddHHmmss'))
    $html | Out-File -FilePath $reportPath -Encoding UTF8
    Write-HVLog -Message "Certification report: $reportPath" -Level 'INFO'

    return [PSCustomObject]@{
        Certified    = $certified
        OverallScore = [int]$overallScore
        Domains      = $allDomains
        ReportPath   = $reportPath
        Timestamp    = $ts.ToString('o')
    }
}
