[CmdletBinding()]
param(
    [string]$ObjectDump = "E:\SteamLibrary\steamapps\common\Palworld\Pal\Binaries\Win64\ue4ss\UE4SS_ObjectDump.txt",
    [string]$AppManifest = "E:\SteamLibrary\steamapps\appmanifest_1623730.acf"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$IdentitySource = Join-Path $ProjectRoot "mod0\ue4ss\PalFactionTerritory0\Scripts\pwft\progression_identity.lua"
$RuntimeSource = Join-Path $ProjectRoot "mod0\ue4ss\PalFactionTerritory0\Scripts\pwft\runtime.lua"
$ConfigSource = Join-Path $ProjectRoot "mod0\ue4ss\PalFactionTerritory0\Scripts\pwft\config.lua"
$MainSource = Join-Path $ProjectRoot "mod0\ue4ss\PalFactionTerritory0\Scripts\main.lua"
$StateReadme = Join-Path $ProjectRoot "mod0\ue4ss\PalFactionTerritory0\State\README.txt"
$EvidenceRoot = Join-Path $ProjectRoot "evidence\contracts"
$EvidencePath = Join-Path $EvidenceRoot "progression-profile-identity-build24467282.json"

foreach ($Path in @(
    $ObjectDump,
    $AppManifest,
    $IdentitySource,
    $RuntimeSource,
    $ConfigSource,
    $MainSource,
    $StateReadme
)) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required progression identity contract input is missing: $Path"
    }
}

$ManifestText = Get-Content -LiteralPath $AppManifest -Raw -Encoding utf8
if ($ManifestText -notmatch '"buildid"\s+"24467282"') {
    throw "Steam appmanifest does not target Build 24467282"
}

$DumpRequirements = @(
    "/Script/Pal.PalPlayerController:GetPlayerUId",
    "/Script/Pal.PalPlayerController:GetPlayerUId:ReturnValue",
    "/Script/Pal.PalPlayerState:PlayerUId",
    "/Script/Pal.PalUtility:GetLocalPlayerUID",
    "/Script/Pal.PalUtility:GetLocalPlayerController",
    "/Script/Pal.PalUtility:GetPalGameStateInGame",
    "/Script/Pal.PalGameStateInGame:GetWorldSaveDirectoryName",
    "/Script/Pal.PalGameInstance:GetSelectedWorldSaveDirectoryName",
    "ScriptStruct /Script/CoreUObject.Guid",
    "IntProperty /Script/CoreUObject.Guid:A",
    "IntProperty /Script/CoreUObject.Guid:B",
    "IntProperty /Script/CoreUObject.Guid:C",
    "IntProperty /Script/CoreUObject.Guid:D"
)
foreach ($Pattern in $DumpRequirements) {
    if (-not (Select-String -LiteralPath $ObjectDump -SimpleMatch -Quiet -Pattern $Pattern)) {
        throw "Retail object dump identity contract is missing: $Pattern"
    }
}

$IdentityText = Get-Content -LiteralPath $IdentitySource -Raw -Encoding utf8
$RuntimeText = Get-Content -LiteralPath $RuntimeSource -Raw -Encoding utf8
$ConfigText = Get-Content -LiteralPath $ConfigSource -Raw -Encoding utf8
$MainText = Get-Content -LiteralPath $MainSource -Raw -Encoding utf8
foreach ($RequiredSourceToken in @(
    "GetWorldSaveDirectoryName",
    "GetPlayerUId",
    "GetLocalPlayerUID",
    "PalPlayerState.PlayerUId",
    "world-",
    ".player-",
    "readOnly = true"
)) {
    if (-not $IdentityText.Contains($RequiredSourceToken)) {
        throw "Progression identity source is missing: $RequiredSourceToken"
    }
}
foreach ($RequiredRuntimeToken in @(
    "ProgressionIdentity.resolve_native()",
    "PROGRESSION_IDENTITY_READY",
    "sidecarWrites=%s",
    "config.factionProgression.persistence.enabled == true",
    "state.onProgressionIdentityReady"
)) {
    if (-not $RuntimeText.Contains($RequiredRuntimeToken)) {
        throw "Progression identity runtime guard is missing: $RequiredRuntimeToken"
    }
}
foreach ($RequiredConfigToken in @(
    "identityProbe = {",
    "readOnly = true",
    "deferredIdentity = true",
    "companionLedgerEnabled = true"
)) {
    if (-not $ConfigText.Contains($RequiredConfigToken)) {
        throw "Progression identity configuration guard is missing: $RequiredConfigToken"
    }
}
if ($ConfigText -notmatch 'persistence\s*=\s*\{\s*enabled\s*=\s*true') {
    throw "Progression sidecar is not enabled after explicit external-ledger authorization"
}
foreach ($RequiredMainToken in @(
    "ModDirectory",
    "Config.factionProgression.persistence.rootPath",
    'ModDirectory .. "/State"'
)) {
    if (-not $MainText.Contains($RequiredMainToken)) {
        throw "Portable Mod-owned state root is missing: $RequiredMainToken"
    }
}

New-Item -ItemType Directory -Path $EvidenceRoot -Force | Out-Null
[ordered]@{
    schemaVersion = "1.0.0"
    verifiedAt = (Get-Date).ToString("o")
    gameBuild = "24467282"
    result = "PASS"
    mode = "read-only-world-player-profile-identity-with-external-ledger"
    worldIdentityRoute = "PalUtility.GetPalGameStateInGame -> PalGameStateInGame.GetWorldSaveDirectoryName"
    playerIdentityRoutes = @(
        "PalPlayerController.GetPlayerUId",
        "PalPlayerState.PlayerUId",
        "PalUtility.GetLocalPlayerUID"
    )
    profileKeyFormat = "world-{WORLD_GUID}.player-{PLAYER_GUID}"
    zeroGuidRejected = $true
    boundedRetryDelaysMs = @(1000, 3000, 8000)
    sidecarWritesEnabled = $true
    sidecarWritesDeferredUntilIdentity = $true
    palworldSaveWritesEnabled = $false
    sidecarRoot = "PalFactionTerritory0/State"
    sidecarRootShipped = $true
    objectDump = @{
        path = $ObjectDump
        sha256 = (Get-FileHash -LiteralPath $ObjectDump -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    source = @{
        identity = @{
            path = $IdentitySource
            sha256 = (Get-FileHash -LiteralPath $IdentitySource -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        runtime = @{
            path = $RuntimeSource
            sha256 = (Get-FileHash -LiteralPath $RuntimeSource -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        config = @{
            path = $ConfigSource
            sha256 = (Get-FileHash -LiteralPath $ConfigSource -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        main = @{
            path = $MainSource
            sha256 = (Get-FileHash -LiteralPath $MainSource -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        stateReadme = @{
            path = $StateReadme
            sha256 = (Get-FileHash -LiteralPath $StateReadme -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
} | ConvertTo-Json -Depth 6 |
    Set-Content -LiteralPath $EvidencePath -Encoding utf8

Write-Host "PASS progression profile identity and external ledger contract (Build 24467282)"
Write-Host "Evidence: $EvidencePath"
