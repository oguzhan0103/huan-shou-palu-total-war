package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local Registry = require("pwft.registry")
local FactionApi = require("pwft.faction_api")
local FactionEconomy = require("pwft.faction_economy")
local FactionEconomyShopCatalog =
    require("pwft.faction_economy_shop_catalog")
local FactionEconomyMerchantRuntime =
    require("pwft.faction_economy_merchant_runtime")
local FactionProgression = require("pwft.faction_progression")

local function copy(value)
    if type(value) ~= "table" then
        return value
    end
    local result = {}
    for key, item in pairs(value) do
        result[copy(key)] = copy(item)
    end
    return result
end

local economy = FactionEconomy.create(Registry.economy)
local shops = FactionEconomyShopCatalog.create(
    Registry.economyShops,
    economy
)
local api = FactionApi.create(
    FactionProgression.create(Registry.progression)
)
local registered = {}
local unregistered = {}
local bridge = {
    register_vendor_actor = function(
        _,
        faction_id,
        actor,
        metadata
    )
        registered[faction_id] = {
            actor = actor,
            metadata = metadata,
        }
        return true, "registered"
    end,
    unregister_vendor_actor = function(_, actor)
        table.insert(unregistered, actor)
        return true, "unregistered"
    end,
}

local pending = FactionEconomyMerchantRuntime.create(
    shops,
    Registry.commerce,
    api,
    bridge,
    nil,
    { activationAuthorized = false }
)
assert(pending:status().representativeCount == 7)
assert(pending:status().runtimeStatus
    == "disabled-pending-live-acceptance")
assert(pending.capabilities.sevenMerchantGuildCounters == true)
assert(pending.capabilities.raynePalMerchantExcluded == true)
assert(pending:activate_market(
    { X = 0, Y = 0, Z = 0 },
    { Pitch = 0, Yaw = 0, Roll = 0 }
).reason == "economy-market-runtime-disabled")

local root = { X = 1000, Y = 2000, Z = 300 }
local rotation = { Pitch = 0, Yaw = 90, Roll = 0 }
local plans = assert(pending:market_plan(root, rotation))
assert(#plans == 7)
local unique_rows = {}
local unique_factions = {}
for _, plan in ipairs(plans) do
    assert(unique_rows[plan.shopRowName] == nil)
    assert(unique_factions[plan.factionId] == nil)
    unique_rows[plan.shopRowName] = true
    unique_factions[plan.factionId] = true
end
assert(plans[1].salesChannel == "ItemShop")
assert(plans[1].shopRowName == "PFT_Economy_Rayne")
assert(plans[1].productGroupRowName
    == "PFT_Economy_Rayne_Products")
assert(plans[1].nativeSpawnerRequired == false)
assert(plans[1].npcManagerServerSpawnRequired == false)
assert(plans[1].provenNativeSpawnerRoute
    == "DirectDarkTraderDeferredActor")
assert(plans[1].merchantOrganisationId
    == "pwft.commerce.merchant_guild")
assert(plans[1].characterId == "NPC_Male_DarkTrader")
assert(string.find(
    plans[1].characterClassPath,
    "BP_NPC_DarkTrader_C",
    1,
    true
) ~= nil)
assert(string.find(
    plans[1].spawnerClassPath,
    "BP_MonoNPCSpawnerBossBase_BOSS_DarkTrader_C",
    1,
    true
) ~= nil)
local unique_save_keys = {}
for _, plan in ipairs(plans) do
    assert(unique_save_keys[plan.spawnerSaveKey] == nil)
    unique_save_keys[plan.spawnerSaveKey] = true
end
assert(math.floor(plans[2].location.X + 0.5) == 1600)
assert(math.floor(plans[2].location.Y + 0.5) == 2000)

local active_contract = copy(Registry.economyShops)
active_contract.runtimeActivation.customProductRowsEnabled = true
active_contract.runtimeActivation.nativeMerchantSpawnEnabled = true
active_contract.runtimeActivation.nativeShopBindingEnabled = true
local active_shops = FactionEconomyShopCatalog.create(
    active_contract,
    economy
)
local spawned = {}
local despawned = {}
local adapter = {
    spawn_merchant = function(_, plan)
        table.insert(spawned, plan)
        return "economy-actor:" .. plan.runtimeId
    end,
    refresh_merchant_shop = function()
        return true, "network-shop-rebound"
    end,
    despawn = function(_, actor)
        table.insert(despawned, actor)
        return true
    end,
}
local runtime = FactionEconomyMerchantRuntime.create(
    active_shops,
    Registry.commerce,
    api,
    bridge,
    adapter,
    { activationAuthorized = true }
)
local one = runtime:activate_faction(
    "pwft.faction.rayne_syndicate",
    root,
    rotation
)
assert(one.ok)
assert(one.reason == "economy-merchant-activated")
assert(#one.spawned == 1)
assert(runtime:status().activeCount == 1)
local duplicate = runtime:activate_faction(
    "pwft.faction.rayne_syndicate",
    root,
    rotation
)
assert(duplicate.ok)
assert(duplicate.reason == "economy-merchant-already-active")
assert(#duplicate.spawned == 0)
local removed_one = runtime:deactivate_faction(
    "pwft.faction.rayne_syndicate",
    "single-counter-test-complete"
)
assert(removed_one.ok)
assert(runtime:status().activeCount == 0)
spawned = {}
despawned = {}
unregistered = {}
local activated = runtime:activate_market(root, rotation)
assert(activated.ok)
assert(#activated.spawned == 7)
assert(#spawned == 7)
assert(runtime:status().activeCount == 7)
assert(runtime:status().ownedCount == 7)
assert(runtime:status().runtimeStatus
    == "ready-for-placement-adapter")
assert(
    registered["pwft.faction.rayne_syndicate"]
        .metadata.economyCatalogBinding
        == true
)
assert(
    registered["pwft.faction.rayne_syndicate"]
        .metadata.representedFactionId
        == "pwft.faction.rayne_syndicate"
)

local deactivated = runtime:deactivate_market("test-complete")
assert(deactivated.ok)
assert(#deactivated.removedFactionIds == 7)
assert(#despawned == 7)
assert(#unregistered == 7)
assert(runtime:status().activeCount == 0)

local rollback_spawn_count = 0
local rollback_despawned = {}
local rollback_unregistered = {}
local rollback_bridge = {
    register_vendor_actor = function()
        return true, "registered"
    end,
    unregister_vendor_actor = function(_, actor)
        table.insert(rollback_unregistered, actor)
        return true, "unregistered"
    end,
}
local rollback_adapter = {
    spawn_merchant = function(_, plan)
        rollback_spawn_count = rollback_spawn_count + 1
        if rollback_spawn_count == 4 then
            error("synthetic-fourth-counter-failure")
        end
        return "rollback-actor:" .. plan.runtimeId
    end,
    refresh_merchant_shop = function()
        return true, "network-shop-rebound"
    end,
    despawn = function(_, actor)
        table.insert(rollback_despawned, actor)
        return true
    end,
}
local rollback_runtime = FactionEconomyMerchantRuntime.create(
    active_shops,
    Registry.commerce,
    api,
    rollback_bridge,
    rollback_adapter,
    { activationAuthorized = true }
)
local rolled_back = rollback_runtime:activate_market(
    root,
    rotation
)
assert(not rolled_back.ok)
assert(rolled_back.reason == "economy-merchant-spawn-failed")
assert(rollback_runtime:status().rollbackCount == 1)
assert(rollback_runtime:status().activeCount == 0)
assert(#rollback_despawned == 3)
assert(#rollback_unregistered == 3)

-- The async lifecycle remains covered when an adapter explicitly enables it.
-- Registration happens before the post-registration shop refresh so commerce
-- hooks can bind the component.
local lifecycle = {}
local last_native_handle = nil
local native_bridge = {
    register_vendor_actor = function(_, faction_id, actor)
        table.insert(lifecycle, "register:" .. faction_id)
        return actor ~= nil, "registered"
    end,
    unregister_vendor_actor = function()
        table.insert(lifecycle, "unregister")
        return true, "unregistered"
    end,
}
local native_adapter = {
    asyncMerchantSpawnerEnabled = true,
    spawn_merchant = function()
        error("direct merchant spawn must not be used")
    end,
    spawn_merchant_async = function(_, plan, callbacks)
        table.insert(lifecycle, "native-spawner:" .. plan.characterId)
        local handle = { runtimeId = plan.runtimeId }
        last_native_handle = handle
        callbacks.onReady("native-actor:" .. plan.runtimeId, handle)
        return handle
    end,
    refresh_merchant_shop = function(_, actor, plan)
        table.insert(lifecycle, "refresh:" .. plan.shopRowName)
        assert(actor == "native-actor:" .. plan.runtimeId)
        return true, "network-shop-rebound"
    end,
    despawn = function(_, target)
        assert(target == last_native_handle)
        table.insert(lifecycle, "despawn-native-handle")
        return true
    end,
}
local native_runtime = FactionEconomyMerchantRuntime.create(
    active_shops,
    Registry.commerce,
    api,
    native_bridge,
    native_adapter,
    { activationAuthorized = true }
)
local native_outcome = native_runtime:activate_faction(
    "pwft.faction.rayne_syndicate",
    root,
    rotation
)
assert(native_outcome.ok)
assert(native_outcome.reason == "economy-merchant-activation-queued")
assert(native_runtime:status().activeCount == 1)
assert(string.find(lifecycle[1], "native-spawner:", 1, true) == 1)
assert(string.find(lifecycle[2], "register:", 1, true) == 1)
assert(lifecycle[3] == "refresh:PFT_Economy_Rayne")
local native_removed = native_runtime:deactivate_faction(
    "pwft.faction.rayne_syndicate",
    "native-reentry-test"
)
assert(native_removed.ok)
assert(lifecycle[#lifecycle] == "despawn-native-handle")
assert(native_runtime:status().activeCount == 0)
local native_reentered = native_runtime:activate_faction(
    "pwft.faction.rayne_syndicate",
    root,
    rotation
)
assert(native_reentered.ok)
assert(native_runtime:status().activeCount == 1)

local proven_spawner_route = nil
local manager_preferred_adapter = {
    asyncMerchantSpawnerEnabled = true,
    spawn_merchant_async = function(_, plan, callbacks)
        proven_spawner_route = plan.spawnerClassPath
        local handle = { runtimeId = plan.runtimeId }
        callbacks.onReady(
            "proven-spawner-actor:" .. plan.runtimeId,
            handle
        )
        return handle
    end,
    spawn_merchant_via_npc_manager = function()
        error("PalNPCManager route must not be selected")
    end,
    refresh_merchant_shop = function()
        return true, "network-shop-rebound"
    end,
    despawn = function()
        return true
    end,
}
local manager_runtime = FactionEconomyMerchantRuntime.create(
    active_shops,
    Registry.commerce,
    api,
    bridge,
    manager_preferred_adapter,
    { activationAuthorized = true }
)
local manager_outcome = manager_runtime:activate_faction(
    "pwft.faction.free_pal_alliance",
    root,
    rotation
)
assert(manager_outcome.ok)
assert(string.find(
    proven_spawner_route,
    "BP_MonoNPCSpawnerBossBase_BOSS_DarkTrader_C",
    1,
    true
) ~= nil)
assert(manager_runtime:status().activeCount == 1)

local market_spawn_rows = {}
local market_handle_despawns = 0
local market_adapter = {
    asyncMerchantSpawnerEnabled = true,
    spawn_merchant_async = function(_, plan, callbacks)
        assert(market_spawn_rows[plan.shopRowName] == nil)
        market_spawn_rows[plan.shopRowName] = plan.factionId
        local handle = {
            runtimeId = plan.runtimeId,
            factionId = plan.factionId,
        }
        callbacks.onReady(
            "market-native-actor:" .. plan.runtimeId,
            handle
        )
        return handle
    end,
    refresh_merchant_shop = function()
        return true, "network-shop-rebound"
    end,
    despawn = function(_, handle)
        assert(type(handle) == "table")
        assert(handle.factionId ~= nil)
        market_handle_despawns = market_handle_despawns + 1
        return true
    end,
}
local market_runtime = FactionEconomyMerchantRuntime.create(
    active_shops,
    Registry.commerce,
    api,
    bridge,
    market_adapter,
    { activationAuthorized = true }
)
local queued_market = market_runtime:activate_market(root, rotation)
assert(queued_market.ok)
assert(queued_market.reason == "economy-market-activation-queued")
assert(#queued_market.spawned == 7)
assert(market_runtime:status().activeCount == 7)
assert(market_runtime:status().pendingCount == 0)
local spawned_row_count = 0
for _, _ in pairs(market_spawn_rows) do
    spawned_row_count = spawned_row_count + 1
end
assert(spawned_row_count == 7)
local removed_market = market_runtime:deactivate_market(
    "seven-counter-reentry-test"
)
assert(removed_market.ok)
assert(#removed_market.removedFactionIds == 7)
assert(market_handle_despawns == 7)
assert(market_runtime:status().activeCount == 0)
market_spawn_rows = {}
local reentered_market = market_runtime:activate_market(root, rotation)
assert(reentered_market.ok)
assert(market_runtime:status().activeCount == 7)

local routed_player = {
    K2_GetActorLocation = function()
        return { X = 10, Y = 10, Z = 0 }
    end,
}
local routed_calls = 0
local routed_shop = {}
local routed_parameter = nil
local routed_parameter_spawns = 0
local routed_hud_pushes = 0
local routed_ui_id = { A = 1, B = 2, C = 3, D = 4 }
local saved_static_find_object = StaticFindObject
local saved_load_asset = LoadAsset
local routed_widget_class = {
    kind = "item-shop-widget-class",
    IsValid = function()
        return true
    end,
}
local routed_parameter_class = {
    kind = "item-shop-parameter-class",
    IsValid = function()
        return true
    end,
}
local routed_hud_service = {
    IsValid = function()
        return true
    end,
}
function routed_hud_service:Push(widget_class, parameter)
    assert(widget_class == routed_widget_class)
    assert(parameter == routed_parameter)
    assert(parameter.OpenTabType == 1)
    assert(parameter.shop == routed_shop)
    routed_hud_pushes = routed_hud_pushes + 1
    return routed_ui_id
end
local routed_utility = {
    IsValid = function()
        return true
    end,
}
function routed_utility:GetHUDService(context)
    assert(context == routed_player)
    return routed_hud_service
end
local routed_gameplay = {
    IsValid = function()
        return true
    end,
}
function routed_gameplay:SpawnObject(parameter_class, outer)
    assert(parameter_class == routed_parameter_class)
    assert(outer == routed_hud_service)
    routed_parameter_spawns = routed_parameter_spawns + 1
    routed_parameter = {
        IsValid = function()
            return true
        end,
    }
    return routed_parameter
end
StaticFindObject = function(path)
    if path:match("WBP_ItemShop_C$") then
        return routed_widget_class
    end
    if path:match("BP_PalUIDispatchParameter_ItemShop_C$") then
        return routed_parameter_class
    end
    if path == "/Script/Pal.Default__PalUtility" then
        return routed_utility
    end
    if path == "/Script/Engine.Default__GameplayStatics" then
        return routed_gameplay
    end
    return nil
end
LoadAsset = function()
    error("the native ItemShop classes are already present in this test")
end
local near_merchant = {
    K2_GetActorLocation = function()
        return { X = 40, Y = 10, Z = 0 }
    end,
}
near_merchant.BP_NPCInteractionComponent = {
    OnTriggerInteract = function(_, other, indicator_type)
        assert(other == routed_player)
        assert(indicator_type == 39)
        routed_calls = routed_calls + 1
    end,
}
near_merchant.BP_PalShopVenderDataComponent = {
    MyItemShop = routed_shop,
}
local far_merchant = {
    K2_GetActorLocation = function()
        return { X = 900, Y = 10, Z = 0 }
    end,
}
far_merchant.BP_NPCInteractionComponent = {
    OnTriggerInteract = function()
        error("out-of-range merchant must not receive interaction")
    end,
}
market_runtime.records["pwft.faction.rayne_syndicate"].actor =
    near_merchant
market_runtime.records["pwft.faction.free_pal_alliance"].actor =
    far_merchant
for faction_id, record in pairs(market_runtime.records) do
    if faction_id ~= "pwft.faction.rayne_syndicate"
        and faction_id ~= "pwft.faction.free_pal_alliance" then
        record.actor = nil
    end
end
local routed = market_runtime:interact_nearest(routed_player, 350)
assert(routed.ok)
assert(routed.reason == "merchant-native-item-shop-dispatched")
assert(routed.factionId == "pwft.faction.rayne_syndicate")
assert(
    routed.route
        == "PalNPCInteractionComponent.OnTriggerInteract -> "
            .. "PalHUDService.Push(WBP_ItemShop_C,native-parameter)"
)
assert(routed.indicatorType == 39)
assert(math.abs(routed.distance - 30) < 0.001)
assert(routed_calls == 1)
assert(routed_parameter_spawns == 1)
assert(routed_hud_pushes == 1)
assert(routed.dispatchParameter == routed_parameter)
assert(routed.uiId == routed_ui_id)
assert(
    market_runtime.nativeItemShopHudParams[near_merchant]
        == routed_parameter
)
local out_of_range = market_runtime:interact_nearest(
    {
        K2_GetActorLocation = function()
            return { X = 2000, Y = 2000, Z = 0 }
        end,
    },
    350
)
assert(not out_of_range.ok)
assert(out_of_range.reason == "no-economy-merchant-in-range")
local hud_parameter_cleanup = market_runtime:deactivate_faction(
    "pwft.faction.rayne_syndicate",
    "native-item-shop-flow-cleanup-test"
)
assert(hud_parameter_cleanup.ok)
assert(
    market_runtime.nativeItemShopHudParams[near_merchant] == nil
)
StaticFindObject = saved_static_find_object
LoadAsset = saved_load_asset

print(
    "PASS Merchant Guild economy-counter plans, activation gate, "
        .. "native shop rebind, F interaction routing, and rollback-safe lifecycle"
)
