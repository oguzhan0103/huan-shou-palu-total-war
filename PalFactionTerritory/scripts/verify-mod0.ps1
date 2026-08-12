$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $PSScriptRoot

& python (Join-Path $ProjectRoot "tools\generate_mod0_registry.py") --check
if ($LASTEXITCODE -ne 0) { throw "Registry generation check failed" }
& python (Join-Path $ProjectRoot "tools\generate_pal_faction_mask.py") --check
if ($LASTEXITCODE -ne 0) { throw "Pal-faction mask generation check failed" }
& python (Join-Path $ProjectRoot "tools\verify_mod0.py")
if ($LASTEXITCODE -ne 0) { throw "Mod 0 structural verification failed" }

# The workspace verifier parses every shipped Lua source and discovers every
# Lua test dynamically.  Running the pinned local Node entry directly avoids
# hundreds of npx subprocesses and guarantees that newly added contract tests
# (such as the companion ledger) cannot be omitted from this release gate.
$WorkspaceRoot = Split-Path -Parent $ProjectRoot
& node (Join-Path $WorkspaceRoot "tools\verify-public.mjs")
if ($LASTEXITCODE -ne 0) { throw "Public Lua verification failed" }
return

$LuaFiles = @(
    Get-ChildItem -LiteralPath (Join-Path $ProjectRoot "mod0\ue4ss\PalFactionTerritory0\Scripts") -Recurse -Filter *.lua -File
    Get-ChildItem -LiteralPath (Join-Path $ProjectRoot "examples\minimal-content-pack") -Recurse -Filter *.lua -File
)
foreach ($LuaFile in $LuaFiles) {
    # Validation packages are already pinned in the local npm cache.  Keeping
    # this offline makes a mod deployment independent of the Steam/proxy
    # connection state and prevents an otherwise-valid script check hanging.
    & npx.cmd --offline --yes luaparse@0.3.1 --quiet --file $LuaFile.FullName
    if ($LASTEXITCODE -ne 0) {
        throw "Lua syntax check failed: $($LuaFile.FullName)"
    }
}

Push-Location $ProjectRoot
try {
    $JsonOutput = & npx.cmd --offline --yes --package=fengari-node-cli@0.1.0 fengari "mod0/tests/json_spec.lua" 2>&1
    $JsonExitCode = $LASTEXITCODE
    $JsonOutput | Write-Output
    $JsonText = $JsonOutput -join "`n"
    if ($JsonExitCode -ne 0 -or $JsonText -match "(?im)assertion failed|stack traceback:") {
        throw "Lua JSON codec test failed"
    }

    $StoreOutput = & npx.cmd --offline --yes --package=fengari-node-cli@0.1.0 fengari "mod0/tests/progression_store_spec.lua" 2>&1
    $StoreExitCode = $LASTEXITCODE
    $StoreOutput | Write-Output
    $StoreText = $StoreOutput -join "`n"
    if ($StoreExitCode -ne 0 -or $StoreText -match "(?im)assertion failed|stack traceback:") {
        throw "Lua progression sidecar store test failed"
    }

    $CompanionOutput = & npx.cmd --offline --yes --package=fengari-node-cli@0.1.0 fengari "mod0/tests/companion_ledger_spec.lua" 2>&1
    $CompanionExitCode = $LASTEXITCODE
    $CompanionOutput | Write-Output
    $CompanionText = $CompanionOutput -join "`n"
    if ($CompanionExitCode -ne 0 -or $CompanionText -match "(?im)assertion failed|stack traceback:") {
        throw "Lua external companion ledger test failed"
    }

    $IdentityOutput = & npx.cmd --offline --yes --package=fengari-node-cli@0.1.0 fengari "mod0/tests/progression_identity_spec.lua" 2>&1
    $IdentityExitCode = $LASTEXITCODE
    $IdentityOutput | Write-Output
    $IdentityText = $IdentityOutput -join "`n"
    if ($IdentityExitCode -ne 0 -or $IdentityText -match "(?im)assertion failed|stack traceback:") {
        throw "Lua progression identity test failed"
    }

    $PolicyOutput = & npx.cmd --offline --yes --package=fengari-node-cli@0.1.0 fengari "mod0/tests/policy_spec.lua" 2>&1
    $PolicyExitCode = $LASTEXITCODE
    $PolicyOutput | Write-Output
    $PolicyText = $PolicyOutput -join "`n"
    if ($PolicyExitCode -ne 0 -or $PolicyText -match "(?im)assertion failed|stack traceback:") {
        throw "Lua policy test failed"
    }

    $ProgressionOutput = & npx.cmd --offline --yes --package=fengari-node-cli@0.1.0 fengari "mod0/tests/faction_progression_spec.lua" 2>&1
    $ProgressionExitCode = $LASTEXITCODE
    $ProgressionOutput | Write-Output
    $ProgressionText = $ProgressionOutput -join "`n"
    if ($ProgressionExitCode -ne 0 -or $ProgressionText -match "(?im)assertion failed|stack traceback:") {
        throw "Lua faction progression test failed"
    }

    $PalReconciliationOutput = & npx.cmd --offline --yes --package=fengari-node-cli@0.1.0 fengari "mod0/tests/pal_reconciliation_spec.lua" 2>&1
    $PalReconciliationExitCode = $LASTEXITCODE
    $PalReconciliationOutput | Write-Output
    $PalReconciliationText = $PalReconciliationOutput -join "`n"
    if ($PalReconciliationExitCode -ne 0 -or $PalReconciliationText -match "(?im)assertion failed|stack traceback:") {
        throw "Lua finite Pal token and discourse reconciliation test failed"
    }

    $PalRaidAdapterOutput = & npx.cmd --offline --yes --package=fengari-node-cli@0.1.0 fengari "mod0/tests/pal_raid_result_adapter_spec.lua" 2>&1
    $PalRaidAdapterExitCode = $LASTEXITCODE
    $PalRaidAdapterOutput | Write-Output
    $PalRaidAdapterText = $PalRaidAdapterOutput -join "`n"
    if ($PalRaidAdapterExitCode -ne 0 -or $PalRaidAdapterText -match "(?im)assertion failed|stack traceback:") {
        throw "Lua authoritative Pal raid-result adapter test failed"
    }

    $PalDiscourseOutput = & npx.cmd --offline --yes --package=fengari-node-cli@0.1.0 fengari "mod0/tests/pal_discourse_runtime_spec.lua" 2>&1
    $PalDiscourseExitCode = $LASTEXITCODE
    $PalDiscourseOutput | Write-Output
    $PalDiscourseText = $PalDiscourseOutput -join "`n"
    if ($PalDiscourseExitCode -ne 0 -or $PalDiscourseText -match "(?im)assertion failed|stack traceback:") {
        throw "Lua offline Pal discourse-tree runtime test failed"
    }

    $PalDialogueControllerOutput = & npx.cmd --offline --yes --package=fengari-node-cli@0.1.0 fengari "mod0/tests/pal_dialogue_controller_spec.lua" 2>&1
    $PalDialogueControllerExitCode = $LASTEXITCODE
    $PalDialogueControllerOutput | Write-Output
    $PalDialogueControllerText = $PalDialogueControllerOutput -join "`n"
    if ($PalDialogueControllerExitCode -ne 0 -or $PalDialogueControllerText -match "(?im)assertion failed|stack traceback:") {
        throw "Lua optional Agent Pal dialogue controller test failed"
    }

    foreach ($AgentTest in @(
        "mod0/tests/agent_dialogue_file_bridge_spec.lua",
        "mod0/tests/agent_dialogue_operator_spec.lua"
    )) {
        $AgentOutput = & npx.cmd --offline --yes --package=fengari-node-cli@0.1.0 fengari $AgentTest 2>&1
        $AgentExitCode = $LASTEXITCODE
        $AgentOutput | Write-Output
        $AgentText = $AgentOutput -join "`n"
        if ($AgentExitCode -ne 0 -or $AgentText -match "(?im)assertion failed|stack traceback:") {
            throw "Lua local Ollama Agent bridge test failed: $AgentTest"
        }
    }

    $PalDialoguePresenterOutput = & npx.cmd --offline --yes --package=fengari-node-cli@0.1.0 fengari "mod0/tests/pal_dialogue_presenter_spec.lua" 2>&1
    $PalDialoguePresenterExitCode = $LASTEXITCODE
    $PalDialoguePresenterOutput | Write-Output
    $PalDialoguePresenterText = $PalDialoguePresenterOutput -join "`n"
    if ($PalDialoguePresenterExitCode -ne 0 -or $PalDialoguePresenterText -match "(?im)assertion failed|stack traceback:") {
        throw "Lua Pal dialogue presentation router test failed"
    }

    $PalRepresentativeInteractionOutput = & npx.cmd --offline --yes --package=fengari-node-cli@0.1.0 fengari "mod0/tests/pal_representative_interaction_spec.lua" 2>&1
    $PalRepresentativeInteractionExitCode = $LASTEXITCODE
    $PalRepresentativeInteractionOutput | Write-Output
    $PalRepresentativeInteractionText = $PalRepresentativeInteractionOutput -join "`n"
    if ($PalRepresentativeInteractionExitCode -ne 0 -or $PalRepresentativeInteractionText -match "(?im)assertion failed|stack traceback:") {
        throw "Lua Pal representative proximity and interaction router test failed"
    }

    $ContentPackOutput = & npx.cmd --offline --yes --package=fengari-node-cli@0.1.0 fengari "mod0/tests/content_pack_registry_spec.lua" 2>&1
    $ContentPackExitCode = $LASTEXITCODE
    $ContentPackOutput | Write-Output
    $ContentPackText = $ContentPackOutput -join "`n"
    if ($ContentPackExitCode -ne 0 -or $ContentPackText -match "(?im)assertion failed|stack traceback:") {
        throw "Lua content-pack manifest registry test failed"
    }

    $QuestRuntimeOutput = & npx.cmd --offline --yes --package=fengari-node-cli@0.1.0 fengari "mod0/tests/quest_runtime_spec.lua" 2>&1
    $QuestRuntimeExitCode = $LASTEXITCODE
    $QuestRuntimeOutput | Write-Output
    $QuestRuntimeText = $QuestRuntimeOutput -join "`n"
    if ($QuestRuntimeExitCode -ne 0 -or $QuestRuntimeText -match "(?im)assertion failed|stack traceback:") {
        throw "Lua content-pack quest runtime test failed"
    }

    $StrategicWorldOutput = & npx.cmd --offline --yes --package=fengari-node-cli@0.1.0 fengari "mod0/tests/strategic_world_spec.lua" 2>&1
    $StrategicWorldExitCode = $LASTEXITCODE
    $StrategicWorldOutput | Write-Output
    $StrategicWorldText = $StrategicWorldOutput -join "`n"
    if ($StrategicWorldExitCode -ne 0 -or $StrategicWorldText -match "(?im)assertion failed|stack traceback:") {
        throw "Lua strategic world and unique Pal runtime test failed"
    }

    $EndingRuntimeOutput = & npx.cmd --offline --yes --package=fengari-node-cli@0.1.0 fengari "mod0/tests/ending_runtime_spec.lua" 2>&1
    $EndingRuntimeExitCode = $LASTEXITCODE
    $EndingRuntimeOutput | Write-Output
    $EndingRuntimeText = $EndingRuntimeOutput -join "`n"
    if ($EndingRuntimeExitCode -ne 0 -or $EndingRuntimeText -match "(?im)assertion failed|stack traceback:") {
        throw "Lua deterministic ending routes runtime test failed"
    }

    $ContentRuntimeOutput = & npx.cmd --offline --yes --package=fengari-node-cli@0.1.0 fengari "mod0/tests/content_runtime_spec.lua" 2>&1
    $ContentRuntimeExitCode = $LASTEXITCODE
    $ContentRuntimeOutput | Write-Output
    $ContentRuntimeText = $ContentRuntimeOutput -join "`n"
    if ($ContentRuntimeExitCode -ne 0 -or $ContentRuntimeText -match "(?im)assertion failed|stack traceback:") {
        throw "Lua atomic cross-domain content runtime test failed"
    }

    $AuthorSdkOutput = & npx.cmd --offline --yes --package=fengari-node-cli@0.1.0 fengari "mod0/tests/content_pack_author_sdk_e2e_spec.lua" 2>&1
    $AuthorSdkExitCode = $LASTEXITCODE
    $AuthorSdkOutput | Write-Output
    $AuthorSdkText = $AuthorSdkOutput -join "`n"
    if ($AuthorSdkExitCode -ne 0 -or $AuthorSdkText -match "(?im)assertion failed|stack traceback:") {
        throw "Lua minimal content-pack author SDK end-to-end test failed"
    }

    $FactionApiOutput = & npx.cmd --offline --yes --package=fengari-node-cli@0.1.0 fengari "mod0/tests/faction_api_spec.lua" 2>&1
    $FactionApiExitCode = $LASTEXITCODE
    $FactionApiOutput | Write-Output
    $FactionApiText = $FactionApiOutput -join "`n"
    if ($FactionApiExitCode -ne 0 -or $FactionApiText -match "(?im)assertion failed|stack traceback:") {
        throw "Lua faction content API test failed"
    }

    $FactionJoinOutput = & npx.cmd --offline --yes --package=fengari-node-cli@0.1.0 fengari "mod0/tests/faction_join_spec.lua" 2>&1
    $FactionJoinExitCode = $LASTEXITCODE
    $FactionJoinOutput | Write-Output
    $FactionJoinText = $FactionJoinOutput -join "`n"
    if ($FactionJoinExitCode -ne 0 -or $FactionJoinText -match "(?im)assertion failed|stack traceback:") {
        throw "Lua faction join interaction test failed"
    }

    $CommerceOutput = & npx.cmd --offline --yes --package=fengari-node-cli@0.1.0 fengari "mod0/tests/faction_commerce_spec.lua" 2>&1
    $CommerceExitCode = $LASTEXITCODE
    $CommerceOutput | Write-Output
    $CommerceText = $CommerceOutput -join "`n"
    if ($CommerceExitCode -ne 0 -or $CommerceText -match "(?im)assertion failed|stack traceback:") {
        throw "Lua faction commerce test failed"
    }

    $EconomyOutput = & npx.cmd --offline --yes --package=fengari-node-cli@0.1.0 fengari "mod0/tests/faction_economy_spec.lua" 2>&1
    $EconomyExitCode = $LASTEXITCODE
    $EconomyOutput | Write-Output
    $EconomyText = $EconomyOutput -join "`n"
    if ($EconomyExitCode -ne 0 -or $EconomyText -match "(?im)assertion failed|stack traceback:") {
        throw "Lua faction economy test failed"
    }

    $EconomyShopOutput = & npx.cmd --offline --yes --package=fengari-node-cli@0.1.0 fengari "mod0/tests/faction_economy_shop_catalog_spec.lua" 2>&1
    $EconomyShopExitCode = $LASTEXITCODE
    $EconomyShopOutput | Write-Output
    $EconomyShopText = $EconomyShopOutput -join "`n"
    if ($EconomyShopExitCode -ne 0 -or $EconomyShopText -match "(?im)assertion failed|stack traceback:") {
        throw "Lua faction economy shop catalog test failed"
    }

    $CommerceBridgeOutput = & npx.cmd --offline --yes --package=fengari-node-cli@0.1.0 fengari "mod0/tests/commerce_bridge_spec.lua" 2>&1
    $CommerceBridgeExitCode = $LASTEXITCODE
    $CommerceBridgeOutput | Write-Output
    $CommerceBridgeText = $CommerceBridgeOutput -join "`n"
    if ($CommerceBridgeExitCode -ne 0 -or $CommerceBridgeText -match "(?im)assertion failed|stack traceback:") {
        throw "Lua native commerce bridge test failed"
    }

    $FactionServicesOutput = & npx.cmd --offline --yes --package=fengari-node-cli@0.1.0 fengari "mod0/tests/faction_services_spec.lua" 2>&1
    $FactionServicesExitCode = $LASTEXITCODE
    $FactionServicesOutput | Write-Output
    $FactionServicesText = $FactionServicesOutput -join "`n"
    if ($FactionServicesExitCode -ne 0 -or $FactionServicesText -match "(?im)assertion failed|stack traceback:") {
        throw "Lua faction UI, defense, and guard services test failed"
    }

    $FactionUiPresenterOutput = & npx.cmd --offline --yes --package=fengari-node-cli@0.1.0 fengari "mod0/tests/faction_ui_presenter_spec.lua" 2>&1
    $FactionUiPresenterExitCode = $LASTEXITCODE
    $FactionUiPresenterOutput | Write-Output
    $FactionUiPresenterText = $FactionUiPresenterOutput -join "`n"
    if ($FactionUiPresenterExitCode -ne 0 -or $FactionUiPresenterText -match "(?im)assertion failed|stack traceback:") {
        throw "Lua faction UI native presenter adapter test failed"
    }

    $FactionMerchantRuntimeOutput = & npx.cmd --offline --yes --package=fengari-node-cli@0.1.0 fengari "mod0/tests/faction_merchant_runtime_spec.lua" 2>&1
    $FactionMerchantRuntimeExitCode = $LASTEXITCODE
    $FactionMerchantRuntimeOutput | Write-Output
    $FactionMerchantRuntimeText = $FactionMerchantRuntimeOutput -join "`n"
    if ($FactionMerchantRuntimeExitCode -ne 0 -or $FactionMerchantRuntimeText -match "(?im)assertion failed|stack traceback:") {
        throw "Lua fixed faction market and caravan runtime test failed"
    }

    $NativeCharacterAdapterOutput = & npx.cmd --offline --yes --package=fengari-node-cli@0.1.0 fengari "mod0/tests/native_character_adapter_spec.lua" 2>&1
    $NativeCharacterAdapterExitCode = $LASTEXITCODE
    $NativeCharacterAdapterOutput | Write-Output
    $NativeCharacterAdapterText = $NativeCharacterAdapterOutput -join "`n"
    if ($NativeCharacterAdapterExitCode -ne 0 -or $NativeCharacterAdapterText -match "(?im)assertion failed|stack traceback:") {
        throw "Lua inactive native character adapter test failed"
    }

    $MerchantOutput = & npx.cmd --offline --yes --package=fengari-node-cli@0.1.0 fengari "mod0/tests/rayne_merchant_spec.lua" 2>&1
    $MerchantExitCode = $LASTEXITCODE
    $MerchantOutput | Write-Output
    $MerchantText = $MerchantOutput -join "`n"
    if ($MerchantExitCode -ne 0 -or $MerchantText -match "(?im)assertion failed|stack traceback:") {
        throw "Lua Rayne merchant test failed"
    }

    $WorldBalanceOutput = & npx.cmd --offline --yes --package=fengari-node-cli@0.1.0 fengari "mod0/tests/world_balance_spec.lua" 2>&1
    $WorldBalanceExitCode = $LASTEXITCODE
    $WorldBalanceOutput | Write-Output
    $WorldBalanceText = $WorldBalanceOutput -join "`n"
    if ($WorldBalanceExitCode -ne 0 -or $WorldBalanceText -match "(?im)assertion failed|stack traceback:") {
        throw "Lua world-balance test failed"
    }

    $SettlementRaidOutput = & npx.cmd --offline --yes --package=fengari-node-cli@0.1.0 fengari "mod0/tests/settlement_raid_spec.lua" 2>&1
    $SettlementRaidExitCode = $LASTEXITCODE
    $SettlementRaidOutput | Write-Output
    $SettlementRaidText = $SettlementRaidOutput -join "`n"
    if ($SettlementRaidExitCode -ne 0 -or $SettlementRaidText -match "(?im)assertion failed|stack traceback:") {
        throw "Lua settlement-raid test failed"
    }

    $RuntimeOutput = & npx.cmd --offline --yes --package=fengari-node-cli@0.1.0 fengari "mod0/tests/runtime_smoke.lua" 2>&1
    $RuntimeExitCode = $LASTEXITCODE
    $RuntimeOutput | Write-Output
    $RuntimeText = $RuntimeOutput -join "`n"
    if ($RuntimeExitCode -ne 0 -or $RuntimeText -match "(?im)assertion failed|stack traceback:") {
        throw "Lua runtime smoke test failed"
    }
}
finally {
    Pop-Location
}
