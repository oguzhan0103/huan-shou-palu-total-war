param(
    [Parameter(Mandatory = $true)]
    [string]$PackPath
)

$ErrorActionPreference = "Stop"
$ScriptHome = $PSScriptRoot
if (-not (Test-Path -LiteralPath $PackPath -PathType Container)) {
    throw "Content-pack path is not a directory: $PackPath"
}
$ResolvedPack = (Resolve-Path -LiteralPath $PackPath).Path

$BundlePath = Join-Path $ResolvedPack "bundle.lua"
if (-not (Test-Path -LiteralPath $BundlePath -PathType Leaf)) {
    throw "Content pack is missing bundle.lua: $BundlePath"
}

$PackParent = Split-Path -Parent $ResolvedPack
$PackName = Split-Path -Leaf $ResolvedPack
$ModuleName = "$PackName.bundle"
$RepositoryRoot = Split-Path -Parent $ScriptHome
$LuaToolCandidates = @(
    (Join-Path $RepositoryRoot "tools\validate_content_pack.lua"),
    (Join-Path $ScriptHome "validate_content_pack.lua")
)
$CoreScriptCandidates = @(
    (Join-Path $RepositoryRoot "mod0\ue4ss\PalFactionTerritory0\Scripts"),
    (Join-Path (Split-Path -Parent $ScriptHome) "Mods\PalFactionTerritory0\Scripts")
)
$LuaTool = @($LuaToolCandidates | Where-Object {
    Test-Path -LiteralPath $_ -PathType Leaf
}) | Select-Object -First 1
$CoreScripts = @($CoreScriptCandidates | Where-Object {
    Test-Path -LiteralPath (Join-Path $_ "pwft\registry.lua") -PathType Leaf
}) | Select-Object -First 1
if ([string]::IsNullOrWhiteSpace($LuaTool)) {
    throw "Content-pack validator Lua entrypoint was not found"
}
if ([string]::IsNullOrWhiteSpace($CoreScripts)) {
    throw "PalFactionTerritory0 Core scripts were not found"
}

Push-Location $ScriptHome
try {
    & npx.cmd --offline --yes --package=fengari-node-cli@0.1.0 fengari `
        $LuaTool `
        ($CoreScripts.Replace("\", "/")) `
        ($PackParent.Replace("\", "/")) `
        $ModuleName
    if ($LASTEXITCODE -ne 0) {
        throw "Content-pack validation failed: $ResolvedPack"
    }
}
finally {
    Pop-Location
}
