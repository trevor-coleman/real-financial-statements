# Copies the mod into the Transport Fever 3 staging area.
# Usage:  .\install.ps1
#         .\install.ps1 -Target "D:\path\to\staging_area"
#
# IMPORTANT: after you publish to mod.io, the game writes _metadata\mod.io_fileid.txt into the staging
# copy. That file links the mod to its mod.io listing; without it every publish creates a NEW listing.
# This script therefore preserves it across reinstalls (and the project keeps a copy of it too).
param(
    [string]$Target = "C:\Program Files (x86)\Steam\userdata\101660563\3493540\local\staging_area"
)
$src = Join-Path $PSScriptRoot "tcoleman_financial_statements_1"
$dst = Join-Path $Target "tcoleman_financial_statements_1"
$linkFile = Join-Path $dst "_metadata\mod.io_fileid.txt"

New-Item -ItemType Directory -Force $Target | Out-Null

$savedLink = $null
if (Test-Path $linkFile) { $savedLink = [IO.File]::ReadAllBytes($linkFile) }

if (Test-Path $dst) { Remove-Item -Recurse -Force $dst }
Copy-Item -Recurse $src $dst

if ($null -ne $savedLink) {
    [IO.File]::WriteAllBytes((Join-Path $dst "_metadata\mod.io_fileid.txt"), $savedLink)
    Write-Host "Kept mod.io link: $([Text.Encoding]::ASCII.GetString($savedLink).Trim())"
}
Write-Host "Installed to $dst"
