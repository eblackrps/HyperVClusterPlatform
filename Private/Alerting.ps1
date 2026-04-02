function Send-HVAlert {
    <#
    .SYNOPSIS
        Dispatches a cluster health or compliance alert via email, Teams webhook,
        Slack webhook, and/or Windows Event Log. Channel selection is driven by
        which parameters are provided.
    .PARAMETER Subject
        Alert subject / title.
    .PARAMETER Body
        Alert body text (plain text; HTML is auto-generated for email).
    .PARAMETER Severity
        Info | Warning | Critical. Controls event log entry type and visual styling.
    .PARAMETER SmtpServer
        SMTP server hostname. Required for email delivery.
    .PARAMETER EmailFrom
        Sender address.
    .PARAMETER EmailTo
        One or more recipient addresses.
    .PARAMETER TeamsWebhookUrl
        Microsoft Teams Incoming Webhook URL.
    .PARAMETER SlackWebhookUrl
        Slack Incoming Webhook URL.
    .PARAMETER WriteEventLog
        Write alert to Windows Application event log under source 'HyperVClusterPlatform'.
    .OUTPUTS
        PSCustomObject: EmailSent, TeamsSent, SlackSent, EventLogWritten, Errors (string[]).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]  $Subject,
        [Parameter(Mandatory)][string]  $Body,
        [ValidateSet('Info','Warning','Critical')][string]$Severity = 'Info',
        [string]   $SmtpServer,
        [string]   $EmailFrom,
        [string[]] $EmailTo,
        [string]   $TeamsWebhookUrl,
        [string]   $SlackWebhookUrl,
        [switch]   $WriteEventLog
    )

    $errors      = [System.Collections.Generic.List[string]]::new()
    $emailSent   = $false
    $teamsSent   = $false
    $slackSent   = $false
    $eventLogged = $false

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

    # ── Email ────────────────────────────────────────────────────────────────
    if ($SmtpServer -and $EmailFrom -and $EmailTo) {
        try {
            $color   = switch ($Severity) { 'Critical' { '#c0392b' } 'Warning' { '#b86e00' } default { '#2d7a2d' } }
            $htmlBody = @"
<html><body style='font-family:Segoe UI,Arial;'>
<h2 style='color:$color'>[$Severity] $Subject</h2>
<p><strong>Time:</strong> $timestamp</p>
<pre style='background:#f5f5f5;padding:12px;border-radius:4px'>$Body</pre>
<p style='color:#888;font-size:.8em'>HyperVClusterPlatform</p>
</body></html>
"@
            Send-MailMessage -SmtpServer $SmtpServer -From $EmailFrom -To $EmailTo `
                             -Subject "[$Severity] $Subject" -Body $htmlBody -BodyAsHtml `
                             -ErrorAction Stop
            $emailSent = $true
            Write-HVLog -Message "Alert email sent to: $($EmailTo -join ', ')" -Level 'INFO'
        }
        catch {
            $errors.Add("Email failed: $($_.Exception.Message)")
            Write-HVLog -Message "Alert email failed: $($_.Exception.Message)" -Level 'ERROR'
        }
    }

    # ── Teams ────────────────────────────────────────────────────────────────
    if ($TeamsWebhookUrl) {
        try {
            $color   = switch ($Severity) { 'Critical' { 'attention' } 'Warning' { 'warning' } default { 'good' } }
            $payload = @{
                type        = 'message'
                attachments = @(@{
                    contentType = 'application/vnd.microsoft.card.adaptive'
                    content     = @{
                        '$schema' = 'http://adaptivecards.io/schemas/adaptive-card.json'
                        type      = 'AdaptiveCard'
                        version   = '1.2'
                        body      = @(
                            @{ type = 'TextBlock'; text = "[$Severity] $Subject"; weight = 'Bolder'; color = $color }
                            @{ type = 'TextBlock'; text = $Body; wrap = $true }
                            @{ type = 'TextBlock'; text = $timestamp; isSubtle = $true; size = 'Small' }
                        )
                    }
                })
            } | ConvertTo-Json -Depth 10

            Invoke-RestMethod -Uri $TeamsWebhookUrl -Method POST -Body $payload `
                              -ContentType 'application/json' -ErrorAction Stop | Out-Null
            $teamsSent = $true
            Write-HVLog -Message "Teams alert sent." -Level 'INFO'
        }
        catch {
            $errors.Add("Teams webhook failed: $($_.Exception.Message)")
            Write-HVLog -Message "Teams alert failed: $($_.Exception.Message)" -Level 'ERROR'
        }
    }

    # ── Slack ────────────────────────────────────────────────────────────────
    if ($SlackWebhookUrl) {
        try {
            $icon    = switch ($Severity) { 'Critical' { ':red_circle:' } 'Warning' { ':warning:' } default { ':white_check_mark:' } }
            $payload = @{
                text        = "$icon *[$Severity] $Subject*"
                attachments = @(@{
                    text  = $Body
                    color = switch ($Severity) { 'Critical' { 'danger' } 'Warning' { 'warning' } default { 'good' } }
                    footer = "HyperVClusterPlatform | $timestamp"
                })
            } | ConvertTo-Json -Depth 5

            Invoke-RestMethod -Uri $SlackWebhookUrl -Method POST -Body $payload `
                              -ContentType 'application/json' -ErrorAction Stop | Out-Null
            $slackSent = $true
            Write-HVLog -Message "Slack alert sent." -Level 'INFO'
        }
        catch {
            $errors.Add("Slack webhook failed: $($_.Exception.Message)")
            Write-HVLog -Message "Slack alert failed: $($_.Exception.Message)" -Level 'ERROR'
        }
    }

    # ── Windows Event Log ────────────────────────────────────────────────────
    if ($WriteEventLog) {
        try {
            $source = 'HyperVClusterPlatform'
            $sourceExists = $false
            try {
                $sourceExists = [System.Diagnostics.EventLog]::SourceExists($source)
            }
            catch {
                Write-HVLog -Message "Could not query event log source '$source': $($_.Exception.Message)" -Level 'WARN'
            }
            if (-not $sourceExists) {
                New-EventLog -LogName Application -Source $source -ErrorAction SilentlyContinue
            }
            $entryType = switch ($Severity) { 'Critical' { 'Error' } 'Warning' { 'Warning' } default { 'Information' } }
            $eventId   = switch ($Severity) { 'Critical' { 1001 } 'Warning' { 1002 } default { 1000 } }
            Write-EventLog -LogName Application -Source $source -EntryType $entryType `
                           -EventId $eventId -Message "$Subject`n`n$Body" -ErrorAction Stop
            $eventLogged = $true
            Write-HVLog -Message "Event log entry written (EventId=$eventId)." -Level 'INFO'
        }
        catch {
            $errors.Add("Event log failed: $($_.Exception.Message)")
            Write-HVLog -Message "Event log write failed: $($_.Exception.Message)" -Level 'WARN'
        }
    }

    return [PSCustomObject]@{
        EmailSent       = $emailSent
        TeamsSent       = $teamsSent
        SlackSent       = $slackSent
        EventLogWritten = $eventLogged
        Errors          = $errors.ToArray()
    }
}

function Invoke-HVHealthAlertPolicy {
    <#
    .SYNOPSIS
        Runs a health check and fires alerts if the health score drops below threshold.
    .PARAMETER AlertThreshold
        Health score below which alerts are triggered. Default: 80.
    .PARAMETER AlertParams
        Splat hashtable passed to Send-HVAlert (SmtpServer, EmailTo, webhooks, etc.).
    .OUTPUTS
        PSCustomObject: HealthResult, AlertFired, AlertResult.
    #>
    [CmdletBinding()]
    param(
        [int]      $AlertThreshold = 80,
        [hashtable]$AlertParams    = @{}
    )

    $health     = Get-HVClusterHealth
    $alertFired = $false
    $alertResult = $null

    if ($health.Score -lt $AlertThreshold) {
        Write-HVLog -Message "Health score $($health.Score) below threshold $AlertThreshold — firing alert." -Level 'WARN'

        $severity = if ($health.Score -lt 50) { 'Critical' } else { 'Warning' }
        $body     = "Cluster: $($health.ClusterName)`nScore: $($health.Score)/100`nStatus: $($health.Overall)`n`nIssues:`n$($health.Details -join "`n")"

        $sendParams = $AlertParams + @{
            Subject  = "Cluster Health Alert: $($health.ClusterName) — $($health.Overall)"
            Body     = $body
            Severity = $severity
        }
        $alertResult = Send-HVAlert @sendParams
        $alertFired  = $true
    }
    else {
        Write-HVLog -Message "Health score $($health.Score) — no alert needed." -Level 'INFO'
    }

    return [PSCustomObject]@{
        HealthResult = $health
        AlertFired   = $alertFired
        AlertResult  = $alertResult
    }
}
