local Runtime = {}

local PREFIX = "[PalMultiOtomo0]"
local EXACT_RECALL_FUNCTION = "Inactivate Otomo By Handle"

local function log(message)
    print(string.format("%s %s\n", PREFIX, tostring(message)))
end

local function safe_to_string(value)
    if value == nil then
        return "<nil>"
    end
    local value_type = type(value)
    if value_type == "string" or value_type == "number" or value_type == "boolean" then
        return tostring(value)
    end
    local ok, rendered = pcall(function()
        if value.ToString ~= nil then
            return value:ToString()
        end
        return tostring(value)
    end)
    return ok and rendered or "<unreadable>"
end

local function safe_full_name(object)
    if object == nil then
        return "<nil>"
    end
    local ok, value = pcall(function()
        return object:GetFullName()
    end)
    return ok and safe_to_string(value) or "<unreadable>"
end

local function is_valid_object(object)
    if object == nil then
        return false
    end
    local ok, value = pcall(function()
        return object:IsValid()
    end)
    return ok and value == true
end

local function invoke(object, function_name, ...)
    if object == nil then
        return false, "object-is-nil"
    end
    local arguments = table.pack(...)
    return pcall(function()
        local callable = object[function_name]
        if callable == nil then
            error("function-not-found:" .. tostring(function_name))
        end
        return callable(object, table.unpack(arguments, 1, arguments.n))
    end)
end

local function call_game_thread(callback)
    if type(ExecuteInGameThread) == "function" then
        ExecuteInGameThread(callback)
    else
        callback()
    end
end

local function schedule_game_thread(delay_ms, callback)
    if type(ExecuteWithDelay) == "function" then
        ExecuteWithDelay(delay_ms, function()
            call_game_thread(callback)
        end)
    else
        call_game_thread(callback)
    end
end

local function find_local_player_holder()
    if type(FindAllOf) ~= "function" then
        return nil, nil, "FindAllOf-unavailable"
    end

    local ok, holders = pcall(function()
        return FindAllOf("BP_OtomoPalHolderComponent_C")
    end)
    if not ok or type(holders) ~= "table" then
        return nil, nil, "holder-scan-failed"
    end

    local player_candidates = {}
    for _, holder in ipairs(holders) do
        if is_valid_object(holder) then
            local controlled_ok, controlled = invoke(holder, "IsControlledByPlayer")
            local owner_ok, owner = invoke(holder, "TryGetOwnerControlledCharacter")
            if controlled_ok and controlled == true and owner_ok and is_valid_object(owner) then
                local local_ok, is_local = invoke(owner, "IsLocallyControlled")
                if local_ok and is_local == true then
                    return holder, owner, nil
                end
                table.insert(player_candidates, {
                    holder = holder,
                    owner = owner,
                })
            end
        end
    end

    -- Single-player and listen-server worlds have exactly one player-owned
    -- holder even when IsLocallyControlled is not exposed by a particular
    -- generated class.
    if #player_candidates == 1 then
        return player_candidates[1].holder, player_candidates[1].owner, nil
    end
    if #player_candidates > 1 then
        return nil, nil, "multiple-player-holders-no-local-match"
    end
    return nil, nil, "local-player-holder-not-found"
end

local function get_slot_handle(holder, slot_index)
    local ok, handle = invoke(holder, "GetOtomoIndividualHandle", slot_index)
    if not ok or not is_valid_object(handle) then
        return nil
    end
    return handle
end

local function get_slot_actor(holder, slot_index)
    local ok, actor = invoke(holder, "TryGetOtomoActorBySlotIndex", slot_index)
    if not ok or not is_valid_object(actor) then
        return nil
    end
    return actor
end

local function is_actor_active(actor)
    if actor == nil then
        return false
    end
    local ok, active = invoke(actor, "GetActiveActorFlag")
    if ok and type(active) == "boolean" then
        return active
    end
    -- Unknown is deliberately not treated as inactive. Activating an actor
    -- whose state cannot be read is riskier than skipping that party slot.
    return nil
end

local function get_primary_slot(holder)
    local ok, slot_index = invoke(holder, "GetSpawnedOtomoID")
    if not ok or type(slot_index) ~= "number" then
        return -1
    end
    return slot_index
end

local function get_slot_limit(holder, config)
    local configured = tonumber(config.maxPartySlots) or 5
    local ok, native_limit = invoke(holder, "GetMaxOtomoNum")
    if ok and type(native_limit) == "number" and native_limit > 0 then
        return math.min(configured, native_limit)
    end
    return configured
end

local function make_candidate_order(preferred_slot, slot_limit)
    local result = {}
    local seen = {}
    if preferred_slot >= 0 and preferred_slot < slot_limit then
        table.insert(result, preferred_slot)
        seen[preferred_slot] = true
    end
    for slot_index = 0, slot_limit - 1 do
        if not seen[slot_index] then
            table.insert(result, slot_index)
        end
    end
    return result
end

local function choose_auxiliary_slot(holder, config, primary_slot)
    local slot_limit = get_slot_limit(holder, config)
    local preferred = tonumber(config.preferredAuxiliarySlotIndex) or 1
    local candidates = make_candidate_order(preferred, slot_limit)

    for _, slot_index in ipairs(candidates) do
        if slot_index ~= primary_slot then
            local handle = get_slot_handle(holder, slot_index)
            local actor = get_slot_actor(holder, slot_index)
            local active = is_actor_active(actor)
            if handle ~= nil and active == false then
                return slot_index, handle
            end
        end
    end
    return nil, nil
end

local function find_active_auxiliary(holder, config, primary_slot)
    local slot_limit = get_slot_limit(holder, config)
    for slot_index = 0, slot_limit - 1 do
        if slot_index ~= primary_slot then
            local actor = get_slot_actor(holder, slot_index)
            if is_actor_active(actor) == true then
                local handle = get_slot_handle(holder, slot_index)
                if handle ~= nil then
                    return slot_index, handle, actor
                end
            end
        end
    end
    return nil, nil, nil
end

local function find_active_auxiliaries(holder, config, primary_slot)
    local result = {}
    local slot_limit = get_slot_limit(holder, config)
    for slot_index = 0, slot_limit - 1 do
        if slot_index ~= primary_slot then
            local actor = get_slot_actor(holder, slot_index)
            if is_actor_active(actor) == true then
                local handle = get_slot_handle(holder, slot_index)
                if handle ~= nil then
                    table.insert(result, {
                        slotIndex = slot_index,
                        handle = handle,
                        actor = actor,
                    })
                end
            end
        end
    end
    return result
end

local function build_spawn_transform(owner, config, formation_index)
    local location_ok, location = invoke(owner, "K2_GetActorLocation")
    local rotation_ok, rotation = invoke(owner, "K2_GetActorRotation")
    local forward_ok, forward = invoke(owner, "GetActorForwardVector")
    local right_ok, right = invoke(owner, "GetActorRightVector")
    if not location_ok or not rotation_ok or not forward_ok or not right_ok then
        return nil, nil, "trainer-transform-unavailable"
    end

    local formation = nil
    if type(config.formationOffsets) == "table" then
        formation = config.formationOffsets[formation_index or 1]
    end
    local offset_forward = tonumber(formation and formation.forward)
        or tonumber(config.spawnOffsetForward)
        or -120.0
    local offset_right = tonumber(formation and formation.right)
        or tonumber(config.spawnOffsetRight)
        or 280.0
    local offset_up = tonumber(formation and formation.up)
        or tonumber(config.spawnOffsetUp)
        or 40.0
    local spawn_location = {
        X = location.X + forward.X * offset_forward + right.X * offset_right,
        Y = location.Y + forward.Y * offset_forward + right.Y * offset_right,
        Z = location.Z + forward.Z * offset_forward + right.Z * offset_right + offset_up,
    }
    local spawn_rotation = {
        Pitch = rotation.Pitch,
        Yaw = rotation.Yaw,
        Roll = rotation.Roll,
    }
    return spawn_location, spawn_rotation, nil
end

local function finish_operation(state)
    state.busy = false
end

local function verify_spawn(config, state, operation_id)
    if state.operationId ~= operation_id or state.mode ~= "spawn-requested" then
        return
    end
    local holder = state.holder
    local slot_index = state.auxiliarySlotIndex
    if not is_valid_object(holder) then
        state.mode = "idle"
        state.auxiliaryActive = false
        finish_operation(state)
        log("SPAWN_VERIFY_FAILED reason=holder-invalid")
        return
    end

    local actor = get_slot_actor(holder, slot_index)
    local actor_active = is_actor_active(actor)
    local primary_slot = get_primary_slot(holder)
    if actor ~= nil and actor_active == true and primary_slot == state.primarySlotIndex then
        state.mode = "auxiliary-active"
        state.auxiliaryActive = true
        finish_operation(state)
        log(string.format(
            "SPAWN_VERIFIED auxiliarySlot=%d primarySlot=%d actor=%s",
            slot_index + 1,
            primary_slot + 1,
            safe_full_name(actor)
        ))
        return
    end

    state.mode = "idle"
    state.auxiliaryActive = false
    finish_operation(state)
    log(string.format(
        "SPAWN_VERIFY_FAILED auxiliarySlot=%d expectedPrimarySlot=%d actualPrimarySlot=%d actorActive=%s actor=%s",
        slot_index + 1,
        state.primarySlotIndex + 1,
        primary_slot + 1,
        safe_to_string(actor_active),
        safe_full_name(actor)
    ))
end

local function spawn_auxiliary(config, state, holder, owner)
    local primary_slot = get_primary_slot(holder)
    local primary_ok, primary_actor = invoke(holder, "TryGetSpawnedOtomo")
    if primary_slot < 0
        or not primary_ok
        or not is_valid_object(primary_actor)
        or is_actor_active(primary_actor) ~= true then
        log("SPAWN_SKIPPED reason=primary-pal-not-active")
        return false
    end

    local active_auxiliaries = find_active_auxiliaries(holder, config, primary_slot)
    local maximum_auxiliaries = math.min(
        tonumber(config.maxAuxiliaryCount) or 4,
        get_slot_limit(holder, config) - 1
    )
    if #active_auxiliaries >= maximum_auxiliaries then
        log(string.format(
            "SPAWN_SKIPPED reason=auxiliary-limit-reached active=%d limit=%d",
            #active_auxiliaries,
            maximum_auxiliaries
        ))
        return false
    end

    local slot_index, handle = choose_auxiliary_slot(holder, config, primary_slot)
    if slot_index == nil or handle == nil then
        log("SPAWN_SKIPPED reason=no-inactive-party-pal-available")
        return false
    end

    local location, rotation, transform_error =
        build_spawn_transform(owner, config, #active_auxiliaries + 1)
    if location == nil then
        log("SPAWN_SKIPPED reason=" .. tostring(transform_error))
        return false
    end

    state.busy = true
    state.operationId = state.operationId + 1
    state.mode = "spawn-requested"
    state.holder = holder
    state.holderFullName = safe_full_name(holder)
    state.auxiliaryHandle = handle
    state.auxiliarySlotIndex = slot_index
    state.primarySlotIndex = primary_slot
    state.auxiliaryActive = false
    local operation_id = state.operationId

    local call_ok, call_error = invoke(
        holder,
        "ActivatePalByHandle",
        handle,
        location,
        rotation,
        config.keepPrimaryActiveOtomoId == true
    )
    if not call_ok then
        state.mode = "idle"
        finish_operation(state)
        log(string.format(
            "SPAWN_CALL_FAILED auxiliarySlot=%d error=%s",
            slot_index + 1,
            tostring(call_error)
        ))
        return false
    end

    log(string.format(
        "SPAWN_REQUESTED auxiliarySlot=%d primarySlot=%d requestedAuxiliaryCount=%d keepPrimaryId=%s handle=%s",
        slot_index + 1,
        primary_slot + 1,
        #active_auxiliaries + 1,
        tostring(config.keepPrimaryActiveOtomoId == true),
        safe_full_name(handle)
    ))
    schedule_game_thread(config.verificationDelayMs or 900, function()
        verify_spawn(config, state, operation_id)
    end)
    return true
end

local function verify_recall(state, operation_id)
    if state.operationId ~= operation_id or state.mode ~= "recall-requested" then
        return
    end
    local holder = state.holder
    if not is_valid_object(holder) then
        state.mode = "idle"
        state.auxiliaryActive = false
        finish_operation(state)
        log("RECALL_VERIFY_COMPLETE reason=holder-invalid-after-request")
        return
    end

    local actor = get_slot_actor(holder, state.auxiliarySlotIndex)
    local actor_active = is_actor_active(actor)
    if actor == nil or actor_active == false then
        state.mode = "idle"
        state.auxiliaryActive = false
        state.auxiliaryHandle = nil
        finish_operation(state)
        log(string.format(
            "RECALL_VERIFIED auxiliarySlot=%d primarySlot=%d",
            state.auxiliarySlotIndex + 1,
            get_primary_slot(holder) + 1
        ))
        return
    end

    state.mode = "auxiliary-active"
    state.auxiliaryActive = true
    finish_operation(state)
    log(string.format(
        "RECALL_VERIFY_FAILED auxiliarySlot=%d actorActive=%s actor=%s",
        state.auxiliarySlotIndex + 1,
        safe_to_string(actor_active),
        safe_full_name(actor)
    ))
end

local function recall_auxiliary(config, state, holder)
    local current_holder_name = safe_full_name(holder)
    if current_holder_name ~= state.holderFullName or state.auxiliaryHandle == nil then
        log("RECALL_SKIPPED reason=runtime-state-does-not-match-current-holder")
        state.mode = "idle"
        state.auxiliaryActive = false
        state.auxiliaryHandle = nil
        return false
    end

    local current_primary_slot = get_primary_slot(holder)
    if current_primary_slot == state.auxiliarySlotIndex
        and current_primary_slot ~= state.primarySlotIndex then
        log(string.format(
            "RECALL_BLOCKED reason=engine-reassigned-primary auxiliarySlot=%d originalPrimarySlot=%d",
            state.auxiliarySlotIndex + 1,
            state.primarySlotIndex + 1
        ))
        return false
    end

    state.busy = true
    state.operationId = state.operationId + 1
    state.mode = "recall-requested"
    local operation_id = state.operationId
    -- UE4SS requires a Lua table for every non-struct out parameter. The
    -- Blueprint function has three reflected parameters:
    -- IndividualHandle, IsDelayAddReserver, and out bool IsSuccess.
    local success_out = {}
    local call_ok, result_or_error = invoke(
        holder,
        EXACT_RECALL_FUNCTION,
        state.auxiliaryHandle,
        config.delayedReserveOnRecall == true,
        success_out
    )
    if not call_ok then
        state.mode = "auxiliary-active"
        state.auxiliaryActive = true
        finish_operation(state)
        log(string.format(
            "RECALL_CALL_FAILED auxiliarySlot=%d function=%s error=%s",
            state.auxiliarySlotIndex + 1,
            EXACT_RECALL_FUNCTION,
            tostring(result_or_error)
        ))
        return false
    end

    log(string.format(
        "RECALL_REQUESTED auxiliarySlot=%d delayedReserve=%s nativeResult=%s nativeSuccess=%s",
        state.auxiliarySlotIndex + 1,
        tostring(config.delayedReserveOnRecall == true),
        safe_to_string(result_or_error),
        safe_to_string(success_out.IsSuccess)
    ))
    schedule_game_thread(config.verificationDelayMs or 900, function()
        verify_recall(state, operation_id)
    end)
    return true
end

local function verify_recall_all(config, state, operation_id)
    if state.operationId ~= operation_id or state.mode ~= "recall-all-requested" then
        return
    end
    local holder = state.holder
    if not is_valid_object(holder) then
        state.mode = "idle"
        state.auxiliaryActive = false
        finish_operation(state)
        log("RECALL_ALL_VERIFY_COMPLETE reason=holder-invalid-after-request")
        return
    end

    local current_primary_slot = get_primary_slot(holder)
    local original_primary_actor = get_slot_actor(holder, state.primarySlotIndex)
    local original_primary_active = is_actor_active(original_primary_actor)
    if current_primary_slot ~= state.primarySlotIndex
        and state.primarySlotIndex >= 0
        and original_primary_active == true
        and state.primaryRestoreAttempted ~= true then
        state.primaryRestoreAttempted = true
        local restore_ok, restore_error = invoke(
            holder,
            "SetActivateOtomoID_ToALL",
            state.primarySlotIndex
        )
        log(string.format(
            "PRIMARY_ID_RESTORE_REQUESTED from=%d to=%d callOk=%s error=%s",
            current_primary_slot + 1,
            state.primarySlotIndex + 1,
            tostring(restore_ok),
            tostring(restore_error or "none")
        ))
        if restore_ok then
            schedule_game_thread(300, function()
                verify_recall_all(config, state, operation_id)
            end)
            return
        end
    end

    current_primary_slot = get_primary_slot(holder)
    local remaining = find_active_auxiliaries(holder, config, current_primary_slot)
    if #remaining == 0 then
        state.mode = "idle"
        state.auxiliaryActive = false
        state.auxiliaryHandle = nil
        finish_operation(state)
        log(string.format(
            "RECALL_ALL_VERIFIED remaining=0 primarySlot=%d expectedPrimarySlot=%d",
            current_primary_slot + 1,
            state.primarySlotIndex + 1
        ))
        return
    end

    local remaining_slots = {}
    for _, entry in ipairs(remaining) do
        table.insert(remaining_slots, tostring(entry.slotIndex + 1))
    end
    state.mode = "auxiliaries-active"
    state.auxiliaryActive = true
    finish_operation(state)
    log(string.format(
        "RECALL_ALL_VERIFY_FAILED remaining=%d slots=%s",
        #remaining,
        table.concat(remaining_slots, ",")
    ))
end

local function recall_all_auxiliaries(config, state, holder)
    local primary_slot = get_primary_slot(holder)
    local active_auxiliaries = find_active_auxiliaries(holder, config, primary_slot)
    if #active_auxiliaries == 0 then
        log("RECALL_ALL_SKIPPED reason=no-active-auxiliaries")
        return false
    end

    state.busy = true
    state.operationId = state.operationId + 1
    state.mode = "recall-all-requested"
    state.holder = holder
    state.holderFullName = safe_full_name(holder)
    state.primarySlotIndex = primary_slot
    state.primaryRestoreAttempted = false
    local operation_id = state.operationId
    local spacing_ms = tonumber(config.recallSpacingMs) or 250

    for index, entry in ipairs(active_auxiliaries) do
        schedule_game_thread((index - 1) * spacing_ms, function()
            if state.operationId ~= operation_id
                or state.mode ~= "recall-all-requested"
                or not is_valid_object(holder) then
                return
            end

            local success_out = {}
            local call_ok, result_or_error = invoke(
                holder,
                EXACT_RECALL_FUNCTION,
                entry.handle,
                config.delayedReserveOnRecall == true,
                success_out
            )
            if call_ok then
                log(string.format(
                    "RECALL_ONE_REQUESTED auxiliarySlot=%d nativeResult=%s nativeSuccess=%s",
                    entry.slotIndex + 1,
                    safe_to_string(result_or_error),
                    safe_to_string(success_out.IsSuccess)
                ))
            else
                log(string.format(
                    "RECALL_ONE_CALL_FAILED auxiliarySlot=%d error=%s",
                    entry.slotIndex + 1,
                    tostring(result_or_error)
                ))
            end
        end)
    end

    local verify_delay = (#active_auxiliaries - 1) * spacing_ms
        + (tonumber(config.verificationDelayMs) or 900)
    schedule_game_thread(verify_delay, function()
        verify_recall_all(config, state, operation_id)
    end)
    log(string.format(
        "RECALL_ALL_STARTED count=%d primarySlot=%d spacingMs=%d",
        #active_auxiliaries,
        primary_slot + 1,
        spacing_ms
    ))
    return true
end

function Runtime.addOne(config, state)
    if state.busy then
        log("ADD_SKIPPED reason=operation-in-progress")
        return false
    end

    local holder, owner, find_error = find_local_player_holder()
    if holder == nil then
        log("ADD_SKIPPED reason=" .. tostring(find_error))
        return false
    end

    return spawn_auxiliary(config, state, holder, owner)
end

function Runtime.recallAll(config, state)
    if state.busy then
        log("RECALL_ALL_SKIPPED reason=operation-in-progress")
        return false
    end
    local holder, _, find_error = find_local_player_holder()
    if holder == nil then
        log("RECALL_ALL_SKIPPED reason=" .. tostring(find_error))
        return false
    end
    return recall_all_auxiliaries(config, state, holder)
end

Runtime.toggle = Runtime.addOne

local function validate_config(config)
    assert(config.schemaVersion == "0.2.0", "unsupported config schema")
    assert(config.addHotkey == "F6", "add hotkey must be F6")
    assert(config.recallAllHotkey == "F7", "recall-all hotkey must be F7")
    assert(type(config.preferredAuxiliarySlotIndex) == "number", "invalid auxiliary slot")
    assert(type(config.maxPartySlots) == "number" and config.maxPartySlots > 1, "invalid party slot limit")
    assert(
        type(config.maxAuxiliaryCount) == "number"
            and config.maxAuxiliaryCount >= 0
            and config.maxAuxiliaryCount <= config.maxPartySlots - 1,
        "invalid maximum auxiliary count"
    )
    assert(config.keepPrimaryActiveOtomoId == true, "prototype must preserve primary Otomo ID")
end

function Runtime.start(config)
    validate_config(config)
    local state = {
        mode = "idle",
        busy = false,
        operationId = 0,
        holder = nil,
        holderFullName = nil,
        primarySlotIndex = -1,
        auxiliarySlotIndex = -1,
        auxiliaryHandle = nil,
        auxiliaryActive = false,
        callbacks = {},
    }

    if type(RegisterKeyBind) ~= "function"
        or Key == nil
        or Key.F6 == nil
        or Key.F7 == nil then
        log("START_FAILED reason=F6-or-F7-keybind-api-unavailable")
        return state
    end

    local add_callback = function()
        call_game_thread(function()
            local ok, error_message = pcall(function()
                Runtime.addOne(config, state)
            end)
            if not ok then
                state.busy = false
                log("ADD_ERROR error=" .. tostring(error_message))
            end
        end)
    end
    local recall_all_callback = function()
        call_game_thread(function()
            local ok, error_message = pcall(function()
                Runtime.recallAll(config, state)
            end)
            if not ok then
                state.busy = false
                log("RECALL_ALL_ERROR error=" .. tostring(error_message))
            end
        end)
    end
    state.callbacks.add = add_callback
    state.callbacks.recallAll = recall_all_callback
    RegisterKeyBind(Key.F6, add_callback)
    RegisterKeyBind(Key.F7, recall_all_callback)
    log("READY addKey=F6 recallAllKey=F7 maxAuxiliaries=4 noTick=true noSaveWrites=true")
    return state
end

Runtime._test = {
    isValidObject = is_valid_object,
    invoke = invoke,
    findLocalPlayerHolder = find_local_player_holder,
    chooseAuxiliarySlot = choose_auxiliary_slot,
    findActiveAuxiliary = find_active_auxiliary,
    findActiveAuxiliaries = find_active_auxiliaries,
    isActorActive = is_actor_active,
}

return Runtime
