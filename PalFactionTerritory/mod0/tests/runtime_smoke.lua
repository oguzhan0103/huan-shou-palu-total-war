package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?/init.lua",
    package.path,
}, ";")

local commands = {}
local hooks = {}
local load_map_hook = nil
local load_map_pre_hook = nil

-- The blocker must not depend on scanning the global UObject list. The live
-- build proved that scan cannot see the active map confirmation.
function FindAllOf(_)
    return {}
end

function RegisterConsoleCommandGlobalHandler(name, callback)
    commands[name] = callback
end

function RegisterHook(path, callback, post_callback)
    hooks[path] = { callback = callback, postCallback = post_callback }
    return #hooks + 1, #hooks + 2
end

function RegisterLoadMapPostHook(callback)
    load_map_hook = callback
end

function RegisterLoadMapPreHook(callback)
    load_map_pre_hook = callback
end

local Config = require("pwft.config")
local Registry = require("pwft.registry")
local Policy = require("pwft.policy")
local Runtime = require("pwft.runtime")

-- Production keeps every world-balance capability disabled. Smoke the full
-- module only with explicit, test-local overrides.
Config.demoNativeRaidSafeMode = false
Config.worldBalance.levelOverride.enabled = true
Config.worldBalance.palFactionRage.enabled = true
Config.worldBalance.loadedActorReconcile.enabled = true
Config.factionProgression.persistence.rootPath =
    "mod0/ue4ss/PalFactionTerritory0/State"
Config.palReconciliation.agentBridge.rootPath =
    "C:/pwft-test/AgentDialogue"
Config.palReconciliation.agentBridge.operatorInputPath =
    "C:/pwft-test/pwft-agent-operator-input-v1.json"
Config.palReconciliation.agentBridge.operatorStatusPath =
    "C:/pwft-test/pwft-agent-operator-status-v1.json"
-- Runtime smoke has no sidecar directory or scheduler. Inject a filesystem
-- after construction through the public operator/bridge tests instead.
local state = Runtime.start(Config, Registry, Policy)

assert(state.mapMode == "Original")
assert(commands["pwft.status"] ~= nil)
assert(commands["pwft.map"] ~= nil)
assert(commands["pwft.relation"] ~= nil)
assert(commands["pwft.progress"] ~= nil)
assert(commands["pwft.factions"] ~= nil)
assert(commands["pwft.commerce"] ~= nil)
assert(commands["pwft.economy"] ~= nil)
assert(commands["pwft.merchant"] ~= nil)
assert(commands["pwft.region"] ~= nil)
assert(commands["pwft.place"] ~= nil)
assert(commands["pwft.danger"] ~= nil)
assert(commands["pwft.raid"] ~= nil)
assert(commands["pwft.dialogue"] ~= nil)
assert(hooks["/Script/Pal.PalUIWorldMap:CreateWorldMapData"] ~= nil)
assert(hooks["/Game/Pal/Blueprint/UI/UserInterface/InGame/PlaceName/WBP_IngamePlaceName.WBP_IngamePlaceName_C:Display Region"] ~= nil)
assert(hooks["/Game/Pal/Blueprint/UI/UserInterface/Map/WBP_Map_IconFTTower.WBP_Map_IconFTTower_C:ClickEvent"] ~= nil)
assert(hooks["/Game/Pal/Blueprint/UI/UserInterface/Map/WBP_Map_Base.WBP_Map_Base_C:On Icon Clicked"] ~= nil)
assert(hooks["/Script/Pal.PalLocationPoint:InvokeFastTravel"] ~= nil)
assert(hooks["/Script/Pal.PalLocationPoint:IsEnableFastTravel"] ~= nil)
assert(hooks["/Script/Pal.PalLocationPoint:IsEnableFastTravel"].postCallback ~= nil)
assert(load_map_hook ~= nil)
assert(load_map_pre_hook ~= nil)
assert(state.callbacks.loadMapPre == load_map_pre_hook)
assert(state.callbacks.loadMapPost == load_map_hook)
assert(state.settlementRaid ~= nil)
assert(state.worldBalance ~= nil)
assert(state.settlementRaid.config.nearestPalFactionId == "pwft.faction.dark_nocturnal_pal_tribe")
assert(state.factionProgression ~= nil)
assert(state.palReconciliation ~= nil)
assert(state.palRaidResultAdapter ~= nil)
assert(state.palDiscourseRuntime ~= nil)
assert(state.palDialogueController ~= nil)
assert(state.palDialoguePresenter ~= nil)
assert(state.palRepresentativeInteraction ~= nil)
assert(state.agentDialogueFileBridge ~= nil)
assert(state.agentDialogueOperator ~= nil)
assert(state.palDialogueController:status().bridgeAvailable == true)
assert(state.factionApi ~= nil)
assert(state.factionResourceLedger ~= nil)
assert(state.factionEconomyWar ~= nil)
assert(state.rewardPolicy ~= nil)
assert(state.factionCommerce ~= nil)
assert(state.factionEconomy ~= nil)
assert(state.factionEconomyShops ~= nil)
assert(state.commerceBridge ~= nil)
assert(state.commerceWindowLiveTest == nil)
assert(state.hostileCommerceLiveTest == nil)
assert(state.strategicWorldNativeBus ~= nil)
assert(state.endingEffectProviderBus ~= nil)
assert(state.factionDefense ~= nil)
assert(state.factionGuard ~= nil)
assert(state.factionJoin ~= nil)
assert(state.factionJoinNativePresenter ~= nil)
assert(state.factionJoinNativeRouter ~= nil)
assert(state.factionMerchantRuntime ~= nil)
assert(state.nativeCharacterAdapter ~= nil)
assert(state.factionUiModel ~= nil)
assert(state.factionUiPresenter ~= nil)
assert(state.factionUiPresenter:status().key == "F5")
assert(state.factionUiPresenter:status().keyBound == false)
assert(state.factionUiPresenter:status().visible == false)
assert(state.progressionStore ~= nil)
assert(state.progressionStore:status().enabled == false)
assert(state.progressionStore:status().mode == "mod-sidecar-json")
assert(state.companionLedger ~= nil)
assert(state.companionLedger:status().enabled == true)
assert(state.companionLedger:status().active == false)
assert(state.backgroundRaidRecorder ~= nil)
assert(state.backgroundRaidRecorder:status().pendingCount == 0)
assert(state.progressionIdentity ~= nil)
assert(state.progressionIdentity.status == "waiting-for-world")
assert(state.progressionIdentity.readOnly == true)
assert(state.progressionIdentity.value == nil)
assert(
    state.progressionIdentity.sidecarRootPath
        == "mod0/ue4ss/PalFactionTerritory0/State"
)
assert(Config.factionProgression.persistence.enabled == true)
assert(Config.factionProgression.persistence.deferredIdentity == true)
assert(state.factionApi.version == "1.1.0")
assert(state.factionCommerce.version == "1.0.0")
assert(state.factionEconomy.version == "1.1.0")
assert(state.factionEconomyShops.version == "1.0.0")
assert(_G.PWFT_FACTION_API_V1 == state.factionApi)
assert(
    _G.PWFT_FACTION_CONSEQUENCE_API_V1
        == state.factionConsequenceRouter
)
assert(state.factionConsequenceRouter:status().apiVersion == "1.0.0")
assert(state.factionConsequenceRouter:status().providerCount == 3)
assert(state.factionConsequenceRouter:status().reasonRouteCount == 5)
assert(
    state.factionConsequenceRouter:status()
        .exactActorAndClassBinding == true
)
assert(
    state.factionConsequenceRouter:status()
        .nativeConfirmationRequired == true
)
assert(state.factionConsequenceRouter:status().modelMayDispatch == false)
assert(
    _G.PWFT_FACTION_CONSEQUENCE_NATIVE_BINDING_V1
        == state.factionConsequenceNativeBinding
)
assert(state.factionConsequenceNativeBindingStart.ok == true)
assert(
    state.factionConsequenceNativeBinding:status().hookReady
        == true
)
assert(
    state.factionConsequenceNativeBinding:status().sourceBuildId
        == "24370881"
)
assert(
    state.factionConsequenceNativeBinding:status()
        .currentHostBuildId == "24575825"
)
assert(
    state.factionConsequenceNativeBinding:status()
        .currentHostSignatureVerified == false
)
assert(
    state.factionConsequenceNativeBinding:status()
        .settlementEnabled == false
)
assert(
    state.factionConsequenceNativeBinding:status().broadActorScan
        == false
)
assert(
    hooks[
        "/Script/Pal.PalCharacterParameterComponent:OnDamage"
    ] ~= nil
)
assert(_G.PWFT_COMPANION_LEDGER_V1 == state.companionLedger)
assert(
    _G.PWFT_BACKGROUND_RAID_RECORDER_V1
        == state.backgroundRaidRecorder
)
assert(
    state.settlementRaid.backgroundRaidRecorder
        == state.backgroundRaidRecorder
)
assert(_G.PWFT_PAL_RECONCILIATION_API_V1 == state.palReconciliation)
assert(_G.PWFT_AGENT_DIALOGUE_BRIDGE_V1 == state.agentDialogueFileBridge)
assert(_G.PWFT_AGENT_DIALOGUE_OPERATOR_V1 == state.agentDialogueOperator)
assert(
    _G.PWFT_PAL_RAID_RESULT_ADAPTER_V1
        == state.palRaidResultAdapter
)
assert(
    _G.PWFT_PAL_DISCOURSE_API_V1
        == state.palDiscourseRuntime
)
assert(_G.PWFT_CONTENT_PACK_API_V1 == state.contentPackRegistry)
assert(_G.PWFT_CONTENT_RUNTIME_API_V1 == state.contentRuntime)
assert(_G.PWFT_QUEST_API_V1 == state.questRuntime)
assert(_G.PWFT_STRATEGIC_WORLD_API_V1 == state.strategicWorld)
assert(_G.PWFT_ENDING_API_V1 == state.endingRuntime)
assert(_G.PWFT_STRATEGIC_WORLD_NATIVE_BUS_V1
    == state.strategicWorldNativeBus)
assert(_G.PWFT_ENDING_EFFECT_PROVIDER_BUS_V1
    == state.endingEffectProviderBus)
assert(_G.PWFT_FACTION_RESOURCE_LEDGER_V1
    == state.factionResourceLedger)
assert(_G.PWFT_FACTION_ECONOMY_WAR_V1 == state.factionEconomyWar)
assert(_G.PWFT_REWARD_POLICY_V1 == state.rewardPolicy)
assert(state.factionResourceLedger:status().factionCount == 7)
assert(state.factionResourceLedger:status().resourceCount == 8)
assert(state.factionEconomyWar:status().conflictCount == 0)
assert(state.strategicWorldNativeBus:status().bindingCount == 0)
assert(state.endingEffectProviderBus:status().modelCommitAuthority == false)
assert(state.rewardPolicy:status().capabilities.modelAuthority == false)
assert(type(state.factionProgression.state.factionResourceLedger) == "table")
assert(type(state.factionProgression.state.factionEconomyWar) == "table")
assert(type(state.factionProgression.state.strategicWorldNativeBus) == "table")
assert(type(state.factionProgression.state.endingEffectProviderBus) == "table")
assert(type(state.factionProgression.state.rewardPolicy) == "table")
assert(_G.PWFT_FACTION_NPC_ATTITUDE_API_V1
    == state.factionNpcAttitudeBus)
assert(_G.PWFT_NPC_LEADER_GUARD_API_V1
    == state.npcLeaderGuardOrchestrator)
assert(state.strategicWorld:status().contentPackCount == 0)
assert(state.endingRuntime:status().routeCount == 0)
assert(state.contentPackRegistry:status().registeredPackCount == 0)
assert(state.contentRuntime:status().registeredBundleCount == 0)
assert(state.questRuntime:status().templateCount == 0)
assert(state.contentRuntime:status().rewardPolicyAtomicRegistration == true)
assert(_G.PWFT_JOIN_API_V1 == state.factionJoin)
assert(
    _G.PWFT_FACTION_JOIN_NATIVE_ROUTER_V1
        == state.factionJoinNativeRouter
)
assert(_G.PWFT_COMMERCE_API_V1 == state.factionCommerce)
assert(_G.PWFT_ECONOMY_API_V1 == state.factionEconomy)
assert(
    _G.PWFT_ECONOMY_SHOP_API_V1
        == state.factionEconomyShops
)
assert(_G.PWFT_COMMERCE_BRIDGE_V1 == state.commerceBridge)
assert(_G.PWFT_DEFENSE_API_V1 == state.factionDefense)
assert(_G.PWFT_GUARD_API_V1 == state.factionGuard)
assert(
    _G.PWFT_NATIVE_CHARACTER_ADAPTER_V1
        == state.nativeCharacterAdapter
)
assert(_G.PWFT_MERCHANT_RUNTIME_V1 == state.factionMerchantRuntime)
assert(
    _G.PWFT_ECONOMY_MERCHANT_RUNTIME_V1
        == state.factionEconomyMerchantRuntime
)
assert(
    _G.PWFT_ECONOMY_MERCHANT_PRESENCE_V1
        == state.factionEconomyMerchantPresence
)
assert(state.factionEconomyMerchantPresence:status().enabled == true)
assert(
    state.factionEconomyMerchantPresence:status().lastReason
        == "waiting-for-world"
)
assert(_G.PWFT_FACTION_UI_MODEL_V1 == state.factionUiModel)
assert(_G.PWFT_FACTION_UI_V1 == state.factionUiPresenter)
assert(
    state.palRaidResultAdapter:status()
        .normalizedRaidAdapterEnabled == true
)
assert(
    state.palRaidResultAdapter:status()
        .nativeRaidResultBindingEnabled == true
)
assert(
    state.palDiscourseRuntime:status()
        .registeredFactionCount == 0
)
assert(
    state.palDiscourseRuntime:status()
        .nativeDialoguePresenterEnabled == true
)
assert(
    _G.PWFT_PAL_DIALOGUE_CONTROLLER_V1
        == state.palDialogueController
)
assert(
    _G.PWFT_PAL_DIALOGUE_PRESENTER_V1
        == state.palDialoguePresenter
)
assert(
    _G.PWFT_PAL_REPRESENTATIVE_INTERACTION_V1
        == state.palRepresentativeInteraction
)
assert(state.palDialogueController:status().enabled == true)
assert(
    state.palDialogueController:status()
        .directAgentStateMutation == false
)
assert(
    state.palDialogueController:status()
        .offlineTreeFallback == true
)
assert(state.palDialoguePresenter:status().enabled == true)
assert(
    state.palDialoguePresenter:status()
        .nativePresenterEnabled == true
)
assert(
    state.palDialoguePresenter:status()
        .deterministicRuleEngineOwnsOutcome == true
)
assert(
    state.palRepresentativeInteraction:status().enabled == true
)
assert(
    state.palRepresentativeInteraction:status()
        .proximityGate == true
)
assert(
    state.palRepresentativeInteraction:status()
        .nativeDelegateBinding == false
)
assert(state.factionEconomy:status().closedLoopProductCount == 4)
assert(
    state.factionEconomy:status().merchantSuppliedInputProductCount == 5
)
assert(state.factionEconomy:status().unresolvedProductCount == 0)
assert(
    state.factionEconomy:status().balanceProfileId
        == "pwft.economy.balance.supply_band_v1"
)
assert(state.factionEconomy:status().balanceRuntimeAuthority == false)
assert(state.factionEconomy:status().customProductRowsEnabled == false)
assert(
    state.factionEconomyShops:status().representativeCount == 7
)
assert(state.factionEconomyShops:status().productRowCount == 26)
assert(
    state.factionEconomyShops:status().requestedItemCount == 37
)
assert(state.factionEconomyShops:status().marketSignalCount == 63)
assert(
    state.factionEconomyShops:status().customProductRowsReady
        == true
)
assert(
    state.factionEconomyShops:status().customProductRowsEnabled
        == true
)
assert(
    state.factionEconomyShops:status().nativeShopBindingEnabled
        == true
)
assert(
    state.factionEconomyShops:status()
        .procurementMoneyBonusEnabled
        == false
)
assert(state.factionJoin:status().sourceCount == 7)
assert(state.factionJoin:status().presenterReady == true)
assert(state.factionJoin:status().nativePresenter == true)
assert(
    state.factionJoinNativePresenter:status().native == true
)
assert(
    state.factionJoinNativeRouter:status().nativeHookReady == false
)
assert(state.factionJoinNativeRouter:status().bindingCount == 0)
assert(
    state.factionJoinNativeStartError
        == "RegisterKeyBind-unavailable"
)
assert(
    state.factionJoin:status(
        "pwft.join.source.rayne_syndicate"
    ).factionId
        == "pwft.faction.rayne_syndicate"
)
assert(hooks["/Script/Pal.PalNetworkShopComponent:SetupShopDataForActor_ToServer"] ~= nil)
assert(hooks["/Script/Pal.PalNetworkShopComponent:RequestBuyProduct_ToServer"] ~= nil)
assert(hooks["/Script/Pal.PalNetworkShopComponent:RecieveBuyResult_ToClient"] ~= nil)
assert(hooks["/Script/Pal.PalNetworkShopComponent:RequestSellItems_ToServer"] ~= nil)
assert(hooks["/Script/Pal.PalUIItemShopBase:TrySell"] ~= nil)
assert(hooks["/Script/Pal.PalUIItemShopBase:TrySell"].postCallback == nil)
assert(state.factionProgression:status("pwft.faction.rayne_syndicate").relation == "Friendly")
assert(state.factionProgression:status("pwft.faction.dark_nocturnal_pal_tribe").relation == "Hostile")

-- A5-A8 world-scoped native handles are fenced on unload. A6 replays the
-- committed ending through a stable generation ID and reports no-op when no
-- ending has been committed; the bus never invents a successful provider.
local generation_before = state.nativeWorldGeneration
local consequence_generation_before =
    state.factionConsequenceRouter:status().worldGeneration
load_map_pre_hook()
assert(state.nativeWorldGeneration == generation_before + 1)
assert(
    state.factionConsequenceRouter:status().worldGeneration
        == consequence_generation_before + 1
)
assert(state.inGameWorldReady == false)
assert(state.strategicWorldNativeBus:status().bindingCount == 0)
local presence_generation_after_unload =
    state.factionEconomyMerchantPresence.generation
load_map_hook()
-- Splash/Login/Title generations must not start any UObject-polling merchant
-- or tower callback. Only a successfully resolved in-game identity activates
-- those services.
assert(state.inGameWorldReady == false)
assert(
    state.factionEconomyMerchantPresence.generation
        == presence_generation_after_unload
)
assert(state.endingEffectProviderBus:status().replayCount == 0)
assert(hooks["/Script/Pal.PalUIWorldMap:CreateWorldMapData"].callback == state.hooks["/Script/Pal.PalUIWorldMap:CreateWorldMapData"].callback)
assert(hooks["/Game/Pal/Blueprint/UI/UserInterface/InGame/PlaceName/WBP_IngamePlaceName.WBP_IngamePlaceName_C:Display Region"].callback == state.hooks["/Game/Pal/Blueprint/UI/UserInterface/InGame/PlaceName/WBP_IngamePlaceName.WBP_IngamePlaceName_C:Display Region"].callback)
assert(hooks["/Game/Pal/Blueprint/UI/UserInterface/Map/WBP_Map_IconFTTower.WBP_Map_IconFTTower_C:ClickEvent"].callback == state.hooks["/Game/Pal/Blueprint/UI/UserInterface/Map/WBP_Map_IconFTTower.WBP_Map_IconFTTower_C:ClickEvent"].callback)
assert(hooks["/Game/Pal/Blueprint/UI/UserInterface/Map/WBP_Map_Base.WBP_Map_Base_C:On Icon Clicked"].callback == state.hooks["/Game/Pal/Blueprint/UI/UserInterface/Map/WBP_Map_Base.WBP_Map_Base_C:On Icon Clicked"].callback)
assert(hooks["/Script/Pal.PalLocationPoint:InvokeFastTravel"].callback == state.hooks["/Script/Pal.PalLocationPoint:InvokeFastTravel"].callback)
assert(hooks["/Script/Pal.PalLocationPoint:IsEnableFastTravel"].postCallback == state.hooks["/Script/Pal.PalLocationPoint:IsEnableFastTravel"].postCallback)

-- Read-only probes must stay inert when a build changes a hook parameter shape.
assert(pcall(function()
    hooks["/Script/Pal.PalUIWorldMap:CreateWorldMapData"].callback(nil, nil)
end))
assert(pcall(function()
    hooks["/Game/Pal/Blueprint/UI/UserInterface/Map/WBP_Map_IconFTTower.WBP_Map_IconFTTower_C:ClickEvent"].callback(nil)
end))
assert(pcall(function()
    hooks["/Game/Pal/Blueprint/UI/UserInterface/Map/WBP_Map_Base.WBP_Map_Base_C:On Icon Clicked"].callback(nil, nil)
end))
assert(pcall(function()
    hooks["/Script/Pal.PalLocationPoint:InvokeFastTravel"].callback(nil)
end))

-- The availability override is intentionally UI-free because Palworld calls
-- it for the complete map during refresh, not only for one clicked point.
assert(state.fastTravelToIsland["FTPoint21"] == "pwft.island.central_southeast_archipelago")
assert(state.fastTravelToIsland["WatchTower_1"] == "pwft.island.central_southeast_archipelago")
local function make_location_param(fast_travel_id)
    return {
        get = function()
            return {
                FastTravelPointID = fast_travel_id,
                IsValid = function() return true end,
            }
        end,
    }
end
local function make_bool_param(value)
    return { get = function() return value end }
end
local availability_post = hooks["/Script/Pal.PalLocationPoint:IsEnableFastTravel"].postCallback
local original_rayne_relation = state.relations["pwft.faction.rayne_syndicate"]
state.relations["pwft.faction.rayne_syndicate"] = {
    factionId = "pwft.faction.rayne_syndicate",
    state = "Hostile",
    revision = original_rayne_relation.revision + 1,
}
assert(availability_post(make_location_param("FTPoint21"), make_bool_param(true)) == false)
assert(state.fastTravelAvailabilityDeniedCount == 1)
assert(state.dangerWarningCount == 0)

state.relations["pwft.faction.rayne_syndicate"] = {
    factionId = "pwft.faction.rayne_syndicate",
    state = "Friendly",
    revision = original_rayne_relation.revision + 1,
}
assert(availability_post(make_location_param("FTPoint21"), make_bool_param(true)) == nil)
state.relations["pwft.faction.rayne_syndicate"] = original_rayne_relation
assert(state.dangerWarningCount == 0)

-- A mapped native RegionNameID colors the one existing place-name card with
-- the configured post-main-story Friendly relation. The two calls are the original
-- display dispatch plus one animation refresh, not a polling loop.
Registry.regionNameIdToIsland["PWFT_TestRegion"] = "pwft.island.central_southeast_archipelago"
local function valid_widget(name)
    return {
        IsValid = function()
            return true
        end,
        GetFullName = function()
            return name
        end,
    }
end
local place_text = valid_widget("Text_RegionName")
function place_text:SetColorAndOpacity(color)
    self.lastColor = color
end
local place_widget = valid_widget("WBP_IngamePlaceName_C")
place_widget.CachedRegionNameID = "PWFT_TestRegion"
place_widget.Text_RegionName = place_text
for _, image_name in ipairs({
    "Base", "BaseLineC", "BaseLineC_1", "BaseLineL", "BaseLineL_1",
    "BaseLineR", "BaseLineR_1", "Flare",
}) do
    local image = valid_widget(image_name)
    function image:SetColorAndOpacity(color)
        self.lastColor = color
    end
    place_widget[image_name] = image
end
local place_context = { get = function() return place_widget end }
local region_name_param = { get = function() return "PWFT_TestRegion" end }
assert(pcall(function()
    hooks["/Game/Pal/Blueprint/UI/UserInterface/InGame/PlaceName/WBP_IngamePlaceName.WBP_IngamePlaceName_C:Display Region"].callback(
        place_context,
        region_name_param
    )
end))
assert(state.placeNameDisplayCount == 1)
assert(state.placeNamePresentationCount == 2)
assert(place_text.lastColor.SpecifiedColor.B > 0.75)
assert(place_text.lastColor.SpecifiedColor.R < 0.50)
assert(place_widget.Base.lastColor.B > 0.75)
assert(place_widget.Base.lastColor.R < 0.50)

local output = { messages = {} }
function output:Log(message)
    table.insert(self.messages, message)
end

assert(commands["pwft.map"]("pwft.map human", { "pwft.map", "human" }, output) == true)
assert(state.mapMode == "Human")
assert(commands["pwft.map"]("pwft.map pal", { "pwft.map", "pal" }, output) == true)
assert(state.mapMode == "Pal")
assert(commands["pwft.relation"](
    "pwft.relation pwft.faction.rayne_syndicate Hostile",
    { "pwft.relation", "pwft.faction.rayne_syndicate", "Hostile" },
    output
) == true)
assert(state.relations["pwft.faction.rayne_syndicate"].state == "Hostile")
assert(state.relations["pwft.faction.free_pal_alliance"].state == "Friendly")
assert(commands["pwft.region"]("pwft.region M-A", { "pwft.region", "M-A" }, output) == true)
assert(commands["pwft.place"]("pwft.place PWFT_TestRegion", { "pwft.place", "PWFT_TestRegion" }, output) == true)
assert(commands["pwft.status"]("pwft.status", { "pwft.status" }, output) == true)
assert(commands["pwft.progress"](
    "pwft.progress gate",
    { "pwft.progress", "gate" },
    output
) == true)
assert(string.find(output.messages[#output.messages], "missingHumanLords=7", 1, true) ~= nil)
assert(commands["pwft.commerce"](
    "pwft.commerce status",
    { "pwft.commerce", "status" },
    output
) == true)
assert(
    string.find(
        output.messages[#output.messages],
        "requestSource=faction-economy-commodity-signals-v1",
        1,
        true
    ) ~= nil
)
assert(
    string.find(
        output.messages[#output.messages],
        "guildAuthorised=true guildCounters=0",
        1,
        true
    ) ~= nil
)
assert(commands["pwft.commerce"](
    "pwft.commerce faction pwft.faction.free_pal_alliance",
    {
        "pwft.commerce",
        "faction",
        "pwft.faction.free_pal_alliance",
    },
    output
) == true)
assert(
    string.find(
        output.messages[#output.messages],
        "shop=PFT_Economy_FPA",
        1,
        true
    ) ~= nil
)
assert(
    string.find(
        output.messages[#output.messages],
        "palMerchantSpecial=false",
        1,
        true
    ) ~= nil
)
assert(commands["pwft.economy"](
    "pwft.economy status",
    { "pwft.economy", "status" },
    output
) == true)
assert(
    string.find(
        output.messages[#output.messages],
        "customRowsReady=true customRows=false",
        1,
        true
    ) ~= nil
)
assert(commands["pwft.economy"](
    "pwft.economy shop pwft.faction.rayne_syndicate",
    {
        "pwft.economy",
        "shop",
        "pwft.faction.rayne_syndicate",
    },
    output
) == true)
assert(
    string.find(
        output.messages[#output.messages],
        "character=NPC_Male_Trader01_v10",
        1,
        true
    ) ~= nil
)
assert(
    string.find(
        output.messages[#output.messages],
        "rowsReady=true rowsEnabled=true binding=true",
        1,
        true
    ) ~= nil
)
assert(commands["pwft.merchant"](
    "pwft.merchant status",
    { "pwft.merchant", "status" },
    output
) == true)
assert(string.find(output.messages[#output.messages], "shopRow=PFT_Rayne_AllPaldex", 1, true) ~= nil)
assert(#output.messages >= 9)

print("PASS Lua runtime smoke (startup, hooks, commands, safety gates)")
