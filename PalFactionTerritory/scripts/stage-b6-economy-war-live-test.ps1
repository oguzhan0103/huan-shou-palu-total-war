[CmdletBinding()]
param(
    [string]$GameRoot = "E:\SteamLibrary\steamapps\common\Palworld"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$SourceMod = Join-Path $ProjectRoot `
    "mod0\ue4ss\PalFactionTerritory0"
$TargetMod = Join-Path $GameRoot `
    "Pal\Binaries\Win64\ue4ss\Mods\PalFactionTerritory0"
$SourceConfig = Join-Path $SourceMod "Scripts\pwft\config.lua"
$TargetConfig = Join-Path $TargetMod "Scripts\pwft\config.lua"
$Stamp = Get-Date -Format "yyyyMMdd-HHmmssfff"
$OutputRoot = Join-Path $ProjectRoot `
    ("outputs\b6-economy-war-live-test\" + $Stamp)

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
    throw "A game or asset-editing process is active; B6 staging refused"
}
foreach ($Path in @($SourceConfig, $TargetConfig)) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "B6 staging input is missing: $Path"
    }
}

& (Join-Path $PSScriptRoot `
    "verify-dynamic-economy-native-contract.ps1") `
    -GameRoot $GameRoot
if (-not $?) {
    throw "Build-native dynamic economy contract failed"
}

$SourceFiles = @(
    Get-ChildItem -LiteralPath $SourceMod -Recurse -File |
        Sort-Object FullName
)
$ResolvedSource = (Resolve-Path -LiteralPath $SourceMod).Path.TrimEnd('\')
$ResolvedTarget = (Resolve-Path -LiteralPath $TargetMod).Path.TrimEnd('\')
foreach ($SourceFile in $SourceFiles) {
    $Relative = $SourceFile.FullName.Substring(
        $ResolvedSource.Length + 1
    )
    $TargetFile = Join-Path $ResolvedTarget $Relative
    if (-not (Test-Path -LiteralPath $TargetFile -PathType Leaf)) {
        throw "Installed B6 source parity missing: $Relative"
    }
    $SourceHash = (
        Get-FileHash -LiteralPath $SourceFile.FullName -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    $TargetHash = (
        Get-FileHash -LiteralPath $TargetFile -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    if ($SourceHash -ne $TargetHash) {
        throw "Installed B6 source parity drifted before staging: $Relative"
    }
}

$SourceText = Get-Content -LiteralPath $SourceConfig -Raw -Encoding utf8
foreach ($Required in @(
    'economyWarLiveTest = {',
    'enabled = false',
    'key = "F3"',
    'runId = "b6-live-20260823-r1"',
    'factionId = "pwft.faction.rayne_syndicate"',
    'resourceId = "metal_ore"',
    'productItemId = "CopperIngot"',
    'initialQuantity = 150',
    'firstReduction = 100',
    'secondReduction = 1',
    'nativeMerchantRequired = true'
)) {
    if (-not $SourceText.Contains($Required)) {
        throw "Formal B6 source contract is missing: $Required"
    }
}
$Pattern =
    '(economyWarLiveTest\s*=\s*\{.*?enabled\s*=\s*)false'
$Regex = [regex]::new(
    $Pattern,
    [System.Text.RegularExpressions.RegexOptions]::Singleline
)
if ($Regex.Matches($SourceText).Count -ne 1) {
    throw "Expected exactly one B6 economy-war live-test gate"
}
$StagedText = $Regex.Replace($SourceText, '${1}true', 1)
if (-not [regex]::IsMatch(
    $StagedText,
    'economyWarLiveTest\s*=\s*\{.*?enabled\s*=\s*true.*?nativeMerchantRequired\s*=\s*true',
    [System.Text.RegularExpressions.RegexOptions]::Singleline
)) {
    throw "Staged B6 live-test safety contract is incomplete"
}

New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
$PreStageCopy = Join-Path $OutputRoot "installed-config-before.lua"
Copy-Item -LiteralPath $TargetConfig -Destination $PreStageCopy
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText(
    $TargetConfig,
    $StagedText,
    $Utf8NoBom
)
$TargetText = Get-Content -LiteralPath $TargetConfig -Raw -Encoding utf8
if (-not [regex]::IsMatch(
    $TargetText,
    'economyWarLiveTest\s*=\s*\{.*?enabled\s*=\s*true',
    [System.Text.RegularExpressions.RegexOptions]::Singleline
)) {
    throw "Installed B6 live-test gate did not enable"
}
if (-not [regex]::IsMatch(
    $SourceText,
    'economyWarLiveTest\s*=\s*\{.*?enabled\s*=\s*false',
    [System.Text.RegularExpressions.RegexOptions]::Singleline
)) {
    throw "Formal B6 source gate was modified unexpectedly"
}

[ordered]@{
    schemaVersion = "1.0.0"
    stagedAt = (Get-Date).ToString("o")
    result = "PASS"
    runId = "b6-live-20260823-r1"
    hotkey = "Ctrl+F3"
    requiredLocation = "Merchant Guild island beside Terraria Seal (FTPoint90)"
    phases = @(
        "established CopperIngot 240x66",
        "limited CopperIngot 280x25",
        "scarce procurement and trade request",
        "threat",
        "war",
        "mandatory game restart and sidecar readback",
        "supply restoration and ceasefire",
        "stable complete"
    )
    nativeMerchantRequired = $true
    merchantRespawnAllowed = $false
    storyContentIncluded = $false
    PalworldSaveMutation = $false
    formalConfigSha256 = (
        Get-FileHash -LiteralPath $SourceConfig -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    stagedConfigSha256 = (
        Get-FileHash -LiteralPath $TargetConfig -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    installedConfigBeforeSha256 = (
        Get-FileHash -LiteralPath $PreStageCopy -Algorithm SHA256
    ).Hash.ToLowerInvariant()
} | ConvertTo-Json -Depth 6 |
    Set-Content -LiteralPath (
        Join-Path $OutputRoot "staging-manifest.json"
    ) -Encoding utf8

Write-Host "PASS staged B6 dynamic economy/war live test"
Write-Host "Location: Merchant Guild island beside Terraria Seal (FTPoint90)"
Write-Host "Hotkey: Ctrl+F3 advances exactly one phase"
Write-Host "After war, close and restart the game before the next phase"
Write-Host "Formal source remains disabled; output: $OutputRoot"
