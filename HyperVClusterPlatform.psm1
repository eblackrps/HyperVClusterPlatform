# HyperVClusterPlatform.psm1
# Loader that dot-sources Private + Public functions

$ErrorActionPreference = 'Stop'

# Dot-source Private functions
Get-ChildItem -Path (Join-Path $PSScriptRoot 'Private') -Filter '*.ps1' |
    Sort-Object Name |
    ForEach-Object {
    . $_.FullName
}

# Dot-source Public functions
Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1' |
    Sort-Object Name |
    ForEach-Object {
    . $_.FullName
}

if (Get-Command Initialize-HVCommandAliases -ErrorAction SilentlyContinue) {
    Initialize-HVCommandAliases
}

# Export supported entry points plus selected operational commands documented for users
$publicFunctions = Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1' |
    ForEach-Object { $_.BaseName }
$documentedOperationalFunctions = @(
    'Get-HVClusterHealth'
    'Invoke-HVHealthAlertPolicy'
    'Invoke-HVCertificationSuite'
)

Export-ModuleMember -Function ($publicFunctions + $documentedOperationalFunctions | Sort-Object -Unique)
