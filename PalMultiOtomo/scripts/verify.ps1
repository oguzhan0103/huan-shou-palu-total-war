$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$ModRoot = Join-Path $ProjectRoot "mod0\ue4ss\PalMultiOtomo0"
$RequiredFiles = @(
    "enabled.txt",
    "Scripts\main.lua",
    "Scripts\pmo\config.lua",
    "Scripts\pmo\runtime.lua"
)

foreach ($RelativePath in $RequiredFiles) {
    $Path = Join-Path $ModRoot $RelativePath
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required Mod file missing: $Path"
    }
}

$LuaFiles = Get-ChildItem -LiteralPath (Join-Path $ModRoot "Scripts") -Recurse -Filter *.lua -File
foreach ($LuaFile in $LuaFiles) {
    & npx --offline --yes luaparse@0.3.1 --quiet --file $LuaFile.FullName
    if ($LASTEXITCODE -ne 0) {
        throw "Lua syntax check failed: $($LuaFile.FullName)"
    }
}

Push-Location $ProjectRoot
try {
    & npx --offline --yes --package=fengari-node-cli@0.1.0 fengari "mod0/tests/runtime_smoke.lua"
    if ($LASTEXITCODE -ne 0) {
        throw "Lua runtime smoke test failed"
    }
}
finally {
    Pop-Location
}

$RuntimePath = Join-Path $ModRoot "Scripts\pmo\runtime.lua"
$ConfigPath = Join-Path $ModRoot "Scripts\pmo\config.lua"
$RuntimeText = Get-Content -LiteralPath $RuntimePath -Raw
$ConfigText = Get-Content -LiteralPath $ConfigPath -Raw
if ($ConfigText -notmatch 'expectedSteamBuildId\s*=\s*"24467282"') {
    throw "PalMultiOtomo0 config must target Steam Build 24467282."
}
if ($RuntimeText -match "RegisterHook\s*\(") {
    throw "Prototype must not register runtime hooks."
}
if ($RuntimeText -match "LoopAsync\s*\(") {
    throw "Prototype must not create an async polling loop."
}
if ($RuntimeText -match "InactivateAllOtomo") {
    throw "Prototype must never use the all-Pal recall fallback."
}
if ($RuntimeText -notmatch [regex]::Escape('Inactivate Otomo By Handle')) {
    throw "Single-Pal recall function is missing."
}

Write-Host "PASS PalMultiOtomo0 offline verification"
Write-Host "LuaFiles: $($LuaFiles.Count)"
Write-Host "RuntimeSHA256: $((Get-FileHash -LiteralPath $RuntimePath -Algorithm SHA256).Hash)"
