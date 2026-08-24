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
$Stamp = Get-Date -Format "yyyyMMdd-HHmmssfff"
$OutputRoot = Join-Path $ProjectRoot `
    ("outputs\a9-reward-live-test\" + $Stamp)
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
    throw "A game or asset-editing process is active; A9 staging refused"
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
        throw "A9 staging input is missing: $Path"
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
    throw "Unexpected A9 save target: $ResolvedSaveTarget"
}
if (-not (Test-Path -LiteralPath `
    (Join-Path $GameRoot "Pal\Binaries\Win64\Palworld-Win64-Shipping.exe") `
    -PathType Leaf)) {
    throw "A9 GameRoot does not contain the Palworld executable"
}
if ($ResolvedStateTarget -ne (Join-Path $ResolvedTargetMod "State")) {
    throw "Unexpected A9 Mod-State target: $ResolvedStateTarget"
}

# Refuse to stage from a deployment that has drifted from the verified source.
$ResolvedSourceMod = (Resolve-Path -LiteralPath $SourceMod).Path.TrimEnd('\')
$SourceFiles = @(
    Get-ChildItem -LiteralPath $ResolvedSourceMod -Recurse -File -Force |
        Sort-Object FullName
)
foreach ($SourceFile in $SourceFiles) {
    $Relative = $SourceFile.FullName.Substring(
        $ResolvedSourceMod.Length + 1
    )
    $TargetFile = Join-Path $ResolvedTargetMod $Relative
    if (-not (Test-Path -LiteralPath $TargetFile -PathType Leaf)) {
        throw "Installed A9 source parity missing: $Relative"
    }
    $SourceHash = (Get-FileHash -LiteralPath $SourceFile.FullName `
        -Algorithm SHA256).Hash
    $TargetHash = (Get-FileHash -LiteralPath $TargetFile `
        -Algorithm SHA256).Hash
    if ($SourceHash -ne $TargetHash) {
        throw "Installed A9 source parity drifted before staging: $Relative"
    }
}

$SourceText = Get-Content -LiteralPath $SourceConfig -Raw -Encoding utf8
$BlockRegex = [regex]::new(
    '(rewardItemNativeLiveTest\s*=\s*\{.*?storyContentIncluded\s*=\s*false\s*,?\s*\})',
    [System.Text.RegularExpressions.RegexOptions]::Singleline
)
$BlockMatch = $BlockRegex.Match($SourceText)
if (-not $BlockMatch.Success) {
    throw "Unable to isolate the A9 reward live-test block"
}
$StagedBlock = [regex]::Replace(
    $BlockMatch.Value,
    '(enabled\s*=\s*)false',
    '${1}true',
    1
)
if (-not [regex]::IsMatch(
    $StagedBlock,
    'enabled\s*=\s*true.*?key\s*=\s*"F8".*?requireControlModifier\s*=\s*true.*?nativeItemId\s*=\s*"StainlessSteel".*?units\s*=\s*1',
    [System.Text.RegularExpressions.RegexOptions]::Singleline
)) {
    throw "Staged A9 controls are incomplete"
}
$StagedText = $SourceText.Substring(0, $BlockMatch.Index) +
    $StagedBlock +
    $SourceText.Substring($BlockMatch.Index + $BlockMatch.Length)

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
    "A9 SaveGames snapshot"
Assert-ManifestEqual $StateManifest (Get-TreeManifest $StateSnapshot) `
    "A9 Mod-State snapshot"

$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($TargetConfig, $StagedText, $Utf8NoBom)
$TargetText = Get-Content -LiteralPath $TargetConfig -Raw -Encoding utf8
if (-not [regex]::IsMatch(
    $TargetText,
    'rewardItemNativeLiveTest\s*=\s*\{.*?enabled\s*=\s*true.*?key\s*=\s*"F8".*?requireControlModifier\s*=\s*true',
    [System.Text.RegularExpressions.RegexOptions]::Singleline
)) {
    throw "Installed A9 live-test controls did not stage"
}
if (-not [regex]::IsMatch(
    $SourceText,
    'rewardItemNativeLiveTest\s*=\s*\{.*?enabled\s*=\s*false',
    [System.Text.RegularExpressions.RegexOptions]::Singleline
)) {
    throw "Formal A9 source controls were modified unexpectedly"
}

$Manifest = [ordered]@{
    schemaVersion = "1.0.0"
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
    operationId = "pwft.qa.reward-item.20260824.1"
    nativeItemId = "StainlessSteel"
    units = 1
    hotkey = "Ctrl+F8"
    repeatSameKeyTestsIdempotency = $true
    restorationRequired = $true
}
$Manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath `
    (Join-Path $OutputRoot "staging-manifest.json") -Encoding utf8

Write-Host "PASS staged A9 reward native-item controlled live test"
Write-Host "Press Ctrl+F8 once for one StainlessSteel, then again for idempotency"
Write-Host "Formal source remains QA-off; snapshot: $OutputRoot"
