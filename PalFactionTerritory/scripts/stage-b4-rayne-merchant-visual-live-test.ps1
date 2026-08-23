[CmdletBinding()]
param(
    [string]$GameRoot = "E:\SteamLibrary\steamapps\common\Palworld"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$SourceConfig = Join-Path $ProjectRoot `
    "mod0\ue4ss\PalFactionTerritory0\Scripts\pwft\config.lua"
$TargetConfig = Join-Path $GameRoot `
    "Pal\Binaries\Win64\ue4ss\Mods\PalFactionTerritory0\Scripts\pwft\config.lua"
$Stamp = Get-Date -Format "yyyyMMdd-HHmmssfff"
$OutputRoot = Join-Path $ProjectRoot `
    ("outputs\b4-rayne-merchant-visual-live-test\" + $Stamp)

$Blocking = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $_.ProcessName -in @(
        "Palworld",
        "Palworld-Win64-Shipping",
        "UnrealEditor",
        "UnrealEditor-Cmd",
        "UAssetGUI",
        "FModel"
    )
})
if ($Blocking.Count -gt 0) {
    throw "A game or asset-editing process is active; B4 staging refused"
}
foreach ($Path in @($SourceConfig, $TargetConfig)) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "B4 staging input is missing: $Path"
    }
}

$SourceText = Get-Content -LiteralPath $SourceConfig -Raw -Encoding utf8
foreach ($Required in @(
    'enableMapFastTravelSelectionProbe = false',
    'mapFastTravelSelectionProbeTarget = "FTPoint24"',
    'rayneMerchant = {',
    'towerFastTravelPointId = "WatchTower_1"',
    'relationLiveTest = {',
    'enabled = false',
    'key = "F11"',
    'enableCustomShop = true',
    'enableFactionHostility = true',
    'shopRowName = "PFT_Rayne_AllPaldex"',
    'capturePlayerAnchorOnLoad = false',
    'X = -319082.076',
    'Y = 208361.251',
    'Z = -23.445',
    'modules = {},',
    'saveWrites = false'
)) {
    if (-not $SourceText.Contains($Required)) {
        throw "Formal B4 source contract is missing: $Required"
    }
}

function Replace-One {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Replacement,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $Regex = [regex]::new(
        $Pattern,
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )
    if ($Regex.Matches($Text).Count -ne 1) {
        throw "Expected exactly one $Label B4 staging gate"
    }
    return $Regex.Replace($Text, $Replacement, 1)
}

$StagedText = $SourceText
$StagedText = Replace-One $StagedText `
    '(enableMapFastTravelSelectionProbe\s*=\s*)false' `
    '${1}true' `
    'Rayne-tower-entrance-fast-travel-probe'
$StagedText = Replace-One $StagedText `
    '(mapFastTravelSelectionProbeTarget\s*=\s*)"FTPoint24"' `
    '${1}"FTPoint45"' `
    'Rayne-tower-entrance-fast-travel-target'
$StagedText = Replace-One $StagedText `
    '(rayneMerchant\s*=\s*\{.*?relationLiveTest\s*=\s*\{.*?enabled\s*=\s*)false' `
    '${1}true' `
    'Rayne-relation-hotkey'
$StagedText = Replace-One $StagedText `
    '(rayneMerchant\s*=\s*\{.*?fixedSpawnLocation\s*=\s*\{\s*X\s*=\s*)-319082\.076(\s*,\s*Y\s*=\s*)208361\.251(\s*,\s*Z\s*=\s*)-23\.445' `
    '${1}-318082.156${2}211753.623${3}-722.810' `
    'FTPoint45-adjacent-Rayne-merchant-location'

foreach ($SafetyPattern in @(
    'contentModules\s*=\s*\{.*?modules\s*=\s*\{\s*\}',
    'rayneMerchant\s*=\s*\{.*?enableCustomShop\s*=\s*true',
    'rayneMerchant\s*=\s*\{.*?enableFactionHostility\s*=\s*true',
    'rayneMerchant\s*=\s*\{.*?shopRowName\s*=\s*"PFT_Rayne_AllPaldex"',
    'rayneMerchant\s*=\s*\{.*?towerFastTravelPointId\s*=\s*"WatchTower_1"',
    'rayneMerchant\s*=\s*\{.*?capturePlayerAnchorOnLoad\s*=\s*false',
    'rayneMerchant\s*=\s*\{.*?fixedSpawnLocation\s*=\s*\{\s*X\s*=\s*-318082\.156\s*,\s*Y\s*=\s*211753\.623\s*,\s*Z\s*=\s*-722\.810',
    'rayneMerchant\s*=\s*\{.*?relationLiveTest\s*=\s*\{.*?key\s*=\s*"F11"',
    'settlementRaid\s*=\s*\{.*?qaHotkeyEnabled\s*=\s*false',
    'settlementRaid\s*=\s*\{.*?nativeCountdownSpawn\s*=\s*\{.*?saveWrites\s*=\s*false'
)) {
    if (-not [regex]::IsMatch(
        $StagedText,
        $SafetyPattern,
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )) {
        throw "B4 staging safety boundary is missing: $SafetyPattern"
    }
}

New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
$PreStageCopy = Join-Path $OutputRoot "installed-config-before.lua"
Copy-Item -LiteralPath $TargetConfig -Destination $PreStageCopy
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($TargetConfig, $StagedText, $Utf8NoBom)

$TargetText = Get-Content -LiteralPath $TargetConfig -Raw -Encoding utf8
foreach ($EnabledPattern in @(
    'enableMapFastTravelSelectionProbe\s*=\s*true',
    'mapFastTravelSelectionProbeTarget\s*=\s*"FTPoint45"',
    'rayneMerchant\s*=\s*\{.*?towerFastTravelPointId\s*=\s*"WatchTower_1"',
    'rayneMerchant\s*=\s*\{.*?capturePlayerAnchorOnLoad\s*=\s*false',
    'rayneMerchant\s*=\s*\{.*?fixedSpawnLocation\s*=\s*\{\s*X\s*=\s*-318082\.156\s*,\s*Y\s*=\s*211753\.623\s*,\s*Z\s*=\s*-722\.810',
    'rayneMerchant\s*=\s*\{.*?relationLiveTest\s*=\s*\{.*?enabled\s*=\s*true',
    'rayneMerchant\s*=\s*\{.*?relationLiveTest\s*=\s*\{.*?key\s*=\s*"F11"'
)) {
    if (-not [regex]::IsMatch(
        $TargetText,
        $EnabledPattern,
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )) {
        throw "Installed B4 staging gate did not enable: $EnabledPattern"
    }
}

[ordered]@{
    schemaVersion = "1.0.0"
    stagedAt = (Get-Date).ToString("o")
    result = "PASS"
    mapFastTravelProbe = "F7 -> FTPoint45"
    merchantPlacement = "Deterministic visual-test placement 5m beside FTPoint45; formal source remains at WatchTower_1 coordinates"
    relationHotkey = "F11"
    requiredSequence = @("Friendly", "Hostile", "Friendly")
    shopRow = "PFT_Rayne_AllPaldex"
    customShopEnabled = $true
    factionHostilityEnabled = $true
    storyContentIncluded = $false
    PalworldSaveMutation = $false
    formalSourceSha256 = (Get-FileHash -LiteralPath $SourceConfig -Algorithm SHA256).Hash.ToLowerInvariant()
    stagedTargetSha256 = (Get-FileHash -LiteralPath $TargetConfig -Algorithm SHA256).Hash.ToLowerInvariant()
    installedConfigBeforeSha256 = (Get-FileHash -LiteralPath $PreStageCopy -Algorithm SHA256).Hash.ToLowerInvariant()
} | ConvertTo-Json -Depth 4 |
    Set-Content -LiteralPath (Join-Path $OutputRoot "staging-manifest.json") -Encoding utf8

Write-Host "PASS staged B4 Rayne merchant visual round-trip live test"
Write-Host "Travel probe: open the native map and press F7 to select FTPoint45 (Rayne tower entrance)"
Write-Host "Merchant placement: deterministic visual-test point 5m beside FTPoint45"
Write-Host "Relation probe: F11 toggles Friendly -> Hostile -> Friendly without save writes"
Write-Host "Formal source keeps both QA gates disabled"
Write-Host "Output: $OutputRoot"
