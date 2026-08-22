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
    ("outputs\pal-faction-rage-live-test\" + $Stamp)

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
    throw "A game or asset-editing process is active; B2 staging refused"
}
foreach ($Path in @($SourceConfig, $TargetConfig)) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Pal-faction rage staging input is missing: $Path"
    }
}

$SourceHash = (Get-FileHash -LiteralPath $SourceConfig -Algorithm SHA256).Hash
$TargetHash = (Get-FileHash -LiteralPath $TargetConfig -Algorithm SHA256).Hash
if ($SourceHash -ne $TargetHash) {
    throw "Installed config does not match formal source; redeploy before B2 staging"
}

$SourceText = Get-Content -LiteralPath $SourceConfig -Raw -Encoding utf8
foreach ($Required in @(
    'demoNativeRaidSafeMode = true',
    'maxDetailLogCount = 24',
    'liveAudit = {',
    'bossProbe = {',
    'levelOverride = {',
    'palFactionRage = {',
    'characterId = "PinkCat"',
    'key = "F7"',
    'loadedActorReconcile = {'
)) {
    if (-not $SourceText.Contains($Required)) {
        throw "Formal B2 source contract is missing: $Required"
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
    '(demoNativeRaidSafeMode\s*=\s*)true' `
    '${1}false' `
    'native-raid safe-mode bypass'
$StagedText = Replace-One $StagedText `
    '(worldBalance\s*=\s*\{.*?maxDetailLogCount\s*=\s*)24' `
    '${1}512' `
    'detail-log'
$StagedText = Replace-One $StagedText `
    '(worldBalance\s*=\s*\{.*?liveAudit\s*=\s*\{\s*enabled\s*=\s*)false' `
    '${1}true' `
    'world live-audit'
$StagedText = Replace-One $StagedText `
    '(worldBalance\s*=\s*\{.*?palFactionRage\s*=\s*\{\s*enabled\s*=\s*)false' `
    '${1}true' `
    'Pal-faction rage'
$StagedText = Replace-One $StagedText `
    '(worldBalance\s*=\s*\{.*?palFactionRage\s*=\s*\{.*?liveAudit\s*=\s*\{\s*enabled\s*=\s*)false' `
    '${1}true' `
    'rage live-audit'
$StagedText = Replace-One $StagedText `
    '(worldBalance\s*=\s*\{.*?palFactionRage\s*=\s*\{.*?liveAudit\s*=\s*\{.*?probe\s*=\s*\{\s*enabled\s*=\s*)false' `
    '${1}true' `
    'rage probe'

foreach ($FailClosedPattern in @(
    'worldBalance\s*=\s*\{.*?liveAudit\s*=\s*\{.*?bossProbe\s*=\s*\{\s*enabled\s*=\s*false',
    'worldBalance\s*=\s*\{.*?levelOverride\s*=\s*\{\s*enabled\s*=\s*false',
    'worldBalance\s*=\s*\{.*?loadedActorReconcile\s*=\s*\{\s*enabled\s*=\s*false'
)) {
    if (-not [regex]::IsMatch(
        $StagedText,
        $FailClosedPattern,
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )) {
        throw "B2 staging would not isolate Boss, level, or loaded-actor gates"
    }
}
if (-not [regex]::IsMatch($StagedText, 'demoNativeRaidSafeMode\s*=\s*false')) {
    throw "B2 staging did not temporarily bypass the native-raid safe-mode guard"
}

New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
$PreStageCopy = Join-Path $OutputRoot "installed-config-before.lua"
Copy-Item -LiteralPath $TargetConfig -Destination $PreStageCopy
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($TargetConfig, $StagedText, $Utf8NoBom)

$TargetText = Get-Content -LiteralPath $TargetConfig -Raw -Encoding utf8
foreach ($EnabledPattern in @(
    'demoNativeRaidSafeMode\s*=\s*false',
    'worldBalance\s*=\s*\{.*?liveAudit\s*=\s*\{\s*enabled\s*=\s*true',
    'worldBalance\s*=\s*\{.*?palFactionRage\s*=\s*\{\s*enabled\s*=\s*true',
    'worldBalance\s*=\s*\{.*?palFactionRage\s*=\s*\{.*?liveAudit\s*=\s*\{\s*enabled\s*=\s*true',
    'worldBalance\s*=\s*\{.*?palFactionRage\s*=\s*\{.*?liveAudit\s*=\s*\{.*?probe\s*=\s*\{\s*enabled\s*=\s*true'
)) {
    if (-not [regex]::IsMatch(
        $TargetText,
        $EnabledPattern,
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )) {
        throw "Installed B2 staging gate did not enable"
    }
}

[ordered]@{
    schemaVersion = "1.0.0"
    stagedAt = (Get-Date).ToString("o")
    result = "PASS"
    demoNativeRaidSafeMode = $false
    safeModeBypassScope = "B2-live-test-only"
    targetLevel = 80
    levelOverride = $false
    worldLiveAudit = $true
    bossProbe = $false
    palFactionRage = $true
    rageLiveAudit = $true
    rageProbe = $true
    rageProbeKey = "F7"
    rageProbeCharacter = "PinkCat"
    rageProbeLevel = 80
    loadedActorReconcile = $false
    broadActorScan = $false
    rageProbeSaveWrites = $false
    formalSourceSha256 = $SourceHash.ToLowerInvariant()
    stagedTargetSha256 = (Get-FileHash -LiteralPath $TargetConfig -Algorithm SHA256).Hash.ToLowerInvariant()
    installedConfigBeforeSha256 = (Get-FileHash -LiteralPath $PreStageCopy -Algorithm SHA256).Hash.ToLowerInvariant()
} | ConvertTo-Json -Depth 4 |
    Set-Content -LiteralPath (Join-Path $OutputRoot "staging-manifest.json") -Encoding utf8

Write-Host "PASS staged B2 Pal-faction rage live test"
Write-Host "Pal rage/readback: enabled; controlled PinkCat probe: F7"
Write-Host "Native-raid safe mode: disabled for this staged B2 run only"
Write-Host "Level override: disabled; Boss probe: disabled; loaded reconciliation: disabled"
Write-Host "Output: $OutputRoot"
