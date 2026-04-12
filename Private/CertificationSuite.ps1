function Test-HVConfigUsesSecretReferences {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)

    $sensitiveProperties = @($Config.PSObject.Properties | Where-Object {
        $_.Name -match '(?i)(key|password|token|credential)' -and
        $_.Name -notlike '*SecretName'
    })
    $secretReferenceProperties = @($Config.PSObject.Properties | Where-Object { $_.Name -like '*SecretName' })

    $cleartextSensitive = @(
        $sensitiveProperties |
            Where-Object {
                $null -ne $_.Value -and
                (-not ($_.Value -is [string]) -or -not [string]::IsNullOrWhiteSpace($_.Value))
            }
    )

    return [PSCustomObject]@{
        UsesSecretReferences = ($secretReferenceProperties.Count -gt 0)
        CleartextSensitive   = $cleartextSensitive.Name
    }
}

function Invoke-HVCertificationSuite {
    <#
    .SYNOPSIS
        Runs a production-readiness certification against a deployed cluster.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ClusterName,
        [Parameter(Mandatory)][string[]]$Nodes,
        [ValidateSet('None','Disk','Cloud','Share')][string]$WitnessType = '',
        [string]$WitnessDiskName = '',
        [string]$FileShareWitnessPath = '',
        [hashtable]$DesiredNetworkRoleMap = @{},
        [int]$DesiredCSVCount = 0,
        [double]$DesiredMinTotalGB = 0,
        [hashtable]$DesiredPreferredOwners = @{},
        [hashtable]$DesiredAntiAffinityGroups = @{},
        [string]$ConfigFile = '',
        [switch]$RequireSecretBackedConfig,
        [string]$ReportsPath = '.\Reports',
        [switch]$SkipLiveMigrationTest
    )

    Write-HVLog -Message '=== CERTIFICATION SUITE STARTING ===' -Level 'INFO'
    Write-HVLog -Message "Cluster: $ClusterName Nodes: [$($Nodes -join ',')]" -Level 'INFO'

    $domains = [System.Collections.Generic.List[object]]::new()
    $ts = Get-Date

    function Add-Domain {
        param([string]$Name, [int]$Score, [string[]]$Details, [bool]$Pass)
        $domains.Add([PSCustomObject]@{
            Domain  = $Name
            Score   = [int]$Score
            Pass    = $Pass
            Details = $Details
        })
        Write-HVLog -Message "[$(if ($Pass) { 'PASS' } else { 'FAIL' })] $Name - $Score/100" -Level $(if ($Pass) { 'INFO' } else { 'WARN' })
    }

    $cluster = Get-Cluster -ErrorAction SilentlyContinue
    if (-not $cluster -or $cluster.Name -ne $ClusterName) {
        Add-Domain 'ClusterCore' 0 @("Cluster '$ClusterName' not found or name mismatch.") $false
    }
    else {
        $currentNodes = @(Get-ClusterNode -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
        $diff = Compare-Object ($Nodes | Sort-Object) ($currentNodes | Sort-Object) -ErrorAction SilentlyContinue
        if ($diff) {
            Add-Domain 'ClusterCore' 50 @('Node membership mismatch.') $false
        }
        else {
            Add-Domain 'ClusterCore' 100 @("Cluster '$ClusterName' has expected node membership.") $true
        }
    }

    $currentState = Get-HVClusterCurrentState
    $effectiveWitnessType = if ($WitnessType) { $WitnessType } elseif ($currentState) { ConvertTo-HVWitnessType -QuorumType $currentState.WitnessType } else { 'None' }
    $desired = Get-HVDesiredState -ClusterName $ClusterName -Nodes $Nodes -WitnessType $effectiveWitnessType `
        -WitnessDiskName $WitnessDiskName -FileShareWitnessPath $FileShareWitnessPath
    $drift = if ($currentState) { Get-HVDriftScore -Desired $desired -Current $currentState } else { [PSCustomObject]@{ Score = 100; Details = @('No cluster state.') } }
    $quorumIssues = @($drift.Details | Where-Object { $_ -match '^Witness' })
    $quorumScore = if ($quorumIssues.Count -eq 0) { 100 } else { 50 }
    $quorumDetails = if ($quorumIssues.Count -eq 0) { @('Witness configuration matches desired state.') } else { @($quorumIssues) }
    Add-Domain 'Quorum' $quorumScore $quorumDetails ($quorumIssues.Count -eq 0)

    $health = Get-HVClusterHealth
    $allUp = @($health.Nodes | Where-Object { -not $_.Healthy }).Count -eq 0
    Add-Domain 'NodeHealth' $health.Score @($health.Details) $allUp

    if ($DesiredNetworkRoleMap.Count -gt 0) {
        $networkDrift = Get-HVNetworkDrift -DesiredRoleMap $DesiredNetworkRoleMap
        Add-Domain 'Network' (100 - $networkDrift.Score) @($networkDrift.Details) ($networkDrift.Score -eq 0)
    }
    else {
        $networks = @(Get-ClusterNetwork -ErrorAction SilentlyContinue)
        $networkDetails = if ($networks.Count -eq 0) { @('No cluster networks found.') } else { @('No desired network role policy provided for certification.') }
        $networkScore = if ($networks.Count -eq 0) { 0 } else { 60 }
        Add-Domain 'Network' $networkScore $networkDetails $false
    }

    if ($DesiredCSVCount -gt 0 -or $DesiredMinTotalGB -gt 0) {
        $storage = Get-HVStorageDrift -DesiredCSVCount $DesiredCSVCount -DesiredMinTotalGB $DesiredMinTotalGB
        Add-Domain 'Storage' (100 - $storage.Score) @($storage.Details) ($storage.Score -eq 0)
    }
    else {
        $csvs = @(Get-HVCSVState)
        $storageDetails = if ($csvs.Count -eq 0) { @('No Cluster Shared Volumes found.') } else { @('No storage capacity/count policy provided for certification.') }
        $storageScore = if ($csvs.Count -eq 0) { 0 } else { 60 }
        Add-Domain 'Storage' $storageScore $storageDetails $false
    }

    $placement = Get-HVVMPlacementState
    $vmCount = @($placement.VMs).Count
    if ($vmCount -eq 0) {
        Add-Domain 'VMPlacement' 100 @('No clustered VMs require placement policy.') $true
    }
    elseif ($DesiredPreferredOwners.Count -gt 0 -or $DesiredAntiAffinityGroups.Count -gt 0) {
        $placementDrift = Get-HVVMPlacementDrift -DesiredPreferredOwners $DesiredPreferredOwners -DesiredAntiAffinityGroups $DesiredAntiAffinityGroups
        Add-Domain 'VMPlacement' (100 - $placementDrift.Score) @($placementDrift.Details) ($placementDrift.Score -eq 0)
    }
    else {
        Add-Domain 'VMPlacement' 60 @('Clustered VMs exist, but no placement policy was provided for certification.') $false
    }

    if (-not $SkipLiveMigrationTest) {
        $lmReady = Get-HVMigrationReadiness -Nodes $Nodes
        $notReady = @($lmReady | Where-Object { -not $_.Ready })
        $lmScore = [math]::Round((($lmReady.Count - $notReady.Count) / [math]::Max($lmReady.Count, 1)) * 100)
        Add-Domain 'LiveMigration' $lmScore @($notReady | ForEach-Object { "$($_.NodeName): $($_.Issues -join '; ')" }) ($notReady.Count -eq 0)
    }
    else {
        Add-Domain 'LiveMigration' 100 @('Skipped (-SkipLiveMigrationTest).') $true
    }

    $dr = Test-HVDRReadiness
    Add-Domain 'DRReadiness' $dr.Score @($dr.Checks | ForEach-Object { "$($_.Check): $($_.Detail)" }) $dr.Ready

    $secretMgmtAvailable = $null -ne (Get-Module -ListAvailable 'Microsoft.PowerShell.SecretManagement' -ErrorAction SilentlyContinue)
    if ($ConfigFile) {
        $cfg = Import-HVClusterConfig -ConfigPath $ConfigFile
        $configSecrets = Test-HVConfigUsesSecretReferences -Config $cfg
        if ($configSecrets.CleartextSensitive.Count -gt 0) {
            Add-Domain 'Security' 0 @("Sensitive config values are stored in cleartext: $($configSecrets.CleartextSensitive -join ', ')") $false
        }
        elseif ($RequireSecretBackedConfig -and -not $configSecrets.UsesSecretReferences) {
            Add-Domain 'Security' 50 @('Secret-backed config was required, but no SecretName references were found.') $false
        }
        elseif (-not $secretMgmtAvailable) {
            Add-Domain 'Security' 60 @('Microsoft.PowerShell.SecretManagement is not installed.') $false
        }
        else {
            Add-Domain 'Security' 100 @('Config uses secret references and SecretManagement is available.') $true
        }
    }
    else {
        $securityScore = if ($secretMgmtAvailable) { 60 } else { 40 }
        Add-Domain 'Security' $securityScore @('No config file was provided, so certification cannot verify secret-backed configuration.') $false
    }

    $compScore = 100 - $drift.Score
    Add-Domain 'Compliance' $compScore @($drift.Details) ($drift.Score -le 10)

    $allDomains = $domains.ToArray()
    $overallScore = [math]::Round(($allDomains | Measure-Object -Property Score -Average).Average)
    $certified = ($allDomains | Where-Object { -not $_.Pass }).Count -eq 0

    Write-HVLog -Message "=== CERTIFICATION $(if ($certified) { 'PASSED' } else { 'FAILED' }) - Overall: $overallScore/100 ===" -Level $(if ($certified) { 'INFO' } else { 'WARN' })

    if (-not (Test-Path $ReportsPath)) { New-Item -ItemType Directory -Path $ReportsPath -Force | Out-Null }

    $encode = [System.Net.WebUtility]
    $domainRows = $allDomains | ForEach-Object {
        $color = if ($_.Pass) { '#2d7a2d' } else { '#c0392b' }
        $icon = if ($_.Pass) { '&#10003;' } else { '&#10007;' }
        $detailHtml = (@($_.Details) | ForEach-Object { $encode::HtmlEncode([string]$_) }) -join '<br>'
        "<tr><td>$($encode::HtmlEncode($_.Domain))</td><td style='color:$color;font-weight:bold'>$icon $($_.Score)/100</td><td>$detailHtml</td></tr>"
    }

    $certColor = if ($certified) { '#2d7a2d' } else { '#c0392b' }
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
<p><strong>Cluster:</strong> $($encode::HtmlEncode($ClusterName)) &nbsp;|&nbsp; <strong>Generated:</strong> $($ts.ToString('yyyy-MM-dd HH:mm:ss'))</p>
<p class='badge'>$certStatus - $overallScore / 100</p>
<table><tr><th>Domain</th><th>Score</th><th>Detail</th></tr>
$($domainRows -join "`n")
</table></div></body></html>
"@

    $reportPath = Get-HVArtifactPath -Directory $ReportsPath -Prefix 'Certification' -Extension 'html' -Identity @(
        $ClusterName
    )
    $html | Out-File -FilePath $reportPath -Encoding UTF8
    Invoke-HVArtifactRetention -Path $ReportsPath -Filter 'Certification-*.html' -MaxFiles 30
    Write-HVLog -Message "Certification report: $reportPath" -Level 'INFO'

    return [PSCustomObject]@{
        Certified    = $certified
        OverallScore = [int]$overallScore
        Domains      = $allDomains
        ReportPath   = $reportPath
        Timestamp    = $ts.ToString('o')
    }
}
