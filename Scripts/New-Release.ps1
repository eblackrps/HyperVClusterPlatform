<#
.SYNOPSIS
    Creates a GitHub release by extracting release notes from CHANGELOG.md,
    bumping the module version, committing, tagging, pushing, and publishing via gh CLI.

.PARAMETER Version
    Explicit version string (e.g. '21.0.0'). If omitted, uses current manifest version.

.PARAMETER BumpType
    Major | Minor | Patch — auto-bumps if -Version not specified.

.PARAMETER DryRun
    Simulate all steps without writing files, committing, or pushing.

.EXAMPLE
    .\Scripts\New-Release.ps1 -Version 21.0.0
    .\Scripts\New-Release.ps1 -BumpType Minor -DryRun
#>
[CmdletBinding()]
param(
    [string]$Version,
    [ValidateSet('Major','Minor','Patch')][string]$BumpType = 'Patch',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot '..'

# ── 1. Bump version ───────────────────────────────────────────────────────────
$bumpParams = @{ ManifestPath = (Join-Path $root 'HyperVClusterPlatform.psd1'); DryRun = $DryRun }
if ($Version) { $bumpParams['ExplicitVersion'] = $Version }
else          { $bumpParams['BumpType']        = $BumpType }

$newVersion = & (Join-Path $PSScriptRoot 'Update-ModuleVersion.ps1') @bumpParams
$tag        = "v$newVersion"
Write-Host "Target version: $newVersion" -ForegroundColor Cyan

# ── 2. Extract release notes from CHANGELOG.md ───────────────────────────────
$changelog = Join-Path $root 'CHANGELOG.md'
$notes     = ''
if (Test-Path $changelog) {
    $lines      = Get-Content $changelog
    $inSection  = $false
    $noteLines  = [System.Collections.Generic.List[string]]::new()

    foreach ($line in $lines) {
        if ($line -match "^## \[$newVersion\]") {
            $inSection = $true
            continue
        }
        if ($inSection -and $line -match '^## \[') {
            break
        }
        if ($inSection) {
            $noteLines.Add($line)
        }
    }
    $notes = $noteLines -join "`n"
}

if (-not $notes) {
    $notes = "Release $newVersion of HyperVClusterPlatform."
    Write-Warning "No CHANGELOG section found for [$newVersion] — using generic notes."
}

# ── 3. Stage, commit, push ────────────────────────────────────────────────────
Push-Location $root
try {
    if ($DryRun) {
        Write-Host "DRY RUN: would commit + push + tag $tag" -ForegroundColor Cyan
    }
    else {
        & git add -A
        & git commit -m "chore: release $newVersion"
        & git push origin main
        & git tag -a $tag -m "Release $newVersion"
        & git push origin $tag
        Write-Host "Committed, tagged, and pushed $tag." -ForegroundColor Green
    }

    # ── 4. Create GitHub release via gh CLI ──────────────────────────────────
    $ghExe = (Get-Command gh -ErrorAction SilentlyContinue)?.Source
    if (-not $ghExe) {
        $ghExe = 'C:\Program Files\GitHub CLI\gh.exe'
    }

    if (Test-Path $ghExe) {
        if ($DryRun) {
            Write-Host "DRY RUN: would create GitHub release $tag" -ForegroundColor Cyan
        }
        else {
            & $ghExe release create $tag --title "$tag — HyperVClusterPlatform" --notes $notes --latest
            Write-Host "GitHub release created: $tag" -ForegroundColor Green
        }
    }
    else {
        Write-Warning "gh CLI not found. Create GitHub release manually for tag $tag."
    }
}
finally {
    Pop-Location
}

return $newVersion
