<#
.SYNOPSIS
    Creates a GitHub release by extracting release notes from CHANGELOG.md,
    bumping the module version, committing, tagging, pushing, and publishing via gh CLI.

.PARAMETER Version
    Explicit version string (e.g. '21.1.0'). If omitted, uses current manifest version.

.PARAMETER BumpType
    Major | Minor | Patch — auto-bumps if -Version not specified.

.PARAMETER DryRun
    Simulate all steps without writing files, committing, or pushing.

.EXAMPLE
    .\Scripts\New-Release.ps1 -Version 21.1.0
    .\Scripts\New-Release.ps1 -BumpType Minor -DryRun
#>
[CmdletBinding()]
param(
    [string]$Version,
    [ValidateSet('Major','Minor','Patch')][string]$BumpType = 'Patch',
    [switch]$DryRun,
    [switch]$SkipValidation
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

function Invoke-Git {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $output = & git @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
    }

    return @($output)
}

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $output = & $FilePath @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "$FilePath $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
    }

    return @($output)
}

function New-HVReleasePackage {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$Version
    )

    $distRoot = Join-Path $RepositoryRoot 'dist'
    $packageRoot = Join-Path $distRoot 'HyperVClusterPlatform'
    $zipPath = Join-Path $distRoot ("HyperVClusterPlatform-{0}.zip" -f $Version)

    if (Test-Path $distRoot -and $PSCmdlet.ShouldProcess($distRoot, 'Remove existing dist directory')) {
        Remove-Item -LiteralPath $distRoot -Recurse -Force
    }
    if ($PSCmdlet.ShouldProcess($packageRoot, 'Create release package workspace')) {
        New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null
    }

    if ($PSCmdlet.ShouldProcess($packageRoot, 'Copy release package contents')) {
        Get-ChildItem -Path $RepositoryRoot -Force |
            Where-Object { $_.Name -notin @('.git', '.github', 'Logs', 'Reports', 'dist') } |
            Copy-Item -Destination $packageRoot -Recurse -Force
    }

    if (Test-Path $zipPath -and $PSCmdlet.ShouldProcess($zipPath, 'Remove existing release package archive')) {
        Remove-Item -LiteralPath $zipPath -Force
    }

    if ($PSCmdlet.ShouldProcess($zipPath, 'Create release package archive')) {
        Compress-Archive -Path (Join-Path $packageRoot '*') -DestinationPath $zipPath -CompressionLevel Optimal
    }
    return $zipPath
}

function Test-HVReleaseReadiness {
    param([Parameter(Mandatory)][string]$RepositoryRoot)

    $manifestPath = Join-Path $RepositoryRoot 'HyperVClusterPlatform.psd1'
    Test-ModuleManifest -Path $manifestPath -ErrorAction Stop | Out-Null
    Import-Module $manifestPath -Force -ErrorAction Stop

    $pester = Invoke-Pester -Path (Join-Path $RepositoryRoot 'Tests') -PassThru -Output Detailed
    if ($pester.FailedCount -gt 0) {
        throw "Pester reported $($pester.FailedCount) failed test(s)."
    }
}

Push-Location $root
try {
    $currentBranch = (Invoke-Git -Arguments @('rev-parse','--abbrev-ref','HEAD') | Select-Object -First 1).Trim()
    if ($currentBranch -eq 'HEAD') {
        throw 'Release creation requires a checked-out branch, not a detached HEAD.'
    }

    if (-not $DryRun) {
        $gitStatus = Invoke-Git -Arguments @('status','--porcelain')
        if ($gitStatus.Count -gt 0) {
            throw "Release creation requires a clean working tree. Commit or stash changes before running this script.`n$($gitStatus -join [Environment]::NewLine)"
        }
    }

    # ── 1. Bump version ───────────────────────────────────────────────────────
    $manifestPath = Join-Path $root 'HyperVClusterPlatform.psd1'
    $bumpParams = @{ ManifestPath = $manifestPath; DryRun = $DryRun }
    if ($Version) { $bumpParams['ExplicitVersion'] = $Version }
    else          { $bumpParams['BumpType']        = $BumpType }

    $newVersion = & (Join-Path $PSScriptRoot 'Update-ModuleVersion.ps1') @bumpParams
    $tag        = "v$newVersion"
    Write-Host "Target version: $newVersion" -ForegroundColor Cyan

    # ── 2. Extract release notes from CHANGELOG.md ───────────────────────────
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
        Write-Warning "No CHANGELOG section found for [$newVersion] - using generic notes."
    }

    $packagePath = $null
    if (-not $DryRun) {
        $packagePath = New-HVReleasePackage -RepositoryRoot $root -Version $newVersion
        Write-Host "Release package created: $packagePath" -ForegroundColor Cyan
    }

    if (-not $DryRun -and -not $SkipValidation) {
        Write-Host 'Running release validation (manifest + Pester)...' -ForegroundColor Cyan
        Test-HVReleaseReadiness -RepositoryRoot $root
    }

    # ── 3. Stage, commit, push ────────────────────────────────────────────────
    if ($DryRun) {
        Write-Host "DRY RUN: would commit + push + tag $tag" -ForegroundColor Cyan
    }
    else {
        if ((Invoke-Git -Arguments @('tag','--list',$tag) | Measure-Object).Count -gt 0) {
            throw "Tag '$tag' already exists."
        }

        Invoke-Git -Arguments @('add','--',$manifestPath) | Out-Null
        Invoke-Git -Arguments @('commit','-m',"chore: release $newVersion") | Out-Null
        Invoke-Git -Arguments @('push','origin',$currentBranch) | Out-Null
        Invoke-Git -Arguments @('tag','-a',$tag,'-m',"Release $newVersion") | Out-Null
        Invoke-Git -Arguments @('push','origin',$tag) | Out-Null
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
            $ghArgs = @(
                'release', 'create', $tag,
                '--title', "$tag - HyperVClusterPlatform",
                '--notes', $notes,
                '--latest'
            )
            if ($packagePath) {
                $ghArgs += $packagePath
            }
            Invoke-NativeCommand -FilePath $ghExe -Arguments $ghArgs | Out-Null
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
