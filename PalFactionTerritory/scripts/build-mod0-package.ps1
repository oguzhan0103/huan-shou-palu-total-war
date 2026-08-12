param(
    [string]$OutputRoot = ""
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $ProjectRoot "artifacts\releases"
}

& (Join-Path $PSScriptRoot "verify-mod0.ps1")
if ($LASTEXITCODE -ne 0) {
    throw "Mod 0 verification failed; package was not created."
}

$ReleaseName = "PalFactionTerritory0-v1.0.2-build24575825"
$StageRoot = Join-Path $OutputRoot "$ReleaseName-staging"
$ZipPath = Join-Path $OutputRoot "$ReleaseName.zip"
$HashPath = "$ZipPath.sha256.json"

foreach ($Path in @($StageRoot, $ZipPath, $HashPath)) {
    if (Test-Path -LiteralPath $Path) {
        throw "Refusing to overwrite existing artifact: $Path"
    }
}

New-Item -ItemType Directory -Path (Join-Path $StageRoot "Mods") -Force | Out-Null
$SourceMod = Join-Path $ProjectRoot "mod0\ue4ss\PalFactionTerritory0"
$StagedMod = Join-Path $StageRoot "Mods\PalFactionTerritory0"
Copy-Item -LiteralPath $SourceMod -Destination $StagedMod -Recurse

$StagedAuthorSdk = Join-Path $StageRoot "AuthorSDK\minimal-content-pack"
New-Item -ItemType Directory -Path (Split-Path -Parent $StagedAuthorSdk) -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $ProjectRoot "examples\minimal-content-pack") -Destination $StagedAuthorSdk -Recurse
$StagedAuthorSdkRoot = Split-Path -Parent $StagedAuthorSdk
Copy-Item -LiteralPath (Join-Path $ProjectRoot "scripts\validate-content-pack.ps1") `
    -Destination (Join-Path $StagedAuthorSdkRoot "validate-content-pack.ps1")
Copy-Item -LiteralPath (Join-Path $ProjectRoot "tools\validate_content_pack.lua") `
    -Destination (Join-Path $StagedAuthorSdkRoot "validate_content_pack.lua")
$StagedContracts = Join-Path $StageRoot "AuthorSDK\contracts"
New-Item -ItemType Directory -Path $StagedContracts -Force | Out-Null
foreach ($ContractName in @(
    "content_pack.v1.json",
    "content_bundle.v1.json",
    "pal_reconciliation.v1.json",
    "strategic_world.v1.json",
    "ending_routes.v1.json"
)) {
    Copy-Item -LiteralPath (Join-Path $ProjectRoot "contracts\$ContractName") -Destination $StagedContracts
}

$ManifestFiles = @(
    Get-ChildItem -LiteralPath $StageRoot -Recurse -File |
        Sort-Object FullName |
        ForEach-Object {
            [ordered]@{
                path = $_.FullName.Substring($StageRoot.Length + 1).Replace("\", "/")
                bytes = $_.Length
                sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        }
)

$Manifest = [ordered]@{
    schemaVersion = "1.0.0"
    releaseId = "PalFactionTerritory0-v1.0.2"
    releaseVersion = "1.0.2"
    expectedSteamBuildId = "24575825"
    installRelativeRoot = "Pal/Binaries/Win64/ue4ss"
    safetyMode = "mod-owned-state-no-palworld-save-write"
    files = $ManifestFiles
}
$Manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $StageRoot "package-manifest.json") -Encoding UTF8

Compress-Archive -Path (Join-Path $StageRoot "*") -DestinationPath $ZipPath -CompressionLevel Optimal

Add-Type -AssemblyName System.IO.Compression.FileSystem
$Archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
try {
    $EntryNames = @($Archive.Entries | ForEach-Object { $_.FullName.Replace("\", "/") })
    $RequiredEntries = @(
        "Mods/PalFactionTerritory0/enabled.txt",
        "Mods/PalFactionTerritory0/Scripts/main.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/agent_dialogue_file_bridge.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/agent_dialogue_operator.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/commerce_bridge.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/config.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/content_pack_registry.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/content_runtime.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/content_module_loader.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/localization_runtime.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/ending_runtime.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/content_pack_registry.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/content_runtime.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/ending_runtime.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/faction_api.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/faction_commerce.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/faction_defense.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/faction_economy.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/faction_economy_merchant_runtime.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/faction_economy_shop_catalog.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/faction_guard.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/faction_join.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/faction_merchant_runtime.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/faction_progression.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/faction_ui_model.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/faction_ui_presenter.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/json.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/native_character_adapter.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/pal_discourse_runtime.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/pal_raid_result_adapter.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/pal_raid_native_binding.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/pal_reconciliation.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/policy.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/progression_store.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/quest_runtime.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/quest_runtime.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/registry.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/runtime.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/strategic_world.lua",
        "AuthorSDK/contracts/content_pack.v1.json",
        "AuthorSDK/contracts/content_bundle.v1.json",
        "AuthorSDK/contracts/pal_reconciliation.v1.json",
        "AuthorSDK/contracts/strategic_world.v1.json",
        "AuthorSDK/contracts/ending_routes.v1.json",
        "AuthorSDK/validate-content-pack.ps1",
        "AuthorSDK/validate_content_pack.lua",
        "AuthorSDK/minimal-content-pack/README.md",
        "AuthorSDK/minimal-content-pack/pack.lua",
        "AuthorSDK/minimal-content-pack/manifest.lua",
        "AuthorSDK/minimal-content-pack/localization_keys.lua",
        "AuthorSDK/minimal-content-pack/quest_template.lua",
        "AuthorSDK/minimal-content-pack/strategic_world.lua",
        "AuthorSDK/minimal-content-pack/ending_routes.lua",
        "AuthorSDK/minimal-content-pack/pal_discourse.lua",
        "AuthorSDK/minimal-content-pack/localization_catalogs.lua",
        "AuthorSDK/minimal-content-pack/bundle.lua",
        "AuthorSDK/minimal-content-pack/content_module.lua",
        "package-manifest.json"
    )
    foreach ($RequiredEntry in $RequiredEntries) {
        if ($EntryNames -notcontains $RequiredEntry) {
            throw "Package is missing required entry: $RequiredEntry"
        }
    }
}
finally {
    $Archive.Dispose()
}

$ZipHash = Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256
$HashRecord = [ordered]@{
    file = [System.IO.Path]::GetFileName($ZipPath)
    bytes = (Get-Item -LiteralPath $ZipPath).Length
    sha256 = $ZipHash.Hash.ToLowerInvariant()
}
$HashRecord | ConvertTo-Json | Set-Content -LiteralPath $HashPath -Encoding UTF8

Write-Host "PASS package structure: $ZipPath"
Write-Host "SHA256 $($HashRecord.sha256)"
