param(
    [string]$GameRoot = "E:\SteamLibrary\steamapps\common\Palworld"
)

$ErrorActionPreference = "Stop"
$ExpectedBuildId = "24575825"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$SourceMod = Join-Path $ProjectRoot "mod0\ue4ss\PalFactionTerritory0"
$Win64Root = Join-Path $GameRoot "Pal\Binaries\Win64"
$TargetMod = Join-Path $Win64Root "ue4ss\Mods\PalFactionTerritory0"
$SteamManifest = "E:\SteamLibrary\steamapps\appmanifest_1623730.acf"
$EvidenceRoot = Join-Path $ProjectRoot "evidence\deployments"
$EvidencePath = Join-Path $EvidenceRoot "mod0-dev-build24575825.json"
$RelativeFiles = @(
    Get-ChildItem -LiteralPath $SourceMod -Recurse -File |
        ForEach-Object { $_.FullName.Substring($SourceMod.Length + 1) } |
        Sort-Object
)

try {
    & (Join-Path $PSScriptRoot "verify-mod0.ps1")
}
catch {
    throw "Mod 0 verification failed; no game files were updated. $($_.Exception.Message)"
}
$BlockingProcesses = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $_.ProcessName -in @("Palworld-Win64-Shipping", "Palworld", "UnrealEditor", "UnrealEditor-Cmd", "UAssetGUI", "FModel")
})
if ($BlockingProcesses.Count -gt 0) {
    throw "A game or asset-editing process is running. Close it before updating UE4SS scripts."
}
if (-not (Test-Path -LiteralPath $SteamManifest -PathType Leaf)) {
    throw "Steam manifest not found: $SteamManifest"
}
$SteamManifestText = Get-Content -LiteralPath $SteamManifest -Raw -Encoding utf8
foreach ($ManifestField in @("buildid", "TargetBuildID")) {
    if ($SteamManifestText -notmatch ('"' + $ManifestField + '"\s+"' + [regex]::Escape($ExpectedBuildId) + '"')) {
        throw "Steam $ManifestField does not match audited Build $ExpectedBuildId; no game files were updated."
    }
}
if (-not (Test-Path -LiteralPath $TargetMod)) {
    throw "Installed Mod 0 folder not found: $TargetMod"
}

foreach ($RelativeFile in $RelativeFiles) {
    $Source = Join-Path $SourceMod $RelativeFile
    $Target = Join-Path $TargetMod $RelativeFile
    if (-not (Test-Path -LiteralPath $Source)) { throw "Source file missing: $Source" }
}
$BackupStamp = Get-Date -Format "yyyyMMdd-HHmmss"
$BackupRoot = Join-Path $EvidenceRoot ("mod0-runtime-script-backups\" + $BackupStamp)
foreach ($RelativeFile in $RelativeFiles) {
    $Source = Join-Path $TargetMod $RelativeFile
    $Backup = Join-Path $BackupRoot $RelativeFile
    if (Test-Path -LiteralPath $Source) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $Backup) -Force | Out-Null
        Copy-Item -LiteralPath $Source -Destination $Backup
    }
}
if (Test-Path -LiteralPath $EvidencePath) {
    Copy-Item -LiteralPath $EvidencePath -Destination (Join-Path $BackupRoot "previous-deployment-evidence.json")
}

$BackupFiles = foreach ($RelativeFile in $RelativeFiles) {
    $Backup = Join-Path $BackupRoot $RelativeFile
    if (Test-Path -LiteralPath $Backup) {
        [ordered]@{
            relativePath = $RelativeFile
            path = $Backup
            sha256 = (Get-FileHash -LiteralPath $Backup -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
}
[ordered]@{
    createdAt = (Get-Date).ToString("o")
    reason = "Deploy Build 24575825 mechanism base with in-Mod Agent bridge, local Ollama operator loop, reciprocal combat-defender targeting, and the previously accepted commerce and siege runtimes."
    targetMod = $TargetMod
    backupFiles = $BackupFiles
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $BackupRoot "backup-manifest.json") -Encoding UTF8

foreach ($RelativeFile in $RelativeFiles) {
    $Target = Join-Path $TargetMod $RelativeFile
    New-Item -ItemType Directory -Path (Split-Path -Parent $Target) -Force |
        Out-Null
    Copy-Item -LiteralPath (Join-Path $SourceMod $RelativeFile) -Destination $Target -Force
}

$InstalledFiles = foreach ($RelativeFile in $RelativeFiles) {
    $Source = Join-Path $SourceMod $RelativeFile
    $Target = Join-Path $TargetMod $RelativeFile
    $SourceHash = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash.ToLowerInvariant()
    $TargetHash = (Get-FileHash -LiteralPath $Target -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($SourceHash -ne $TargetHash) {
        throw "Hash mismatch after copy: $Target"
    }
    [ordered]@{
        path = $Target
        bytes = (Get-Item -LiteralPath $Target).Length
        sha256 = $TargetHash
        relativePath = $RelativeFile
    }
}

[ordered]@{
    schemaVersion = "1.1.0"
    releaseId = "PalFactionTerritory0-mod0"
    steamBuildId = $ExpectedBuildId
    mode = "faction-territory-with-identity-keyed-external-ledger-commerce-services-small-settlement-raid-world-balance-fail-closed"
    installedAt = (Get-Date).ToString("o")
    gameRoot = $GameRoot
    scope = "UE4SS faction territory mechanism base plus the local Ollama dialogue bridge/operator and Small Settlement raid routes; external Agent output remains presentation-only and player-confirmed; no Palworld save, PAK, or original game content changed."
    previousEvidenceBackup = $BackupRoot
    installedFiles = $InstalledFiles
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $EvidencePath -Encoding UTF8

& (Join-Path $PSScriptRoot "check-mod0-deployment.ps1") -GameRoot $GameRoot

Write-Host "PASS updated $($RelativeFiles.Count) Mod 0 runtime files"
Write-Host "Backup: $BackupRoot"
Write-Host "Deployment evidence: $EvidencePath"
Write-Host "No Palworld save files, PAK files, or original game-content files were changed."
