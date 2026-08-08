param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePak,
    [string]$GameRoot = "E:\SteamLibrary\steamapps\common\Palworld"
)

$ErrorActionPreference = "Stop"
$ExpectedBuildId = "24467282"

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$EvidenceRoot = Join-Path $ProjectRoot "evidence\deployments"
$TargetPak = Join-Path $GameRoot "Pal\Content\Paks\LogicMods\PalFactionTerritory0.pak"
$SteamManifest = "E:\SteamLibrary\steamapps\appmanifest_1623730.acf"

if (-not (Test-Path -LiteralPath $SourcePak -PathType Leaf)) {
    throw "Source PAK not found: $SourcePak"
}
if (-not (Test-Path -LiteralPath $TargetPak -PathType Leaf)) {
    throw "Target LogicMod PAK not found: $TargetPak"
}
$BlockingProcesses = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $_.ProcessName -in @("Palworld-Win64-Shipping", "Palworld", "UnrealEditor", "UnrealEditor-Cmd", "UAssetGUI", "FModel")
})
if ($BlockingProcesses.Count -gt 0) {
    throw "A game or asset-editing process is running. Close it before replacing the LogicMod PAK."
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

$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$BackupRoot = Join-Path $EvidenceRoot ("pmk-logicmod-pak-backups\" + $Stamp)
$BackupPak = Join-Path $BackupRoot "PalFactionTerritory0.pre-deploy.pak"
New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null

$SourceHash = (Get-FileHash -LiteralPath $SourcePak -Algorithm SHA256).Hash.ToLowerInvariant()
$TargetHashBefore = (Get-FileHash -LiteralPath $TargetPak -Algorithm SHA256).Hash.ToLowerInvariant()
Copy-Item -LiteralPath $TargetPak -Destination $BackupPak
Copy-Item -LiteralPath $SourcePak -Destination $TargetPak -Force
$TargetHashAfter = (Get-FileHash -LiteralPath $TargetPak -Algorithm SHA256).Hash.ToLowerInvariant()

if ($TargetHashAfter -ne $SourceHash) {
    throw "Deployment verification failed: installed PAK hash differs from source."
}

$Evidence = [ordered]@{
    deployedAt = (Get-Date).ToString("o")
    steamBuildId = $ExpectedBuildId
    sourcePak = (Resolve-Path -LiteralPath $SourcePak).Path
    sourceSha256 = $SourceHash
    targetPak = $TargetPak
    targetSha256Before = $TargetHashBefore
    targetSha256After = $TargetHashAfter
    backupPak = $BackupPak
    backupSha256 = (Get-FileHash -LiteralPath $BackupPak -Algorithm SHA256).Hash.ToLowerInvariant()
    scope = "LogicMods/PalFactionTerritory0.pak only"
    saveFilesChanged = $false
    originalGamePaksChanged = $false
} | ConvertTo-Json -Depth 4
$EvidencePath = Join-Path $BackupRoot "deployment-evidence.json"
Set-Content -LiteralPath $EvidencePath -Value $Evidence -Encoding UTF8

Write-Host "PASS deployed LogicMod PAK"
Write-Host "Source SHA256: $SourceHash"
Write-Host "Target SHA256: $TargetHashAfter"
Write-Host "Backup: $BackupPak"
Write-Host "Evidence: $EvidencePath"
