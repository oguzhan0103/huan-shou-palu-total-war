local UEHelpers = require("UEHelpers")

local PREFIX = "[PalFactionTerritoryQAHarness0]"
local SETTLEMENT_LOCATION = {
    -- Live-confirmed fast-travel clearing beside the Small Settlement.  The
    -- previous registry centre resolved inside the western rock face.
    X = -346921.47,
    Y = 191667.52,
    -- Five metres above the live ground sample lets native collision settle.
    Z = 300.00,
}
local SETTLEMENT_ROTATION = {
    Pitch = 0.0,
    Yaw = 0.0,
    Roll = 0.0,
}
local callbacks = {}
local active_item_shop_widget = nil
local pending_item_shop_pushes = {}
local SALE_TEST_ITEM_ID = "IronIngot"
local SALE_TEST_ITEM_COUNT = 40
local SALE_TEST_BULK_ITEM_COUNT = 400
local make_name
local full_name

local function log(message)
    print(string.format("%s %s\n", PREFIX, tostring(message)))
end

local function is_valid(object)
    if object == nil then
        return false
    end
    local ok, valid = pcall(function()
        return object:IsValid()
    end)
    return ok and valid == true
end

local function unwrap(value)
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
    return ok and unwrapped or nil
end

local function get_player()
    local ok, controller = pcall(function()
        return UEHelpers.GetPlayerController()
    end)
    if not ok or not is_valid(controller) then
        return nil, "player-controller-not-ready"
    end

    local pawn = nil
    pcall(function()
        pawn = controller.Pawn
    end)
    if not is_valid(pawn) then
        pcall(function()
            pawn = controller.AcknowledgedPawn
        end)
    end
    if not is_valid(pawn) then
        return nil, "player-pawn-not-ready"
    end
    return pawn, nil
end

local function stabilize_test_player()
    local function apply()
        local pawn, player_error = get_player()
        if not is_valid(pawn) then
            log(string.format(
                "QA_PLAYER_STABILIZE_FAILED reason=%s saveWrite=false",
                tostring(player_error)
            ))
            return
        end

        local component = nil
        pcall(function()
            component = pawn:GetCharacterParameterComponent()
        end)
        if not is_valid(component) then
            pcall(function()
                component = pawn.CharacterParameterComponent
            end)
        end
        if not is_valid(component) then
            log("QA_PLAYER_STABILIZE_FAILED reason=character-parameter-component-not-ready saveWrite=false")
            return
        end

        local max_hp = nil
        local hp_before = nil
        local stomach_before = nil
        local max_stomach = nil
        local individual = nil
        pcall(function()
            hp_before = component:GetHP()
            max_hp = component:GetMaxHP()
            stomach_before = component:GetFullStomach()
            max_stomach = component:GetMaxFullStomach()
            individual = component:GetIndividualParameter()
        end)
        if not is_valid(individual) then
            pcall(function()
                individual = component.IndividualParameter
            end)
        end

        local hp_ok = false
        local hp_error = "max-hp-not-ready"
        if max_hp ~= nil then
            hp_ok, hp_error = pcall(function()
                component:SetHP(max_hp)
            end)
        end
        local stomach_ok = false
        local stomach_error = "individual-parameter-not-ready"
        if is_valid(individual) then
            stomach_ok, stomach_error = pcall(function()
                individual:SetFullStomach(tonumber(max_stomach) or 100.0)
            end)
        end
        local muteki_ok = false
        local muteki_error = "fname-route-not-ready"
        if type(make_name) == "function" then
            local flag_name = select(1, make_name("PWFT_QA_SUSTAIN"))
            if flag_name ~= nil then
                muteki_ok, muteki_error = pcall(function()
                    component:SetMuteki(flag_name, true)
                end)
            end
        end
        if not muteki_ok then
            muteki_ok, muteki_error = pcall(function()
                component.bIsDebugMuteki = true
            end)
        end

        local hp_after = nil
        local stomach_after = nil
        pcall(function()
            hp_after = component:GetHP()
            stomach_after = component:GetFullStomach()
        end)
        log(string.format(
            "QA_PLAYER_STABILIZED actor=%s hpBefore=%s hpAfter=%s maxHP=%s stomachBefore=%s stomachAfter=%s maxStomach=%s hpOk=%s hpDetail=%s stomachOk=%s stomachDetail=%s mutekiOk=%s mutekiDetail=%s saveWrite=true restorationRequired=true",
            full_name(pawn),
            tostring(hp_before),
            tostring(hp_after),
            tostring(max_hp),
            tostring(stomach_before),
            tostring(stomach_after),
            tostring(max_stomach),
            tostring(hp_ok),
            tostring(hp_error),
            tostring(stomach_ok),
            tostring(stomach_error),
            tostring(muteki_ok),
            tostring(muteki_error)
        ))
    end

    if type(ExecuteInGameThread) == "function" then
        -- UE4SS stores only a Lua registry reference for queued callbacks. Keep
        -- the closure reachable until the game thread has consumed it; without
        -- this strong reference a manual QA hotkey can be collected before the
        -- next tick and fail with "Ref was not function".
        callbacks.stabilizeTestPlayerApply = apply
        ExecuteInGameThread(callbacks.stabilizeTestPlayerApply)
    else
        apply()
    end
end

full_name = function(object)
    if not is_valid(object) then
        return "<invalid>"
    end
    local ok, value = pcall(function()
        return object:GetFullName()
    end)
    return ok and tostring(value) or tostring(object)
end

local function name_text(value)
    if value == nil then
        return nil
    end
    local ok, rendered = pcall(function()
        if type(value.ToString) == "function" then
            return value:ToString()
        end
        return tostring(value)
    end)
    if not ok or rendered == nil or tostring(rendered) == "" then
        return nil
    end
    return tostring(rendered)
end

local function item_slot_state(slot)
    if not is_valid(slot) then
        return nil, nil
    end
    local item_id = nil
    pcall(function()
        item_id = slot.ItemId
    end)
    if item_id == nil then
        pcall(function()
            item_id = slot:GetItemId()
        end)
    end
    local static_id = nil
    if item_id ~= nil then
        pcall(function()
            static_id = item_id.StaticId
        end)
    end
    local count = nil
    pcall(function()
        count = slot.StackCount
    end)
    if tonumber(count) == nil then
        pcall(function()
            count = slot:GetStackCount()
        end)
    end
    return name_text(static_id), tonumber(count)
end

local function find_sale_test_slot()
    local native_name = nil
    if type(make_name) == "function" then
        native_name = select(1, make_name(SALE_TEST_ITEM_ID))
    end
    if native_name ~= nil then
        local inventory_ok, inventories = pcall(
            FindAllOf,
            "PalPlayerInventoryData"
        )
        if inventory_ok and type(inventories) == "table" then
            for _, inventory in pairs(inventories) do
                local inventory_name = full_name(inventory)
                if is_valid(inventory)
                    and string.find(
                        inventory_name,
                        "Default__",
                        1,
                        true
                    ) == nil then
                    local item_count = nil
                    pcall(function()
                        item_count = inventory:CountItemNum(native_name)
                    end)
                    if tonumber(item_count) ~= nil
                        and tonumber(item_count) > 0 then
                        local got_container, returned_container,
                            out_container = pcall(function()
                                return inventory
                                    :TryGetContainerFromStaticItemID(
                                        native_name
                                    )
                            end)
                        returned_container = unwrap(returned_container)
                        out_container = unwrap(out_container)
                        local container = nil
                        if got_container
                            and is_valid(returned_container) then
                            container = returned_container
                        elseif got_container and is_valid(out_container) then
                            container = out_container
                        end
                        if is_valid(container) then
                            local num = nil
                            pcall(function()
                                num = container:Num()
                            end)
                            for index = 0, (tonumber(num) or 0) - 1 do
                                local slot = nil
                                pcall(function()
                                    slot = container:Get(index)
                                end)
                                local item_id, count =
                                    item_slot_state(slot)
                                if item_id == SALE_TEST_ITEM_ID
                                    and tonumber(count) ~= nil
                                    and tonumber(count) > 0 then
                                    return slot,
                                        nil,
                                        count,
                                        "PalPlayerInventoryData.TryGetContainerFromStaticItemID"
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    local ok, slots = pcall(FindAllOf, "PalItemSlot")
    if not ok or type(slots) ~= "table" then
        return nil, "PalItemSlot-unavailable"
    end
    for _, slot in pairs(slots) do
        local slot_name = full_name(slot)
        local item_id, count = item_slot_state(slot)
        if item_id == SALE_TEST_ITEM_ID
            and tonumber(count) ~= nil
            and tonumber(count) > 0 then
            return slot, nil, count, "FindAllOf.PalItemSlot"
        end
    end
    return nil, "sale-test-player-item-slot-not-found"
end

local function find_active_item_shop_ui()
    if is_valid(active_item_shop_widget) then
        return active_item_shop_widget,
            nil,
            "UMG.UserWidget.Construct-captured"
    end
    local failures = {}
    local class_names = {
        "WBP_ItemShop_C",
        "PalUIItemShopBase",
    }
    if type(FindFirstOf) == "function" then
        for _, class_name in ipairs(class_names) do
            local ok, widget = pcall(FindFirstOf, class_name)
            widget = unwrap(widget)
            if ok and is_valid(widget) then
                local widget_name = full_name(widget)
                if string.find(
                    widget_name,
                    "Default__",
                    1,
                    true
                ) == nil then
                    return widget,
                        nil,
                        "FindFirstOf:" .. class_name
                end
            end
        end
    end
    for _, class_name in ipairs(class_names) do
        local ok, widgets = pcall(FindAllOf, class_name)
        if ok and type(widgets) == "table" then
            for _, widget in pairs(widgets) do
                local widget_name = full_name(widget)
                if is_valid(widget)
                    and string.find(
                        widget_name,
                        "Default__",
                        1,
                        true
                    ) == nil then
                    local in_viewport = nil
                    pcall(function()
                        in_viewport = widget:IsInViewport()
                    end)
                    if in_viewport == true then
                        return widget, nil, "IsInViewport"
                    end
                    table.insert(failures, {
                        widget = widget,
                        name = widget_name,
                    })
                end
            end
        end
    end
    -- Some Palworld widgets do not expose IsInViewport to UE4SS even while
    -- visible.  A unique non-CDO instance is still safe for this QA-only
    -- native TrySell route.
    if #failures == 1 then
        return failures[1].widget, nil, "unique-live-instance"
    end
    return nil, "active-item-shop-ui-not-found", tostring(#failures)
end

local function capture_constructed_item_shop(context)
    local widget = unwrap(context)
    if not is_valid(widget) then
        return
    end
    local widget_name = full_name(widget)
    local try_sell = nil
    pcall(function()
        try_sell = widget.TrySell
    end)
    if type(try_sell) == "function"
        or string.find(widget_name, "ItemShop", 1, true) ~= nil then
        active_item_shop_widget = widget
        log(string.format(
            "QA_ITEM_SHOP_WIDGET_CAPTURED widget=%s trySell=%s route=UMG.UserWidget.Construct saveWrite=false",
            widget_name,
            tostring(type(try_sell) == "function")
        ))
    end
end

local function capture_item_shop_push(
    context,
    widget_class
)
    local service = unwrap(context)
    local class_object = unwrap(widget_class)
    if not is_valid(service) or not is_valid(class_object) then
        return
    end
    local class_name = full_name(class_object)
    if string.find(class_name, "ItemShop", 1, true) == nil then
        return
    end
    pending_item_shop_pushes[full_name(service)] = {
        service = service,
        className = class_name,
    }
end

local function resolve_item_shop_push(
    context,
    _,
    __,
    return_value
)
    local service = unwrap(context)
    if not is_valid(service) then
        return
    end
    local service_key = full_name(service)
    local pending = pending_item_shop_pushes[service_key]
    if pending == nil then
        return
    end
    pending_item_shop_pushes[service_key] = nil
    local widget_id = unwrap(return_value)
    local got_widget, widget = pcall(function()
        return service:GetWidget(widget_id)
    end)
    widget = unwrap(widget)
    if got_widget and is_valid(widget) then
        active_item_shop_widget = widget
        log(string.format(
            "QA_ITEM_SHOP_WIDGET_CAPTURED widget=%s class=%s route=PalHUDService.Push->GetWidget saveWrite=false",
            full_name(widget),
            tostring(pending.className)
        ))
        return
    end
    log(string.format(
        "QA_ITEM_SHOP_WIDGET_CAPTURE_FAILED class=%s service=%s detail=%s route=PalHUDService.Push->GetWidget saveWrite=false",
        tostring(pending.className),
        service_key,
        tostring(widget)
    ))
end

local function sell_sale_test_items()
    local apply = function()
        if type(FindAllOf) ~= "function" then
            log("QA_ITEM_SELL_FAILED reason=FindAllOf-unavailable")
            return
        end
        local slot, slot_error, before, slot_route =
            find_sale_test_slot()
        if not is_valid(slot) then
            log("QA_ITEM_SELL_FAILED reason=" .. tostring(slot_error))
            return
        end
        local widget, widget_error, widget_route =
            find_active_item_shop_ui()
        if not is_valid(widget) then
            log(string.format(
                "QA_ITEM_SELL_FAILED reason=%s detail=%s",
                tostring(widget_error),
                tostring(widget_route)
            ))
            return
        end
        local invoked, result_or_error = pcall(function()
            return widget:TrySell({ slot })
        end)
        if not invoked then
            log(string.format(
                "QA_ITEM_SELL_FAILED reason=native-TrySell-call-failed widget=%s slot=%s detail=%s",
                full_name(widget),
                full_name(slot),
                tostring(result_or_error)
            ))
            return
        end
        log(string.format(
            "QA_ITEM_SELL_REQUESTED item=%s countBefore=%s widget=%s slot=%s result=%s route=PalUIItemShopBase.TrySell widgetRoute=%s slotRoute=%s saveWrite=true restorationRequired=true",
            SALE_TEST_ITEM_ID,
            tostring(before),
            full_name(widget),
            full_name(slot),
            tostring(result_or_error),
            tostring(widget_route),
            tostring(slot_route)
        ))
    end
    if type(ExecuteInGameThread) == "function" then
        -- Keep the queued closure alive until UE4SS consumes it on the game
        -- thread. The harness is disabled by default, so retaining one latest
        -- callback for its lifetime is intentional.
        callbacks.sellSaleTestItemsApply = apply
        ExecuteInGameThread(callbacks.sellSaleTestItemsApply)
    else
        apply()
    end
end

make_name = function(value)
    if type(FName) == "function" then
        local ok, native_name = pcall(FName, value)
        if ok and native_name ~= nil then
            return native_name, "FName"
        end
    end
    if type(StaticFindObject) == "function" then
        local ok, strings = pcall(
            StaticFindObject,
            "/Script/Engine.Default__KismetStringLibrary"
        )
        if ok and is_valid(strings) then
            local converted, native_name = pcall(function()
                return strings:Conv_StringToName(value)
            end)
            if converted and native_name ~= nil then
                return native_name, "KismetStringLibrary.Conv_StringToName"
            end
        end
    end
    return nil, "native-name-conversion-unavailable"
end

local function grant_sale_test_items(requested_count)
    local grant_count = tonumber(requested_count)
        or SALE_TEST_ITEM_COUNT
    grant_count = math.max(1, math.floor(grant_count))
    local apply = function()
        if type(FindAllOf) ~= "function" then
            log("QA_ITEM_GRANT_FAILED reason=FindAllOf-unavailable")
            return
        end
        local native_name, name_route = make_name(SALE_TEST_ITEM_ID)
        if native_name == nil then
            log("QA_ITEM_GRANT_FAILED reason=" .. tostring(name_route))
            return
        end
        local inventory_ok, inventories = pcall(
            FindAllOf,
            "PalPlayerInventoryData"
        )
        if inventory_ok and type(inventories) == "table" then
            for _, inventory in pairs(inventories) do
                local inventory_name = full_name(inventory)
                if is_valid(inventory)
                    and string.find(
                        inventory_name,
                        "Default__",
                        1,
                        true
                    ) == nil then
                    local before = nil
                    pcall(function()
                        before = inventory:CountItemNum(native_name)
                    end)
                    local added, result_or_error = pcall(function()
                        return inventory:AddItem_ServerInternal(
                            native_name,
                            grant_count,
                            false,
                            0.0,
                            true
                        )
                    end)
                    local after = nil
                    pcall(function()
                        after = inventory:CountItemNum(native_name)
                    end)
                    if added
                        and tonumber(after) ~= nil
                        and tonumber(after) >= (tonumber(before) or 0)
                            + grant_count then
                        log(string.format(
                            "QA_ITEM_GRANT_CONFIRMED item=%s count=%d inventory=%s before=%s after=%s result=%s route=PalPlayerInventoryData.AddItem_ServerInternal nameRoute=%s saveWrite=true restorationRequired=true",
                            SALE_TEST_ITEM_ID,
                            grant_count,
                            inventory_name,
                            tostring(before),
                            tostring(after),
                            tostring(result_or_error),
                            tostring(name_route)
                        ))
                        return
                    end
                end
            end
        end

        -- Fallback for builds that expose only the network transmitter.  A
        -- request log is not considered confirmation; the inventory route
        -- above remains the acceptance path for the sale test.
        local ok, transmitters = pcall(FindAllOf, "PalNetworkTransmitter")
        if not ok or type(transmitters) ~= "table" then
            log("QA_ITEM_GRANT_FAILED reason=network-transmitter-unavailable")
            return
        end
        local failures = {}
        for _, transmitter in pairs(transmitters) do
            if is_valid(transmitter)
                and string.find(full_name(transmitter), "Default__", 1, true) == nil then
                local player = nil
                local got_player, player_or_error = pcall(function()
                    return transmitter:GetPlayer()
                end)
                if got_player and is_valid(player_or_error) then
                    player = player_or_error
                end
                if player ~= nil then
                    local requested, request_error = pcall(function()
                        return player:RequestAddItem_ToServer(
                            native_name,
                            grant_count,
                            false
                        )
                    end)
                    if requested then
                        log(string.format(
                            "QA_ITEM_GRANT_REQUESTED_UNCONFIRMED item=%s count=%d transmitter=%s player=%s nameRoute=%s saveWrite=true restorationRequired=true",
                            SALE_TEST_ITEM_ID,
                            grant_count,
                            full_name(transmitter),
                            full_name(player),
                            tostring(name_route)
                        ))
                        return
                    end
                    table.insert(failures, tostring(request_error))
                end
            end
        end
        log(
            "QA_ITEM_GRANT_FAILED reason=no-live-network-player detail="
                .. table.concat(failures, "|")
        )
    end
    if type(ExecuteInGameThread) == "function" then
        -- Keep the queued closure alive for the same reason as the native sell
        -- callback above.
        callbacks.grantSaleTestItemsApply = apply
        ExecuteInGameThread(callbacks.grantSaleTestItemsApply)
    else
        apply()
    end
end

local function distance_to_settlement(location)
    local dx = location.X - SETTLEMENT_LOCATION.X
    local dy = location.Y - SETTLEMENT_LOCATION.Y
    local dz = location.Z - SETTLEMENT_LOCATION.Z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function probe(label)
    local pawn, player_error = get_player()
    if player_error ~= nil then
        log(string.format(
            "QA_PROBE label=%s result=%s raidMutation=false saveWrite=false",
            tostring(label),
            tostring(player_error)
        ))
        return
    end

    local location = nil
    pcall(function()
        location = pawn:K2_GetActorLocation()
    end)
    if location == nil then
        log(string.format(
            "QA_PROBE label=%s playerLocation=<unreadable> raidMutation=false saveWrite=false",
            tostring(label)
        ))
        return
    end

    log(string.format(
        "QA_PROBE label=%s playerLocation=(%.3f,%.3f,%.3f) distanceToSettlement=%.1f raidMutation=false saveWrite=false",
        tostring(label),
        location.X,
        location.Y,
        location.Z,
        distance_to_settlement(location)
    ))
end

local function schedule_probe(delay_ms, label)
    local callback = function()
        if type(ExecuteInGameThread) == "function" then
            ExecuteInGameThread(function()
                probe(label)
            end)
        else
            probe(label)
        end
    end
    callbacks[label] = callback
    if type(ExecuteWithDelay) == "function" then
        ExecuteWithDelay(delay_ms, callback)
    elseif type(ExecuteInGameThreadWithDelay) == "function" then
        ExecuteInGameThreadWithDelay(delay_ms, callback)
    end
end

local function teleport_to_settlement()
    local apply = function()
        local pawn, player_error = get_player()
        if player_error ~= nil then
            log("QA_TELEPORT_FAILED reason=" .. tostring(player_error))
            return
        end

        local hit_result = {}
        local ok, result = pcall(function()
            return pawn:K2_SetActorLocationAndRotation(
                SETTLEMENT_LOCATION,
                SETTLEMENT_ROTATION,
                false,
                hit_result,
                true
            )
        end)
        if not ok then
            log("QA_TELEPORT_FAILED reason=" .. tostring(result))
            return
        end

        log(string.format(
            "QA_TELEPORT_REQUESTED success=%s destination=(%.3f,%.3f,%.3f) raidMutation=false saveWrite=false",
            tostring(result),
            SETTLEMENT_LOCATION.X,
            SETTLEMENT_LOCATION.Y,
            SETTLEMENT_LOCATION.Z
        ))
        schedule_probe(1000, "after-teleport-1s")
        schedule_probe(3000, "after-teleport-3s")
        schedule_probe(8000, "after-teleport-8s")
    end

    if type(ExecuteInGameThread) == "function" then
        ExecuteInGameThread(apply)
    else
        apply()
    end
end

if type(RegisterKeyBind) == "function"
    and Key ~= nil
    and Key.F4 ~= nil
    and Key.F3 ~= nil
    and Key.F5 ~= nil
    and Key.F7 ~= nil
    and Key.F9 ~= nil
    and Key.F10 ~= nil
    and Key.F11 ~= nil
    and Key.F12 ~= nil
    and ModifierKey ~= nil
    and ModifierKey.CONTROL ~= nil then
    callbacks.teleport = teleport_to_settlement
    callbacks.stabilizeTestPlayer = stabilize_test_player
    callbacks.grantSaleTestItems = grant_sale_test_items
    callbacks.grantSaleTestItemsBulk = function()
        grant_sale_test_items(SALE_TEST_BULK_ITEM_COUNT)
    end
    callbacks.sellSaleTestItems = sell_sale_test_items
    callbacks.probe = function()
        if type(ExecuteInGameThread) == "function" then
            ExecuteInGameThread(function()
                probe("manual-Ctrl+F9")
            end)
        else
            probe("manual-Ctrl+F9")
        end
    end
    RegisterKeyBind(Key.F10, { ModifierKey.CONTROL }, callbacks.teleport)
    RegisterKeyBind(Key.F4, { ModifierKey.CONTROL }, callbacks.stabilizeTestPlayer)
    RegisterKeyBind(Key.F3, { ModifierKey.CONTROL }, callbacks.grantSaleTestItemsBulk)
    RegisterKeyBind(Key.F9, { ModifierKey.CONTROL }, callbacks.probe)
    RegisterKeyBind(Key.F7, { ModifierKey.CONTROL }, callbacks.grantSaleTestItems)
    RegisterKeyBind(Key.F5, { ModifierKey.CONTROL }, callbacks.sellSaleTestItems)
    -- Unmodified fallbacks avoid collisions with the production Mod's own
    -- modifier-aware F5/F7 routes on builds where UE4SS drops the later chord.
    RegisterKeyBind(Key.F11, callbacks.grantSaleTestItems)
    RegisterKeyBind(Key.F12, callbacks.sellSaleTestItems)
    if type(RegisterHook) == "function" then
        callbacks.itemShopConstruct = capture_constructed_item_shop
        local hook_ok, hook_error = pcall(
            RegisterHook,
            "/Script/UMG.UserWidget:Construct",
            function()
            end,
            callbacks.itemShopConstruct
        )
        log(string.format(
            "QA_ITEM_SHOP_WIDGET_HOOK_READY ok=%s detail=%s route=UMG.UserWidget.Construct saveWrite=false",
            tostring(hook_ok),
            tostring(hook_error)
        ))
        callbacks.itemShopPush = capture_item_shop_push
        callbacks.itemShopPushPost = resolve_item_shop_push
        local push_hook_ok, push_hook_error = pcall(
            RegisterHook,
            "/Script/Pal.PalHUDService:Push",
            callbacks.itemShopPush,
            callbacks.itemShopPushPost
        )
        log(string.format(
            "QA_ITEM_SHOP_PUSH_HOOK_READY ok=%s detail=%s route=PalHUDService.Push->GetWidget saveWrite=false",
            tostring(push_hook_ok),
            tostring(push_hook_error)
        ))
    end
    log("QA_READY teleport=Ctrl+F10 stabilizePlayer=Ctrl+F4 probe=Ctrl+F9 grantSaleItems=Ctrl+F7|F11 grantSaleItemsBulk=Ctrl+F3 sellSaleItems=Ctrl+F5|F12 raidMutation=false testSustainSaveWrite=true itemGrantSaveWrite=true itemSellSaveWrite=true restorationRequired=true")
else
    log("QA_KEYBIND_UNAVAILABLE")
end

_G.PAL_FACTION_TERRITORY_QA_HARNESS0 = {
    settlementLocation = SETTLEMENT_LOCATION,
    callbacks = callbacks,
}
