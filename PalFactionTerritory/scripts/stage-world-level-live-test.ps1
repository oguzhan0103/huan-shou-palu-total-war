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
    ("outputs\world-level-live-test\" + $Stamp)

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
    throw "A game or asset-editing process is active; staging refused"
}
foreach ($Path in @($SourceConfig, $TargetConfig)) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "World-level staging input is missing: $Path"
    }
}

$SourceText = Get-Content -LiteralPath $SourceConfig -Raw -Encoding utf8
foreach ($Required in @(
    'maxDetailLogCount = 24',
    'liveAudit = {',
    'characterId = "Boss_Anubis"',
    'saveWrites = false',
    'levelOverride = {',
    'palFactionRage = {',
    'loadedActorReconcile = {'
)) {
    if (-not $SourceText.Contains($Required)) {
        throw "Formal world-level source contract is missing: $Required"
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
        throw "Expected exactly one $Label staging gate"
    }
    return $Regex.Replace($Text, $Replacement, 1)
}

$StagedText = $SourceText
$StagedText = Replace-One $StagedText `
    '(worldBalance\s*=\s*\{.*?maxDetailLogCount\s*=\s*)24' `
    '${1}256' `
    'detail-log'
$StagedText = Replace-One $StagedText `
    '(worldBalance\s*=\s*\{.*?liveAudit\s*=\s*\{\s*enabled\s*=\s*)false' `
    '${1}true' `
    'live-audit'
$StagedText = Replace-One $StagedText `
    '(worldBalance\s*=\s*\{.*?liveAudit\s*=\s*\{.*?bossProbe\s*=\s*\{\s*enabled\s*=\s*)false' `
    '${1}true' `
    'Boss-probe'
$StagedText = Replace-One $StagedText `
    '(worldBalance\s*=\s*\{.*?levelOverride\s*=\s*\{\s*enabled\s*=\s*)false' `
    '${1}true' `
    'level-override'

foreach ($FailClosedPattern in @(
    'worldBalance\s*=\s*\{.*?palFactionRage\s*=\s*\{\s*enabled\s*=\s*false',
    'worldBalance\s*=\s*\{.*?loadedActorReconcile\s*=\s*\{\s*enabled\s*=\s*false'
)) {
    if (-not [regex]::IsMatch(
        $StagedText,
        $FailClosedPattern,
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )) {
        throw "B1 staging would not isolate rage and loaded-actor reconciliation"
    }
}

New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
$PreStageCopy = Join-Path $OutputRoot "installed-config-before.lua"
Copy-Item -LiteralPath $TargetConfig -Destination $PreStageCopy
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($TargetConfig, $StagedText, $Utf8NoBom)

$TargetText = Get-Content -LiteralPath $TargetConfig -Raw -Encoding utf8
foreach ($EnabledPattern in @(
    'worldBalance\s*=\s*\{.*?liveAudit\s*=\s*\{\s*enabled\s*=\s*true',
    'worldBalance\s*=\s*\{.*?liveAudit\s*=\s*\{.*?bossProbe\s*=\s*\{\s*enabled\s*=\s*true',
    'worldBalance\s*=\s*\{.*?levelOverride\s*=\s*\{\s*enabled\s*=\s*true'
)) {
    if (-not [regex]::IsMatch(
        $TargetText,
        $EnabledPattern,
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )) {
        throw "Installed B1 staging gate did not enable"
    }
}

[ordered]@{
    schemaVersion = "1.0.0"
    stagedAt = (Get-Date).ToString("o")
    result = "PASS"
    targetLevel = 80
    levelOverride = $true
    liveAudit = $true
    bossProbe = $true
    palFactionRage = $false
    loadedActorReconcile = $false
    broadActorScan = $false
    bossProbeSaveWrites = $false
    formalSourceSha256 = (Get-FileHash -LiteralPath $SourceConfig -Algorithm SHA256).Hash.ToLowerInvariant()
    stagedTargetSha256 = (Get-FileHash -LiteralPath $TargetConfig -Algorithm SHA256).Hash.ToLowerInvariant()
    installedConfigBeforeSha256 = (Get-FileHash -LiteralPath $PreStageCopy -Algorithm SHA256).Hash.ToLowerInvariant()
} | ConvertTo-Json -Depth 4 |
    Set-Content -LiteralPath (Join-Path $OutputRoot "staging-manifest.json") -Encoding utf8

Write-Host "PASS staged B1 world-level live test"
Write-Host "Level override: enabled; live audit: enabled; Boss probe: F8"
Write-Host "Pal rage: disabled; loaded-actor reconciliation: disabled; broad scan: disabled"
Write-Host "Output: $OutputRoot"
