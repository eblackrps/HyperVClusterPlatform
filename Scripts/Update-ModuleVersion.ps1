<#
.SYNOPSIS
    Bumps the ModuleVersion in HyperVClusterPlatform.psd1.
    Can increment Major, Minor, or Patch automatically, or accept an explicit version.

.PARAMETER ManifestPath
    Path to the .psd1 file. Defaults to the repo root manifest.

.PARAMETER BumpType
    Major | Minor | Patch — which segment to increment. Default: Patch.

.PARAMETER ExplicitVersion
    If specified, sets this exact version string instead of auto-bumping.

.PARAMETER DryRun
    Show what would change without writing the file.

.EXAMPLE
    .\Scripts\Update-ModuleVersion.ps1 -BumpType Minor
    .\Scripts\Update-ModuleVersion.ps1 -ExplicitVersion 21.1.0
#>
[CmdletBinding()]
param(
    [string][ValidateScript({ Test-Path $_ })]
    $ManifestPath = (Join-Path $PSScriptRoot '..\HyperVClusterPlatform.psd1'),

    [ValidateSet('Major','Minor','Patch')][string]$BumpType = 'Patch',

    [string]$ExplicitVersion,

    [switch]$DryRun
)

function Write-HVUtf8BomContent {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content
    )

    $encoding = [System.Text.UTF8Encoding]::new($true)
    [System.IO.File]::WriteAllText((Resolve-Path $Path), $Content, $encoding)
}

$content = Get-Content -Path $ManifestPath -Raw

if ($content -notmatch "ModuleVersion\s*=\s*'([^']+)'") {
    throw "Could not find ModuleVersion in '$ManifestPath'."
}

$currentStr = $Matches[1]
$current    = [Version]$currentStr

if ($ExplicitVersion) {
    $newVersion = [Version]$ExplicitVersion
}
else {
    $newVersion = switch ($BumpType) {
        'Major' { [Version]::new($current.Major + 1, 0, 0) }
        'Minor' { [Version]::new($current.Major, $current.Minor + 1, 0) }
        'Patch' { [Version]::new($current.Major, $current.Minor, [math]::Max($current.Build,0) + 1) }
    }
}

if ($newVersion -lt $current) {
    throw "Refusing to decrease module version from $currentStr to $newVersion."
}

if ($newVersion -eq $current -and -not $DryRun) {
    throw "ModuleVersion is already $currentStr. Specify a newer version or use a bump type that advances the manifest."
}

$newContent = $content -replace "ModuleVersion\s*=\s*'[^']+'", "ModuleVersion     = '$newVersion'"

if ($DryRun) {
    Write-Host "DRY RUN: $currentStr -> $newVersion" -ForegroundColor Cyan
}
else {
    Write-HVUtf8BomContent -Path $ManifestPath -Content $newContent
    Write-Host "Version bumped: $currentStr -> $newVersion" -ForegroundColor Green
}

return $newVersion.ToString()
