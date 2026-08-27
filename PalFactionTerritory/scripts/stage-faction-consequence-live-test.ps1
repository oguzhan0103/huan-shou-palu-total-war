[CmdletBinding()]
param(
    [string]$GameRoot = "E:\SteamLibrary\steamapps\common\Palworld",
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
$Stamp = Get-Date -Format "yyyyMMdd-HHmmssfff"
$OutputRoot = Join-Path $ProjectRoot `
    ("outputs\faction-consequence-live-test\" + $Stamp)
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
        "Palworld",
        "Palworld-Win64-Shipping",
        "UnrealEditor",
        "UnrealEditor-Cmd",
        "UAssetGUI",
        "FModel"
    )
})
if ($Blocking.Count -gt 0) {
    throw "A game or asset-editing process is active; consequence staging refused"
}
foreach ($Path in @(
    $SourceMod,
    $TargetMod,
    $SourceConfig,
    $TargetConfig,
    $SaveTarget,
    $StateTarget
)) {
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Consequence staging input is missing: $Path"
    }
}

$ExpectedSaveRoot = [System.IO.Path]::GetFullPath(
    (Join-Path ([Environment]::GetFolderPath("LocalApplicationData")) `
        "Pal\Saved\SaveGames")
).TrimEnd('\')
$ResolvedSaveTarget = (Resolve-Path -LiteralPath $SaveTarget).Path.TrimEnd('\')
$ResolvedStateTarget = (Resolve-Path -LiteralPath $StateTarget).Path.TrimEnd('\')
$ResolvedTargetMod = (Resolve-Path -LiteralPath $TargetMod).Path.TrimEnd('\')
$SaveParent = [System.IO.Path]::GetDirectoryName($ResolvedSaveTarget).TrimEnd('\')
$SaveLeaf = [System.IO.Path]::GetFileName($ResolvedSaveTarget)
if ($SaveParent -ne $ExpectedSaveRoot -or $SaveLeaf -notmatch '^\d{17}$') {
    throw "Unexpected consequence save target: $ResolvedSaveTarget"
}
if ($ResolvedStateTarget -ne (Join-Path $ResolvedTargetMod "State")) {
    throw "Unexpected consequence Mod-State target: $ResolvedStateTarget"
}
if (-not (Test-Path -LiteralPath `
    (Join-Path $GameRoot "Pal\Binaries\Win64\Palworld-Win64-Shipping.exe") `
    -PathType Leaf)) {
    throw "GameRoot does not contain the Palworld executable"
}

$ResolvedSourceMod = (Resolve-Path -LiteralPath $SourceMod).Path.TrimEnd('\')
$SourceFiles = @(
    Get-ChildItem -LiteralPath $ResolvedSourceMod -Recurse -File -Force |
        Sort-Object FullName
)
foreach ($SourceFile in $SourceFiles) {
    $Relative = $SourceFile.FullName.Substring($ResolvedSourceMod.Length + 1)
    $TargetFile = Join-Path $ResolvedTargetMod $Relative
    if (-not (Test-Path -LiteralPath $TargetFile -PathType Leaf)) {
        throw "Installed consequence source parity missing: $Relative"
    }
    if ((Get-FileHash -LiteralPath $SourceFile.FullName -Algorithm SHA256).Hash `
        -ne (Get-FileHash -LiteralPath $TargetFile -Algorithm SHA256).Hash) {
        throw "Installed consequence source parity drifted before staging: $Relative"
    }
}

$SourceText = Get-Content -LiteralPath $SourceConfig -Raw -Encoding utf8
$LiveTestPattern = [regex]::new(
    '(playerGuard\s*=\s*\{.*?liveTest\s*=\s*\{.*?consequenceProbe\s*=\s*\{.*?\}\s*,?\s*\}\s*,?\s*\})',
    [System.Text.RegularExpressions.RegexOptions]::Singleline
)
$LiveTestMatch = $LiveTestPattern.Match($SourceText)
if (-not $LiveTestMatch.Success) {
    throw "Unable to isolate player-guard consequence live-test block"
}
$StagedBlock = $LiveTestMatch.Value
$StagedBlock = [regex]::Replace(
    $StagedBlock,
    '(liveTest\s*=\s*\{\s*enabled\s*=\s*)false',
    '${1}true',
    1
)
$StagedBlock = [regex]::Replace(
    $StagedBlock,
    '(consequenceProbe\s*=\s*\{\s*enabled\s*=\s*)false',
    '${1}true',
    1
)
$DamageableNpcController =
    "/Game/Pal/Blueprint/Controller/NPC/" +
    "BP_NPCAIController.BP_NPCAIController_C"
$StagedBlock = [regex]::Replace(
    $StagedBlock,
    '(targetControllerClassPath\s*=\s*)""',
    ('${1}"' + $DamageableNpcController + '"'),
    1
)
$StagedBlock = [regex]::Replace(
    $StagedBlock,
    '(nativePalTarget\s*=\s*)false',
    '${1}true',
    1
)
# UE4SS Lua's CRT-backed io.open cannot reliably open the project's Chinese
# output path. Keep the transient QA command inside the already snapshotted Mod
# State tree, whose installed path is ASCII-only; restore removes it again.
$CommandFile = Join-Path $StateTarget "qa-guard-command.txt"
$EscapedCommandFile = $CommandFile.Replace('\', '\\')
$StagedBlock = [regex]::Replace(
    $StagedBlock,
    '(commandFileEnabled\s*=\s*)false',
    '${1}true',
    1
)
$StagedBlock = [regex]::Replace(
    $StagedBlock,
    '(commandFilePath\s*=\s*)""',
    ('${1}"' + $EscapedCommandFile + '"'),
    1
)
if (-not [regex]::IsMatch(
    $StagedBlock,
    'liveTest\s*=\s*\{\s*enabled\s*=\s*true.*?key\s*=\s*"F4".*?commandFileEnabled\s*=\s*true.*?commandFilePath\s*=\s*"[^"]+".*?consequenceProbe\s*=\s*\{\s*enabled\s*=\s*true.*?targetControllerClassPath\s*=\s*"/Game/Pal/Blueprint/Controller/NPC/BP_NPCAIController\.BP_NPCAIController_C".*?forceHostileTarget\s*=\s*false.*?triggerActualProcessedCallback\s*=\s*false.*?nativePalTarget\s*=\s*true',
    [System.Text.RegularExpressions.RegexOptions]::Singleline
)) {
    throw "Staged consequence controls are incomplete"
}
$StagedText = $SourceText.Substring(0, $LiveTestMatch.Index) +
    $StagedBlock +
    $SourceText.Substring($LiveTestMatch.Index + $LiveTestMatch.Length)

New-Item -ItemType Directory -Path $SaveSnapshot -Force | Out-Null
New-Item -ItemType Directory -Path $StateSnapshot -Force | Out-Null
$PreStageConfig = Join-Path $OutputRoot "installed-config-before.lua"
Copy-Item -LiteralPath $TargetConfig -Destination $PreStageConfig
Get-ChildItem -LiteralPath $ResolvedSaveTarget -Force | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $SaveSnapshot `
        -Recurse -Force
}
Get-ChildItem -LiteralPath $ResolvedStateTarget -Force | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $StateSnapshot `
        -Recurse -Force
}

$SaveManifest = Get-TreeManifest $ResolvedSaveTarget
$StateManifest = Get-TreeManifest $ResolvedStateTarget
Assert-ManifestEqual $SaveManifest (Get-TreeManifest $SaveSnapshot) `
    "Consequence SaveGames snapshot"
Assert-ManifestEqual $StateManifest (Get-TreeManifest $StateSnapshot) `
    "Consequence Mod-State snapshot"

$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($TargetConfig, $StagedText, $Utf8NoBom)
[System.IO.File]::WriteAllText(
    $CommandFile,
    "sequence=0`ncommand=none`n",
    $Utf8NoBom
)
if (-not [regex]::IsMatch(
    (Get-Content -LiteralPath $TargetConfig -Raw -Encoding utf8),
    'playerGuard\s*=\s*\{.*?liveTest\s*=\s*\{\s*enabled\s*=\s*true.*?consequenceProbe\s*=\s*\{\s*enabled\s*=\s*true',
    [System.Text.RegularExpressions.RegexOptions]::Singleline
)) {
    throw "Installed consequence live-test controls did not stage"
}
if (-not [regex]::IsMatch(
    $SourceText,
    'playerGuard\s*=\s*\{.*?liveTest\s*=\s*\{\s*enabled\s*=\s*false.*?consequenceProbe\s*=\s*\{\s*enabled\s*=\s*false',
    [System.Text.RegularExpressions.RegexOptions]::Singleline
)) {
    throw "Formal consequence source controls were modified unexpectedly"
}

$SettlementEnabled = [regex]::IsMatch(
    (Get-Content -LiteralPath (Join-Path $SourceMod "Scripts\pwft\registry.lua") `
        -Raw -Encoding utf8),
    '\["settlementEnabled"\]\s*=\s*true'
)
[ordered]@{
    schemaVersion = "1.0.0"
    stagedAt = (Get-Date).ToString("o")
    result = "PASS"
    steamBuildId = "24575825"
    snapshotRoot = $SnapshotRoot
    saveTarget = $ResolvedSaveTarget
    stateTarget = $ResolvedStateTarget
    targetConfig = $TargetConfig
    installedConfigBefore = $PreStageConfig
    saveFiles = $SaveManifest
    stateFiles = $StateManifest
    hotkey = "Ctrl+F4"
    commandFile = $CommandFile
    commandFileCommands = @("spawn", "damage", "recall")
    characterId = "NPC_Hunter"
    factionId = "pwft.faction.rayne_syndicate"
    actorRole = "faction-member"
    targetControllerClassPath = $DamageableNpcController
    forceHostileTarget = $false
    triggerActualProcessedCallback = $false
    nativePalTarget = $true
    settlementEnabled = $SettlementEnabled
    exactSpawnedActorOnly = $true
    broadActorScan = $false
    palworldSaveWritesByQaRoute = $false
    restorationRequired = $true
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath `
    (Join-Path $OutputRoot "staging-manifest.json") -Encoding utf8

Write-Host "PASS staged current-Build faction-consequence live test"
Write-Host "Edit the staged ASCII command file, then press M in game:"
Write-Host "  $CommandFile"
Write-Host "Commands: spawn, damage, recall (increment sequence each time)"
Write-Host "Settlement enabled in current source: $SettlementEnabled"
Write-Host "Formal source remains QA-off; snapshot: $OutputRoot"
