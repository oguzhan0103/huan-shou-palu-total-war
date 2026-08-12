param(
    [string]$GameRoot = "E:\SteamLibrary\steamapps\common\Palworld"
)

$ErrorActionPreference = "Stop"
$ExpectedBuildId = "24575825"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$SourcePak = Join-Path $ProjectRoot "artifacts\faction-economy-shops\PalFactionTerritory_FactionEconomyShops_P.pak"
$TargetDirectory = Join-Path $GameRoot "Pal\Content\Paks\~mods"
$TargetPak = Join-Path $TargetDirectory "PalFactionTerritory_FactionEconomyShops_P.pak"
$EvidenceRoot = Join-Path $ProjectRoot "evidence\deployments"
$EvidencePath = Join-Path $EvidenceRoot "faction-economy-shops.json"
$SteamManifest = "E:\SteamLibrary\steamapps\appmanifest_1623730.acf"

$BlockingProcesses = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $_.ProcessName -in @("Palworld-Win64-Shipping", "Palworld", "UnrealEditor", "UnrealEditor-Cmd", "UAssetGUI", "FModel")
})
if ($BlockingProcesses.Count -gt 0) {
    throw "A game or asset-editing process is running. Close it before updating the Merchant Guild economy PAK."
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

& python (Join-Path $ProjectRoot "tools\verify_faction_economy_shops.py")
if ($LASTEXITCODE -ne 0) {
    throw "Merchant Guild economy verification failed; no game files were updated."
}
if (-not (Test-Path -LiteralPath $SourcePak)) {
    throw "Source PAK not found: $SourcePak"
}

New-Item -ItemType Directory -Path $TargetDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $EvidenceRoot -Force | Out-Null

$BackupStamp = Get-Date -Format "yyyyMMdd-HHmmss"
$BackupRoot = Join-Path $EvidenceRoot ("faction-economy-shops-backups\" + $BackupStamp)
$PreviousPak = $null
if (Test-Path -LiteralPath $TargetPak) {
    New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
    $BackupPak = Join-Path $BackupRoot (Split-Path -Leaf $TargetPak)
    Copy-Item -LiteralPath $TargetPak -Destination $BackupPak
    $PreviousPak = [ordered]@{
        path = $BackupPak
        bytes = (Get-Item -LiteralPath $BackupPak).Length
        sha256 = (Get-FileHash -LiteralPath $BackupPak -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}
if (Test-Path -LiteralPath $EvidencePath) {
    New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
    Copy-Item -LiteralPath $EvidencePath -Destination (Join-Path $BackupRoot "previous-deployment-evidence.json")
}

Copy-Item -LiteralPath $SourcePak -Destination $TargetPak -Force
$SourceHash = (Get-FileHash -LiteralPath $SourcePak -Algorithm SHA256).Hash.ToLowerInvariant()
$TargetHash = (Get-FileHash -LiteralPath $TargetPak -Algorithm SHA256).Hash.ToLowerInvariant()
if ($SourceHash -ne $TargetHash) {
    throw "Hash mismatch after Merchant Guild economy PAK deployment."
}

[ordered]@{
    schemaVersion = "1.0.0"
    releaseId = "PalFactionTerritory-FactionEconomyShops"
    steamBuildId = $ExpectedBuildId
    installedAt = (Get-Date).ToString("o")
    gameRoot = $GameRoot
    sourcePak = $SourcePak
    targetPak = $TargetPak
    bytes = (Get-Item -LiteralPath $TargetPak).Length
    sha256 = $TargetHash
    previousPak = $PreviousPak
    backupRoot = if (Test-Path -LiteralPath $BackupRoot) { $BackupRoot } else { $null }
    scope = "Merchant Guild faction shop DataTables only; no original game PAK or save file changed."
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $EvidencePath -Encoding UTF8

Write-Host "PASS deployed Merchant Guild economy PAK"
Write-Host "Target: $TargetPak"
Write-Host "SHA256: $TargetHash"
Write-Host "Deployment evidence: $EvidencePath"
Write-Host "No save files or original game PAK files were changed."
