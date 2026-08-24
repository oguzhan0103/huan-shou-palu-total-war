[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$GameRoot,
    [Parameter(Mandatory = $true)]
    [string]$SaveTarget
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$SourceMod = Join-Path $ProjectRoot "mod0\ue4ss\PalFactionTerritory0"
$TargetMod = Join-Path $GameRoot `
    "Pal\Binaries\Win64\ue4ss\Mods\PalFactionTerritory0"
$SourceConfig = Join-Path $SourceMod "Scripts\pwft\config.lua"
$TargetConfig = Join-Path $TargetMod "Scripts\pwft\config.lua"
$StateTarget = Join-Path $TargetMod "State"
$CommandFile = Join-Path $StateTarget "b7-unique-pal-command.txt"
$Stamp = Get-Date -Format "yyyyMMdd-HHmmssfff"
$OutputRoot = Join-Path $ProjectRoot `
    ("outputs\b7-unique-pal-live-test\" + $Stamp)
$SnapshotRoot = Join-Path $OutputRoot "snapshot"
$SaveSnapshot = Join-Path $SnapshotRoot "SaveGames"
$StateSnapshot = Join-Path $SnapshotRoot "ModState"

function Get-TreeManifest([string]$Root) {
    $ResolvedRoot = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\')
    return @(
        Get-ChildItem -LiteralPath $ResolvedRoot -Recurse -File -Force |
            Sort-Object FullName |
            ForEach-Object {
                [ordered]@{
                    path = $_.FullName.Substring(
                        $ResolvedRoot.Length + 1
                    ).Replace('\', '/')
                    length = $_.Length
                    sha256 = (Get-FileHash -LiteralPath $_.FullName `
                        -Algorithm SHA256).Hash.ToLowerInvariant()
                }
            }
    )
}

function Assert-ManifestEqual(
    [object[]]$Expected,
    [object[]]$Actual,
    [string]$Label
) {
    if ($Expected.Count -ne $Actual.Count) {
        throw "$Label file-count mismatch: expected=$($Expected.Count) actual=$($Actual.Count)"
    }
    for ($Index = 0; $Index -lt $Expected.Count; $Index++) {
        $Left = $Expected[$Index]
        $Right = $Actual[$Index]
        if ($Left.path -ne $Right.path -or
            [int64]$Left.length -ne [int64]$Right.length -or
            $Left.sha256 -ne $Right.sha256) {
            throw "$Label mismatch at index ${Index}: expected=$($Left.path) actual=$($Right.path)"
        }
    }
}

$Blocking = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $_.ProcessName -in @(
        "Palworld", "Palworld-Win64-Shipping", "UnrealEditor",
        "UnrealEditor-Cmd", "UAssetGUI", "FModel"
    )
})
if ($Blocking.Count -gt 0) {
    throw "A game or asset-editing process is active; B7 staging refused"
}
foreach ($Path in @(
    $SourceMod, $TargetMod, $SourceConfig, $TargetConfig,
    $SaveTarget, $StateTarget
)) {
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "B7 staging input is missing: $Path"
    }
}

$ExpectedSaveRoot = [System.IO.Path]::GetFullPath(
    (Join-Path ([Environment]::GetFolderPath("LocalApplicationData")) `
        "Pal\Saved\SaveGames")
).TrimEnd('\')
$ResolvedSaveTarget = (Resolve-Path -LiteralPath $SaveTarget).Path.TrimEnd('\')
$ResolvedStateTarget = (Resolve-Path -LiteralPath $StateTarget).Path.TrimEnd('\')
$ResolvedSourceMod = (Resolve-Path -LiteralPath $SourceMod).Path.TrimEnd('\')
$ResolvedTargetMod = (Resolve-Path -LiteralPath $TargetMod).Path.TrimEnd('\')
$SaveParent = [System.IO.Path]::GetDirectoryName($ResolvedSaveTarget).TrimEnd('\')
$SaveLeaf = [System.IO.Path]::GetFileName($ResolvedSaveTarget)
if ($SaveParent -ne $ExpectedSaveRoot -or $SaveLeaf -notmatch '^\d{17}$') {
    throw "Unexpected B7 save target: $ResolvedSaveTarget"
}
if (-not (Test-Path -LiteralPath `
    (Join-Path $GameRoot "Pal\Binaries\Win64\Palworld-Win64-Shipping.exe") `
    -PathType Leaf)) {
    throw "B7 GameRoot does not contain the Palworld executable"
}
if ($ResolvedStateTarget -ne (Join-Path $ResolvedTargetMod "State")) {
    throw "Unexpected B7 Mod-State target: $ResolvedStateTarget"
}

# Refuse staging if any installed runtime source differs from the worktree.
$SourceFiles = @(
    Get-ChildItem -LiteralPath $ResolvedSourceMod -Recurse -File -Force |
        Sort-Object FullName
)
foreach ($SourceFile in $SourceFiles) {
    $Relative = $SourceFile.FullName.Substring($ResolvedSourceMod.Length + 1)
    $TargetFile = Join-Path $ResolvedTargetMod $Relative
    if (-not (Test-Path -LiteralPath $TargetFile -PathType Leaf)) {
        throw "Installed B7 source parity missing: $Relative"
    }
    if ((Get-FileHash -LiteralPath $SourceFile.FullName -Algorithm SHA256).Hash `
        -ne (Get-FileHash -LiteralPath $TargetFile -Algorithm SHA256).Hash) {
        throw "Installed B7 source parity drifted before staging: $Relative"
    }
}

$SourceText = Get-Content -LiteralPath $SourceConfig -Raw -Encoding utf8
foreach ($Required in @(
    'uniquePalBossNativeProduction = {',
    'automaticSchedulerEnabled = true',
    'uniquePalId = "pwft.unique.anubis"',
    'cycleKey = "F12"',
    'weakenKey = "F9"',
    'suppressionProbeKey = "F3"',
    'suppressionProbeCharacterId = "BOSS_SheepBall"',
    'commandFileEnabled = false',
    'commandFilePath = ""',
    'uniquePalWorldEffectNativeProduction = {',
    'autoWarEnabled = true',
    'ransomInteractionRadius = 700',
    'rewardItemNativeLiveTest = {',
    'nativeItemId = "StainlessSteel"',
    'units = 1',
    'enableMapFastTravelSelectionProbe = false',
    'mapFastTravelSelectionProbeTarget = "FTPoint24"'
)) {
    if (-not $SourceText.Contains($Required)) {
        throw "Formal B7 source contract is missing: $Required"
    }
}

$BossRegex = [regex]::new(
    '(uniquePalBossNativeProduction\s*=\s*\{.*?storyContentIncluded\s*=\s*false\s*,?\s*\})',
    [System.Text.RegularExpressions.RegexOptions]::Singleline
)
$BossMatch = $BossRegex.Match($SourceText)
if (-not $BossMatch.Success) { throw "Unable to isolate B7 Boss block" }
$BossBlock = $BossMatch.Value
$BossBlock = [regex]::Replace(
    $BossBlock, '(automaticSchedulerEnabled\s*=\s*)true', '${1}false', 1)
$BossQaRegex = [regex]::new(
    '(qa\s*=\s*\{.*?enabled\s*=\s*)false',
    [System.Text.RegularExpressions.RegexOptions]::Singleline
)
$BossBlock = $BossQaRegex.Replace($BossBlock, '${1}true', 1)
$BossBlock = $BossBlock.Replace(
    'requireControlModifier = true', 'requireControlModifier = false')
$BossBlock = $BossBlock.Replace(
    'uniquePalId = "pwft.unique.anubis"',
    'uniquePalId = "pwft.unique.pinkcat"')
$BossBlock = $BossBlock.Replace(
    'commandFileEnabled = false', 'commandFileEnabled = true')
$CommandPathLua = $CommandFile.Replace('\', '/')
$BossBlock = $BossBlock.Replace(
    'commandFilePath = ""',
    'commandFilePath = "' + $CommandPathLua + '"')
$StagedText = $SourceText.Substring(0, $BossMatch.Index) +
    $BossBlock +
    $SourceText.Substring($BossMatch.Index + $BossMatch.Length)

$WorldRegex = [regex]::new(
    '(uniquePalWorldEffectNativeProduction\s*=\s*\{.*?storyContentIncluded\s*=\s*false\s*,?\s*\})',
    [System.Text.RegularExpressions.RegexOptions]::Singleline
)
$WorldMatch = $WorldRegex.Match($StagedText)
if (-not $WorldMatch.Success) { throw "Unable to isolate B7 world block" }
$WorldBlock = $WorldMatch.Value
$WorldBlock = [regex]::Replace(
    $WorldBlock, '(autoWarEnabled\s*=\s*)true', '${1}false', 1)
$WorldQaRegex = [regex]::new(
    '(qa\s*=\s*\{.*?enabled\s*=\s*)false',
    [System.Text.RegularExpressions.RegexOptions]::Singleline
)
$WorldBlock = $WorldQaRegex.Replace($WorldBlock, '${1}true', 1)
$WorldBlock = $WorldBlock.Replace(
    'requireControlModifier = true', 'requireControlModifier = false')
$WorldBlock = $WorldBlock.Replace(
    'ransomInteractionRequireControlModifier = true',
    'ransomInteractionRequireControlModifier = false')
$WorldBlock = [regex]::Replace(
    $WorldBlock, '(ransomInteractionRadius\s*=\s*)700', '${1}10000', 1)
$WorldBlock = $WorldBlock.Replace('warKey = "F5"', 'warKey = "F10"')
$StagedText = $StagedText.Substring(0, $WorldMatch.Index) +
    $WorldBlock +
    $StagedText.Substring($WorldMatch.Index + $WorldMatch.Length)

$RewardRegex = [regex]::new(
    '(rewardItemNativeLiveTest\s*=\s*\{.*?storyContentIncluded\s*=\s*false\s*,?\s*\})',
    [System.Text.RegularExpressions.RegexOptions]::Singleline
)
$RewardMatch = $RewardRegex.Match($StagedText)
if (-not $RewardMatch.Success) { throw "Unable to isolate B7 fund block" }
$RewardBlock = [regex]::Replace(
    $RewardMatch.Value, '(enabled\s*=\s*)false', '${1}true', 1)
$RewardBlock = $RewardBlock.Replace(
    'requireControlModifier = true', 'requireControlModifier = false')
$RewardBlock = $RewardBlock.Replace(
    'operationId = "pwft.qa.reward-item.20260824.1"',
    'operationId = "pwft.qa.b7-ransom-funds.' + $Stamp + '"')
$RewardBlock = $RewardBlock.Replace(
    'contentPackId = "pwft.qa.reward-item"',
    'contentPackId = "pwft.qa.b7-ransom-funds"')
$RewardBlock = $RewardBlock.Replace(
    'policyId = "pwft.qa.reward-item.boss"',
    'policyId = "pwft.qa.b7-ransom-funds.boss"')
$RewardBlock = $RewardBlock.Replace(
    'channelId = "pwft.qa.reward-item.channel.stainless-steel"',
    'channelId = "pwft.qa.b7-ransom-funds.channel.money"')
$RewardBlock = $RewardBlock.Replace(
    'nativeItemId = "StainlessSteel"', 'nativeItemId = "Money"')
$RewardBlock = $RewardBlock.Replace('units = 1', 'units = 100000000')
$StagedText = $StagedText.Substring(0, $RewardMatch.Index) +
    $RewardBlock +
    $StagedText.Substring($RewardMatch.Index + $RewardMatch.Length)

$StagedText = $StagedText.Replace(
    'enableMapFastTravelSelectionProbe = false',
    'enableMapFastTravelSelectionProbe = true')
$StagedText = $StagedText.Replace(
    'mapFastTravelSelectionProbeTarget = "FTPoint24"',
    'mapFastTravelSelectionProbeTarget = "FTPoint90"')

foreach ($Expected in @(
    'automaticSchedulerEnabled = false',
    'uniquePalId = "pwft.unique.pinkcat"',
    'requireControlModifier = false',
    'autoWarEnabled = false',
    'ransomInteractionRadius = 10000',
    'nativeItemId = "Money"',
    'units = 100000000',
    'enableMapFastTravelSelectionProbe = true',
    'mapFastTravelSelectionProbeTarget = "FTPoint90"'
    'commandFileEnabled = true'
    ('commandFilePath = "' + $CommandPathLua + '"')
)) {
    if (-not $StagedText.Contains($Expected)) {
        throw "Staged B7 control is incomplete: $Expected"
    }
}

New-Item -ItemType Directory -Path $SaveSnapshot -Force | Out-Null
New-Item -ItemType Directory -Path $StateSnapshot -Force | Out-Null
$PreStageConfig = Join-Path $OutputRoot "installed-config-before.lua"
Copy-Item -LiteralPath $TargetConfig -Destination $PreStageConfig
Get-ChildItem -LiteralPath $ResolvedSaveTarget -Force | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $SaveSnapshot -Recurse -Force
}
Get-ChildItem -LiteralPath $ResolvedStateTarget -Force | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $StateSnapshot -Recurse -Force
}
$SaveManifest = Get-TreeManifest $ResolvedSaveTarget
$StateManifest = Get-TreeManifest $ResolvedStateTarget
Assert-ManifestEqual $SaveManifest (Get-TreeManifest $SaveSnapshot) `
    "B7 SaveGames snapshot"
Assert-ManifestEqual $StateManifest (Get-TreeManifest $StateSnapshot) `
    "B7 Mod-State snapshot"

$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($TargetConfig, $StagedText, $Utf8NoBom)
[System.IO.File]::WriteAllText($CommandFile, "", $Utf8NoBom)
$InstalledStagedText = Get-Content -LiteralPath $TargetConfig -Raw -Encoding utf8
if ($InstalledStagedText -ne $StagedText) {
    throw "Installed B7 staged configuration readback mismatch"
}
if (-not $SourceText.Contains('automaticSchedulerEnabled = true') -or
    -not $SourceText.Contains('nativeItemId = "StainlessSteel"') -or
    -not $SourceText.Contains('units = 1')) {
    throw "Formal B7 source controls were modified unexpectedly"
}

$Manifest = [ordered]@{
    schemaVersion = "2.0.0"
    stagedAt = (Get-Date).ToString("o")
    result = "PASS"
    steamBuildId = "24575825"
    snapshotRoot = $SnapshotRoot
    saveTarget = $ResolvedSaveTarget
    stateTarget = $ResolvedStateTarget
    targetConfig = $TargetConfig
    installedConfigBefore = $PreStageConfig
    formalConfigSha256 = (Get-FileHash -LiteralPath $SourceConfig `
        -Algorithm SHA256).Hash.ToLowerInvariant()
    installedConfigBeforeSha256 = (
        Get-FileHash -LiteralPath $PreStageConfig -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    stagedConfigSha256 = (
        Get-FileHash -LiteralPath $TargetConfig -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    saveFiles = $SaveManifest
    stateFiles = $StateManifest
    uniquePalIds = @(
        "pwft.unique.pinkcat", "pwft.unique.anubis",
        "pwft.unique.weasel_dragon", "pwft.unique.black_metal_dragon",
        "pwft.unique.ronin"
    )
    initialUniquePalId = "pwft.unique.pinkcat"
    expectedLevel = 80
    expectedHpMultiplier = 12.0
    expectedDamageMultiplier = 2.5
    suppressionProbeCharacterId = "BOSS_SheepBall"
    commandFile = [ordered]@{
        path = $CommandFile
        format = "sequence|operation|uniquePalId"
        operations = @("open", "capture", "timeout", "weaken", "probe", "status")
        pollIntervalMs = 250
        qaOnly = $true
    }
    ransomPrice = 100000000
    fundSetup = [ordered]@{
        nativeItemId = "Money"
        units = 100000000
        hotkey = "F8"
        exactInventoryReadbackRequired = $true
        qaOnly = $true
    }
    hotkeys = [ordered]@{
        open = "F4"
        timeout = "F6"
        capture = "F11"
        weakenToOneHp = "F9"
        cycleUniquePal = "F12"
        suppressNonUniqueBossProbe = "F3"
        joinTargetFaction = "F1"
        forceDestructionWar = "F10"
        openRansomAtNearbyHolderCounter = "F7"
    }
    automaticSchedulerEnabled = $false
    automaticWarEnabled = $false
    exactActorCleanupRequired = $true
    broadActorScanAllowed = $false
    restorationRequired = $true
    storyContentIncluded = $false
}
$Manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath `
    (Join-Path $OutputRoot "staging-manifest.json") -Encoding utf8

Write-Host "PASS staged B7 final unique-Pal live matrix"
Write-Host "Boss: F4 open, F11 capture, F6 timeout, F9 one-HP, F12 cycle"
Write-Host "Suppression: F3; ransom: F8 funds, F1 join, F7 shop"
Write-Host "Formal source remains scheduler-on/QA-off; snapshot: $OutputRoot"
