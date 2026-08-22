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
$SourceRaidRuntime = Join-Path $ProjectRoot `
    "mod0\ue4ss\PalFactionTerritory0\Scripts\pwft\settlement_raid.lua"
$TargetRaidRuntime = Join-Path $GameRoot `
    "Pal\Binaries\Win64\ue4ss\Mods\PalFactionTerritory0\Scripts\pwft\settlement_raid.lua"
$AcceptanceModule = Join-Path $GameRoot `
    "Pal\Binaries\Win64\ue4ss\Mods\PalFactionTerritory0\Scripts\pwft_b5_acceptance\content_module.lua"
$Stamp = Get-Date -Format "yyyyMMdd-HHmmssfff"
$OutputRoot = Join-Path $ProjectRoot `
    ("outputs\b5-task-defense-live-test\" + $Stamp)

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
    throw "A game or asset-editing process is active; B5 staging refused"
}
foreach ($Path in @(
    $SourceConfig,
    $TargetConfig,
    $SourceRaidRuntime,
    $TargetRaidRuntime,
    $AcceptanceModule
)) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "B5 staging input is missing: $Path"
    }
}

$SourceText = Get-Content -LiteralPath $SourceConfig -Raw -Encoding utf8
$SourceRaidText = Get-Content -LiteralPath $SourceRaidRuntime -Raw -Encoding utf8
foreach ($Required in @(
    'contentModules = {',
    'modules = {},',
    'storyContentIncludedByBase = false',
    'enableMapFastTravelSelectionProbe = false',
    'settlementRaid = {',
    'qaHotkeyEnabled = false',
    'level = 80',
    'resultBindingEnabled = true',
    'saveWrites = false'
)) {
    if (-not $SourceText.Contains($Required)) {
        throw "Formal B5 source contract is missing: $Required"
    }
}
if (-not $SourceRaidText.Contains(
    'assert(config.level == 80, "settlement attackers must use level 80")'
)) {
    throw "Formal settlement raid level-80 assertion is missing"
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
        throw "Expected exactly one $Label B5 staging gate"
    }
    return $Regex.Replace($Text, $Replacement, 1)
}

$StagedText = $SourceText
$StagedText = Replace-One $StagedText `
    '(contentModules\s*=\s*\{.*?modules\s*=\s*)\{\}' `
    '${1}{ "pwft_b5_acceptance.content_module" }' `
    'mechanics-only-content-module'
$StagedText = Replace-One $StagedText `
    '(enableMapFastTravelSelectionProbe\s*=\s*)false' `
    '${1}true' `
    'small-settlement-fast-travel-probe'
$StagedText = Replace-One $StagedText `
    '(settlementRaid\s*=\s*\{.*?qaHotkeyEnabled\s*=\s*)false' `
    '${1}true' `
    'raid-hotkey'
$StagedText = Replace-One $StagedText `
    '(settlementRaid\s*=\s*\{.*?nativeInvaderGroupName\s*=\s*"[^"]+".*?level\s*=\s*)80' `
    '${1}1' `
    'raid-level'
$StagedRaidText = Replace-One $SourceRaidText `
    'assert\(config\.level\s*==\s*80,\s*"settlement attackers must use level 80"\)' `
    'assert(config.level == 80 or (config.qaHotkeyEnabled == true and config.level == 1), "settlement attackers must use level 80 outside the explicit QA hotkey harness")' `
    'qa-level-assertion'

foreach ($SafetyPattern in @(
    'contentModules\s*=\s*\{.*?storyContentIncludedByBase\s*=\s*false',
    'settlementRaid\s*=\s*\{.*?attendanceSimulation\s*=\s*\{.*?resultBindingEnabled\s*=\s*true',
    'settlementRaid\s*=\s*\{.*?attendanceSimulation\s*=\s*\{.*?nativeCountdownSpawn\s*=\s*\{.*?saveWrites\s*=\s*false'
)) {
    if (-not [regex]::IsMatch(
        $StagedText,
        $SafetyPattern,
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )) {
        throw "B5 staging safety boundary is missing"
    }
}
if (-not $StagedRaidText.Contains(
    'config.qaHotkeyEnabled == true and config.level == 1'
)) {
    throw "B5 staged settlement raid did not retain the QA-only level gate"
}

New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
$PreStageCopy = Join-Path $OutputRoot "installed-config-before.lua"
$PreStageRaidCopy = Join-Path $OutputRoot "installed-settlement-raid-before.lua"
Copy-Item -LiteralPath $TargetConfig -Destination $PreStageCopy
Copy-Item -LiteralPath $TargetRaidRuntime -Destination $PreStageRaidCopy
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($TargetConfig, $StagedText, $Utf8NoBom)
[System.IO.File]::WriteAllText(
    $TargetRaidRuntime,
    $StagedRaidText,
    $Utf8NoBom
)

$TargetText = Get-Content -LiteralPath $TargetConfig -Raw -Encoding utf8
$TargetRaidText = Get-Content -LiteralPath $TargetRaidRuntime -Raw -Encoding utf8
foreach ($EnabledPattern in @(
    'contentModules\s*=\s*\{.*?modules\s*=\s*\{\s*"pwft_b5_acceptance\.content_module"\s*\}',
    'enableMapFastTravelSelectionProbe\s*=\s*true',
    'settlementRaid\s*=\s*\{.*?qaHotkeyEnabled\s*=\s*true',
    'settlementRaid\s*=\s*\{.*?nativeInvaderGroupName\s*=\s*"[^"]+".*?level\s*=\s*1'
)) {
    if (-not [regex]::IsMatch(
        $TargetText,
        $EnabledPattern,
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )) {
        throw "Installed B5 staging gate did not enable"
    }
}
if (-not $TargetRaidText.Contains(
    'config.qaHotkeyEnabled == true and config.level == 1'
)) {
    throw "Installed B5 QA-only raid-level assertion did not enable"
}

[ordered]@{
    schemaVersion = "1.0.0"
    stagedAt = (Get-Date).ToString("o")
    result = "PASS"
    contentModule = "pwft_b5_acceptance.content_module"
    storyContentIncluded = $false
    mapFastTravelProbe = "F7 -> FTPoint24"
    qaHotkey = "Ctrl+F8"
    countdownSeconds = 5
    attackerLevel = 1
    authoritativeResultBinding = $true
    defenseReputationAward = 50
    palTokenAuthority = $false
    PalworldSaveMutation = $false
    formalSourceSha256 = (Get-FileHash -LiteralPath $SourceConfig -Algorithm SHA256).Hash.ToLowerInvariant()
    formalRaidSourceSha256 = (Get-FileHash -LiteralPath $SourceRaidRuntime -Algorithm SHA256).Hash.ToLowerInvariant()
    stagedTargetSha256 = (Get-FileHash -LiteralPath $TargetConfig -Algorithm SHA256).Hash.ToLowerInvariant()
    stagedRaidTargetSha256 = (Get-FileHash -LiteralPath $TargetRaidRuntime -Algorithm SHA256).Hash.ToLowerInvariant()
    installedConfigBeforeSha256 = (Get-FileHash -LiteralPath $PreStageCopy -Algorithm SHA256).Hash.ToLowerInvariant()
    installedRaidBeforeSha256 = (Get-FileHash -LiteralPath $PreStageRaidCopy -Algorithm SHA256).Hash.ToLowerInvariant()
} | ConvertTo-Json -Depth 4 |
    Set-Content -LiteralPath (Join-Path $OutputRoot "staging-manifest.json") -Encoding utf8

Write-Host "PASS staged B5 mechanics-only task/defense live test"
Write-Host "Content module: enabled only in installed config; formal source remains empty"
Write-Host "Travel probe: open the native map and press F7 to select FTPoint24"
Write-Host "Raid probe: Ctrl+F8, five-second countdown, four level-1 native attackers"
Write-Host "Output: $OutputRoot"
