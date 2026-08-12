[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ExpectedBuildId = '24575825'
$ModuleRoot = Split-Path -Parent $PSScriptRoot
$Source = Join-Path $ModuleRoot 'mod0\ue4ss\PalFactionTerritoryQAHarness0'
$ModsRoot = 'E:\SteamLibrary\steamapps\common\Palworld\Pal\Binaries\Win64\ue4ss\Mods'
$Destination = Join-Path $ModsRoot 'PalFactionTerritoryQAHarness0'
$DeploymentRoot = Join-Path $ModuleRoot 'evidence\deployments'
$Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$Backup = Join-Path $DeploymentRoot "settlement-qa-harness-backup-$Timestamp"
$SteamManifest = 'E:\SteamLibrary\steamapps\appmanifest_1623730.acf'

$gameProcesses = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $_.ProcessName -in @('Palworld','Palworld-Win64-Shipping','UnrealEditor','UnrealEditor-Cmd','UAssetGUI','FModel')
})
if ($gameProcesses.Count -gt 0) {
    throw 'Palworld is running; close the game before deploying the settlement QA harness'
}
if (-not (Test-Path -LiteralPath $SteamManifest -PathType Leaf)) {
    throw "Steam manifest not found: $SteamManifest"
}
$SteamManifestText = Get-Content -LiteralPath $SteamManifest -Raw -Encoding utf8
foreach ($ManifestField in @('buildid', 'TargetBuildID')) {
    if ($SteamManifestText -notmatch ('"' + $ManifestField + '"\s+"' + [regex]::Escape($ExpectedBuildId) + '"')) {
        throw "Steam $ManifestField does not match audited Build $ExpectedBuildId"
    }
}
if (-not (Test-Path -LiteralPath (Join-Path $Source 'Scripts\main.lua'))) {
    throw "Settlement QA harness source not found: $Source"
}
if (-not (Test-Path -LiteralPath $ModsRoot)) {
    throw "UE4SS Mods directory not found: $ModsRoot"
}

New-Item -ItemType Directory -Force -Path $DeploymentRoot | Out-Null
if (Test-Path -LiteralPath $Destination) {
    Copy-Item -LiteralPath $Destination -Destination $Backup -Recurse -Force
    $resolvedModsRoot = (Resolve-Path -LiteralPath $ModsRoot).Path
    $resolvedDestination = (Resolve-Path -LiteralPath $Destination).Path
    if (-not $resolvedDestination.StartsWith(
        $resolvedModsRoot + '\',
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Refusing to replace unexpected QA harness path: $resolvedDestination"
    }
    Remove-Item -LiteralPath $resolvedDestination -Recurse -Force
}

Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force
$sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $Source 'Scripts\main.lua')).Hash
$destinationHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $Destination 'Scripts\main.lua')).Hash
if ($sourceHash -ne $destinationHash) {
    throw 'Settlement QA harness deployment hash mismatch'
}

$record = [ordered]@{
    schemaVersion = '1.0.0'
    deployedAt = (Get-Date).ToString('o')
    steamBuildId = $ExpectedBuildId
    source = $Source
    destination = $Destination
    sha256 = $destinationHash
    teleportHotkey = 'Ctrl+F10'
    probeHotkey = 'Ctrl+F9'
    target = [ordered]@{
        name = 'Grass_Village_001'
        x = -346617.56
        y = 191706.60
        z = 500.00
    }
    spawnsRaid = $false
    mutatesRaid = $false
    saveFilesChanged = $false
    originalGamePakChanged = $false
    previousHarnessBackup = if (Test-Path -LiteralPath $Backup) { $Backup } else { $null }
}
$recordPath = Join-Path $DeploymentRoot "settlement-qa-harness-deployment-$Timestamp.json"
$record | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $recordPath -Encoding utf8

[pscustomobject]@{
    Status = 'DEPLOYED'
    Destination = $Destination
    SHA256 = $destinationHash
    TeleportHotkey = 'Ctrl+F10'
    ProbeHotkey = 'Ctrl+F9'
    RaidMutation = $false
    SaveWrite = $false
    Record = $recordPath
} | Format-List
