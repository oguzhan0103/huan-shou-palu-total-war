param(
    [string]$GameRoot = "E:\SteamLibrary\steamapps\common\Palworld"
)

$ErrorActionPreference = "Stop"
$ExpectedBuildId = "24467282"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$SourceMod = Join-Path $ProjectRoot "mod0\ue4ss\PalMultiOtomo0"
$Win64Root = Join-Path $GameRoot "Pal\Binaries\Win64"
$ModsRoot = Join-Path $Win64Root "ue4ss\Mods"
$TargetMod = Join-Path $ModsRoot "PalMultiOtomo0"
$SteamManifest = "E:\SteamLibrary\steamapps\appmanifest_1623730.acf"
$EvidenceRoot = Join-Path $ProjectRoot "evidence\deployments"
$EvidencePath = Join-Path $EvidenceRoot "PalMultiOtomo0-build24467282.json"
$RelativeFiles = @(
    Get-ChildItem -LiteralPath $SourceMod -Recurse -File |
        ForEach-Object { $_.FullName.Substring($SourceMod.Length + 1) } |
        Sort-Object
)

& (Join-Path $PSScriptRoot "verify.ps1")
if (-not $?) {
    throw "Verification failed; no game files were updated."
}

$BlockingProcesses = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $_.ProcessName -in @("Palworld-Win64-Shipping", "Palworld", "UnrealEditor", "UnrealEditor-Cmd", "UAssetGUI", "FModel")
})
if ($BlockingProcesses.Count -gt 0) {
    throw "A game or asset-editing process is running. Close it before installing PalMultiOtomo0."
}
if (-not (Test-Path -LiteralPath $SteamManifest -PathType Leaf)) {
    throw "Steam manifest not found: $SteamManifest"
}
$SteamManifestText = Get-Content -LiteralPath $SteamManifest -Raw -Encoding utf8
foreach ($ManifestField in @("buildid", "TargetBuildID")) {
    if ($SteamManifestText -notmatch ('"' + $ManifestField + '"\s+"' + [regex]::Escape($ExpectedBuildId) + '"')) {
        throw "Steam $ManifestField does not match audited Build $ExpectedBuildId"
    }
}
if (-not (Test-Path -LiteralPath $ModsRoot -PathType Container)) {
    throw "UE4SS Mods folder not found: $ModsRoot"
}

$ResolvedModsRoot = [System.IO.Path]::GetFullPath($ModsRoot).TrimEnd('\') + '\'
$ResolvedTarget = [System.IO.Path]::GetFullPath($TargetMod).TrimEnd('\') + '\'
if (-not $ResolvedTarget.StartsWith($ResolvedModsRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to install outside the UE4SS Mods folder: $ResolvedTarget"
}

New-Item -ItemType Directory -Path $EvidenceRoot -Force | Out-Null
$BackupRoot = $null
if (Test-Path -LiteralPath $TargetMod -PathType Container) {
    $BackupStamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $BackupRoot = Join-Path $EvidenceRoot ("backups\" + $BackupStamp + "\PalMultiOtomo0")
    New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
    Get-ChildItem -LiteralPath $TargetMod -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $BackupRoot -Recurse -Force
    }
}

foreach ($RelativePath in $RelativeFiles) {
    $Source = Join-Path $SourceMod $RelativePath
    $Target = Join-Path $TargetMod $RelativePath
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        throw "Source file missing: $Source"
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $Target) -Force | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Target -Force
}

$InstalledFiles = foreach ($RelativePath in $RelativeFiles) {
    $Source = Join-Path $SourceMod $RelativePath
    $Target = Join-Path $TargetMod $RelativePath
    $SourceHash = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash.ToLowerInvariant()
    $TargetHash = (Get-FileHash -LiteralPath $Target -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($SourceHash -ne $TargetHash) {
        throw "Hash mismatch after copy: $Target"
    }
    [ordered]@{
        relativePath = $RelativePath
        path = $Target
        bytes = (Get-Item -LiteralPath $Target).Length
        sha256 = $TargetHash
    }
}

[ordered]@{
    schemaVersion = "1.0.0"
    releaseId = "PalMultiOtomo0-v1.0.0"
    steamBuildId = $ExpectedBuildId
    installedAt = (Get-Date).ToString("o")
    gameRoot = $GameRoot
    targetMod = $TargetMod
    backupRoot = $BackupRoot
    scope = "Independent UE4SS Lua two-Pal prototype; F6-only, no hooks, no polling, no save writes, no PAK changes."
    installedFiles = $InstalledFiles
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $EvidencePath -Encoding UTF8

& (Join-Path $PSScriptRoot "check-deployment.ps1") -GameRoot $GameRoot

Write-Host "PASS installed PalMultiOtomo0"
Write-Host "Target: $TargetMod"
Write-Host "Evidence: $EvidencePath"
$BackupDisplay = if ($null -eq $BackupRoot) { "<none-new-install>" } else { $BackupRoot }
Write-Host "Backup: $BackupDisplay"
Write-Host "No save files, PAK files, or PalFactionTerritory0 files were changed."
