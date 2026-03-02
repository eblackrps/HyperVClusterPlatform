\
# HyperVClusterPlatform.psm1
# Loader that dot-sources Private + Public functions

$ErrorActionPreference = 'Stop'

# Dot-source Private functions
Get-ChildItem -Path (Join-Path $PSScriptRoot 'Private') -Filter '*.ps1' | ForEach-Object {
    . $_.FullName
}

# Dot-source Public functions
Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1' | ForEach-Object {
    . $_.FullName
}

# Export ONLY public functions
$publicFunctions = Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1' |
    ForEach-Object { $_.BaseName }

Export-ModuleMember -Function $publicFunctions
