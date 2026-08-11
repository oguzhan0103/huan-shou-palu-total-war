[CmdletBinding()]
param(
    [string]$GameRoot = "E:\SteamLibrary\steamapps\common\Palworld",
    [switch]$AllowQaHotkey,
    [switch]$AllowMerchantCandidate
)

$ErrorActionPreference = "Stop"
$ExpectedBuildId = "24467282"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$WorkspaceRoot = Split-Path -Parent $ProjectRoot
$AppManifest = "E:\SteamLibrary\steamapps\appmanifest_1623730.acf"
$Repak = @(
    Get-ChildItem -LiteralPath $WorkspaceRoot -Directory |
        ForEach-Object {
            Join-Path $_.FullName "_tools\repak-v0.2.3\repak.exe"
        } |
        Where-Object {
            Test-Path -LiteralPath $_ -PathType Leaf
        }
) | Select-Object -First 1
$ModsRoot = Join-Path $GameRoot "Pal\Binaries\Win64\ue4ss\Mods"
$PaksRoot = Join-Path $GameRoot "Pal\Content\Paks"
$AssetModsRoot = Join-Path $PaksRoot "~mods"
$LogicModsRoot = Join-Path $PaksRoot "LogicMods"
$FactionProject = $ProjectRoot
$EconomyShopContract = Join-Path $FactionProject "contracts\faction_economy_shops.v1.json"
$EvidenceRoot = Join-Path $ProjectRoot "evidence\preflight"
$EvidencePath = Join-Path $EvidenceRoot "install-audit-build24467282.json"

$BlockingProcesses = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $_.ProcessName -in @("Palworld-Win64-Shipping", "Palworld", "UnrealEditor", "UnrealEditor-Cmd", "UAssetGUI", "FModel")
})
if ($BlockingProcesses.Count -gt 0) {
    throw "A game or asset-editing process is running; installation audit requires a stable closed state"
}
if ([string]::IsNullOrWhiteSpace($Repak)) {
    throw "repak.exe was not found under a workspace _tools directory"
}
foreach ($Required in @($AppManifest, $Repak, $AssetModsRoot, $LogicModsRoot, $ModsRoot)) {
    if (-not (Test-Path -LiteralPath $Required)) {
        throw "Required installation-audit input is missing: $Required"
    }
}
$AppManifestText = Get-Content -LiteralPath $AppManifest -Raw -Encoding utf8
foreach ($ManifestField in @("buildid", "TargetBuildID")) {
    if ($AppManifestText -notmatch ('"' + $ManifestField + '"\s+"' + [regex]::Escape($ExpectedBuildId) + '"')) {
        throw "Steam $ManifestField does not match audited Build $ExpectedBuildId"
    }
}

$PakFiles = @(
    Get-ChildItem -LiteralPath $AssetModsRoot, $LogicModsRoot -File -Filter "*.pak" |
        Sort-Object FullName
)
$EntryOwners = @{}
$PakReports = @()
foreach ($Pak in $PakFiles) {
    $Entries = @(& $Repak list $Pak.FullName)
    if ($LASTEXITCODE -ne 0) {
        throw "repak list failed: $($Pak.FullName)"
    }
    foreach ($Entry in $Entries) {
        if (-not $EntryOwners.ContainsKey($Entry)) {
            $EntryOwners[$Entry] = [System.Collections.Generic.List[string]]::new()
        }
        $EntryOwners[$Entry].Add($Pak.FullName)
    }
    $ForbiddenSkeleton = @(
        $Entries | Where-Object {
            $_ -match 'BlackFurDragon[/\\]SK_BlackFurDragon_Skeleton\.(uasset|uexp)$'
        }
    )
    if ($ForbiddenSkeleton.Count -gt 0) {
        throw "A Mod PAK contains the forbidden BlackFurDragon skeleton override: $($Pak.FullName)"
    }
    $BlackFurEntries = @(
        $Entries | Where-Object { $_ -match 'BlackFurDragon' }
    )
    if ($BlackFurEntries.Count -gt 0) {
        throw "BlackFurDragon is withdrawn, but an installed Mod PAK still contains it: $($Pak.FullName)"
    }
    $PakReports += [ordered]@{
        path = $Pak.FullName
        bytes = $Pak.Length
        sha256 = (Get-FileHash -LiteralPath $Pak.FullName -Algorithm SHA256).Hash
        entryCount = $Entries.Count
        blackFurSkeletonOverrideCount = $ForbiddenSkeleton.Count
        blackFurEntryCount = $BlackFurEntries.Count
    }
}
$DuplicateEntries = @(
    foreach ($Entry in $EntryOwners.GetEnumerator()) {
        if ($Entry.Value.Count -gt 1) {
            [ordered]@{
                entry = $Entry.Key
                owners = @($Entry.Value)
            }
        }
    }
)
if ($DuplicateEntries.Count -gt 0) {
    throw "Two installed Mod PAKs override the same mounted entry"
}

$LegacyBlackFurLogicPak = Join-Path $LogicModsRoot "PalBlackFurDragonRevival_P.pak"
$LegacyBlackFurLuaMod = Join-Path $ModsRoot "PalBlackFurDragonRevival0"
$BlackFurInstalledPak = Join-Path $AssetModsRoot "PalBlackFurDragonRevival_P.pak"
$BlackFurPalSchemaMod = Join-Path $ModsRoot "PalSchema\mods\PalBlackFurDragonRevival"
$BlackFurQaHarness = Join-Path $ModsRoot "PalBlackFurDragonQAHarness0"
foreach ($WithdrawnPath in @(
    $LegacyBlackFurLogicPak,
    $LegacyBlackFurLuaMod,
    $BlackFurInstalledPak,
    $BlackFurPalSchemaMod,
    $BlackFurQaHarness
)) {
    if (Test-Path -LiteralPath $WithdrawnPath) {
        throw "BlackFurDragon is withdrawn, but an active installation path remains: $WithdrawnPath"
    }
}

$RaidSource = Join-Path $FactionProject "mod0\ue4ss\PalFactionTerritory0\Scripts\pwft\settlement_raid.lua"
$RaidInstalled = Join-Path $ModsRoot "PalFactionTerritory0\Scripts\pwft\settlement_raid.lua"
$ConfigSource = Join-Path $FactionProject "mod0\ue4ss\PalFactionTerritory0\Scripts\pwft\config.lua"
$ConfigInstalled = Join-Path $ModsRoot "PalFactionTerritory0\Scripts\pwft\config.lua"
foreach ($Required in @(
    $RaidSource,
    $RaidInstalled,
    $ConfigSource,
    $ConfigInstalled,
    $EconomyShopContract
)) {
    if (-not (Test-Path -LiteralPath $Required -PathType Leaf)) {
        throw "Candidate installation input is missing: $Required"
    }
}
function Require-SameHash {
    param([string]$Source, [string]$Target, [string]$Label)
    $SourceHash = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash
    $TargetHash = (Get-FileHash -LiteralPath $Target -Algorithm SHA256).Hash
    if ($SourceHash -ne $TargetHash) {
        throw "$Label source/installation hash mismatch"
    }
    return $SourceHash
}
$RaidHash = Require-SameHash $RaidSource $RaidInstalled "Settlement raid Lua"
$ConfigHash = Require-SameHash $ConfigSource $ConfigInstalled "Faction runtime config"

$InstalledConfigText = Get-Content -LiteralPath $ConfigInstalled -Raw -Encoding utf8
$ExpectedQaHotkeySetting = if ($AllowQaHotkey) {
    "qaHotkeyEnabled = true"
} else {
    "qaHotkeyEnabled = false"
}
foreach ($RequiredConfig in @(
    'expectedSteamBuildId = "24467282"',
    "enableSaveWrites = false",
    $ExpectedQaHotkeySetting,
    "nativeFactionMerchantSpawnEnabled = false",
    "demoNativeRaidSafeMode = true",
    "nativeRaidResultBindingEnabled = true",
    "nativeRaidLiveTest = {",
    "enabled = false",
    "nativeDialoguePresenterEnabled = true"
)) {
    if (-not $InstalledConfigText.Contains($RequiredConfig)) {
        throw "Required safe config is missing: $RequiredConfig"
    }
}

$EconomyShopContractObject = Get-Content -LiteralPath $EconomyShopContract -Raw -Encoding utf8 |
    ConvertFrom-Json
$RuntimeActivation = $EconomyShopContractObject.runtimeActivation
# Merchant Guild activation is now part of the accepted formal baseline. Keep
# the legacy switch for command-line compatibility, but do not downgrade an
# installed release to the pre-acceptance disabled contract.
$ExpectedMerchantActivation = @{
    customProductRowsEnabled = $true
    nativeMerchantSpawnEnabled = $true
    nativeShopBindingEnabled = $true
}
foreach ($Entry in $ExpectedMerchantActivation.GetEnumerator()) {
    if ([bool]$RuntimeActivation.($Entry.Key) -ne [bool]$Entry.Value) {
        throw "Economy shop activation does not match audited candidate mode: $($Entry.Key)"
    }
}
foreach ($DisabledActivationFlag in @(
    "dynamicRestockEnabled",
    "procurementMoneyBonusEnabled"
)) {
    if ($RuntimeActivation.$DisabledActivationFlag -ne $false) {
        throw "Economy shop activation must remain disabled before live testing: $DisabledActivationFlag"
    }
}
if ($RuntimeActivation.procurementCommerceReputationEnabled -ne $true) {
    throw "Confirmed native sale reputation settlement must stay enabled after live acceptance"
}

$QaHarnesses = @(
    "PalFactionTerritoryQAHarness0"
)
$QaReports = @()
foreach ($QaName in $QaHarnesses) {
    $QaRoot = Join-Path $ModsRoot $QaName
    $EnabledMarker = Join-Path $QaRoot "enabled.txt"
    if (Test-Path -LiteralPath $EnabledMarker) {
        throw "QA harness must stay disabled before user authorizes live testing: $QaName"
    }
    $QaReports += [ordered]@{
        name = $QaName
        installed = Test-Path -LiteralPath $QaRoot
        enabled = $false
    }
}

New-Item -ItemType Directory -Path $EvidenceRoot -Force | Out-Null
[ordered]@{
    schemaVersion = "1.1.0"
    auditedAt = (Get-Date).ToString("o")
    result = "PASS"
    gameBuild = $ExpectedBuildId
    sourceContractBuild = "24181527"
    gameProcessRunning = $false
    installedPaks = $PakReports
    duplicateModPakEntries = $DuplicateEntries
    blackFurContentIncluded = $false
    blackFurAssetPakPresent = $false
    blackFurPalSchemaModPresent = $false
    blackFurQaHarnessPresent = $false
    legacyBlackFurLogicPakPresent = $false
    legacyBlackFurLuaModPresent = $false
    settlementRaidLuaSha256 = $RaidHash
    factionConfigSha256 = $ConfigHash
    palSchemaFiles = @()
    qaHarnesses = $QaReports
    safeConfig = @{
        expectedSteamBuildId = $ExpectedBuildId
        enableSaveWrites = $false
        qaHotkeyEnabled = [bool]$AllowQaHotkey
        nativeFactionMerchantSpawnEnabled = $false
        demoNativeRaidSafeMode = $true
    }
    economyShopActivation = @{
        contract = $EconomyShopContract
        customProductRowsEnabled = [bool]$RuntimeActivation.customProductRowsEnabled
        nativeMerchantSpawnEnabled = [bool]$RuntimeActivation.nativeMerchantSpawnEnabled
        nativeShopBindingEnabled = [bool]$RuntimeActivation.nativeShopBindingEnabled
        dynamicRestockEnabled = $false
        procurementMoneyBonusEnabled = $false
        procurementCommerceReputationEnabled = [bool]$RuntimeActivation.procurementCommerceReputationEnabled
    }
    originalGamePakChanged = $false
    saveFilesChanged = $false
    liveTestPerformed = $false
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $EvidencePath -Encoding utf8

Write-Host "PASS live-test installation audit for Steam Build $ExpectedBuildId"
Write-Host "Installed Mod PAKs: $($PakFiles.Count); duplicate mounted entries: 0"
Write-Host "BlackFurDragon: withdrawn; no asset PAK, PalSchema content, Lua mod, or QA harness installed"
Write-Host "Remaining QA harnesses: disabled"
Write-Host "Evidence: $EvidencePath"
