[CmdletBinding()]
param(
    [string]$GameRoot = "E:\SteamLibrary\steamapps\common\Palworld",
    [string]$OutputRoot
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $Parent = Join-Path $ProjectRoot "outputs\faction-consequence-live-test"
    $Latest = Get-ChildItem -LiteralPath $Parent -Directory -ErrorAction Stop |
        Sort-Object Name -Descending |
        Select-Object -First 1
    if ($null -eq $Latest) {
        throw "No faction-consequence live-test output exists"
    }
    $OutputRoot = $Latest.FullName
}
$ManifestPath = Join-Path $OutputRoot "staging-manifest.json"
if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
    throw "Consequence staging manifest is missing: $ManifestPath"
}
$Manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding utf8 |
    ConvertFrom-Json

$Blocking = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $_.ProcessName -in @("Palworld", "Palworld-Win64-Shipping")
})
if ($Blocking.Count -gt 0) {
    throw "Palworld is active; consequence baseline restore refused"
}

$TargetMod = Join-Path $GameRoot `
    "Pal\Binaries\Win64\ue4ss\Mods\PalFactionTerritory0"
$ExpectedState = [System.IO.Path]::GetFullPath(
    (Join-Path $TargetMod "State")
).TrimEnd('\')
$ExpectedConfig = [System.IO.Path]::GetFullPath(
    (Join-Path $TargetMod "Scripts\pwft\config.lua")
)
$StateTarget = [System.IO.Path]::GetFullPath(
    [string]$Manifest.stateTarget
).TrimEnd('\')
$SaveTarget = [System.IO.Path]::GetFullPath(
    [string]$Manifest.saveTarget
).TrimEnd('\')
$TargetConfig = [System.IO.Path]::GetFullPath(
    [string]$Manifest.targetConfig
)
if ($StateTarget -ne $ExpectedState -or $TargetConfig -ne $ExpectedConfig) {
    throw "Consequence restore target does not match the intended Mod"
}
$ExpectedSaveRoot = [System.IO.Path]::GetFullPath(
    (Join-Path ([Environment]::GetFolderPath("LocalApplicationData")) `
        "Pal\Saved\SaveGames")
).TrimEnd('\')
if ([System.IO.Path]::GetDirectoryName($SaveTarget).TrimEnd('\') `
    -ne $ExpectedSaveRoot -or
    [System.IO.Path]::GetFileName($SaveTarget) -notmatch '^\d{17}$') {
    throw "Consequence restore save target is unexpected: $SaveTarget"
}

$SaveSnapshot = Join-Path ([string]$Manifest.snapshotRoot) "SaveGames"
$StateSnapshot = Join-Path ([string]$Manifest.snapshotRoot) "ModState"
foreach ($Path in @(
    $SaveTarget,
    $StateTarget,
    $SaveSnapshot,
    $StateSnapshot,
    [string]$Manifest.installedConfigBefore
)) {
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Consequence restore input is missing: $Path"
    }
}

Get-ChildItem -LiteralPath $SaveTarget -Force | Remove-Item -Recurse -Force
Get-ChildItem -LiteralPath $SaveSnapshot -Force | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $SaveTarget -Recurse -Force
}
Get-ChildItem -LiteralPath $StateTarget -Force | Remove-Item -Recurse -Force
Get-ChildItem -LiteralPath $StateSnapshot -Force | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $StateTarget -Recurse -Force
}
Copy-Item -LiteralPath ([string]$Manifest.installedConfigBefore) `
    -Destination $TargetConfig -Force

Write-Host "PASS restored faction-consequence SaveGames, Mod State, and config baseline"
Write-Host "Restored from: $OutputRoot"
