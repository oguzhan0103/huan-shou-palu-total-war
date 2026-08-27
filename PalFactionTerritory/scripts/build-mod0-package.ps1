param(
    [string]$OutputRoot = "",
    [string]$ReleaseVersion = "1.0.6"
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

if ($ReleaseVersion -notmatch '^\d+\.\d+\.\d+$') {
    throw "ReleaseVersion must use semantic x.y.z form."
}
$ReleaseName = "PalFactionTerritory0-v$ReleaseVersion-build24575825-runtime-source"
$OutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)
New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
$StageRoot = Join-Path $OutputRoot "$ReleaseName-staging"
$ZipPath = Join-Path $OutputRoot "$ReleaseName.zip"
$HashPath = "$ZipPath.sha256.json"

foreach ($Path in @($StageRoot, $ZipPath, $HashPath)) {
    $ResolvedPath = [System.IO.Path]::GetFullPath($Path)
    $ExpectedPrefix = $OutputRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if (-not $ResolvedPath.StartsWith($ExpectedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to clean candidate output outside the selected release directory: $ResolvedPath"
    }
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $ResolvedPath -Recurse -Force
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
$StagedCompanion = Join-Path $StageRoot "Companion"
Copy-Item -LiteralPath (Join-Path $ProjectRoot "companion") `
    -Destination $StagedCompanion -Recurse
Copy-Item -LiteralPath (Join-Path $ProjectRoot "INSTALL.md") `
    -Destination (Join-Path $StageRoot "INSTALL.md")
$StagedCommunityTools = Join-Path $StageRoot "CommunityTestTools"
New-Item -ItemType Directory -Path $StagedCommunityTools -Force | Out-Null
$CommunityToolFiles = @(Get-ChildItem -LiteralPath `
    (Join-Path $ProjectRoot "community-test-tools") -File)
$CommunityToolNames = @($CommunityToolFiles | ForEach-Object { $_.Name })
foreach ($CommunityTool in $CommunityToolFiles) {
    Copy-Item -LiteralPath $CommunityTool.FullName `
        -Destination (Join-Path $StagedCommunityTools $CommunityTool.Name)
}
$ReadmeCandidates = @(
    Get-ChildItem -LiteralPath $ProjectRoot -File -Filter "*v$ReleaseVersion*.md"
)
if ($ReadmeCandidates.Count -ne 1) {
    throw "Expected exactly one v$ReleaseVersion player guide at the project root."
}
$ReadmeFirst = $ReadmeCandidates[0].FullName
$ReadmeFirstName = $ReadmeCandidates[0].Name
Copy-Item -LiteralPath $ReadmeFirst `
    -Destination (Join-Path $StageRoot $ReadmeFirstName)

$PlayerToolsRoot = Join-Path $ProjectRoot "player-tools"
$PlayerToolFiles = @(Get-ChildItem -LiteralPath $PlayerToolsRoot -File)
if ($PlayerToolFiles.Count -ne 4) {
    throw "Expected four reviewed player-tool files, found $($PlayerToolFiles.Count)."
}
$PlayerToolNames = @($PlayerToolFiles | ForEach-Object { $_.Name })
foreach ($PlayerTool in $PlayerToolFiles) {
    Copy-Item -LiteralPath $PlayerTool.FullName `
        -Destination (Join-Path $StageRoot $PlayerTool.Name)
}
$StagedContracts = Join-Path $StageRoot "AuthorSDK\contracts"
New-Item -ItemType Directory -Path $StagedContracts -Force | Out-Null
foreach ($ContractFile in Get-ChildItem -LiteralPath `
    (Join-Path $ProjectRoot "contracts") -Filter "*.json" -File) {
    Copy-Item -LiteralPath $ContractFile.FullName -Destination $StagedContracts
}

& (Join-Path $StagedAuthorSdkRoot "validate-content-pack.ps1") -PackPath $StagedAuthorSdk
if ($LASTEXITCODE -ne 0) {
    throw "Staged Author SDK validation failed; package was not created."
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
    releaseId = "PalFactionTerritory0-v$ReleaseVersion-runtime-source"
    releaseVersion = $ReleaseVersion
    expectedSteamBuildId = "24575825"
    installRelativeRoot = "Pal/Binaries/Win64/ue4ss"
    sourceOnly = $true
    cookedAssetsIncluded = $false
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
        "Mods/PalFactionTerritory0/Scripts/pwft/attendance_raid_result_bridge.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/background_raid_recorder.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/commerce_bridge.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/companion_ledger.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/config.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/content_action_runtime.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/content_pack_registry.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/content_runtime.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/content_module_loader.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/localization_runtime.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/ending_runtime.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/ending_effect_provider_bus.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/ending_effect_native_production.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/faction_api.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/faction_commerce.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/faction_defense.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/faction_economy.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/faction_economy_war.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/faction_economy_merchant_runtime.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/faction_economy_shop_catalog.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/faction_guard.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/faction_join.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/faction_join_native_presenter.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/faction_join_native_router.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/faction_npc_attitude_bus.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/faction_npc_attitude_native_production.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/faction_merchant_runtime.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/faction_progression.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/faction_resource_ledger.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/faction_ui_model.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/faction_ui_presenter.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/json.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/human_defense_result_bridge.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/native_character_adapter.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/multiplayer_profile_authority.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/multiplayer_native_binding.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/multiplayer_player_services.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/multiplayer_read_model.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/npc_leader_guard_orchestrator.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/npc_leader_guard_native_production.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/pal_discourse_runtime.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/pal_raid_result_adapter.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/pal_raid_native_binding.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/pal_reconciliation.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/pal_representative_interaction.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/pal_representative_native_router.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/policy.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/progression_store.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/quest_runtime.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/quest_objective_schema.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/quest_objective_router.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/registry.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/reward_policy.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/reward_delivery_bus.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/reward_item_native_adapter.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/runtime.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/settlement_raid.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/strategic_world_native_bus.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/strategic_world_native_production.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/strategic_world.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/unique_pal_campaign.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/unique_pal_boss_provider_bus.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/unique_pal_boss_native_production.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/unique_pal_world_effect_bus.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/unique_pal_world_effect_native_production.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/unique_pal_native_delivery_bridge.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft/unique_pal_ransom_shop_bridge.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft_b7_unique_pals/content_module.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft_b7_unique_pals/unique_pal_campaign.lua",
        "Mods/PalFactionTerritory0/Scripts/pwft_b7_unique_pals/world_effect_bindings.lua",
        "AuthorSDK/contracts/content_pack.v1.json",
        "AuthorSDK/contracts/content_bundle.v1.json",
        "AuthorSDK/contracts/pal_reconciliation.v1.json",
        "AuthorSDK/contracts/strategic_world.v1.json",
        "AuthorSDK/contracts/unique_pal_campaign.v1.json",
        "AuthorSDK/contracts/unique_pal_boss_provider.v1.json",
        "AuthorSDK/contracts/unique_pal_world_effects.v1.json",
        "AuthorSDK/contracts/unique_pal_native_assets.v1.json",
        "AuthorSDK/contracts/ending_routes.v1.json",
        "AuthorSDK/contracts/npc_leader_guard_native_production.v1.json",
        "AuthorSDK/contracts/reward_delivery_native.v1.json",
        "AuthorSDK/contracts/strategic_world_readiness.v1.json",
        "AuthorSDK/validate-content-pack.ps1",
        "AuthorSDK/validate_content_pack.lua",
        "AuthorSDK/minimal-content-pack/README.md",
        "AuthorSDK/minimal-content-pack/pack.lua",
        "AuthorSDK/minimal-content-pack/manifest.lua",
        "AuthorSDK/minimal-content-pack/localization_keys.lua",
        "AuthorSDK/minimal-content-pack/quest_template.lua",
        "AuthorSDK/minimal-content-pack/strategic_world.lua",
        "AuthorSDK/minimal-content-pack/unique_pal_campaign.lua",
        "AuthorSDK/minimal-content-pack/ending_routes.lua",
        "AuthorSDK/minimal-content-pack/pal_discourse.lua",
        "AuthorSDK/minimal-content-pack/localization_catalogs.lua",
        "AuthorSDK/minimal-content-pack/bundle.lua",
        "AuthorSDK/minimal-content-pack/content_module.lua",
        "Companion/start-companion.cmd",
        "Companion/pwft-companion.ps1",
        "Companion/public/index.html",
        "Companion/public/app.js",
        "Companion/public/styles.css",
        "INSTALL.md",
        "Quick-Uninstall-PalFactionTerritory.ps1",
        "Quick-Uninstall-PalFactionTerritory.cmd",
        "package-manifest.json"
    )
    $RequiredEntries += $PlayerToolNames
    $RequiredEntries += @($CommunityToolNames | ForEach-Object {
        "CommunityTestTools/$_"
    })
    $RequiredEntries += $ReadmeFirstName
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
