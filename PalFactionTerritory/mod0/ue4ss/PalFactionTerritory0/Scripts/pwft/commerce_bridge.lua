local CommerceBridge = {}

local BUY_REQUEST_HOOK =
    "/Script/Pal.PalNetworkShopComponent:RequestBuyProduct_ToServer"
local BUY_RESULT_HOOK =
    "/Script/Pal.PalNetworkShopComponent:RecieveBuyResult_ToClient"
local SELL_REQUEST_HOOK =
    "/Script/Pal.PalNetworkShopComponent:RequestSellItems_ToServer"
local ITEM_UI_TRY_SELL_HOOK =
    "/Script/Pal.PalUIItemShopBase:TrySell"
local ITEM_SLOT_STACK_REPLICATION_HOOK =
    "/Script/Pal.PalItemSlot:OnRep_StackCount"
local ITEM_SLOT_ID_REPLICATION_HOOK =
    "/Script/Pal.PalItemSlot:OnRep_ItemId"
local SETUP_HOOK =
    "/Script/Pal.PalNetworkShopComponent:SetupShopDataForActor_ToServer"

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

-- Runtime vendor metadata may acquire UE4SS callbacks or wrapped native
-- objects after registration.  Those values are useful to the in-process
-- bridge, but they must never cross the external companion JSON boundary.
-- Keep the internal copy above intact and emit only the documented public
-- merchant fields.
local function public_vendor_metadata(metadata)
    metadata = type(metadata) == "table" and metadata or {}
    local projected = {}
    local fields = {
        "mode",
        "commercialTruce",
        "merchantOrganisationId",
        "representedFactionId",
        "economyCatalogBinding",
        "source",
    }
    for _, field in ipairs(fields) do
        local value = metadata[field]
        local value_type = type(value)
        if value_type == "string" or value_type == "boolean"
            or (value_type == "number"
                and value == value
                and value ~= math.huge
                and value ~= -math.huge) then
            projected[field] = value
        end
    end
    return projected
end

local function safe_unwrap(value)
    if value == nil then
        return nil
    end
    local value_type = type(value)
    if value_type ~= "table" and value_type ~= "userdata" then
        return value
    end
    local ok, unwrapped = pcall(function()
        if type(value.get) == "function" then
            return value:get()
        end
        return value
    end)
    -- RemoteUnrealParam:get() is a no-argument unwrap, while UE4SS container
    -- wrappers such as TArray also expose get(index).  Once a hook parameter
    -- has already been unwrapped to a TArray, calling get() without an index
    -- raises.  Preserve that wrapper so ForEach can enumerate it instead of
    -- silently turning a valid sale selection into an empty list.
    if ok then
        return unwrapped
    end
    return value
end

local function object_key(value)
    value = safe_unwrap(value)
    if value == nil then
        return "<nil>"
    end
    local ok, full_name = pcall(function()
        if type(value.GetFullName) == "function" then
            return value:GetFullName()
        end
        return nil
    end)
    if ok and type(full_name) == "string" and full_name ~= "" then
        return full_name
    end
    return tostring(value)
end

local function safe_property(object, name)
    object = safe_unwrap(object)
    if object == nil then
        return nil
    end
    local ok, value = pcall(function()
        return object[name]
    end)
    return ok and value or nil
end

local function name_text(value)
    value = safe_unwrap(value)
    if value == nil then
        return nil
    end
    local ok, converted = pcall(function()
        if type(value.ToString) == "function" then
            return value:ToString()
        end
        return tostring(value)
    end)
    if not ok or converted == nil then
        return nil
    end
    converted = tostring(converted)
    return converted ~= "" and converted or nil
end

local function guid_text(value)
    value = safe_unwrap(value)
    if value == nil then
        return "<nil-guid>"
    end
    local ok, converted = pcall(function()
        if type(value.ToString) == "function" then
            return value:ToString()
        end
        return nil
    end)
    if ok and converted ~= nil and tostring(converted) ~= "" then
        return tostring(converted)
    end
    if type(value) == "table"
        and value.A ~= nil and value.B ~= nil
        and value.C ~= nil and value.D ~= nil then
        return string.format(
            "%08x-%08x-%08x-%08x",
            tonumber(value.A) or 0,
            tonumber(value.B) or 0,
            tonumber(value.C) or 0,
            tonumber(value.D) or 0
        )
    end
    return tostring(value)
end

local function integer_value(value, fallback)
    value = safe_unwrap(value)
    local converted = tonumber(value)
    if converted == nil then
        return fallback
    end
    return math.floor(converted)
end

local function is_success_result(value)
    value = safe_unwrap(value)
    if tonumber(value) == 0 then
        return true
    end
    return string.find(tostring(value), "Successed", 1, true) ~= nil
end

local function bool_value(value)
    value = safe_unwrap(value)
    if value == true or value == 1 then
        return true
    end
    local rendered = string.lower(tostring(value))
    return rendered == "true" or rendered == "1"
end

local function for_each_array(array, callback)
    array = safe_unwrap(array)
    if array == nil then
        return false
    end
    local for_each = safe_property(array, "ForEach")
    if type(for_each) == "function" then
        local ok = pcall(function()
            array:ForEach(function(index, element)
                callback(index, element)
            end)
        end)
        return ok
    end
    if type(array) == "table" then
        for index, element in pairs(array) do
            callback(index, element)
        end
        return true
    end
    return false
end

local function extract_item_slots(raw_slots)
    local items = {}
    for_each_array(raw_slots, function(_, raw_slot)
        local slot = safe_unwrap(raw_slot)
        if slot ~= nil then
            local item_id_value =
                safe_property(slot, "ItemId")
            if item_id_value == nil
                and type(slot.GetItemId) == "function" then
                local ok, resolved = pcall(function()
                    return slot:GetItemId()
                end)
                if ok then
                    item_id_value = resolved
                end
            end
            local item_id = name_text(
                safe_property(item_id_value, "StaticId")
            )
            local count_value =
                safe_property(slot, "StackCount")
            if count_value == nil
                and type(slot.GetStackCount) == "function" then
                local ok, resolved = pcall(function()
                    return slot:GetStackCount()
                end)
                if ok then
                    count_value = resolved
                end
            end
            local count = integer_value(count_value, 0)
            if item_id ~= nil and count > 0 then
                table.insert(items, {
                    itemId = item_id,
                    count = count,
                    initialCount = count,
                    slot = slot,
                    slotKey = object_key(slot),
                })
            end
        end
    end)
    return items
end

local function native_name(value)
    if type(FName) == "function" then
        local ok, converted = pcall(FName, value)
        if ok and converted ~= nil then
            return converted
        end
    end
    if type(StaticFindObject) == "function" then
        local ok, strings = pcall(
            StaticFindObject,
            "/Script/Engine.Default__KismetStringLibrary"
        )
        if ok and safe_unwrap(strings) ~= nil then
            local converted_ok, converted = pcall(function()
                return strings:Conv_StringToName(value)
            end)
            if converted_ok and converted ~= nil then
                return converted
            end
        end
    end
    return nil
end

-- ItemShop may pass a transient presentation slot to TrySell. Its fields do
-- not necessarily replicate when the authoritative inventory removes the
-- whole stack. Capture a second, read-only baseline from the live player
-- inventory so confirmation still depends on replicated inventory state.
local function default_inventory_snapshot_resolver(item_id, sold_count)
    if type(FindAllOf) ~= "function" then
        return nil
    end
    local item_name = native_name(item_id)
    if item_name == nil then
        return nil
    end
    local ok, inventories = pcall(FindAllOf, "PalPlayerInventoryData")
    if not ok or type(inventories) ~= "table" then
        return nil
    end
    for _, inventory in pairs(inventories) do
        inventory = safe_unwrap(inventory)
        local inventory_key = object_key(inventory)
        if inventory ~= nil
            and string.find(inventory_key, "Default__", 1, true) == nil then
            local counted, initial_count = pcall(function()
                return inventory:CountItemNum(item_name)
            end)
            initial_count = integer_value(initial_count, nil)
            if counted
                and initial_count ~= nil
                and initial_count >= integer_value(sold_count, 0) then
                return {
                    itemId = item_id,
                    inventoryKey = inventory_key,
                    initialCount = initial_count,
                    soldCount = integer_value(sold_count, 0),
                    readCurrentCount = function()
                        return inventory:CountItemNum(item_name)
                    end,
                }
            end
        end
    end
    return nil
end

local function attach_inventory_snapshots(instance, items)
    local totals = {}
    for _, item in ipairs(items or {}) do
        totals[item.itemId] = (totals[item.itemId] or 0)
            + integer_value(item.count, 0)
    end
    local snapshots = {}
    for item_id, sold_count in pairs(totals) do
        local ok, snapshot = pcall(
            instance.inventorySnapshotResolver,
            item_id,
            sold_count
        )
        if ok and type(snapshot) == "table"
            and type(snapshot.readCurrentCount) == "function"
            and integer_value(snapshot.initialCount, nil) ~= nil then
            snapshot.itemId = item_id
            snapshot.soldCount = sold_count
            snapshots[item_id] = snapshot
        end
    end
    for _, item in ipairs(items or {}) do
        item.inventorySnapshot = snapshots[item.itemId]
    end
end

local function default_window_id()
    if os ~= nil and type(os.date) == "function" then
        return "real-day:" .. os.date("!%Y-%m-%d")
    end
    return "runtime-window:unknown"
end

local function default_transaction_id(instance, direction, shop_id, product_id)
    instance.transactionSequence = instance.transactionSequence + 1
    local epoch = 0
    if os ~= nil and type(os.time) == "function" then
        epoch = os.time()
    end
    return table.concat({
        direction,
        tostring(epoch),
        tostring(instance.transactionSequence),
        shop_id,
        product_id or "none",
    }, ":")
end

local function log(instance, message)
    if instance.logger ~= nil then
        pcall(instance.logger, "[CommerceBridge] " .. message)
    end
end

local function emit_event(instance, event)
    if instance.eventSink == nil then
        return true
    end
    local ok, sink_error = pcall(instance.eventSink, copy(event))
    if not ok then
        log(instance, "EVENT_SINK_FAILED reason=" .. tostring(sink_error))
        return false
    end
    return true
end

function CommerceBridge.create(commerce, options)
    assert(type(commerce) == "table", "faction commerce instance is required")
    assert(type(commerce.register_shop) == "function", "invalid faction commerce instance")
    options = options or {}
    return setmetatable({
        version = "1.0.0",
        commerce = commerce,
        logger = options.logger,
        eventSink = options.eventSink,
        windowIdProvider = options.windowIdProvider or default_window_id,
        transactionIdFactory = options.transactionIdFactory,
        priceResolver = options.priceResolver,
        buyPolicyResolver = options.buyPolicyResolver,
        inventorySnapshotResolver =
            options.inventorySnapshotResolver
                or default_inventory_snapshot_resolver,
        vendorFactions = {},
        vendorMetadata = {},
        componentFactions = {},
        componentMetadata = {},
        pendingBuys = {},
        pendingSales = {},
        activeUiSaleAttempt = nil,
        transactionSequence = 0,
        hookCount = 0,
        buyRequestCount = 0,
        successfulBuyCount = 0,
        failedBuyCount = 0,
        noCommerceAwardBuyCount = 0,
        sellRequestCount = 0,
        itemSellUiRequestCount = 0,
        itemSellUiAcceptedCount = 0,
        extractedSaleItemCount = 0,
        confirmedSellCount = 0,
        callbacks = {},
        nativeSaleReplicationProbeEnabled =
            options.nativeSaleReplicationProbeEnabled == true,
        nativeSaleReputationSettlementEnabled =
            options.nativeSaleReputationSettlementEnabled == true,
        nativeSellReplicationEventCount = 0,
        nativeSellReplicationConfirmedCount = 0,
        nativeSellReplicationProbeOnlyCount = 0,
        nativeSellSettlementAttemptCount = 0,
        nativeSellSettlementRetryCount = 0,
        nativeSellSettlementFailureCount = 0,
        pendingVendorInteraction = nil,
    }, { __index = CommerceBridge })
end

function CommerceBridge:begin_vendor_interaction(faction_id, actor)
    local actor_key = object_key(actor)
    if self.vendorFactions[actor_key] ~= faction_id then
        return false, "vendor-interaction-faction-mismatch"
    end
    self.pendingVendorInteraction = {
        factionId = faction_id,
        actorKey = actor_key,
        metadata = copy(self.vendorMetadata[actor_key] or {}),
    }
    return true, self.pendingVendorInteraction
end

function CommerceBridge:clear_vendor_interaction()
    self.pendingVendorInteraction = nil
end

function CommerceBridge:clear_world_vendor_state()
    -- A load-map callback runs after the previous UWorld has already started
    -- tearing down. Do not stringify or invoke any vendor/component UObject
    -- from that world: replace the string-keyed routing tables atomically.
    self.vendorFactions = {}
    self.vendorMetadata = {}
    self.componentFactions = {}
    self.componentMetadata = {}
    self.pendingBuys = {}
    self.pendingSales = {}
    self.activeUiSaleAttempt = nil
    self.pendingVendorInteraction = nil
    return true, "world-vendor-state-cleared"
end

function CommerceBridge:register_vendor_actor(
    faction_id,
    actor,
    metadata
)
    assert(self.commerce:merchant_status(faction_id) ~= nil, "unknown commerce faction")
    local key = object_key(actor)
    if key == "<nil>" then
        return false, "invalid-vendor-actor"
    end
    self.vendorFactions[key] = faction_id
    self.vendorMetadata[key] = copy(metadata or {})
    log(self, string.format(
        "ECONOMY_VENDOR_REGISTERED faction=%s vendor=%s catalog=%s mode=%s",
        faction_id,
        key,
        tostring(metadata and metadata.economyCatalogBinding == true),
        tostring(metadata and metadata.mode or "unknown")
    ))
    emit_event(self, {
        type = "merchant-registered",
        factionId = faction_id,
        vendorKey = key,
        metadata = public_vendor_metadata(metadata),
    })
    return true, key
end

function CommerceBridge:unregister_vendor_actor(actor)
    local key = object_key(actor)
    if key == "<nil>" then
        return false, "invalid-vendor-actor"
    end
    if self.vendorFactions[key] == nil then
        return true, "vendor-not-registered"
    end
    self.vendorFactions[key] = nil
    self.vendorMetadata[key] = nil
    return true, "vendor-unregistered"
end

function CommerceBridge:on_shop_setup(component, vendor_actor)
    local vendor_key = object_key(vendor_actor)
    local faction_id = self.vendorFactions[vendor_key]
    if faction_id == nil then
        return false, "vendor-unregistered"
    end
    local component_key = object_key(component)
    self.componentFactions[component_key] = faction_id
    self.componentMetadata[component_key] =
        copy(self.vendorMetadata[vendor_key] or {})
    log(self, string.format(
        "ECONOMY_SHOP_BOUND faction=%s vendor=%s component=%s catalog=%s",
        faction_id,
        vendor_key,
        component_key,
        tostring(
            self.componentMetadata[component_key]
                .economyCatalogBinding == true
        )
    ))
    emit_event(self, {
        type = "merchant-shop-opened",
        factionId = faction_id,
        vendorKey = vendor_key,
        componentKey = component_key,
    })
    return true, faction_id
end

function CommerceBridge:on_buy_request(component, shop_guid, product_guid, buy_num)
    local component_key = object_key(component)
    local faction_id = self.componentFactions[component_key]
    if faction_id == nil then
        return false, "component-unregistered"
    end
    local shop_id = guid_text(shop_guid)
    local product_id = guid_text(product_guid)
    local shop_metadata =
        copy(self.componentMetadata[component_key] or {})
    shop_metadata.source = "native-network-shop"
    self.commerce:register_shop(
        shop_id,
        faction_id,
        shop_metadata
    )
    local transaction_id
    if self.transactionIdFactory ~= nil then
        transaction_id = self.transactionIdFactory(
            "buy",
            shop_id,
            product_id,
            integer_value(buy_num, 1)
        )
    else
        transaction_id = default_transaction_id(
            self,
            "buy",
            shop_id,
            product_id
        )
    end
    local total_gold = 0
    if self.priceResolver ~= nil then
        local ok, resolved = pcall(
            self.priceResolver,
            shop_id,
            product_id,
            integer_value(buy_num, 1)
        )
        if ok and tonumber(resolved) ~= nil and tonumber(resolved) >= 0 then
            total_gold = tonumber(resolved)
        end
    end
    local pending = {
        factionId = faction_id,
        shopId = shop_id,
        productId = product_id,
        buyNum = integer_value(buy_num, 1),
        totalGold = total_gold,
        transactionId = tostring(transaction_id),
        commerceWindowId = tostring(self.windowIdProvider()),
    }
    if self.buyPolicyResolver ~= nil then
        local ok, policy = pcall(
            self.buyPolicyResolver,
            copy(pending)
        )
        if ok and type(policy) == "table" then
            pending.buyPolicy = copy(policy)
        elseif not ok then
            log(self, "BUY_POLICY_RESOLVER_FAILED reason=" .. tostring(policy))
        end
    end
    local queue = self.pendingBuys[component_key] or {}
    table.insert(queue, pending)
    self.pendingBuys[component_key] = queue
    self.buyRequestCount = self.buyRequestCount + 1
    return true, queue[#queue]
end

function CommerceBridge:on_buy_result(component, result_type)
    local component_key = object_key(component)
    local queue = self.pendingBuys[component_key]
    if queue == nil or #queue == 0 then
        return false, "no-pending-buy"
    end
    local pending = table.remove(queue, 1)
    if not is_success_result(result_type) then
        self.failedBuyCount = self.failedBuyCount + 1
        emit_event(self, {
            type = "commerce-buy-result",
            ok = false,
            reason = "native-buy-failed",
            transactionId = pending.transactionId,
            factionId = pending.factionId,
            shopId = pending.shopId,
            productId = pending.productId,
            buyNum = pending.buyNum,
            totalGold = pending.totalGold,
            settlementKind = pending.buyPolicy
                    and pending.buyPolicy.settlementKind or nil,
            settlementReferenceId = pending.buyPolicy
                    and pending.buyPolicy.settlementReferenceId or nil,
            commerceReputationSuppressed = pending.buyPolicy
                    and pending.buyPolicy.skipCommerceReputation == true
                or false,
        })
        return true, {
            ok = false,
            reason = "native-buy-failed",
            transactionId = pending.transactionId,
        }
    end
    local suppress_commerce = pending.buyPolicy ~= nil
        and pending.buyPolicy.skipCommerceReputation == true
    local outcome
    if suppress_commerce then
        self.noCommerceAwardBuyCount = self.noCommerceAwardBuyCount + 1
        outcome = {
            ok = true,
            reason = "native-buy-confirmed-commerce-award-suppressed",
            applied = 0,
            requestedAward = 0,
            direction = "buy",
            factionId = pending.factionId,
            shopId = pending.shopId,
            transactionId = pending.transactionId,
        }
    else
        outcome = self.commerce:confirm_buy(
            pending.shopId,
            pending.transactionId,
            pending.totalGold,
            pending.commerceWindowId
        )
    end
    self.successfulBuyCount = self.successfulBuyCount + 1
    log(self, string.format(
        "ECONOMY_BUY_CONFIRMED shop=%s product=%s quantity=%d award=%s",
        pending.shopId,
        pending.productId,
        pending.buyNum,
        tostring(outcome.applied or 0)
    ))
    local event = copy(outcome)
    event.type = "commerce-buy-result"
    event.ok = outcome.ok == true
    event.productId = pending.productId
    event.buyNum = pending.buyNum
    event.totalGold = pending.totalGold
    event.settlementKind = pending.buyPolicy
            and pending.buyPolicy.settlementKind or nil
    event.settlementReferenceId = pending.buyPolicy
            and pending.buyPolicy.settlementReferenceId or nil
    event.commerceReputationSuppressed = suppress_commerce
    event.settlementEligible = pending.buyPolicy
            and pending.buyPolicy.settlementEligible or nil
    emit_event(self, event)
    return true, outcome
end

function CommerceBridge:on_sell_request(component, shop_guid, raw_items)
    local component_key = object_key(component)
    local ui_attempt = self.activeUiSaleAttempt
    local faction_id = ui_attempt
            and ui_attempt.factionId
        or self.componentFactions[component_key]
    if faction_id == nil then
        return false, "component-unregistered"
    end
    local shop_id = guid_text(shop_guid)
    local shop_metadata = copy(
        ui_attempt
                and ui_attempt.vendorMetadata
            or self.componentMetadata[component_key]
            or {}
    )
    shop_metadata.source = "native-network-shop"
    self.commerce:register_shop(
        shop_id,
        faction_id,
        shop_metadata
    )
    if ui_attempt ~= nil then
        -- UE4SS RegisterHook callbacks expose the UFunction inputs, but not
        -- the original return value.  Reaching the authoritative server RPC
        -- from PalUIItemShopBase:TrySell is the native acceptance signal.
        if ui_attempt.accepted ~= true then
            ui_attempt.accepted = true
            self.itemSellUiAcceptedCount =
                self.itemSellUiAcceptedCount + 1
        end
    end
    self.pendingSales[component_key] = {
        shopId = shop_id,
        factionId = faction_id,
        rawItems = safe_unwrap(raw_items),
        extractedItems = ui_attempt
                and ui_attempt.items
            or nil,
        uiAttempt = ui_attempt,
        replicationConfirmed = false,
        confirmationId = nil,
        commerceWindowId = nil,
        settlementAttemptCount = 0,
    }
    if ui_attempt ~= nil then
        ui_attempt.pendingComponentKey =
            component_key
    end
    self.activeUiSaleAttempt = nil
    self.sellRequestCount = self.sellRequestCount + 1
    log(self, string.format(
        "NATIVE_SELL_SERVER_REQUEST faction=%s component=%s items=%d uiAccepted=%s",
        tostring(faction_id),
        tostring(component_key),
        type(self.pendingSales[component_key].extractedItems) == "table"
                and #self.pendingSales[component_key].extractedItems
            or 0,
        tostring(ui_attempt ~= nil and ui_attempt.accepted == true)
    ))
    self:schedule_native_sale_state_confirmation(component_key)
    return true, self.pendingSales[component_key]
end

function CommerceBridge:schedule_native_sale_state_confirmation(
    component_key
)
    if not self.nativeSaleReplicationProbeEnabled
        or type(ExecuteWithDelay) ~= "function" then
        return false
    end
    local max_attempts = 12
    local delay_ms = 200
    local function schedule(attempt)
        ExecuteWithDelay(delay_ms, function()
            local function evaluate()
                local pending = self.pendingSales[component_key]
                if pending == nil then
                    return
                end
                local confirmed, reason =
                    self:evaluate_native_sale_replication(
                        component_key,
                        "server-request-authoritative-slot-state"
                    )
                if confirmed then
                    return
                end
                if reason == "sale-replication-incomplete"
                    and attempt < max_attempts then
                    schedule(attempt + 1)
                    return
                end
                if reason == "sale-replication-incomplete" then
                    log(self, string.format(
                        "NATIVE_SELL_STATE_CONFIRMATION_TIMEOUT component=%s attempts=%d settlement=false",
                        tostring(component_key),
                        attempt
                    ))
                end
            end
            if type(ExecuteInGameThread) == "function" then
                ExecuteInGameThread(evaluate)
            else
                evaluate()
            end
        end)
    end
    schedule(1)
    return true
end

function CommerceBridge:on_item_sell_ui_request(
    ui,
    raw_slots
)
    local items = extract_item_slots(raw_slots)
    attach_inventory_snapshots(self, items)
    local vendor_context = self.pendingVendorInteraction
    self.pendingVendorInteraction = nil
    self.activeUiSaleAttempt = {
        uiKey = object_key(ui),
        items = items,
        accepted = nil,
        factionId = vendor_context
            and vendor_context.factionId,
        vendorActorKey = vendor_context
            and vendor_context.actorKey,
        vendorMetadata = vendor_context
            and copy(vendor_context.metadata),
    }
    self.itemSellUiRequestCount =
        self.itemSellUiRequestCount + 1
    self.extractedSaleItemCount =
        self.extractedSaleItemCount + #items
    log(self, string.format(
        "NATIVE_SELL_UI_REQUEST ui=%s items=%d acceptance=awaiting-server-request",
        tostring(self.activeUiSaleAttempt.uiKey),
        #items
    ))
    return true, self.activeUiSaleAttempt
end

function CommerceBridge:on_item_sell_ui_result(
    ui,
    result_value
)
    local attempt = self.activeUiSaleAttempt
    if attempt == nil then
        return false, "no-active-item-sell-ui-attempt"
    end
    if attempt.uiKey ~= object_key(ui) then
        return false, "item-sell-ui-context-mismatch"
    end
    attempt.accepted = bool_value(result_value)
    if attempt.accepted then
        self.itemSellUiAcceptedCount =
            self.itemSellUiAcceptedCount + 1
        if attempt.pendingComponentKey ~= nil then
            self:evaluate_native_sale_replication(
                attempt.pendingComponentKey,
                "ui-accepted"
            )
        end
    elseif attempt.pendingComponentKey ~= nil then
        self.pendingSales[
            attempt.pendingComponentKey
        ] = nil
        emit_event(self, {
            type = "commerce-sale-ui-result",
            ok = false,
            reason = "player-cancelled-or-native-rejected",
        })
    end
    self.activeUiSaleAttempt = nil
    return true, attempt
end

local function current_item_slot_state(item)
    local slot = item and item.slot or nil
    if safe_unwrap(slot) == nil then
        return nil, nil
    end
    local item_id_value = safe_property(slot, "ItemId")
    if item_id_value == nil
        and type(safe_property(slot, "GetItemId")) == "function" then
        local ok, resolved = pcall(function()
            return slot:GetItemId()
        end)
        if ok then
            item_id_value = resolved
        end
    end
    local item_id = name_text(
        safe_property(item_id_value, "StaticId")
    )
    local count_value = safe_property(slot, "StackCount")
    if count_value == nil
        and type(safe_property(slot, "GetStackCount")) == "function" then
        local ok, resolved = pcall(function()
            return slot:GetStackCount()
        end)
        if ok then
            count_value = resolved
        end
    end
    return item_id, integer_value(count_value, nil)
end

local function sale_item_replication_confirms(item)
    local current_item_id, current_count =
        current_item_slot_state(item)
    if current_count == nil then
        return false
    end
    local initial_count =
        integer_value(item.initialCount, item.count or 0)
    local sold_count = integer_value(item.count, 0)
    if sold_count <= 0 or initial_count < sold_count then
        return false
    end
    if current_count <= initial_count - sold_count then
        return true
    end
    return current_item_id ~= nil
        and current_item_id ~= item.itemId
end

local function sale_inventory_replication_confirms(items)
    local snapshots = {}
    for _, item in ipairs(items or {}) do
        local snapshot = item.inventorySnapshot
        if type(snapshot) ~= "table" then
            return false
        end
        snapshots[item.itemId] = snapshot
    end
    local snapshot_count = 0
    for _, snapshot in pairs(snapshots) do
        snapshot_count = snapshot_count + 1
        local read_ok, current_count = pcall(
            snapshot.readCurrentCount
        )
        current_count = integer_value(current_count, nil)
        local initial_count = integer_value(
            snapshot.initialCount,
            nil
        )
        local sold_count = integer_value(snapshot.soldCount, 0)
        if not read_ok
            or current_count == nil
            or initial_count == nil
            or sold_count <= 0
            or current_count > initial_count - sold_count then
            return false
        end
    end
    return snapshot_count > 0
end

local function public_sale_items(items)
    local result = {}
    for _, item in ipairs(items or {}) do
        table.insert(result, {
            itemId = item.itemId,
            count = integer_value(item.count, 0),
            initialCount = integer_value(
                item.initialCount,
                item.count or 0
            ),
        })
    end
    return result
end

function CommerceBridge:evaluate_native_sale_replication(
    component_key,
    trigger
)
    if not self.nativeSaleReplicationProbeEnabled then
        return false, "native-sale-replication-probe-disabled"
    end
    local pending = self.pendingSales[component_key]
    if pending == nil then
        return false, "no-pending-sale"
    end
    if pending.replicationConfirmed then
        if self.nativeSaleReputationSettlementEnabled then
            return self:settle_replicated_sale(
                component_key,
                pending,
                pending.extractedItems,
                trigger or "replication-retry"
            )
        end
        return false, "sale-already-replication-confirmed"
    end
    if pending.uiAttempt == nil
        or pending.uiAttempt.accepted ~= true then
        return false, "item-shop-ui-sale-not-accepted"
    end
    local items = pending.extractedItems
    if type(items) ~= "table" or #items == 0 then
        return false, "sale-items-unresolved"
    end
    if not sale_inventory_replication_confirms(items) then
        for _, item in ipairs(items) do
            if not sale_item_replication_confirms(item) then
                return false, "sale-replication-incomplete"
            end
        end
    end

    pending.replicationConfirmed = true
    self.nativeSellReplicationConfirmedCount =
        self.nativeSellReplicationConfirmedCount + 1
    if self.nativeSaleReputationSettlementEnabled then
        return self:settle_replicated_sale(
            component_key,
            pending,
            items,
            trigger or "slot-replication"
        )
    end

    local confirmation_id = default_transaction_id(
        self,
        "sell-replication",
        pending.shopId,
        tostring(trigger or "slot-replication")
    )

    self.pendingSales[component_key] = nil
    self.nativeSellReplicationProbeOnlyCount =
        self.nativeSellReplicationProbeOnlyCount + 1
    log(self, string.format(
        "NATIVE_SELL_REPLICATION_CONFIRMED trigger=%s items=%d settlement=false reason=live-acceptance-pending",
        tostring(trigger),
        #items
    ))
    emit_event(self, {
        type = "commerce-sale-confirmed",
        ok = true,
        settlementEnabled = false,
        reason = "native-sale-replication-confirmed-probe-only",
        factionId = pending.factionId,
        shopId = pending.shopId,
        confirmationId = confirmation_id,
        items = public_sale_items(items),
    })
    return true, {
        ok = true,
        reason = "native-sale-replication-confirmed-probe-only",
        confirmationId = confirmation_id,
        itemCount = #items,
    }
end

function CommerceBridge:settle_replicated_sale(
    component_key,
    pending,
    items,
    trigger
)
    if pending.confirmationId == nil then
        pending.confirmationId = default_transaction_id(
            self,
            "sell-replication",
            pending.shopId,
            tostring(trigger or "slot-replication")
        )
    end
    if pending.commerceWindowId == nil then
        pending.commerceWindowId =
            tostring(self.windowIdProvider())
    end
    pending.settlementAttemptCount =
        (pending.settlementAttemptCount or 0) + 1
    self.nativeSellSettlementAttemptCount =
        self.nativeSellSettlementAttemptCount + 1
    if pending.settlementAttemptCount > 1 then
        self.nativeSellSettlementRetryCount =
            self.nativeSellSettlementRetryCount + 1
    end
    local confirmed, outcome = self:confirm_item_sale(
        component_key,
        items,
        pending.confirmationId,
        pending.commerceWindowId
    )
    if not confirmed then
        self.nativeSellSettlementFailureCount =
            self.nativeSellSettlementFailureCount + 1
        log(self, string.format(
            "NATIVE_SELL_SETTLEMENT_RETRYABLE trigger=%s items=%d attempt=%d confirmation=%s reason=%s",
            tostring(trigger),
            #items,
            pending.settlementAttemptCount,
            tostring(pending.confirmationId),
            tostring(type(outcome) == "table" and outcome.reason or outcome)
        ))
        return false, outcome
    end
    log(self, string.format(
        "NATIVE_SELL_REPLICATION_CONFIRMED trigger=%s items=%d settlement=true confirmed=true attempt=%d confirmation=%s applied=%s reason=%s",
        tostring(trigger),
        #items,
        pending.settlementAttemptCount,
        tostring(pending.confirmationId),
        tostring(type(outcome) == "table" and outcome.applied or 0),
        tostring(type(outcome) == "table" and outcome.reason or "unknown")
    ))
    return true, outcome
end

function CommerceBridge:on_item_slot_replicated(slot, trigger)
    if not self.nativeSaleReplicationProbeEnabled then
        return false, "native-sale-replication-probe-disabled"
    end
    self.nativeSellReplicationEventCount =
        self.nativeSellReplicationEventCount + 1
    local slot_key = object_key(slot)
    for component_key, pending in pairs(self.pendingSales) do
        local items = pending.extractedItems or {}
        for _, item in ipairs(items) do
            if item.slotKey == slot_key then
                return self:evaluate_native_sale_replication(
                    component_key,
                    trigger or "slot-replication"
                )
            end
        end
    end
    -- A native ItemShop may have supplied a presentation slot instead of the
    -- player's replicated PalItemSlot. Any inventory OnRep is still a safe
    -- wake-up signal: the aggregate player-inventory baseline must show the
    -- full requested decrease before settlement can succeed.
    for component_key, _ in pairs(self.pendingSales) do
        local confirmed, outcome =
            self:evaluate_native_sale_replication(
                component_key,
                (trigger or "slot-replication")
                    .. "-inventory-aggregate"
            )
        if confirmed then
            return true, outcome
        end
    end
    return false, "replicated-slot-not-pending-sale"
end

function CommerceBridge:confirm_item_sale(
    component,
    items,
    native_confirmation_id,
    commerce_window_id
)
    local component_key = object_key(component)
    local pending = self.pendingSales[component_key]
    if pending == nil then
        return false, "no-pending-sale"
    end
    if pending.uiAttempt ~= nil
        and pending.uiAttempt.accepted ~= true then
        return false, "item-shop-ui-sale-not-accepted"
    end
    items = items or pending.extractedItems
    if type(items) ~= "table" or #items == 0 then
        return false, "sale-items-unresolved"
    end
    assert(
        type(native_confirmation_id) == "string"
            and native_confirmation_id ~= "",
        "native sale confirmation ID is required"
    )
    local outcome = self.commerce:confirm_requested_sale(
        pending.shopId,
        native_confirmation_id,
        items,
        commerce_window_id or tostring(self.windowIdProvider())
    )
    if outcome.ok then
        self.pendingSales[component_key] = nil
        self.confirmedSellCount = self.confirmedSellCount + 1
    end
    local event = copy(outcome)
    event.type = "commerce-sale-confirmed"
    event.ok = outcome.ok == true
    event.settlementEnabled = true
    event.items = public_sale_items(items)
    emit_event(self, event)
    return outcome.ok == true, outcome
end

function CommerceBridge:start()
    if type(RegisterHook) ~= "function" then
        return false, "RegisterHook-unavailable"
    end
    local instance = self
    local registrations = {
        {
            path = SETUP_HOOK,
            callback = function(context, vendor_actor)
                instance:on_shop_setup(
                    safe_unwrap(context),
                    safe_unwrap(vendor_actor)
                )
            end,
        },
        {
            path = BUY_REQUEST_HOOK,
            callback = function(context, shop_id, product_id, buy_num)
                instance:on_buy_request(
                    safe_unwrap(context),
                    safe_unwrap(shop_id),
                    safe_unwrap(product_id),
                    safe_unwrap(buy_num)
                )
            end,
        },
        {
            path = BUY_RESULT_HOOK,
            callback = function(context, result_type)
                instance:on_buy_result(
                    safe_unwrap(context),
                    safe_unwrap(result_type)
                )
            end,
        },
        {
            path = SELL_REQUEST_HOOK,
            callback = function(context, shop_id, items)
                instance:on_sell_request(
                    safe_unwrap(context),
                    safe_unwrap(shop_id),
                    safe_unwrap(items)
                )
            end,
        },
        {
            path = ITEM_UI_TRY_SELL_HOOK,
            callback = function(context, item_slots)
                instance:on_item_sell_ui_request(
                    safe_unwrap(context),
                    safe_unwrap(item_slots)
                )
            end,
        },
    }
    if self.nativeSaleReplicationProbeEnabled then
        for _, hook_path in ipairs({
            ITEM_SLOT_STACK_REPLICATION_HOOK,
            ITEM_SLOT_ID_REPLICATION_HOOK,
        }) do
            table.insert(registrations, {
                path = hook_path,
                callback = function()
                    -- Read the slot only after its replicated property has
                    -- reached the client-side object.
                end,
                postCallback = function(context)
                    instance:on_item_slot_replicated(
                        safe_unwrap(context),
                        hook_path
                    )
                end,
            })
        end
    end
    for _, registration in ipairs(registrations) do
        local ok, hook_error = pcall(
            RegisterHook,
            registration.path,
            registration.callback,
            registration.postCallback
        )
        if ok then
            self.callbacks[registration.path] = registration.callback
            self.hookCount = self.hookCount + 1
            log(self, "HOOK_READY path=" .. registration.path)
        else
            log(
                self,
                "HOOK_FAILED path=" .. registration.path
                    .. " reason=" .. tostring(hook_error)
            )
        end
    end
    return self.hookCount == #registrations,
        string.format("registered-%d-of-%d", self.hookCount, #registrations)
end

function CommerceBridge:status()
    local current_window_id = "unavailable"
    local window_ok, window_or_error = pcall(self.windowIdProvider)
    if window_ok and window_or_error ~= nil then
        current_window_id = tostring(window_or_error)
    end
    return {
        version = self.version,
        hookCount = self.hookCount,
        buyRequestCount = self.buyRequestCount,
        successfulBuyCount = self.successfulBuyCount,
        failedBuyCount = self.failedBuyCount,
        noCommerceAwardBuyCount = self.noCommerceAwardBuyCount,
        sellRequestCount = self.sellRequestCount,
        itemSellUiRequestCount =
            self.itemSellUiRequestCount,
        itemSellUiAcceptedCount =
            self.itemSellUiAcceptedCount,
        extractedSaleItemCount =
            self.extractedSaleItemCount,
        confirmedSellCount = self.confirmedSellCount,
        nativeSellReplicationEventCount =
            self.nativeSellReplicationEventCount,
        nativeSellReplicationConfirmedCount =
            self.nativeSellReplicationConfirmedCount,
        nativeSellReplicationProbeOnlyCount =
            self.nativeSellReplicationProbeOnlyCount,
        nativeSellSettlementAttemptCount =
            self.nativeSellSettlementAttemptCount,
        nativeSellSettlementRetryCount =
            self.nativeSellSettlementRetryCount,
        nativeSellSettlementFailureCount =
            self.nativeSellSettlementFailureCount,
        sellNativeSuccessSignal =
            self.nativeSaleReplicationProbeEnabled
                and (
                    self.nativeSaleReputationSettlementEnabled
                        and "server-inventory-replication-confirmation-enabled"
                    or "server-inventory-replication-probe-ready-settlement-disabled"
                )
            or "ui-slots-extracted-server-success-pending-live-capture",
        currentWindowId = current_window_id,
    }
end

return CommerceBridge
