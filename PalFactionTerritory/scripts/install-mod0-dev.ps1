param(
    [string]$GameRoot = "E:\SteamLibrary\steamapps\common\Palworld",
    [string]$UE4SSArchive = "E:\mod\UE4SS-Palworld_zDev.zip"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$ExpectedBuildId = "24467282"
$ExpectedArchiveSha256 = "5e0c3e29f276eac7ecb3887561083acdd1027fb088b9c2b66417cf3488469035"
$Win64Root = Join-Path $GameRoot "Pal\Binaries\Win64"
$DestinationDwmapi = Join-Path $Win64Root "dwmapi.dll"
$DestinationUE4SS = Join-Path $Win64Root "ue4ss"
$DestinationMod = Join-Path $DestinationUE4SS "Mods\PalFactionTerritory0"
$SteamManifest = "E:\SteamLibrary\steamapps\appmanifest_1623730.acf"
$StageRoot = Join-Path $ProjectRoot "artifacts\deploy-staging\ue4ss-palworld-build24467282"
$EvidenceRoot = Join-Path $ProjectRoot "evidence\deployments"
$EvidencePath = Join-Path $EvidenceRoot "mod0-dev-build24467282.json"

& (Join-Path $PSScriptRoot "verify-mod0.ps1")
if ($LASTEXITCODE -ne 0) {
    throw "Mod 0 verification failed; deployment was not started."
}

$BlockingProcesses = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $_.ProcessName -in @("Palworld-Win64-Shipping", "Palworld", "UnrealEditor", "UnrealEditor-Cmd", "UAssetGUI", "FModel")
})
if ($BlockingProcesses.Count -gt 0) {
    throw "A game or asset-editing process is running. Close it before installing UE4SS."
}
if (-not (Test-Path -LiteralPath (Join-Path $Win64Root "Palworld-Win64-Shipping.exe"))) {
    throw "Palworld executable not found at $Win64Root"
}
if (-not (Test-Path -LiteralPath $SteamManifest)) {
    throw "Steam manifest not found: $SteamManifest"
}
$SteamManifestText = Get-Content -LiteralPath $SteamManifest -Raw
foreach ($ManifestField in @("buildid", "TargetBuildID")) {
    if ($SteamManifestText -notmatch ('"' + $ManifestField + '"\s+"' + [regex]::Escape($ExpectedBuildId) + '"')) {
        throw "Steam $ManifestField does not match the audited Build $ExpectedBuildId."
    }
}
if (-not (Test-Path -LiteralPath $UE4SSArchive)) {
    throw "UE4SS archive not found: $UE4SSArchive"
}
$ArchiveHash = (Get-FileHash -LiteralPath $UE4SSArchive -Algorithm SHA256).Hash.ToLowerInvariant()
if ($ArchiveHash -ne $ExpectedArchiveSha256) {
    throw "UE4SS archive hash changed. Expected $ExpectedArchiveSha256, got $ArchiveHash"
}

foreach ($Path in @($DestinationDwmapi, $DestinationUE4SS, $DestinationMod, $StageRoot, $EvidencePath)) {
    if (Test-Path -LiteralPath $Path) {
        throw "Refusing to overwrite existing path: $Path"
    }
}

New-Item -ItemType Directory -Path $StageRoot -Force | Out-Null
Expand-Archive -LiteralPath $UE4SSArchive -DestinationPath $StageRoot

$StagedDwmapi = Join-Path $StageRoot "dwmapi.dll"
$StagedUE4SS = Join-Path $StageRoot "ue4ss"
$StagedSettings = Join-Path $StagedUE4SS "UE4SS-settings.ini"
foreach ($RequiredPath in @(
    $StagedDwmapi,
    (Join-Path $StagedUE4SS "UE4SS.dll"),
    (Join-Path $StagedUE4SS "MemberVariableLayout.ini"),
    $StagedSettings,
    (Join-Path $StagedUE4SS "Mods\mods.txt")
)) {
    if (-not (Test-Path -LiteralPath $RequiredPath)) {
        throw "UE4SS staging validation failed; missing $RequiredPath"
    }
}

# Palworld's developer setup uses the GUI console and disables the separate text console.
$SettingsText = [IO.File]::ReadAllText($StagedSettings)
if ($SettingsText -notmatch '(?m)^ConsoleEnabled = 1\s*$') {
    throw "Unexpected UE4SS ConsoleEnabled setting; refusing an unreviewed configuration rewrite."
}
$SettingsText = [regex]::Replace($SettingsText, '(?m)^ConsoleEnabled = 1\s*$', 'ConsoleEnabled = 0')
[IO.File]::WriteAllText($StagedSettings, $SettingsText, [Text.UTF8Encoding]::new($false))

Copy-Item -LiteralPath $StagedDwmapi -Destination $DestinationDwmapi
Copy-Item -LiteralPath $StagedUE4SS -Destination $DestinationUE4SS -Recurse
Copy-Item -LiteralPath (Join-Path $ProjectRoot "mod0\ue4ss\PalFactionTerritory0") -Destination $DestinationMod -Recurse

New-Item -ItemType Directory -Path $EvidenceRoot -Force | Out-Null
$InstalledFiles = @(
    Get-Item -LiteralPath $DestinationDwmapi
    Get-ChildItem -LiteralPath $DestinationUE4SS -Recurse -File
) | Sort-Object FullName | ForEach-Object {
    [ordered]@{
        path = $_.FullName
        bytes = $_.Length
        sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}
$Deployment = [ordered]@{
    schemaVersion = "1.0.0"
    releaseId = "PalFactionTerritory0-mod0"
    steamBuildId = $ExpectedBuildId
    mode = "read-only"
    installedAt = (Get-Date).ToString("o")
    gameRoot = $GameRoot
    ue4ssArchive = $UE4SSArchive
    ue4ssArchiveSha256 = $ArchiveHash
    installedFiles = $InstalledFiles
}
$Deployment | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $EvidencePath -Encoding UTF8

Write-Host "PASS installed read-only Mod 0 development slice"
Write-Host "Game root: $GameRoot"
Write-Host "Deployment evidence: $EvidencePath"
Write-Host "No save files or original PAK files were changed."
