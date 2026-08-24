local FactionEconomyMerchantRuntime = {}

local API_VERSION = "1.0.0"

-- Use the game's ordinary item merchant rather than the Dark Trader.  The
-- Dark Trader can be spawned reliably, but its authored vendor component owns
-- only a PalCharacterShop; assigning an ItemShop row does not turn that shop
-- object into an item shop.  The ordinary Trader v04 class carries the native
-- ItemShop vendor lifecycle that the seven faction catalog rows require.
local PROVEN_MERCHANT_CHARACTER_ID = "NPC_Male_Trader01_v04"
local PROVEN_MERCHANT_CHARACTER_CLASS_PATH =
    "/Game/Pal/Blueprint/Character/NPC/Normal/"
        .. "BP_NPC_Male_Trader01_v04."
        .. "BP_NPC_Male_Trader01_v04_C"
local ITEM_MERCHANT_SPAWNER_CLASS_PATH =
    "/Game/Pal/Blueprint/Spawner/HumanNPCBoss/"
        .. "BP_MonoNPCSpawnerBossBase_Male_Trader01."
        .. "BP_MonoNPCSpawnerBossBase_Male_Trader01_C"
local ITEM_SHOP_FLOW_ASSET_PATH =
    "/Game/Pal/Blueprint/FlowGraph/NPCTalkFlow/CommonNode/"
        .. "FNBP_OpenItemShop"
local ITEM_SHOP_FLOW_OBJECT_PATH =
    ITEM_SHOP_FLOW_ASSET_PATH .. ".FNBP_OpenItemShop"
local ITEM_SHOP_FLOW_CLASS_PATH =
    ITEM_SHOP_FLOW_ASSET_PATH .. ".FNBP_OpenItemShop_C"
local ITEM_SHOP_WIDGET_ASSET_PATH =
    "/Game/Pal/Blueprint/UI/ItemShop/WBP_ItemShop"
local ITEM_SHOP_WIDGET_OBJECT_PATH =
    ITEM_SHOP_WIDGET_ASSET_PATH .. ".WBP_ItemShop"
local ITEM_SHOP_WIDGET_CLASS_PATH =
    ITEM_SHOP_WIDGET_ASSET_PATH .. ".WBP_ItemShop_C"
local ITEM_SHOP_PARAMETER_ASSET_PATH =
    "/Game/Pal/Blueprint/UI/ItemShop/"
        .. "BP_PalUIDispatchParameter_ItemShop"
local ITEM_SHOP_PARAMETER_OBJECT_PATH =
    ITEM_SHOP_PARAMETER_ASSET_PATH
        .. ".BP_PalUIDispatchParameter_ItemShop"
local ITEM_SHOP_PARAMETER_CLASS_PATH =
    ITEM_SHOP_PARAMETER_ASSET_PATH
        .. ".BP_PalUIDispatchParameter_ItemShop_C"
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

local function result(ok, reason, extra)
    local value = extra or {}
    value.ok = ok
    value.reason = reason
    return value
end

local function despawn_succeeded(outcome)
    -- Early adapters returned a boolean; the native adapter returns a result
    -- table. Accept both while preserving explicit failure details.
    return outcome == true
        or (type(outcome) == "table" and outcome.ok == true)
end

local function despawn_failure_reason(outcome)
    if type(outcome) == "table" then
        return outcome.reason or "despawn-returned-no-result"
    end
    return tostring(outcome or "despawn-returned-no-result")
end

local function is_valid_uobject(object)
    if object == nil then
        return false
    end
    local ok, valid = pcall(function()
        return object:IsValid()
    end)
    return ok and valid == true
end

local function unwrap_remote_value(value)
    if value == nil then
        return nil
    end
    local ok, unwrapped = pcall(function()
        return value:get()
    end)
    if ok and unwrapped ~= nil then
        return unwrapped
    end
    return value
end

local function safe_uobject_name(object)
    object = unwrap_remote_value(object)
    if not is_valid_uobject(object) then
        return "<invalid>"
    end
    local ok, name = pcall(function()
        return object:GetFullName()
    end)
    return ok and tostring(name) or "<unreadable>"
end

local function safe_row_key(vendor, property_name)
    local row = nil
    local read_ok = pcall(function()
        row = vendor[property_name]
    end)
    if not read_ok or row == nil then
        return "<unavailable>"
    end
    local key = nil
    local key_ok = pcall(function()
        key = row.Key
    end)
    return key_ok and tostring(unwrap_remote_value(key))
        or "<unreadable>"
end

local function require_non_empty_string(value, name)
    assert(
        type(value) == "string" and value ~= "",
        name .. " must be a non-empty string"
    )
    return value
end

local function offset_location(root, rotation, offset)
    local yaw = math.rad((rotation and rotation.Yaw) or 0)
    local forward_x = math.cos(yaw)
    local forward_y = math.sin(yaw)
    local right_x = -forward_y
    local right_y = forward_x
    return {
        X = root.X
            + forward_x * (offset.forward or 0)
            + right_x * (offset.right or 0),
        Y = root.Y
            + forward_y * (offset.forward or 0)
            + right_y * (offset.right or 0),
        Z = root.Z + (offset.up or 0),
    }
end

local function validate(
    shop_catalog,
    commerce_contract,
    faction_api,
    commerce_bridge,
    native_adapter
)
    assert(type(shop_catalog) == "table", "economy shop catalog is required")
    assert(type(shop_catalog.shop_catalog) == "function", "invalid economy shop catalog")
    assert(type(commerce_contract) == "table", "commerce contract is required")
    assert(type(faction_api) == "table", "faction API is required")
    assert(type(commerce_bridge) == "table", "commerce bridge is required")
    assert(
        type(commerce_bridge.register_vendor_actor) == "function",
        "commerce bridge lacks vendor registration"
    )
    assert(
        #commerce_contract.merchantIsland.slotOffsets == 7,
        "economy market requires seven merchant-island slots"
    )
    local contract = shop_catalog.contract
    assert(type(contract) == "table", "economy shop contract is required")
    assert(
        contract.designPolicy.fixedCountersAreMerchantGuildEmployees == true,
        "economy counters must remain Merchant Guild employees"
    )
    assert(
        contract.designPolicy.fixedCountersAreFactionMembers == false,
        "economy counters cannot become faction members"
    )
    assert(
        contract.designPolicy.allCountersUseItemShop == true,
        "economy counters must use ItemShop"
    )
    assert(
        contract.designPolicy.raynePalMerchantIsExcludedSpecialCase == true,
        "the Rayne Pal merchant must remain outside the economy market"
    )
    if native_adapter ~= nil then
        assert(
            type(native_adapter.spawn_merchant) == "function"
                or type(native_adapter.spawn_merchant_async)
                    == "function"
                or type(
                    native_adapter.spawn_merchant_via_npc_manager
                ) == "function",
            "native adapter lacks merchant spawn lifecycle"
        )
        assert(
            type(native_adapter.despawn) == "function",
            "native adapter lacks despawn"
        )
    end
end

function FactionEconomyMerchantRuntime.create(
    shop_catalog,
    commerce_contract,
    faction_api,
    commerce_bridge,
    native_adapter,
    options
)
    validate(
        shop_catalog,
        commerce_contract,
        faction_api,
        commerce_bridge,
        native_adapter
    )
    options = options or {}
    local records = {}
    for _, faction_id in ipairs(shop_catalog.representativeOrder) do
        records[faction_id] = {
            actor = nil,
            owned = false,
            pending = false,
            pendingHandle = nil,
            nativeHandle = nil,
            lastError = nil,
        }
    end
    return setmetatable({
        version = API_VERSION,
        shopCatalog = shop_catalog,
        commerceContract = copy(commerce_contract),
        factionApi = faction_api,
        commerceBridge = commerce_bridge,
        adapter = native_adapter,
        activationAuthorized = options.activationAuthorized == true,
        spawnPolicyResolver = options.spawnPolicyResolver,
        records = records,
        uniquePalRansomOffers = {},
        -- Keep the native dispatch parameter alive while the corresponding
        -- ItemShop is on PalHUDService's stack.  The service owns the UI, but
        -- retaining the exact authored parameter also prevents Lua/UE4SS GC
        -- from invalidating it before the close lifecycle has completed.
        nativeItemShopHudParams = {},
        activationCount = 0,
        deactivationCount = 0,
        rollbackCount = 0,
        spawnSuppressionCount = 0,
        ransomConfigurationCount = 0,
        ransomClearCount = 0,
        capabilities = {
            sevenMerchantGuildCounters = true,
            economyCatalogShopRows = true,
            representedFactionSettlement = true,
            neutralPublicMarketIsland = true,
            transactionalActivationRollback = true,
            nativeItemShopFlowDispatch = false,
            directHudPush = true,
            raynePalMerchantExcluded = true,
            storyContentIncluded = false,
            PalworldSaveMutation = false,
        },
    }, { __index = FactionEconomyMerchantRuntime })
end

function FactionEconomyMerchantRuntime:merchant_plan(
    faction_id,
    root_location,
    root_rotation
)
    faction_id = require_non_empty_string(faction_id, "faction ID")
    local record = self.records[faction_id]
    if record == nil then
        return nil, "unknown-economy-shop-faction"
    end
    if type(root_location) ~= "table"
        or type(root_rotation) ~= "table" then
        return nil, "market-island-placement-pending"
    end
    local shop, reason = self.shopCatalog:shop_catalog(faction_id)
    if shop == nil then
        return nil, reason
    end
    local procurement, procurement_error =
        self.shopCatalog:procurement_catalog(faction_id)
    if procurement == nil then
        return nil, procurement_error
    end
    local market_universe = {}
    for _, product in ipairs(
        self.shopCatalog.economy.contract.auditedProducts
    ) do
        table.insert(market_universe, product.productItemId)
    end
    local economy_status = self.shopCatalog.economy:status()
    local slot = self.commerceContract.merchantIsland.slotOffsets[
        shop.slotIndex + 1
    ]
    assert(type(slot) == "table", "economy merchant slot is missing")
    return {
        runtimeId = "economy-fixed:" .. faction_id,
        mode = "fixed-market",
        factionId = faction_id,
        representedFactionId = faction_id,
        merchantOrganisationId = shop.merchantOrganisationId,
        -- The catalog retains each faction's presentation metadata, while
        -- the executable baseline deliberately reuses the one merchant
        -- lifecycle already proven in the current game build.
        characterId = PROVEN_MERCHANT_CHARACTER_ID,
        -- Instantiate the ordinary item merchant pawn directly.  The
        -- spawner path is retained as descriptive/fallback metadata; the
        -- direct deferred route avoids persistent map-spawner state.
        uniqueNpcId = "None",
        characterClassPath = PROVEN_MERCHANT_CHARACTER_CLASS_PATH,
        expectedActorClassToken = "BP_NPC_Male_Trader01_v04_C",
        spawnerClassPath = ITEM_MERCHANT_SPAWNER_CLASS_PATH,
        spawnerSaveKey = "PFT" .. "_Economy_" .. string.gsub(
            faction_id,
            "[^%w_]",
            "_"
        ),
        salesChannel = "ItemShop",
        shopRowName = shop.lotteryRowName,
        productGroupRowName = shop.productGroupRowName,
        products = copy(shop.products),
        requested = copy(procurement.requested),
        marketUniverseItemIds = market_universe,
        dynamicMarketEnabled =
            self.shopCatalog.economy.capabilities
                    .resourceLedgerAuthority == true,
        resourceLedgerRevision =
            economy_status.resourceLedgerRevision,
        -- Seven unique rows and faction registrations distinguish counters;
        -- their shared neutral merchant model is the 1.0 baseline.
        nativeSpawnerRequired = false,
        npcManagerServerSpawnRequired = false,
        provenNativeSpawnerRoute = "DirectItemTraderDeferredActor",
        clothingColour = shop.clothingColour,
        commercialTruce = true,
        location = offset_location(
            root_location,
            root_rotation,
            slot
        ),
        rotation = copy(root_rotation),
    }
end

function FactionEconomyMerchantRuntime:_spawn_policy(
    faction_id,
    spawn_kind
)
    if type(self.spawnPolicyResolver) ~= "function" then
        return result(true, "merchant-spawn-policy-unbound", {
            suppressSpawn = false,
        })
    end
    local ok, policy = pcall(
        self.spawnPolicyResolver,
        faction_id,
        spawn_kind or "merchant-guild-counter"
    )
    if not ok or type(policy) ~= "table" then
        return result(false, "merchant-spawn-policy-failed", {
            suppressSpawn = true,
            detail = tostring(policy),
        })
    end
    return policy
end

function FactionEconomyMerchantRuntime:_sync_dynamic_plan(plan)
    if type(plan) ~= "table" then
        return false, "merchant-plan-unavailable"
    end
    local shop, shop_error = self.shopCatalog:shop_catalog(
        plan.factionId
    )
    if shop == nil then return false, shop_error end
    local procurement, procurement_error =
        self.shopCatalog:procurement_catalog(plan.factionId)
    if procurement == nil then return false, procurement_error end
    plan.products = copy(shop.products)
    plan.requested = copy(procurement.requested)
    plan.dynamicMarketEnabled =
        self.shopCatalog.economy.capabilities
                .resourceLedgerAuthority == true
    plan.resourceLedgerRevision =
        self.shopCatalog.economy:status().resourceLedgerRevision
    local ransom = self.uniquePalRansomOffers[plan.factionId]
    if ransom ~= nil then
        local replaced = false
        for index, row in ipairs(plan.products) do
            if row.itemId == ransom.productItemId then
                plan.products[index] = {
                    itemId = ransom.productItemId,
                    displayNameZhHans = "唯一帕鲁赎回信物",
                    price = ransom.unitPrice,
                    stock = 1,
                    productType = row.productType or "Normal",
                    productNum = 1,
                    uniquePalRansom = true,
                }
                replaced = true
                break
            end
        end
        if not replaced then
            table.insert(plan.products, {
                itemId = ransom.productItemId,
                displayNameZhHans = "唯一帕鲁赎回信物",
                price = ransom.unitPrice,
                stock = 1,
                productType = "Normal",
                productNum = 1,
                uniquePalRansom = true,
            })
        end
        plan.uniquePalRansomOffer = copy(ransom)
    else
        plan.uniquePalRansomOffer = nil
    end
    return true, nil
end

function FactionEconomyMerchantRuntime:market_plan(
    root_location,
    root_rotation
)
    local plans = {}
    for _, faction_id in ipairs(
        self.shopCatalog.representativeOrder
    ) do
        local plan, reason = self:merchant_plan(
            faction_id,
            root_location,
            root_rotation
        )
        if plan == nil then
            return nil, reason
        end
        table.insert(plans, plan)
    end
    return plans, nil
end

function FactionEconomyMerchantRuntime:bind_existing(
    faction_id,
    actor
)
    faction_id = require_non_empty_string(faction_id, "faction ID")
    local record = self.records[faction_id]
    if record == nil then
        return result(false, "unknown-economy-shop-faction")
    end
    if actor == nil then
        return result(false, "invalid-existing-economy-merchant")
    end
    if record.actor ~= nil then
        return result(true, "economy-merchant-already-bound", {
            factionId = faction_id,
            actor = record.actor,
        })
    end
    local registered, detail =
        self.commerceBridge:register_vendor_actor(
            faction_id,
            actor,
            {
                mode = "fixed-market",
                commercialTruce = true,
                merchantOrganisationId =
                    self.shopCatalog.contract.designPolicy
                        .merchantOrganisationId,
                representedFactionId = faction_id,
                economyCatalogBinding = true,
            }
        )
    if not registered then
        return result(false, "commerce-vendor-registration-failed", {
            detail = detail,
        })
    end
    record.actor = actor
    record.owned = false
    return result(true, "existing-economy-merchant-bound", {
        factionId = faction_id,
        actor = actor,
    })
end

function FactionEconomyMerchantRuntime:_rollback(spawned, reason)
    for index = #spawned, 1, -1 do
        local entry = spawned[index]
        if type(self.commerceBridge.unregister_vendor_actor)
            == "function" then
            pcall(
                self.commerceBridge.unregister_vendor_actor,
                self.commerceBridge,
                entry.actor
            )
        end
        pcall(
            self.adapter.despawn,
            self.adapter,
            entry.actor,
            reason
        )
        local record = self.records[entry.factionId]
        record.actor = nil
        record.owned = false
    end
    self.rollbackCount = self.rollbackCount + 1
end

function FactionEconomyMerchantRuntime:_activation_gate()
    local activation = self.shopCatalog.contract.runtimeActivation
    if not self.activationAuthorized
        or activation.customProductRowsEnabled ~= true
        or activation.nativeMerchantSpawnEnabled ~= true
        or activation.nativeShopBindingEnabled ~= true then
        return false, "economy-market-runtime-disabled"
    end
    if self.adapter == nil then
        return false, "native-merchant-adapter-pending"
    end
    return true, nil
end

function FactionEconomyMerchantRuntime:_uses_async_merchant_spawner(plan)
    return self.adapter ~= nil
        and type(self.adapter.spawn_merchant_async) == "function"
        and (
            self.adapter.asyncMerchantSpawnerEnabled == true
            or (type(plan) == "table"
                and plan.nativeSpawnerRequired == true)
        )
end

function FactionEconomyMerchantRuntime:_uses_npc_manager_spawn(plan)
    return self.adapter ~= nil
        and type(
            self.adapter.spawn_merchant_via_npc_manager
        ) == "function"
        and type(plan) == "table"
        and plan.npcManagerServerSpawnRequired == true
end

function FactionEconomyMerchantRuntime:_register_ready_actor(
    plan,
    actor,
    owned,
    native_handle
)
    local record = self.records[plan.factionId]
    local policy = self:_spawn_policy(
        plan.factionId,
        "merchant-guild-counter"
    )
    if policy.ok ~= true or policy.suppressSpawn == true then
        record.pending = false
        record.pendingHandle = nil
        record.nativeHandle = nil
        record.lastError = policy.reason
        self.spawnSuppressionCount = self.spawnSuppressionCount + 1
        return false, policy.reason or "destroyed-faction-spawn-suppressed"
    end
    local registered, detail =
        self.commerceBridge:register_vendor_actor(
            plan.factionId,
            actor,
            {
                mode = "fixed-market",
                commercialTruce = true,
                merchantOrganisationId =
                    plan.merchantOrganisationId,
                representedFactionId = plan.factionId,
                economyCatalogBinding = true,
            }
        )
    if not registered then
        record.pending = false
        record.pendingHandle = nil
        record.lastError = detail
        return false, detail
    end
    -- This is a hard acceptance gate.  UE4SS may report inherited Lua
    -- methods inconsistently through type(instance.method), so invoke the
    -- adapter directly and roll the merchant back unless the second vendor
    -- row/network setup succeeds after faction registration.
    local refresh_ok, refreshed, detail_or_error = pcall(function()
        if type(self.adapter.capabilities) == "table"
            and self.adapter.capabilities
                .directNativeBlueprintSpawn == true then
            local configured, configure_error =
                self.adapter:_configure_vendor(actor, plan)
            if not configured then
                return false, configure_error
            end
            if plan.dynamicMarketEnabled == true
                and type(self.adapter.apply_dynamic_item_shop_market)
                    == "function" then
                local dynamic_ok, dynamic_reason =
                    self.adapter:apply_dynamic_item_shop_market(
                        actor,
                        plan
                    )
                if not dynamic_ok then
                    self.adapter:_log(string.format(
                        "DYNAMIC_ITEM_SHOP_ACTIVATION_FAILED faction=%s reason=%s staticFallback=true",
                        tostring(plan.factionId),
                        tostring(dynamic_reason)
                    ))
                end
            end
            local requested, network_detail =
                self.adapter:_request_network_shop_setup(actor)
            self.adapter:_log(string.format(
                "MERCHANT_SHOP_REFRESHED actor=%s row=%s requested=%s detail=%s source=runtime-post-registration",
                tostring(actor),
                tostring(plan.shopRowName),
                tostring(requested),
                tostring(network_detail)
            ))
            return requested, network_detail
        end
        return self.adapter:refresh_merchant_shop(actor, plan)
    end)
    if not refresh_ok or refreshed ~= true then
        if type(self.commerceBridge.unregister_vendor_actor)
            == "function" then
            pcall(
                self.commerceBridge.unregister_vendor_actor,
                self.commerceBridge,
                actor
            )
        end
        record.pending = false
        record.pendingHandle = nil
        record.lastError = tostring(
            refresh_ok and detail_or_error or refreshed
        )
        return false, "registered-shop-refresh-failed:"
            .. tostring(record.lastError)
    end
    local refresh_detail = tostring(detail_or_error)
    record.actor = actor
    record.owned = owned == true
    record.pending = false
    record.pendingHandle = nil
    record.nativeHandle = native_handle
    record.plan = plan
    record.lastError = nil
    record.shopRefreshDetail = refresh_detail
    self.activationCount = self.activationCount + 1
    return true, nil
end


function FactionEconomyMerchantRuntime:refresh_dynamic_market(faction_id)
    faction_id = require_non_empty_string(
        faction_id,
        "faction ID"
    )
    local record = self.records[faction_id]
    if record == nil then
        return result(false, "unknown-economy-shop-faction")
    end
    if record.actor == nil or type(record.plan) ~= "table" then
        return result(true, "dynamic-market-no-active-merchant", {
            factionId = faction_id,
            active = false,
        })
    end
    local synced, sync_error = self:_sync_dynamic_plan(record.plan)
    if not synced then
        record.lastDynamicMarketError = sync_error
        return result(false, "dynamic-market-plan-refresh-failed", {
            factionId = faction_id,
            detail = sync_error,
        })
    end
    if self.adapter == nil
        or type(self.adapter.apply_dynamic_item_shop_market)
            ~= "function" then
        record.lastDynamicMarketError =
            "native-dynamic-item-shop-adapter-unavailable"
        return result(false,
            "native-dynamic-item-shop-adapter-unavailable", {
            factionId = faction_id,
        })
    end
    local called, applied, reason, detail = pcall(
        self.adapter.apply_dynamic_item_shop_market,
        self.adapter,
        record.actor,
        record.plan
    )
    if not called or applied ~= true then
        record.lastDynamicMarketError = tostring(
            called and reason or applied
        )
        return result(false, "dynamic-market-native-refresh-failed", {
            factionId = faction_id,
            detail = record.lastDynamicMarketError,
            nativeDetail = detail,
            resourceLedgerRevision =
                record.plan.resourceLedgerRevision,
        })
    end
    record.lastDynamicMarketError = nil
    record.dynamicMarketRefreshCount =
        (record.dynamicMarketRefreshCount or 0) + 1
    record.lastDynamicMarketDetail = detail
    return result(true, "dynamic-market-native-refreshed", {
        factionId = faction_id,
        active = true,
        resourceLedgerRevision =
            record.plan.resourceLedgerRevision,
        nativeReason = reason,
        nativeDetail = detail,
        refreshCount = record.dynamicMarketRefreshCount,
    })
end

function FactionEconomyMerchantRuntime:refresh_all_dynamic_markets()
    local refreshed = {}
    local failed = {}
    for _, faction_id in ipairs(
        self.shopCatalog.representativeOrder
    ) do
        local outcome = self:refresh_dynamic_market(faction_id)
        if outcome.ok then
            table.insert(refreshed, outcome)
        else
            table.insert(failed, outcome)
        end
    end
    return result(#failed == 0,
        #failed == 0
            and "all-dynamic-markets-refreshed"
            or "dynamic-market-refresh-partial", {
        refreshed = refreshed,
        failed = failed,
    })
end

function FactionEconomyMerchantRuntime:activate_faction(
    faction_id,
    root_location,
    root_rotation
)
    local enabled, disabled_reason = self:_activation_gate()
    if not enabled then
        return result(false, disabled_reason)
    end
    local policy = self:_spawn_policy(
        faction_id,
        "merchant-guild-counter"
    )
    if policy.ok ~= true or policy.suppressSpawn == true then
        self.spawnSuppressionCount = self.spawnSuppressionCount + 1
        return result(false,
            policy.reason or "destroyed-faction-spawn-suppressed", {
                factionId = faction_id,
                suppressed = true,
            })
    end
    local plan, plan_error = self:merchant_plan(
        faction_id,
        root_location,
        root_rotation
    )
    if plan == nil then
        return result(false, plan_error)
    end
    local record = self.records[plan.factionId]
    if record.actor ~= nil then
        return result(true, "economy-merchant-already-active", {
            factionId = plan.factionId,
            actor = record.actor,
            spawned = {},
        })
    end
    if record.pending then
        return result(true, "economy-merchant-activation-pending", {
            factionId = plan.factionId,
            pendingHandle = record.pendingHandle,
            spawned = {},
        })
    end
    if self:_uses_npc_manager_spawn(plan)
        or self:_uses_async_merchant_spawner(plan) then
        record.pending = true
        record.lastError = nil
        local callbacks = {
            onReady = function(actor, handle)
                local registered, detail =
                    self:_register_ready_actor(
                        plan,
                        actor,
                        true,
                        handle
                    )
                if not registered then
                    pcall(
                        self.adapter.despawn,
                        self.adapter,
                        handle,
                        "economy-vendor-registration-failed"
                    )
                end
            end,
            onError = function(reason, native_handle)
                local cleanup_handle = native_handle
                    or record.pendingHandle
                if cleanup_handle ~= nil then
                    pcall(
                        self.adapter.despawn,
                        self.adapter,
                        cleanup_handle,
                        "economy-merchant-async-failed"
                    )
                end
                record.pending = false
                record.pendingHandle = nil
                record.nativeHandle = nil
                record.lastError = reason
            end,
        }
        local spawn_method = self:_uses_npc_manager_spawn(plan)
                and self.adapter.spawn_merchant_via_npc_manager
            or self.adapter.spawn_merchant_async
        local ok, handle_or_error = pcall(
            spawn_method,
            self.adapter,
            plan,
            callbacks
        )
        if not ok or handle_or_error == nil then
            record.pending = false
            record.lastError = tostring(handle_or_error)
            return result(false, "economy-merchant-spawn-failed", {
                factionId = plan.factionId,
                detail = tostring(handle_or_error),
            })
        end
        if record.actor == nil and record.pending then
            record.pendingHandle = handle_or_error
        end
        return result(true, "economy-merchant-activation-queued", {
            factionId = plan.factionId,
            pendingHandle = handle_or_error,
            plan = plan,
            spawned = {},
        })
    end
    local ok, actor_or_error = pcall(
        self.adapter.spawn_merchant,
        self.adapter,
        plan
    )
    if not ok or actor_or_error == nil then
        return result(false, "economy-merchant-spawn-failed", {
            factionId = plan.factionId,
            detail = tostring(actor_or_error),
        })
    end
    local registered, detail = self:_register_ready_actor(
        plan,
        actor_or_error,
        true
    )
    if not registered then
        pcall(
            self.adapter.despawn,
            self.adapter,
            actor_or_error,
            "economy-vendor-registration-failed"
        )
        return result(
            false,
            "commerce-vendor-registration-failed",
            {
                factionId = plan.factionId,
                detail = detail,
            }
        )
    end
    return result(true, "economy-merchant-activated", {
        factionId = plan.factionId,
        actor = actor_or_error,
        plan = plan,
        spawned = {
            {
                factionId = plan.factionId,
                actor = actor_or_error,
            },
        },
    })
end

function FactionEconomyMerchantRuntime:deactivate_faction(
    faction_id,
    reason
)
    faction_id = require_non_empty_string(faction_id, "faction ID")
    local record = self.records[faction_id]
    if record == nil then
        return result(false, "unknown-economy-shop-faction")
    end
    if record.actor == nil then
        if record.pending and record.pendingHandle ~= nil then
            local ok, outcome_or_error = pcall(
                self.adapter.despawn,
                self.adapter,
                record.pendingHandle,
                reason or "economy-merchant-pending-cancelled"
            )
            if not ok
                or (type(outcome_or_error) == "table"
                    and outcome_or_error.ok == false) then
                return result(
                    false,
                    "economy-merchant-pending-cancel-failed",
                    {
                        factionId = faction_id,
                        detail = tostring(outcome_or_error),
                    }
                )
            end
            record.pending = false
            record.pendingHandle = nil
            record.nativeHandle = nil
            record.plan = nil
            record.lastError = nil
            self.deactivationCount = self.deactivationCount + 1
            return result(
                true,
                "economy-merchant-pending-cancelled",
                { factionId = faction_id }
            )
        end
        return result(true, "economy-merchant-already-inactive", {
            factionId = faction_id,
        })
    end
    if not record.owned then
        return result(false, "external-economy-merchant-preserved", {
            factionId = faction_id,
            actor = record.actor,
        })
    end
    if type(self.commerceBridge.unregister_vendor_actor)
        == "function" then
        pcall(
            self.commerceBridge.unregister_vendor_actor,
            self.commerceBridge,
            record.actor
        )
    end
    local actor = record.actor
    self.nativeItemShopHudParams[actor] = nil
    local despawn_target = record.nativeHandle or actor
    local ok, outcome_or_error = pcall(
        self.adapter.despawn,
        self.adapter,
        despawn_target,
        reason or "economy-merchant-deactivated"
    )
    if not ok
        or (type(outcome_or_error) == "table"
            and outcome_or_error.ok == false) then
        return result(false, "economy-merchant-despawn-failed", {
            factionId = faction_id,
            detail = tostring(outcome_or_error),
        })
    end
    record.actor = nil
    record.owned = false
    record.nativeHandle = nil
    record.plan = nil
    self.deactivationCount = self.deactivationCount + 1
    return result(true, "economy-merchant-deactivated", {
        factionId = faction_id,
        actor = actor,
    })
end

function FactionEconomyMerchantRuntime:activate_market(
    root_location,
    root_rotation
)
    local enabled, disabled_reason = self:_activation_gate()
    if not enabled then
        return result(false, disabled_reason)
    end
    local plans, plan_error = self:market_plan(
        root_location,
        root_rotation
    )
    if plans == nil then
        return result(false, plan_error)
    end
    local spawned = {}
    local suppressed = {}
    for _, plan in ipairs(plans) do
        local record = self.records[plan.factionId]
        local policy = self:_spawn_policy(
            plan.factionId,
            "merchant-guild-counter"
        )
        if policy.ok ~= true or policy.suppressSpawn == true then
            self.spawnSuppressionCount = self.spawnSuppressionCount + 1
            table.insert(suppressed, {
                factionId = plan.factionId,
                reason = policy.reason,
            })
        elseif record.actor == nil and not record.pending
            and (
                self:_uses_npc_manager_spawn(plan)
                or self:_uses_async_merchant_spawner(plan)
            ) then
            local outcome = self:activate_faction(
                plan.factionId,
                root_location,
                root_rotation
            )
            if not outcome.ok then
                for _, queued_faction_id in ipairs(spawned) do
                    self:deactivate_faction(
                        queued_faction_id,
                        "economy-market-activation-rollback"
                    )
                end
                self.rollbackCount = self.rollbackCount + 1
                return outcome
            end
            table.insert(spawned, plan.factionId)
        elseif record.actor == nil then
            local ok, actor_or_error = pcall(
                self.adapter.spawn_merchant,
                self.adapter,
                plan
            )
            if not ok or actor_or_error == nil then
                self:_rollback(
                    spawned,
                    "economy-market-activation-rollback"
                )
                return result(false, "economy-merchant-spawn-failed", {
                    factionId = plan.factionId,
                    detail = tostring(actor_or_error),
                })
            end
            -- Use the same post-registration shop refresh gate as the
            -- single-counter route.  The former inline registration skipped
            -- the second SetupShopData/network bind for seven-counter markets.
            local registered, detail = self:_register_ready_actor(
                plan,
                actor_or_error,
                true
            )
            if not registered then
                pcall(
                    self.adapter.despawn,
                    self.adapter,
                    actor_or_error,
                    "economy-vendor-registration-failed"
                )
                self:_rollback(
                    spawned,
                    "economy-market-activation-rollback"
                )
                return result(
                    false,
                    "commerce-vendor-registration-failed",
                    {
                        factionId = plan.factionId,
                        detail = detail,
                    }
                )
            end
            table.insert(spawned, {
                factionId = plan.factionId,
                actor = actor_or_error,
            })
        end
    end
    local async_market = #plans > 0
        and (
            self:_uses_npc_manager_spawn(plans[1])
            or self:_uses_async_merchant_spawner(plans[1])
        )
    if not async_market then
        self.activationCount = self.activationCount + 1
    end
    return result(true,
        async_market
            and "economy-market-activation-queued"
            or "economy-market-activated", {
        spawned = spawned,
        suppressed = suppressed,
    })
end

function FactionEconomyMerchantRuntime:nearest_faction(
    player_actor,
    max_distance,
    required_faction_id
)
    if player_actor == nil then
        return result(false, "local-player-unavailable")
    end
    max_distance = tonumber(max_distance) or 350
    local player_ok, player_location = pcall(function()
        return player_actor:K2_GetActorLocation()
    end)
    if not player_ok or player_location == nil then
        return result(false, "local-player-location-unavailable")
    end
    local nearest_faction_id = nil
    local nearest_actor = nil
    local nearest_distance_squared = nil
    local maximum_distance_squared = max_distance * max_distance
    for faction_id, record in pairs(self.records) do
        if record.actor ~= nil
            and (required_faction_id == nil
                or faction_id == required_faction_id) then
            local actor_ok, actor_location = pcall(function()
                return record.actor:K2_GetActorLocation()
            end)
            if actor_ok and actor_location ~= nil then
                local dx = (tonumber(actor_location.X) or 0)
                    - (tonumber(player_location.X) or 0)
                local dy = (tonumber(actor_location.Y) or 0)
                    - (tonumber(player_location.Y) or 0)
                local dz = (tonumber(actor_location.Z) or 0)
                    - (tonumber(player_location.Z) or 0)
                local distance_squared = dx * dx + dy * dy + dz * dz
                if distance_squared <= maximum_distance_squared
                    and (nearest_distance_squared == nil
                        or distance_squared < nearest_distance_squared) then
                    nearest_faction_id = faction_id
                    nearest_actor = record.actor
                    nearest_distance_squared = distance_squared
                end
            end
        end
    end
    if nearest_faction_id == nil then
        return result(false, "no-economy-merchant-in-range")
    end
    return result(true, "nearest-economy-merchant-resolved", {
        factionId = nearest_faction_id,
        actor = nearest_actor,
        distance = math.sqrt(nearest_distance_squared),
    })
end

function FactionEconomyMerchantRuntime:configure_unique_pal_ransom(
    faction_id,
    offer
)
    faction_id = require_non_empty_string(faction_id, "faction ID")
    local record = self.records[faction_id]
    if record == nil then return result(false, "unknown-economy-shop-faction") end
    if record.actor == nil or type(record.plan) ~= "table" then
        return result(false, "ransom-merchant-counter-inactive")
    end
    assert(type(offer) == "table", "unique-Pal ransom offer is required")
    local normalized = copy(offer)
    normalized.merchantFactionId = faction_id
    normalized.currency = normalized.currency or "Gold"
    normalized.buyQuantity = 1
    normalized.singlePurchaseStock = true
    normalized.serverAuthoritativePrice = true
    normalized.serverAuthoritativePaymentResult = true
    self.uniquePalRansomOffers[faction_id] = normalized
    local synced, sync_error = self:_sync_dynamic_plan(record.plan)
    if not synced then
        self.uniquePalRansomOffers[faction_id] = nil
        return result(false, "ransom-market-plan-refresh-failed", {
            detail = tostring(sync_error),
        })
    end
    local refreshed, refresh_detail = self.adapter:refresh_merchant_shop(
        record.actor,
        record.plan
    )
    if refreshed ~= true then
        self.uniquePalRansomOffers[faction_id] = nil
        return result(false, "ransom-merchant-shop-refresh-failed", {
            detail = tostring(refresh_detail),
        })
    end
    local identity, identity_error =
        self.adapter:configure_unique_pal_ransom_product(
            record.actor,
            normalized
        )
    if identity == nil then
        self.uniquePalRansomOffers[faction_id] = nil
        if self.adapter ~= nil and type(self.adapter._log) == "function" then
            self.adapter:_log(string.format(
                "UNIQUE_PAL_RANSOM_PRODUCT_FAILED faction=%s item=%s detail=%s",
                faction_id,
                tostring(normalized.productItemId),
                tostring(identity_error)
            ))
        end
        return result(false, "ransom-native-product-binding-failed", {
            detail = tostring(identity_error),
        })
    end
    self.ransomConfigurationCount = self.ransomConfigurationCount + 1
    for key, value in pairs(identity) do normalized[key] = value end
    normalized.ok = true
    normalized.reason = "unique-pal-ransom-product-configured"
    return normalized
end

function FactionEconomyMerchantRuntime:clear_unique_pal_ransom(
    faction_id,
    unique_pal_id
)
    local offer = self.uniquePalRansomOffers[faction_id]
    if offer == nil then
        return result(true, "unique-pal-ransom-already-cleared")
    end
    if unique_pal_id ~= nil and offer.uniquePalId ~= unique_pal_id then
        return result(false, "unique-pal-ransom-clear-identity-mismatch")
    end
    self.uniquePalRansomOffers[faction_id] = nil
    local record = self.records[faction_id]
    if record ~= nil and record.actor ~= nil and type(record.plan) == "table" then
        self:_sync_dynamic_plan(record.plan)
        pcall(self.adapter.refresh_merchant_shop,
            self.adapter, record.actor, record.plan)
    end
    self.ransomClearCount = self.ransomClearCount + 1
    return result(true, "unique-pal-ransom-cleared")
end

function FactionEconomyMerchantRuntime:deactivate_market(reason)
    local removed = {}
    local preserved = {}
    if reason == "merchant-presence-world-reload" then
        -- At load-map-post the previous UWorld is already being destroyed.
        -- Touching one of its UObject wrappers (even tostring/IsValid) can
        -- crash UE4SS. The world owns actor destruction; here we only abandon
        -- Lua routing/tracking references and let the new world start clean.
        for faction_id, record in pairs(self.records) do
            if record.actor ~= nil or record.pending then
                table.insert(removed, faction_id)
            end
            record.actor = nil
            record.pending = false
            record.pendingHandle = nil
            record.nativeHandle = nil
            record.owned = false
            record.plan = nil
            record.lastError = nil
        end
        local cleanup_errors = {}
        if self.commerceBridge ~= nil
            and type(self.commerceBridge.clear_world_vendor_state)
                == "function" then
            local ok, detail = pcall(
                self.commerceBridge.clear_world_vendor_state,
                self.commerceBridge
            )
            if not ok then
                table.insert(cleanup_errors,
                    "commerce-bridge:" .. tostring(detail))
            end
        end
        -- Keep this in a separate protected call: commerce cleanup must never
        -- prevent the more important adapter generation fence from running.
        if self.adapter ~= nil
            and type(self.adapter.abandon_world_records) == "function" then
            local ok, detail = pcall(
                self.adapter.abandon_world_records,
                self.adapter,
                reason
            )
            if not ok then
                table.insert(cleanup_errors,
                    "native-adapter:" .. tostring(detail))
            end
        end
        self.nativeItemShopHudParams = {}
        self.deactivationCount = self.deactivationCount + 1
        return result(#cleanup_errors == 0,
            #cleanup_errors == 0
                and "economy-market-world-reload-abandoned"
                or "economy-market-world-reload-cleanup-failed", {
            removedFactionIds = removed,
            preservedExternalFactionIds = preserved,
            cleanupErrors = cleanup_errors,
        })
    end
    local failures = {}
    for faction_id, record in pairs(self.records) do
        if record.pending and record.pendingHandle ~= nil then
            local call_ok, outcome = pcall(
                self.adapter.despawn,
                self.adapter,
                record.pendingHandle,
                reason or "economy-market-deactivated"
            )
            if call_ok and despawn_succeeded(outcome) then
                table.insert(removed, faction_id)
                record.pending = false
                record.pendingHandle = nil
                record.nativeHandle = nil
                record.lastError = nil
            else
                table.insert(failures, faction_id)
                record.lastError = call_ok
                        and despawn_failure_reason(outcome)
                    or tostring(outcome)
            end
        elseif record.actor ~= nil then
            if record.owned then
                if type(self.commerceBridge.unregister_vendor_actor)
                    == "function" then
                    pcall(
                        self.commerceBridge.unregister_vendor_actor,
                        self.commerceBridge,
                        record.actor
                    )
                end
                local call_ok, outcome = pcall(
                    self.adapter.despawn,
                    self.adapter,
                    record.nativeHandle or record.actor,
                    reason or "economy-market-deactivated"
                )
                if call_ok and despawn_succeeded(outcome) then
                    table.insert(removed, faction_id)
                    self.nativeItemShopHudParams[record.actor] = nil
                    record.actor = nil
                    record.owned = false
                    record.nativeHandle = nil
                    record.lastError = nil
                else
                    table.insert(failures, faction_id)
                    record.lastError = call_ok
                            and despawn_failure_reason(outcome)
                        or tostring(outcome)
                end
            else
                table.insert(preserved, faction_id)
            end
        end
    end
    self.deactivationCount = self.deactivationCount + 1
    return result(#failures == 0,
        #failures == 0
            and "economy-market-deactivated"
            or "economy-market-deactivation-incomplete", {
        removedFactionIds = removed,
        preservedExternalFactionIds = preserved,
        failedFactionIds = failures,
    })
end

function FactionEconomyMerchantRuntime:status()
    local active_count = 0
    local owned_count = 0
    local pending_count = 0
    local invalid_record_count = 0
    local dynamic_refresh_count = 0
    local dynamic_failure_count = 0
    local ransom_offer_count = 0
    for _ in pairs(self.uniquePalRansomOffers) do
        ransom_offer_count = ransom_offer_count + 1
    end
    for _, record in pairs(self.records) do
        -- UE4SS may retain a stale callback value while its callback garbage
        -- collector is retiring an old native actor.  Status is called from a
        -- repeating hook and therefore must never let one malformed registry
        -- entry remove the whole hook.  Known faction records remain the
        -- authority; unexpected values are reported and ignored fail-closed.
        if type(record) ~= "table" then
            invalid_record_count = invalid_record_count + 1
        else
            if record.actor ~= nil then
                active_count = active_count + 1
                if record.owned then
                    owned_count = owned_count + 1
                end
            end
            if record.pending then
                pending_count = pending_count + 1
            end
            dynamic_refresh_count = dynamic_refresh_count
                + (record.dynamicMarketRefreshCount or 0)
            if record.lastDynamicMarketError ~= nil then
                dynamic_failure_count = dynamic_failure_count + 1
            end
        end
    end
    local activation = self.shopCatalog.contract.runtimeActivation
    return {
        version = self.version,
        representativeCount = #self.shopCatalog.representativeOrder,
        activeCount = active_count,
        ownedCount = owned_count,
        pendingCount = pending_count,
        invalidRecordCount = invalid_record_count,
        adapterReady = self.adapter ~= nil,
        activationAuthorized = self.activationAuthorized,
        nativeMerchantSpawnEnabled =
            activation.nativeMerchantSpawnEnabled,
        customProductRowsEnabled =
            activation.customProductRowsEnabled,
        nativeShopBindingEnabled =
            activation.nativeShopBindingEnabled,
        activationCount = self.activationCount,
        deactivationCount = self.deactivationCount,
        rollbackCount = self.rollbackCount,
        spawnPolicyBound = type(self.spawnPolicyResolver) == "function",
        spawnSuppressionCount = self.spawnSuppressionCount,
        activeUniquePalRansomOfferCount = ransom_offer_count,
        ransomConfigurationCount = self.ransomConfigurationCount,
        ransomClearCount = self.ransomClearCount,
        dynamicMarketEnabled =
            self.shopCatalog.economy.capabilities
                    .resourceLedgerAuthority == true,
        dynamicMarketRefreshCount = dynamic_refresh_count,
        dynamicMarketFailureCount = dynamic_failure_count,
        placementStatus =
            self.commerceContract.merchantIsland.placementStatus,
        runtimeStatus = self.activationAuthorized
                and activation.customProductRowsEnabled
                and activation.nativeMerchantSpawnEnabled
                and activation.nativeShopBindingEnabled
                and "ready-for-placement-adapter"
            or "disabled-pending-live-acceptance",
    }
end

local function find_or_load_class(asset_path, class_path, object_path)
    if type(StaticFindObject) ~= "function" then
        return nil, "StaticFindObject-unavailable"
    end
    local found, class_object = pcall(function()
        return StaticFindObject(class_path)
    end)
    if found and is_valid_uobject(class_object) then
        return class_object, nil
    end
    if type(LoadAsset) ~= "function" then
        return nil, "LoadAsset-unavailable"
    end
    local last_loaded = nil
    for _, load_path in ipairs({
        object_path or ITEM_SHOP_FLOW_OBJECT_PATH,
        asset_path,
        class_path,
    }) do
        local loaded, loaded_asset = pcall(function()
            return LoadAsset(load_path)
        end)
        last_loaded = loaded_asset
        if loaded and is_valid_uobject(loaded_asset) then
            local generated_ok, generated_class = pcall(function()
                return loaded_asset.GeneratedClass
            end)
            if generated_ok and is_valid_uobject(generated_class) then
                return generated_class, nil
            end
        end
        found, class_object = pcall(function()
            return StaticFindObject(class_path)
        end)
        if found and is_valid_uobject(class_object) then
            return class_object, nil
        end
    end
    return nil, "asset-load-failed:" .. tostring(last_loaded)
end

-- Reproduce FNBP_OpenItemShop.OpenItemShop_Internal at the reflected UObject
-- boundary. A standalone FNBP node cannot accept WeakWorldContextObject in
-- UE4SS 3.0.1 (Push_weakobjectproperty Set is unsupported), so use the local
-- player as the authored world context, create the game's native dispatch
-- parameter, and let PalHUDService own the WBP_ItemShop stack lifecycle. This
-- is the route already proven twice in Build 24467282 live evidence.
function FactionEconomyMerchantRuntime:_open_native_item_shop(
    actor,
    player_actor
)
    local vendor = nil
    local vendor_ok = pcall(function()
        vendor = actor.BP_PalShopVenderDataComponent
    end)
    if not vendor_ok or vendor == nil then
        return false, "merchant-vendor-component-unavailable"
    end
    -- Match the cooked FNBP_OpenItemShop path: TryGetItemShop is the
    -- authoritative source and its UObject out parameter can be returned as
    -- the second Lua result by UE4SS.  MyItemShop remains a compatibility
    -- fallback for builds where the reflected out parameter is unavailable.
    local direct_shop = nil
    pcall(function()
        direct_shop = unwrap_remote_value(vendor.MyItemShop)
    end)
    local try_ok, returned_shop, out_shop = pcall(function()
        return vendor:TryGetItemShop()
    end)
    returned_shop = unwrap_remote_value(returned_shop)
    out_shop = unwrap_remote_value(out_shop)
    local shop = nil
    local shop_source = nil
    if try_ok and is_valid_uobject(returned_shop) then
        shop = returned_shop
        shop_source = "TryGetItemShop:return"
    elseif try_ok and is_valid_uobject(out_shop) then
        shop = out_shop
        shop_source = "TryGetItemShop:out"
    elseif is_valid_uobject(direct_shop) then
        shop = direct_shop
        shop_source = "MyItemShop"
    end
    local pal_shop = nil
    pcall(function()
        pal_shop = unwrap_remote_value(vendor.MyPalShop)
    end)
    local shop_state = string.format(
        "itemRow=%s palRow=%s source=%s itemShop=%s palShop=%s tryOk=%s tryReturn=%s tryOut=%s",
        safe_row_key(vendor, "itemShopSimpleLotteryTableName"),
        safe_row_key(vendor, "palShopSimpleLotteryTableName"),
        tostring(shop_source or "none"),
        safe_uobject_name(direct_shop),
        safe_uobject_name(pal_shop),
        tostring(try_ok),
        safe_uobject_name(returned_shop),
        safe_uobject_name(out_shop)
    )
    if self.adapter ~= nil
        and type(self.adapter._log) == "function" then
        self.adapter:_log("MERCHANT_OPEN_SHOP_STATE " .. shop_state)
    end
    if shop == nil then
        return false, "merchant-item-shop-unavailable"
    end
    local widget_class, widget_class_error = find_or_load_class(
        ITEM_SHOP_WIDGET_ASSET_PATH,
        ITEM_SHOP_WIDGET_CLASS_PATH,
        ITEM_SHOP_WIDGET_OBJECT_PATH
    )
    if widget_class == nil then
        return false, "item-shop-native-widget-"
            .. tostring(widget_class_error)
    end
    local parameter_class, parameter_class_error = find_or_load_class(
        ITEM_SHOP_PARAMETER_ASSET_PATH,
        ITEM_SHOP_PARAMETER_CLASS_PATH,
        ITEM_SHOP_PARAMETER_OBJECT_PATH
    )
    if parameter_class == nil then
        return false, "item-shop-native-parameter-"
            .. tostring(parameter_class_error)
    end
    local utility_ok, utility = pcall(function()
        return StaticFindObject("/Script/Pal.Default__PalUtility")
    end)
    if not utility_ok or not is_valid_uobject(utility) then
        return false, "item-shop-native-pal-utility-unavailable"
    end
    local hud_ok, hud_service = pcall(function()
        return utility:GetHUDService(player_actor)
    end)
    if not hud_ok or not is_valid_uobject(hud_service) then
        return false, "item-shop-native-hud-service-unavailable:"
            .. tostring(hud_service)
    end
    local gameplay_ok, gameplay = pcall(function()
        return StaticFindObject(
            "/Script/Engine.Default__GameplayStatics"
        )
    end)
    if not gameplay_ok or not is_valid_uobject(gameplay) then
        return false, "item-shop-native-gameplay-statics-unavailable"
    end
    local parameter_ok, parameter = pcall(function()
        return gameplay:SpawnObject(parameter_class, hud_service)
    end)
    if not parameter_ok or not is_valid_uobject(parameter) then
        return false, "item-shop-native-parameter-spawn-failed:"
            .. tostring(parameter)
    end
    local configured, configure_error = pcall(function()
        -- EPalItemShopTabType::Buy is byte value 1 in the cooked flow.
        parameter.OpenTabType = 1
        parameter.shop = shop
    end)
    if not configured then
        return false, "item-shop-native-parameter-configure-failed:"
            .. tostring(configure_error)
    end
    self.nativeItemShopHudParams[actor] = parameter
    local pushed, ui_id_or_error = pcall(function()
        return hud_service:Push(widget_class, parameter)
    end)
    if not pushed then
        self.nativeItemShopHudParams[actor] = nil
        return false, "item-shop-native-hud-push-failed:"
            .. tostring(ui_id_or_error)
    end
    return true, "PalHUDService.Push(WBP_ItemShop_C,native-parameter)", {
        shop = shop,
        hudService = hud_service,
        dispatchParameter = parameter,
        widgetClass = widget_class,
        uiId = ui_id_or_error,
        shopSource = shop_source,
        shopState = shop_state,
    }
end

-- Runtime-created Dark Trader pawns have the authored interaction component
-- and shop action, but Palworld does not insert a pawn without an
-- IndividualHandle into the local player's overlap-driven interaction list.
-- Route F to the same native OnTriggerInteract entry only when the player is
-- close to one of this runtime's registered Merchant Guild actors.  The
-- distance gate keeps every unrelated NPC and world interaction untouched.
function FactionEconomyMerchantRuntime:interact_nearest(
    player_actor,
    max_distance,
    required_faction_id
)
    if player_actor == nil then
        return result(false, "local-player-unavailable")
    end
    max_distance = tonumber(max_distance) or 350
    if max_distance <= 0 then
        return result(false, "invalid-interaction-distance")
    end
    local player_ok, player_location = pcall(function()
        return player_actor:K2_GetActorLocation()
    end)
    if not player_ok or player_location == nil then
        return result(false, "local-player-location-unavailable")
    end
    local player_x = tonumber(player_location.X)
    local player_y = tonumber(player_location.Y)
    local player_z = tonumber(player_location.Z)
    if player_x == nil or player_y == nil or player_z == nil then
        return result(false, "invalid-local-player-location")
    end

    local nearest_actor = nil
    local nearest_faction_id = nil
    local nearest_distance_squared = nil
    local max_distance_squared = max_distance * max_distance
    for faction_id, record in pairs(self.records) do
        if record.actor ~= nil
            and (required_faction_id == nil
                or faction_id == required_faction_id) then
            local actor_ok, actor_location = pcall(function()
                return record.actor:K2_GetActorLocation()
            end)
            if actor_ok and actor_location ~= nil then
                local actor_x = tonumber(actor_location.X)
                local actor_y = tonumber(actor_location.Y)
                local actor_z = tonumber(actor_location.Z)
                if actor_x ~= nil and actor_y ~= nil
                    and actor_z ~= nil then
                    local dx = actor_x - player_x
                    local dy = actor_y - player_y
                    local dz = actor_z - player_z
                    local distance_squared = dx * dx + dy * dy + dz * dz
                    if distance_squared <= max_distance_squared
                        and (
                            nearest_distance_squared == nil
                            or distance_squared
                                < nearest_distance_squared
                        ) then
                        nearest_actor = record.actor
                        nearest_faction_id = faction_id
                        nearest_distance_squared = distance_squared
                    end
                end
            end
        end
    end
    if nearest_actor == nil then
        return result(false, "no-economy-merchant-in-range")
    end
    local record = self.records[nearest_faction_id]
    local plan = record and record.plan
    if type(plan) ~= "table" then
        return result(false, "merchant-plan-unavailable", {
            factionId = nearest_faction_id,
            actor = nearest_actor,
        })
    end
    local plan_synced, plan_sync_error =
        self:_sync_dynamic_plan(plan)
    if not plan_synced then
        return result(false, "dynamic-market-plan-refresh-failed", {
            factionId = nearest_faction_id,
            actor = nearest_actor,
            detail = tostring(plan_sync_error),
        })
    end
    -- Dark Trader's authored OnTriggerInteract opens its PalShop flow.  That
    -- asynchronous push can race and cover the economy ItemShop with a Pal
    -- list.  Rebind the faction ItemShop immediately before opening and do
    -- not invoke the Dark Trader's PalShop interaction route here.
    local refreshed_ok, refreshed, refresh_detail = pcall(function()
        return self.adapter:refresh_merchant_shop(nearest_actor, plan)
    end)
    if not refreshed_ok or refreshed ~= true then
        return result(false, "merchant-shop-refresh-before-open-failed", {
            factionId = nearest_faction_id,
            actor = nearest_actor,
            detail = tostring(
                refreshed_ok and refresh_detail or refreshed
            ),
        })
    end
    local context_ok, context_detail =
        self.commerceBridge:begin_vendor_interaction(
            nearest_faction_id,
            nearest_actor
        )
    if not context_ok then
        return result(false, "merchant-commerce-context-failed", {
            factionId = nearest_faction_id,
            actor = nearest_actor,
            detail = tostring(context_detail),
        })
    end
    local item_shop_opened, item_shop_route, item_shop_detail =
        self:_open_native_item_shop(nearest_actor, player_actor)
    if not item_shop_opened then
        self.commerceBridge:clear_vendor_interaction()
        return result(false, "merchant-item-shop-open-failed", {
            factionId = nearest_faction_id,
            actor = nearest_actor,
            distance = math.sqrt(nearest_distance_squared),
            route = "refresh_merchant_shop",
            detail = tostring(item_shop_route),
        })
    end
    return result(true, "merchant-native-item-shop-dispatched", {
        factionId = nearest_faction_id,
        actor = nearest_actor,
        distance = math.sqrt(nearest_distance_squared),
        route = "refresh_merchant_shop -> "
            .. tostring(item_shop_route),
        shop = item_shop_detail and item_shop_detail.shop,
        shopSource = item_shop_detail
            and item_shop_detail.shopSource,
        detail = item_shop_detail and item_shop_detail.shopState,
        dispatchParameter = item_shop_detail
            and item_shop_detail.dispatchParameter,
        uiId = item_shop_detail and item_shop_detail.uiId,
    })
end

return FactionEconomyMerchantRuntime
