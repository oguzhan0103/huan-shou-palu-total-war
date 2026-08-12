local SettlementRaid = {}
local AttendanceRaidResultBridge =
    require("pwft.attendance_raid_result_bridge")

local PREFIX = "[PalFactionTerritory0][SettlementRaid]"

-- The production route deliberately reuses Palworld's native invasion
-- incident.  A separately gated attendance route can request transient native
-- NPC-manager Pal actors at countdown completion when the player is present;
-- it never spawns actors for an off-screen/background settlement result.
local NATIVE_START_POINT_PATH =
    "/Script/Pal.PalInvaderIncidentBase:GetInvaderStartPoint"
local NATIVE_SELECT_INVADERS_PATH =
    "/Script/Pal.PalInvaderIncidentBase:SelectInvaders"
local NATIVE_TARGET_POSITION_PATH =
    "/Game/Pal/Blueprint/Incident/Invader/BP_PalIncidentInvaderBase.BP_PalIncidentInvaderBase_C:GetTargetBaseCampPosition"
local NATIVE_BASE_SPAWNED_PATH =
    "/Game/Pal/Blueprint/Incident/Invader/BP_PalIncidentInvaderBase.BP_PalIncidentInvaderBase_C:OnCharacterSpawned"
local NATIVE_ENEMY_SPAWNED_PATH =
    "/Game/Pal/Blueprint/Incident/Invader/BP_PalIncidentInvaderEnemy.BP_PalIncidentInvaderEnemy_C:OnCharacterSpawned"
local NATIVE_VISITOR_START_POINT_PATH =
    "/Game/Pal/Blueprint/Incident/Invader/BP_PalIncidentInvaderVisitorNPC.BP_PalIncidentInvaderVisitorNPC_C:GetInvaderStartPoint"
local NATIVE_VISITOR_ALL_SPAWNED_PATH =
    "/Game/Pal/Blueprint/Incident/Invader/BP_PalIncidentInvaderVisitorNPC.BP_PalIncidentInvaderVisitorNPC_C:OnAllCharacterSpawned"
local ATTENDANCE_DEATH_PATH =
    "/Script/Pal.PalCharacter:OnDeadCharacter"
local NATIVE_REQUIRED_HOOK_PATHS = {
    NATIVE_SELECT_INVADERS_PATH,
    NATIVE_START_POINT_PATH,
    NATIVE_TARGET_POSITION_PATH,
    NATIVE_BASE_SPAWNED_PATH,
    NATIVE_ENEMY_SPAWNED_PATH,
    NATIVE_VISITOR_START_POINT_PATH,
    NATIVE_VISITOR_ALL_SPAWNED_PATH,
    ATTENDANCE_DEATH_PATH,
}
local NATIVE_BASE_ASSET_PATH =
    "/Game/Pal/Blueprint/Incident/Invader/BP_PalIncidentInvaderBase.BP_PalIncidentInvaderBase"
local NATIVE_ENEMY_ASSET_PATH =
    "/Game/Pal/Blueprint/Incident/Invader/BP_PalIncidentInvaderEnemy.BP_PalIncidentInvaderEnemy"
local NATIVE_VISITOR_ASSET_PATH =
    "/Game/Pal/Blueprint/Incident/Invader/BP_PalIncidentInvaderVisitorNPC.BP_PalIncidentInvaderVisitorNPC"
local COUNTDOWN_WIDGET_ASSET_PATH =
    "/Game/Pal/Blueprint/UI/UserInterface/InGame/WarningEvent/WBP_WarningEvent_NoticeTimer.WBP_WarningEvent_NoticeTimer"
local COUNTDOWN_WIDGET_CLASS_PATH =
    COUNTDOWN_WIDGET_ASSET_PATH .. "_C"
local NATIVE_MEADOW_BIOME_VALUE = 1
-- Keep the transient attendance-wave lifecycle separate from the native
-- invasion lifecycle; the latter still owns and removes its own actors.
local TRANSIENT_ATTACKER_DESTROY_METHOD = "K2_DestroyActor"
local is_night
local load_pal_utility

local UEHelpers = nil
pcall(function()
    UEHelpers = require("UEHelpers")
end)

local function log(message)
    print(string.format("%s %s\n", PREFIX, tostring(message)))
end

local function is_valid(object)
    if object == nil then
        return false
    end
    local ok, result = pcall(function()
        return object:IsValid()
    end)
    return ok and result == true
end

local function safe_property(object, property_name)
    if object == nil then
        return nil
    end
    local ok, value = pcall(function()
        return object[property_name]
    end)
    return ok and value or nil
end

local function safe_call(object, method_name, ...)
    if not is_valid(object) then
        return false, nil
    end
    local arguments = { ... }
    local ok, result = pcall(function()
        return object[method_name](object, table.unpack(arguments))
    end)
    return ok, result
end

local function safe_hook_param_get(parameter)
    if parameter == nil then
        return nil
    end
    local ok, value = pcall(function()
        return parameter:get()
    end)
    return ok and value or nil
end

local function safe_hook_param_set(parameter, value)
    if parameter == nil then
        return false, "parameter-is-nil"
    end
    local ok, error_message = pcall(function()
        parameter:set(value)
    end)
    if ok then
        return true, nil
    end
    return false, tostring(error_message)
end

local function safe_to_string(value)
    if value == nil then
        return "<nil>"
    end
    if type(value) == "string"
        or type(value) == "number"
        or type(value) == "boolean" then
        return tostring(value)
    end
    local ok, rendered = pcall(function()
        return value:ToString()
    end)
    return ok and tostring(rendered) or tostring(value)
end

local function make_native_name(value)
    if type(FName) == "function" then
        local constructed, native_name = pcall(function()
            return FName(value)
        end)
        if constructed and native_name ~= nil then
            return native_name, nil
        end
    end
    if type(StaticFindObject) == "function" then
        local found, string_library = pcall(function()
            return StaticFindObject(
                "/Script/Engine.Default__KismetStringLibrary"
            )
        end)
        if found and is_valid(string_library) then
            local converted, native_name = safe_call(
                string_library,
                "Conv_StringToName",
                value
            )
            if converted and native_name ~= nil then
                return native_name, nil
            end
        end
    end
    return nil, "native-name-construction-unavailable"
end

local function safe_remote_value(parameter)
    if parameter == nil then
        return nil
    end
    local ok, value = pcall(function()
        return parameter:get()
    end)
    return ok and value or parameter
end

local function safe_guid_string(value)
    if value == nil then
        return "<nil>"
    end
    local components = {}
    for _, name in ipairs({ "A", "B", "C", "D" }) do
        local component = safe_property(value, name)
        if component == nil then
            return safe_to_string(value)
        end
        table.insert(components, tostring(component))
    end
    return table.concat(components, ":")
end

local function native_map_diagnostics(map, matching_key)
    if map == nil then
        return 0, false, "map-unavailable", nil
    end
    local count = 0
    local matched = false
    local matched_value = nil
    local expected = safe_guid_string(matching_key)
    local first_value = nil
    local first_key = nil
    local ok, error_message = pcall(function()
        map:ForEach(function(key_parameter, value_parameter)
            count = count + 1
            local key = safe_remote_value(key_parameter)
            local value = safe_remote_value(value_parameter)
            if first_value == nil then
                first_key = key
                first_value = value
            end
            if safe_guid_string(key) == expected then
                matched = true
                matched_value = value
            end
            return false
        end)
    end)
    return count,
        matched,
        ok and nil or tostring(error_message),
        matched_value or first_value,
        first_key
end


local function native_time_diagnostics(world_context)
    local utility = load_pal_utility()
    if not is_valid(utility) then
        return "manager-unavailable", "unknown", "unknown"
    end
    local manager_ok, manager = safe_call(
        utility,
        "GetTimeManager",
        world_context
    )
    if not manager_ok or not is_valid(manager) then
        return "manager-unavailable", "unknown", "unknown"
    end
    local hour_ok, hour = safe_call(
        manager,
        "GetCurrentPalWorldTime_Hour"
    )
    local type_ok, day_type = safe_call(
        manager,
        "GetCurrentDayTimeType"
    )
    local debug_ok, debug_text = safe_call(
        manager,
        "GetDebugTimeString"
    )
    return hour_ok and tostring(hour) or "unknown",
        type_ok and safe_to_string(day_type) or "unknown",
        debug_ok and safe_to_string(debug_text) or "unknown"
end

local function safe_full_name(object)
    if not is_valid(object) then
        return "<invalid>"
    end
    local ok, name = pcall(function()
        return object:GetFullName()
    end)
    return ok and tostring(name) or "<unreadable>"
end

local function schedule(instance, key, delay_ms, operation)
    local generation = instance.generation
    local callback = function()
        local execute = function()
            if generation ~= instance.generation then
                log(string.format(
                    "CALLBACK_SKIPPED key=%s scheduledGeneration=%d currentGeneration=%d",
                    tostring(key),
                    generation,
                    instance.generation
                ))
                return
            end
            local ok, error_message = pcall(operation)
            if not ok then
                instance.lastError = tostring(error_message)
                log(string.format(
                    "CALLBACK_ERROR key=%s generation=%d error=%s",
                    tostring(key),
                    generation,
                    tostring(error_message)
                ))
            end
        end
        if type(ExecuteInGameThread) == "function" then
            ExecuteInGameThread(execute)
        else
            execute()
        end
    end
    instance.callbacks[key] = callback
    if type(ExecuteWithDelay) == "function" then
        ExecuteWithDelay(delay_ms, callback)
    elseif delay_ms <= 0 then
        callback()
    end
end

local function find_local_player()
    local controller = nil
    if UEHelpers ~= nil and type(UEHelpers.GetPlayerController) == "function" then
        pcall(function()
            controller = UEHelpers.GetPlayerController()
        end)
    end
    if not is_valid(controller) and type(FindFirstOf) == "function" then
        for _, class_name in ipairs({
            "PalPlayerController",
            "PalPlayerController_C",
        }) do
            local ok, candidate = pcall(function()
                return FindFirstOf(class_name)
            end)
            if ok and is_valid(candidate) then
                controller = candidate
                break
            end
        end
    end
    if not is_valid(controller) then
        return nil, nil, "player-controller-not-ready"
    end

    local pawn = safe_property(controller, "Pawn")
    if not is_valid(pawn) then
        pawn = safe_property(controller, "AcknowledgedPawn")
    end
    if not is_valid(pawn) then
        return controller, nil, "player-pawn-not-ready"
    end
    return controller, pawn, nil
end

local function actor_location(actor)
    local ok, location = safe_call(actor, "K2_GetActorLocation")
    if not ok or location == nil then
        return nil
    end
    local x = tonumber(safe_property(location, "X"))
    local y = tonumber(safe_property(location, "Y"))
    local z = tonumber(safe_property(location, "Z"))
    if x == nil or y == nil or z == nil then
        return nil
    end
    return { X = x, Y = y, Z = z }
end

local function squared_distance(first, second)
    local dx = first.X - second.X
    local dy = first.Y - second.Y
    local dz = first.Z - second.Z
    return dx * dx + dy * dy + dz * dz
end

local function is_player_character(actor)
    local name = safe_full_name(actor)
    return string.find(name, "PalPlayerCharacter", 1, true) ~= nil
        or string.find(name, "BP_Player", 1, true) ~= nil
end

local function player_is_near_settlement(instance, player_location)
    local center = instance.config.settlement.location
    local dx = player_location.X - center.X
    local dy = player_location.Y - center.Y
    return dx * dx + dy * dy
        <= instance.config.settlement.triggerRadius
            * instance.config.settlement.triggerRadius
end

local function is_combat_resident_name(name)
    return string.find(name, "BP_NPC_Hunter_C", 1, true) ~= nil
        or string.find(name, "BP_NPC_Police_C", 1, true) ~= nil
        or string.find(name, "Guardman", 1, true) ~= nil
end

-- Native Pal attackers already receive every nearby human as a hate target.
-- Combat-capable residents need the reciprocal target as well; otherwise a
-- visitor guard can keep obeying its follow order while an invader is walking
-- toward it.  Do not arm traders or ordinary residents: this route is limited
-- to police/guard archetypes and lets their native controller own the fight.
local function arm_resident_defender(
    resident,
    attacker,
    source,
    defender_hate
)
    if type(resident) ~= "table"
        or not is_valid(resident.actor)
        or not is_combat_resident_name(resident.name or "") then
        return false, "resident-not-combat-defender"
    end
    local controller_ok, controller = safe_call(
        resident.actor,
        "GetController"
    )
    if not controller_ok or not is_valid(controller) then
        return false, "defender-controller-not-ready"
    end
    local hate_ok, hate = safe_call(controller, "GetHateSystem")
    if not hate_ok or not is_valid(hate) then
        return false, "defender-hate-not-ready"
    end

    local add_ok = safe_call(controller, "AddTargetNPC", attacker)
    local change_ok = safe_call(
        hate,
        "ChangeHate",
        attacker,
        defender_hate
    )
    local target_set = pcall(function()
        controller.R1AttackTarget = attacker
    end)
    local active_ok = safe_call(controller, "SetActiveAI", true)
    local battle_ok = safe_call(
        resident.actor,
        "ChangeBattleModeFlag_ToAll",
        true
    )
    local approach_ok = safe_call(
        controller,
        "SimpleMoveToActorWithLineTraceGround",
        attacker,
        0
    )
    local ready = add_ok
        and change_ok
        and target_set
        and active_ok
        and battle_ok
    log(string.format(
        "SETTLEMENT_DEFENDER_ARMED source=%s defender=%s attacker=%s hate=%.1f added=%s changed=%s targetSet=%s activeAI=%s battle=%s approach=%s ready=%s",
        tostring(source),
        resident.name,
        safe_full_name(attacker),
        defender_hate,
        tostring(add_ok),
        tostring(change_ok),
        tostring(target_set),
        tostring(active_ok),
        tostring(battle_ok),
        tostring(approach_ok),
        tostring(ready)
    ))
    if ready then
        return true, nil
    end
    return false, "defender-activation-incomplete"
end

local function find_residents(instance)
    local residents = {}
    if type(FindAllOf) ~= "function" then
        return residents
    end

    local seen = {}
    local center = instance.config.settlement.location
    local maximum_distance_squared =
        instance.config.settlement.residentRadius
        * instance.config.settlement.residentRadius
    for _, class_name in ipairs({
        "PalNPC",
        "PalNPCCharacter",
    }) do
        local ok, actors = pcall(function()
            return FindAllOf(class_name)
        end)
        if ok and actors ~= nil then
            for _, actor in pairs(actors) do
                local name = safe_full_name(actor)
                local static_component = safe_property(
                    actor,
                    "StaticCharacterParameterComponent"
                )
                local is_pal = is_valid(static_component)
                    and safe_property(static_component, "IsPal") == true
                if is_valid(actor)
                    and seen[name] ~= true
                    and string.find(name, "Default__", 1, true) == nil
                    and not is_player_character(actor)
                    and not is_pal then
                    local location = actor_location(actor)
                    if location ~= nil
                        and squared_distance(location, center)
                            <= maximum_distance_squared then
                        seen[name] = true
                        table.insert(residents, {
                            actor = actor,
                            name = name,
                            location = location,
                        })
                    end
                end
            end
        end
    end
    return residents
end

local function target_residents(instance, attacker, source, target_hate)
    if not is_valid(attacker) then
        return false, "attacker-invalid"
    end
    local ok, controller = safe_call(attacker, "GetController")
    if not ok or not is_valid(controller) then
        return false, "controller-not-ready"
    end

    local attacker_position = actor_location(attacker)
    local residents = find_residents(instance)
    if attacker_position == nil or #residents == 0 then
        return false, "resident-not-ready"
    end

    local hate_ok, hate = safe_call(controller, "GetHateSystem")
    local resident_hate = tonumber(target_hate)
        or instance.config.targetHate
    local added_target_count = 0
    local hate_target_count = 0
    local defenders_armed = 0
    local nearest = nil
    local nearest_preferred = nil
    for _, resident in ipairs(residents) do
        resident.distanceSquared = squared_distance(
            attacker_position,
            resident.location
        )
        if nearest == nil
            or resident.distanceSquared < nearest.distanceSquared then
            nearest = resident
        end
        -- Reward and shop actors are frequently fixed behind counters or
        -- inside non-navigable settlement geometry. Keep them as fallback
        -- targets, but prefer an ordinary resident for the initial assault so
        -- the wave visibly reaches and attacks the town instead of staring at
        -- an unreachable service NPC.
        local preferred = string.find(
            resident.name,
            "Reward_",
            1,
            true
        ) == nil
            and string.find(resident.name, "Trader", 1, true) == nil
            and string.find(resident.name, "Shop", 1, true) == nil
        if preferred and (nearest_preferred == nil
            or resident.distanceSquared
                < nearest_preferred.distanceSquared) then
            nearest_preferred = resident
        end
        local added = safe_call(
            controller,
            "AddTargetNPC",
            resident.actor
        )
        if added then
            added_target_count = added_target_count + 1
        end
        -- Native random encounters and wanted-police spawners use the same
        -- PalHate.ChangeHate route. Give every resident, not just the first
        -- one, an explicit high value so the attacker can acquire the next
        -- NPC after its current target dies or becomes unreachable.
        if hate_ok and is_valid(hate) then
            local changed = safe_call(
                hate,
                "ChangeHate",
                resident.actor,
                resident_hate
            )
            if changed then
                hate_target_count = hate_target_count + 1
            end
        end
        local armed = arm_resident_defender(
            resident,
            attacker,
            source,
            resident_hate * 2.0
        )
        if armed then
            defenders_armed = defenders_armed + 1
        end
    end

    local primary = nearest_preferred or nearest
    local primary_bonus = resident_hate * 2.0
    local primary_boosted = false
    local primary_target_set = false
    local primary_approach_requested = false
    if primary ~= nil and hate_ok and is_valid(hate) then
        primary_boosted = safe_call(
            hate,
            "ChangeHate",
            primary.actor,
            primary_bonus
        ) == true
        primary_target_set = pcall(function()
            controller.R1AttackTarget = primary.actor
        end)
        -- Palworld's combat module exposes AIMoveToTargetActor, but the module
        -- itself is not a reflected controller property in build 24467282.
        -- Drive the same controller toward the chosen actor through its public
        -- ground-aware move helper; once in range, the native combat action and
        -- skill selection remain fully game-owned.
        primary_approach_requested = safe_call(
            controller,
            "SimpleMoveToActorWithLineTraceGround",
            primary.actor,
            0
        ) == true

    end

    local most_hated = nil
    if hate_ok and is_valid(hate) then
        local found, value = safe_call(hate, "FindMostHateTarget")
        most_hated = found and value or nil
    end
    instance.targetAssignments = instance.targetAssignments + 1
    log(string.format(
        "TARGET_ASSIGNED source=%s attacker=%s residents=%d addedTargets=%d hateTargets=%d defendersArmed=%d hatePerTarget=%.1f nearest=%s primary=%s primaryBonus=%.1f primaryBoosted=%s primaryTargetSet=%s approachRequested=%s mostHated=%s assignments=%d",
        tostring(source),
        safe_full_name(attacker),
        #residents,
        added_target_count,
        hate_target_count,
        defenders_armed,
        resident_hate,
        nearest and nearest.name or "<none>",
        primary and primary.name or "<none>",
        primary_bonus,
        tostring(primary_boosted),
        tostring(primary_target_set),
        tostring(primary_approach_requested),
        safe_full_name(most_hated),
        instance.targetAssignments
    ))
    return added_target_count > 0 and hate_target_count > 0, nil
end

local function get_character_components(actor)
    local component = safe_property(actor, "CharacterParameterComponent")
    if not is_valid(component) then
        local ok, value = safe_call(actor, "GetCharacterParameterComponent")
        component = ok and value or nil
    end
    if not is_valid(component) then
        return nil, nil
    end

    local individual = safe_property(component, "IndividualParameter")
    if not is_valid(individual) then
        local ok, value = safe_call(component, "GetIndividualParameter")
        individual = ok and value or nil
    end
    return component, individual
end

local function activate_attacker_combat(attacker, source)
    if not is_valid(attacker) then
        return false, "attacker-invalid"
    end
    local controller_ok, controller = safe_call(attacker, "GetController")
    if not controller_ok or not is_valid(controller) then
        return false, "controller-not-ready"
    end

    local active_before_ok, active_before = safe_call(
        controller,
        "IsActiveAI"
    )
    local awake_before_ok, awake_before = safe_call(
        controller,
        "GetIsnotSleepWildLife"
    )
    local battle_before_ok, battle_before = safe_call(
        attacker,
        "GetBattleMode"
    )
    local initial_set_ok = true
    local initial_set_attempted = awake_before_ok
        and awake_before == false
    if initial_set_attempted then
        -- PalSchema-created field Pals can have an active controller while
        -- their wild-life sleep flag remains false.  Reuse Palworld's native
        -- controller initializer with NotSleep=true before activating combat.
        initial_set_ok = safe_call(
            controller,
            "SetInitialValue",
            false,
            true
        )
    end
    local active_set_ok = safe_call(controller, "SetActiveAI", true)
    -- This is the same activation call used by the working hostile-merchant
    -- route. AddTargetPlayer/AddTargetNPC and HateList alone do not make a
    -- passive or sleeping Pal enter combat.
    local battle_set_ok = safe_call(
        attacker,
        "ChangeBattleModeFlag_ToAll",
        true
    )
    local active_after_ok, active_after = safe_call(
        controller,
        "IsActiveAI"
    )
    local awake_after_ok, awake_after = safe_call(
        controller,
        "GetIsnotSleepWildLife"
    )
    local battle_after_ok, battle_after = safe_call(
        attacker,
        "GetBattleMode"
    )

    log(string.format(
        "AI_COMBAT_ACTIVATED source=%s attacker=%s initialSetAttempted=%s initialSet=%s activeSet=%s battleSet=%s activeBefore=%s activeAfter=%s awakeBefore=%s awakeAfter=%s battleBefore=%s battleAfter=%s",
        tostring(source),
        safe_full_name(attacker),
        tostring(initial_set_attempted),
        tostring(initial_set_ok),
        tostring(active_set_ok),
        tostring(battle_set_ok),
        active_before_ok and safe_to_string(active_before) or "<error>",
        active_after_ok and safe_to_string(active_after) or "<error>",
        awake_before_ok and safe_to_string(awake_before) or "<error>",
        awake_after_ok and safe_to_string(awake_after) or "<error>",
        battle_before_ok and safe_to_string(battle_before) or "<error>",
        battle_after_ok and safe_to_string(battle_after) or "<error>"
    ))
    return initial_set_ok and active_set_ok and battle_set_ok, nil
end

local function configure_native_attacker(instance, attacker, source)
    local component, individual = get_character_components(attacker)
    if not is_valid(component) or not is_valid(individual) then
        return false, "character-parameter-not-ready"
    end

    local level_ok = safe_call(
        individual,
        "SetOverrideLevel",
        instance.config.level
    )
    local predator_ok = pcall(function()
        component.IsPredator = true
        component.AdditionalEnemyMaxHPRate = 2.0
        component.AdditionalEnemyInflictDamageRate = 2.0
    end)
    local uncapturable_ok = safe_call(individual, "SetUncapturable", true)

    local static_component =
        safe_property(attacker, "StaticCharacterParameterComponent")
    local spawn_type_ok = false
    if is_valid(static_component) then
        spawn_type_ok = safe_call(
            static_component,
            "SetSpawnedCharacterType",
            8
        )
    end

    log(string.format(
        "NATIVE_ATTACKER_CONFIG source=%s actor=%s level=%d levelSet=%s predator=%s hpRate=2.0 damageRate=2.0 uncapturable=%s spawnType=%s",
        tostring(source),
        safe_full_name(attacker),
        tonumber(instance.config.level) or 0,
        tostring(level_ok),
        tostring(predator_ok),
        tostring(uncapturable_ok),
        tostring(spawn_type_ok)
    ))
    return level_ok and predator_ok and uncapturable_ok, nil
end

local function register_attacker(instance, attacker, source)
    if not is_valid(attacker) then
        return false
    end
    local name = safe_full_name(attacker)
    if instance.attackerNames[name] == true then
        return true
    end
    instance.attackerNames[name] = true
    table.insert(instance.attackers, attacker)
    instance.nativeSpawnedCount = instance.nativeSpawnedCount + 1

    configure_native_attacker(instance, attacker, source)
    local targeted = target_residents(instance, attacker, source)
    activate_attacker_combat(attacker, source)
    if not targeted then
        for retry_index, delay_ms in ipairs({ 500, 1500, 3500, 7000 }) do
            schedule(
                instance,
                string.format(
                    "attacker-ready-g%d-%d-%d",
                    instance.generation,
                    instance.nativeSpawnedCount,
                    retry_index
                ),
                delay_ms,
                function()
                    configure_native_attacker(
                        instance,
                        attacker,
                        "spawn-retry-" .. tostring(retry_index)
                    )
                    target_residents(
                        instance,
                        attacker,
                        "spawn-retry-" .. tostring(retry_index)
                    )
                    activate_attacker_combat(
                        attacker,
                        "spawn-retry-" .. tostring(retry_index)
                    )
                end
            )
        end
    end
    return true
end

local function retarget_attackers(instance, source, target_hate)
    local attempted = 0
    local targeted = 0
    for _, attacker in ipairs(instance.attackers) do
        if is_valid(attacker) then
            attempted = attempted + 1
            local ok = target_residents(
                instance,
                attacker,
                source,
                target_hate
            )
            activate_attacker_combat(attacker, source)
            if ok then
                targeted = targeted + 1
            end
        end
    end
    log(string.format(
        "RETARGET_COMPLETE source=%s attempted=%d targeted=%d",
        tostring(source),
        attempted,
        targeted
    ))
end

local function settlement_target_location(instance)
    local center = instance.config.settlement.location
    local anchor = instance.eventAnchor
    return {
        X = center.X,
        Y = center.Y,
        Z = anchor and anchor.Z or center.Z,
    }
end

local function settlement_start_location(instance)
    local target = settlement_target_location(instance)
    local direction = instance.config.defaultApproachDirection
    local length = math.sqrt(
        direction.X * direction.X + direction.Y * direction.Y
    )
    if length <= 0.0001 then
        length = 1.0
    end
    return {
        X = target.X
            + direction.X / length * instance.config.spawnRadius,
        Y = target.Y
            + direction.Y / length * instance.config.spawnRadius,
        Z = target.Z + instance.config.spawnHeightOffset,
    }
end

local function is_unowned_world_pal(actor)
    if not is_valid(actor) or is_player_character(actor) then
        return false, "invalid-or-player"
    end
    local static_component =
        safe_property(actor, "StaticCharacterParameterComponent")
    if not is_valid(static_component)
        or safe_property(static_component, "IsPal") ~= true then
        return false, "not-pal"
    end
    local component, individual = get_character_components(actor)
    if not is_valid(component) or not is_valid(individual) then
        return false, "character-parameter-not-ready"
    end
    for _, method_name in ipairs({
        "IsPlayersOtomo",
        "IsOtomo",
        "IsInactiveOtomo",
        "IsAssignedToAnyWork",
    }) do
        local ok, value = safe_call(component, method_name)
        if ok and value == true then
            return false, "owned-or-worker:" .. method_name
        end
    end
    if is_valid(safe_property(component, "Trainer"))
        or is_valid(safe_property(
            component,
            "NPCSpawnedOtomoTrainer"
        )) then
        return false, "trainer-owned"
    end
    return true, nil
end

local function find_attendance_pals(instance)
    local result = {}
    if type(FindAllOf) ~= "function" then
        return result, "FindAllOf-unavailable"
    end
    local attendance = instance.config.attendanceSimulation
    local center = settlement_target_location(instance)
    local maximum_distance_squared =
        attendance.aggroRadius * attendance.aggroRadius
    local qa_anchor = attendance.qaSpawnAnchor
    local qa_maximum_distance_squared =
        attendance.qaSpawnRadius * attendance.qaSpawnRadius
    local seen = {}
    for _, class_name in ipairs({
        "PalCharacter",
        "PalNPC",
        "PalMonsterCharacter",
    }) do
        local ok, actors = pcall(function()
            return FindAllOf(class_name)
        end)
        if ok and actors ~= nil then
            for _, actor in pairs(actors) do
                local name = safe_full_name(actor)
                local location = actor_location(actor)
                local candidate = is_unowned_world_pal(actor)
                local qa_candidate = true
                if attendance.qaOnly == true then
                    qa_candidate = false
                    for _, blueprint_name in ipairs(
                        attendance.qaCandidateBlueprints
                    ) do
                        if string.find(
                            name,
                            blueprint_name,
                            1,
                            true
                        ) ~= nil then
                            qa_candidate = true
                            break
                        end
                    end
                    qa_candidate = qa_candidate
                        and location ~= nil
                        and squared_distance(location, qa_anchor)
                            <= qa_maximum_distance_squared
                end
                if candidate
                    and qa_candidate
                    and seen[name] ~= true
                    and string.find(name, "Default__", 1, true) == nil
                    and location ~= nil
                    and squared_distance(location, center)
                        <= maximum_distance_squared then
                    seen[name] = true
                    table.insert(result, actor)
                end
            end
        end
    end
    return result, nil
end

local function target_player_for_attendance(
    instance,
    attacker,
    player_pawn,
    source
)
    if not is_valid(attacker) or not is_valid(player_pawn) then
        return false, "actor-or-player-invalid"
    end
    local controller_ok, controller = safe_call(
        attacker,
        "GetController"
    )
    if not controller_ok or not is_valid(controller) then
        return false, "controller-not-ready"
    end
    local added = safe_call(
        controller,
        "AddTargetPlayer_ForEnemy",
        player_pawn
    )
    local hate_ok, hate = safe_call(controller, "GetHateSystem")
    local changed = false
    if hate_ok and is_valid(hate) then
        changed = safe_call(
            hate,
            "ChangeHate",
            player_pawn,
            instance.config.attendanceSimulation.targetPlayerHate
        )
    end
    log(string.format(
        "ATTENDANCE_PLAYER_TARGET source=%s attacker=%s player=%s added=%s hate=%s hateValue=%.1f",
        tostring(source),
        safe_full_name(attacker),
        safe_full_name(player_pawn),
        tostring(added),
        tostring(changed),
        instance.config.attendanceSimulation.targetPlayerHate
    ))
    return added and changed, nil
end

local function record_background_raid(instance, source, player_distance)
    local record = {
        schemaVersion = "1.0.0",
        settlementId = instance.config.settlement.id,
        source = source,
        generation = instance.generation,
        resolvedAt = os.time(),
        playerPresent = false,
        playerDistance = player_distance,
        outcome = "raid-occurred-offscreen",
        actorSpawns = 0,
        worldCombat = false,
        saveWrites = false,
    }
    table.insert(instance.backgroundRaidHistory, record)
    while #instance.backgroundRaidHistory
        > instance.config.attendanceSimulation.maxHistory do
        table.remove(instance.backgroundRaidHistory, 1)
    end
    instance.backgroundRaidCount = instance.backgroundRaidCount + 1
    local recorder_status = "in-memory-only"
    local recorder = instance.backgroundRaidRecorder
    if type(recorder) == "table"
        and type(recorder.record) == "function" then
        local ok, result = pcall(function()
            return recorder:record(record)
        end)
        recorder_status = ok and tostring(result)
            or "provider-error:" .. tostring(result)
    end
    log(string.format(
        "BACKGROUND_RAID_RESOLVED source=%s settlement=%s playerPresent=false playerDistance=%.1f actorSpawns=0 worldCombat=false recorder=%s count=%d saveWrites=0",
        tostring(source),
        instance.config.settlement.id,
        tonumber(player_distance) or -1,
        recorder_status,
        instance.backgroundRaidCount
    ))
    return record
end

local function incident_from_context(context)
    local incident = safe_hook_param_get(context)
    return is_valid(incident) and incident or nil
end

local function incident_kind_from_name(name)
    if type(name) ~= "string" then
        return "unknown"
    end
    if string.find(name, "BP_PalIncidentInvaderVisitorNPC", 1, true)
        ~= nil then
        return "visitor"
    end
    if string.find(name, "BP_PalIncidentInvaderEnemy", 1, true)
        ~= nil then
        return "assault"
    end
    return "unknown"
end

local function incident_kind(incident)
    return incident_kind_from_name(safe_full_name(incident))
end

local function assault_incident_is_tracked(instance, incident)
    if not is_valid(incident) then
        return false
    end
    return instance.nativeIncidentNames[safe_full_name(incident)] == true
end

local function visitor_incident_is_tracked(instance, incident)
    if not is_valid(incident) then
        return false
    end
    return instance.nativeVisitorNames[safe_full_name(incident)] == true
end

local function incident_is_tracked(instance, incident)
    return assault_incident_is_tracked(instance, incident)
        or visitor_incident_is_tracked(instance, incident)
end

local function claim_visitor_incident(instance, incident, source)
    if not is_valid(incident) or not instance.nativeRedirectActive then
        return false
    end
    local name = safe_full_name(incident)
    if instance.nativeVisitorNames[name] == true then
        return true
    end
    if incident_kind(incident) ~= "visitor" then
        return false
    end

    instance.nativeVisitorNames[name] = true
    instance.nativeVisitorCount = instance.nativeVisitorCount + 1
    instance.nativePhase = "negotiator-created"
    instance.lastVisitorIncidentName = name
    log(string.format(
        "NATIVE_NEGOTIATOR_CLAIMED source=%s incident=%s count=%d assaultGateOpen=%s",
        tostring(source),
        name,
        instance.nativeVisitorCount,
        tostring(instance.nativeRedirectArmed == true)
    ))
    return true
end

local function claim_assault_incident(instance, incident, source)
    if not is_valid(incident) or not instance.nativeRedirectActive then
        return false
    end
    local name = safe_full_name(incident)
    if instance.nativeIncidentNames[name] == true then
        return true
    end
    if instance.nativeRedirectArmed ~= true then
        return false
    end

    instance.nativeRedirectArmed = false
    instance.nativeIncidentNames[name] = true
    instance.nativeIncidentCount = instance.nativeIncidentCount + 1
    instance.nativePhase = "assault"
    instance.lastIncidentName = name
    log(string.format(
        "NATIVE_ASSAULT_CLAIMED source=%s incident=%s chosenRow=%s group=%s visitors=%d",
        tostring(source),
        name,
        safe_to_string(safe_property(
            incident,
            "ChosenInvaderDataRowName"
        )),
        instance.config.nativeInvaderGroupName,
        instance.nativeVisitorCount
    ))
    return true
end

local function should_redirect_incident(
    instance,
    context,
    source,
    expected_kind
)
    if not instance.active or not instance.nativeRedirectActive then
        return false, nil
    end
    local incident = incident_from_context(context)
    if not is_valid(incident) then
        return false, nil
    end
    if incident_is_tracked(instance, incident) then
        return true, incident
    end
    local kind = expected_kind or incident_kind(incident)
    if kind == "visitor" then
        return claim_visitor_incident(instance, incident, source), incident
    end
    if kind == "assault" or source == "select-invaders" then
        return claim_assault_incident(instance, incident, source), incident
    end
    log(string.format(
        "NATIVE_INCIDENT_IGNORED source=%s incident=%s reason=unknown-kind",
        tostring(source),
        safe_full_name(incident)
    ))
    return false, incident
end

local function attempt_rampaging_pal_fallback(instance, source)
    local fallback = instance.config.rampagingPalFallback
    if fallback.enabled ~= true then
        instance.rampagingFallbackStatus = "disabled"
        return false, "rampaging-pal-fallback-disabled"
    end
    if type(instance.lastError) ~= "string"
        or string.find(
            instance.lastError,
            "native-negotiator",
            1,
            true
        ) == nil then
        instance.rampagingFallbackStatus =
            "blocked-native-route-not-proven-failed"
        return false, "native-negotiator-route-not-proven-failed"
    end
    local provider = instance.rampagingPalSpawnerProvider
    if type(provider) ~= "table"
        or type(provider.spawn_wave) ~= "function" then
        instance.rampagingFallbackStatus =
            "blocked-native-spawner-provider-unavailable"
        return false, "rampaging-pal-spawner-provider-unavailable"
    end

    local request = {
        source = source,
        settlementId = instance.config.settlement.id,
        settlementLocation = settlement_target_location(instance),
        approachLocation = settlement_start_location(instance),
        nativeInvaderGroupName =
            instance.config.nativeInvaderGroupName,
        level = instance.config.level,
        predator = fallback.predator,
        targetHate = fallback.targetHate,
        makeUncapturable = fallback.makeUncapturable,
        saveWrites = false,
    }
    instance.rampagingFallbackAttemptCount =
        instance.rampagingFallbackAttemptCount + 1
    local spawn_ok, result = pcall(function()
        return provider:spawn_wave(
            request,
            function(actor)
                register_attacker(
                    instance,
                    actor,
                    "rampaging-fallback"
                )
            end
        )
    end)
    if not spawn_ok or result == false then
        instance.rampagingFallbackStatus = "provider-failed"
        instance.rampagingFallbackLastError = spawn_ok
                and "provider-returned-false"
            or tostring(result)
        return false, instance.rampagingFallbackLastError
    end

    instance.nativeRedirectActive = false
    instance.nativeRedirectArmed = false
    instance.nativePhase = "rampaging-fallback"
    instance.rampagingFallbackStatus = "started"
    instance.rampagingFallbackStartCount =
        instance.rampagingFallbackStartCount + 1
    log(string.format(
        "RAMPAGING_PAL_FALLBACK_STARTED source=%s attempts=%d starts=%d predator=%s hatePerResident=%.1f saveWrites=0",
        tostring(source),
        instance.rampagingFallbackAttemptCount,
        instance.rampagingFallbackStartCount,
        tostring(fallback.predator == true),
        fallback.targetHate
    ))
    return true, nil
end

local function try_register_hook(
    instance,
    path,
    callback,
    post_callback
)
    if instance.hooks[path] ~= nil then
        return true
    end
    if type(RegisterHook) ~= "function" then
        instance.hookErrors[path] = "RegisterHook-unavailable"
        return false
    end
    local ok, first_id, second_id = pcall(function()
        if post_callback ~= nil then
            return RegisterHook(path, callback, post_callback)
        end
        return RegisterHook(path, callback)
    end)
    if not ok then
        instance.hookErrors[path] = tostring(first_id)
        log(string.format(
            "HOOK_FAILED path=%s error=%s",
            path,
            tostring(first_id)
        ))
        return false
    end
    instance.hooks[path] = {
        firstId = first_id,
        secondId = second_id,
        callback = callback,
        postCallback = post_callback,
    }
    log("HOOK_READY path=" .. path)
    return true
end

local function load_native_incident_assets()
    if type(LoadAsset) ~= "function" then
        return
    end
    for _, asset_path in ipairs({
        NATIVE_BASE_ASSET_PATH,
        NATIVE_ENEMY_ASSET_PATH,
        NATIVE_VISITOR_ASSET_PATH,
    }) do
        pcall(function()
            LoadAsset(asset_path)
        end)
    end
end

local function register_native_incident_hooks(instance)
    load_native_incident_assets()

    local select_invaders_callback = function(
        context,
        grade_parameter,
        biome_parameter
    )
        local ok, error_message = pcall(function()
            local redirect, incident = should_redirect_incident(
                instance,
                context,
                "select-invaders"
            )
            if not redirect or not is_valid(incident) then
                return
            end
            local grade_ok, grade_error = safe_hook_param_set(
                grade_parameter,
                instance.config.level
            )
            local biome_ok, biome_error = safe_hook_param_set(
                biome_parameter,
                NATIVE_MEADOW_BIOME_VALUE
            )
            if not grade_ok or not biome_ok then
                instance.lastError = string.format(
                    "select-invaders-override-failed:grade=%s biome=%s",
                    tostring(grade_error),
                    tostring(biome_error)
                )
                return
            end
            instance.selectionOverrideCount =
                instance.selectionOverrideCount + 1
            log(string.format(
                "NATIVE_SELECTION_REDIRECTED grade=%d biome=Meadow group=%s count=%d",
                instance.config.level,
                instance.config.nativeInvaderGroupName,
                instance.selectionOverrideCount
            ))
        end)
        if not ok then
            instance.lastError = "select-invaders-hook:"
                .. tostring(error_message)
        end
    end
    try_register_hook(
        instance,
        NATIVE_SELECT_INVADERS_PATH,
        select_invaders_callback
    )

    local function override_start_point(
        context,
        result_parameter,
        return_parameter,
        source,
        expected_kind
    )
        local override = nil
        local ok, error_message = pcall(function()
            local redirect = should_redirect_incident(
                instance,
                context,
                source,
                expected_kind
            )
            if not redirect then
                return
            end
            local location = settlement_start_location(instance)
            local set_ok, set_error = safe_hook_param_set(
                result_parameter,
                location
            )
            if not set_ok then
                instance.lastError = "start-point-set-failed:"
                    .. tostring(set_error)
                return
            end
            -- GetInvaderStartPoint returns both an out FVector and a bool.
            -- Overriding only the vector still lets the native obstruction
            -- check return false, which prevents the negotiator/raid from
            -- being created. The redirected open-ground anchor is valid, so
            -- both values must be overridden together.
            local success_ok, success_error = safe_hook_param_set(
                return_parameter,
                true
            )
            if not success_ok then
                instance.lastError = "start-point-success-set-failed:"
                    .. tostring(success_error)
                return
            end
            instance.startPointOverrideCount =
                instance.startPointOverrideCount + 1
            override = true
            log(string.format(
                "NATIVE_START_POINT_REDIRECTED source=%s x=%.2f y=%.2f z=%.2f success=true count=%d",
                tostring(source),
                location.X,
                location.Y,
                location.Z,
                instance.startPointOverrideCount
            ))
        end)
        if not ok then
            instance.lastError = tostring(source) .. "-hook:"
                .. tostring(error_message)
        end
        return override
    end

    local start_point_pre = function(_)
        -- The original result does not exist until the native function ends.
    end
    local start_point_post = function(
        context,
        result_parameter,
        return_parameter
    )
        return override_start_point(
            context,
            result_parameter,
            return_parameter,
            "start-point",
            nil
        )
    end
    try_register_hook(
        instance,
        NATIVE_START_POINT_PATH,
        start_point_pre,
        start_point_post
    )

    local visitor_start_point_post = function(
        context,
        result_parameter,
        return_parameter
    )
        return override_start_point(
            context,
            result_parameter,
            return_parameter,
            "visitor-start-point",
            "visitor"
        )
    end
    try_register_hook(
        instance,
        NATIVE_VISITOR_START_POINT_PATH,
        start_point_pre,
        visitor_start_point_post
    )

    local target_callback = function(context, location_parameter)
        local ok, error_message = pcall(function()
            local redirect = should_redirect_incident(
                instance,
                context,
                "target-position"
            )
            if not redirect then
                return
            end
            local location = settlement_target_location(instance)
            local set_ok, set_error = safe_hook_param_set(
                location_parameter,
                location
            )
            if not set_ok then
                instance.lastError = "target-position-set-failed:"
                    .. tostring(set_error)
                return
            end
            instance.targetPositionOverrideCount =
                instance.targetPositionOverrideCount + 1
            if instance.targetPositionOverrideCount <= 4 then
                log(string.format(
                    "NATIVE_TARGET_REDIRECTED x=%.2f y=%.2f z=%.2f count=%d",
                    location.X,
                    location.Y,
                    location.Z,
                    instance.targetPositionOverrideCount
                ))
            end
        end)
        if not ok then
            instance.lastError = "target-position-hook:"
                .. tostring(error_message)
        end
    end
    try_register_hook(
        instance,
        NATIVE_TARGET_POSITION_PATH,
        target_callback
    )

    local spawned_callback = function(context, spawned_parameter)
        local ok, error_message = pcall(function()
            local incident = incident_from_context(context)
            if not instance.active
                or not assault_incident_is_tracked(
                    instance,
                    incident
                ) then
                return
            end
            local attacker = safe_hook_param_get(spawned_parameter)
            register_attacker(instance, attacker, "native-hook")
        end)
        if not ok then
            instance.lastError = "spawned-hook:"
                .. tostring(error_message)
        end
    end
    try_register_hook(
        instance,
        NATIVE_BASE_SPAWNED_PATH,
        spawned_callback
    )
    try_register_hook(
        instance,
        NATIVE_ENEMY_SPAWNED_PATH,
        spawned_callback
    )

    local visitor_all_spawned_callback = function(context, ...)
        local ok, error_message = pcall(function()
            local redirect, incident = should_redirect_incident(
                instance,
                context,
                "visitor-all-spawned",
                "visitor"
            )
            if not redirect or not is_valid(incident) then
                return
            end
            instance.negotiatorObserved = true
            instance.nativePhase = "negotiator-active"
            instance.negotiatorSpawnCallbackCount =
                instance.negotiatorSpawnCallbackCount + 1
            log(string.format(
                "NATIVE_NEGOTIATOR_ACTIVE incident=%s callbacks=%d assaultGateOpen=%s",
                safe_full_name(incident),
                instance.negotiatorSpawnCallbackCount,
                tostring(instance.nativeRedirectArmed == true)
            ))
        end)
        if not ok then
            instance.lastError = "visitor-all-spawned-hook:"
                .. tostring(error_message)
        end
    end
    try_register_hook(
        instance,
        NATIVE_VISITOR_ALL_SPAWNED_PATH,
        visitor_all_spawned_callback
    )

    local attendance_death_callback = function(
        context,
        dead_info_parameter
    )
        local ok, error_message = pcall(function()
            local bridge = instance.attendanceResultBridge
            if bridge == nil then
                return
            end
            local bridge_status = bridge:status()
            if bridge_status.active ~= true then
                return
            end
            local dead_info = safe_hook_param_get(
                dead_info_parameter
            )
            local victim = safe_property(dead_info, "SelfActor")
            if not is_valid(victim) then
                victim = safe_hook_param_get(context)
            end
            if type(instance.attendanceDeathObserver) == "function"
                and is_valid(victim) then
                instance.attendanceDeathObserver(victim)
            end
            local attacker = safe_property(dead_info, "LastAttacker")
            local recorded = bridge:record_death(victim, attacker)
            if recorded.ok and recorded.reason == "raid-event-settled" then
                instance.active = false
                instance.nativePhase = "complete"
                log(string.format(
                    "ATTENDANCE_RAID_AUTHORITATIVE_COMPLETE event=%s playerSideWon=true allMembersDead=true tokenAwarded=%s",
                    tostring(bridge_status.eventId),
                    tostring(recorded.settlement
                        and recorded.settlement.tokenAwarded == true)
                ))
            elseif not recorded.ok
                and recorded.reason
                    ~= "death-not-from-active-attendance-raid" then
                instance.lastError = "attendance-death-result:"
                    .. tostring(recorded.reason)
            end
        end)
        if not ok then
            instance.lastError = "attendance-death-hook:"
                .. tostring(error_message)
        end
    end
    try_register_hook(
        instance,
        ATTENDANCE_DEATH_PATH,
        attendance_death_callback
    )
end

local function count_native_hooks(instance)
    local ready = 0
    for _, path in ipairs(NATIVE_REQUIRED_HOOK_PATHS) do
        if instance.hooks[path] ~= nil then
            ready = ready + 1
        end
    end
    return ready
end

local function attempt_native_hook_registration(instance, source)
    instance.hookRegistrationAttempts =
        instance.hookRegistrationAttempts + 1
    register_native_incident_hooks(instance)
    local ready = count_native_hooks(instance)
    instance.nativeHookReadyCount = ready
    log(string.format(
        "NATIVE_HOOK_REGISTRATION source=%s attempt=%d ready=%d required=%d",
        tostring(source),
        instance.hookRegistrationAttempts,
        ready,
        #NATIVE_REQUIRED_HOOK_PATHS
    ))
    return ready == #NATIVE_REQUIRED_HOOK_PATHS
end

local function schedule_native_hook_registration(instance, source)
    attempt_native_hook_registration(instance, source .. "-immediate")
    for retry_index, delay_ms in ipairs({ 250, 1000, 3000, 8000 }) do
        schedule(
            instance,
            string.format(
                "native-hook-registration-g%d-%d",
                instance.generation,
                retry_index
            ),
            delay_ms,
            function()
                if count_native_hooks(instance)
                    < #NATIVE_REQUIRED_HOOK_PATHS then
                    attempt_native_hook_registration(
                        instance,
                        string.format(
                            "%s-retry-%d-after-%dms",
                            source,
                            retry_index,
                            delay_ms
                        )
                    )
                end
            end
        )
    end
end

local function set_native_invader_disabled(instance, disabled, source)
    if type(StaticFindObject) ~= "function" then
        instance.nativeInvaderDisableError =
            "StaticFindObject-unavailable"
        return false
    end
    local ok, setting = pcall(function()
        return StaticFindObject("/Script/Pal.Default__PalDebugSetting")
    end)
    if not ok or not is_valid(setting) then
        instance.nativeInvaderDisableError =
            "Default__PalDebugSetting-unavailable"
        return false
    end

    if instance.originalNativeInvaderDisabled == nil then
        instance.originalNativeInvaderDisabled =
            safe_property(setting, "bInvaderDisable") == true
    end
    local assigned, error_message = pcall(function()
        setting.bInvaderDisable = disabled == true
    end)
    instance.nativeInvaderDisabled = assigned
        and safe_property(setting, "bInvaderDisable") == true
    instance.nativeInvaderDisableError =
        assigned and nil or tostring(error_message)
    log(string.format(
        "NATIVE_INVADER_GATE source=%s requestedDisabled=%s actualDisabled=%s originalDisabled=%s error=%s",
        tostring(source),
        tostring(disabled == true),
        tostring(instance.nativeInvaderDisabled),
        tostring(instance.originalNativeInvaderDisabled),
        tostring(instance.nativeInvaderDisableError)
    ))
    return assigned
end

load_pal_utility = function()
    if type(StaticFindObject) ~= "function" then
        return nil
    end
    local ok, utility = pcall(function()
        return StaticFindObject("/Script/Pal.Default__PalUtility")
    end)
    return ok and is_valid(utility) and utility or nil
end

local function nearest_base_camp(pawn, location)
    local utility = load_pal_utility()
    if not is_valid(utility) then
        return nil, "PalUtility-unavailable"
    end
    local manager_ok, manager = safe_call(
        utility,
        "GetBaseCampManager",
        pawn
    )
    if not manager_ok or not is_valid(manager) then
        return nil, "base-camp-manager-unavailable"
    end
    local model_ok, model = safe_call(
        manager,
        "GetNearestBaseCamp",
        location
    )
    if not model_ok or not is_valid(model) then
        return nil, "base-camp-model-unavailable"
    end
    return model, nil
end

local function native_invader_manager(pawn)
    local utility = load_pal_utility()
    if not is_valid(utility) then
        return nil, "PalUtility-unavailable"
    end
    local manager_ok, manager = safe_call(
        utility,
        "GetInvaderManager",
        pawn
    )
    if not manager_ok or not is_valid(manager) then
        return nil, "invader-manager-unavailable"
    end
    local manager_name = safe_full_name(manager)
    if string.find(manager_name, "PalInvaderManager", 1, true) == nil then
        return nil, "unexpected-invader-manager:" .. manager_name
    end
    return manager, nil
end

local function native_hooks_ready(instance)
    for _, path in ipairs(NATIVE_REQUIRED_HOOK_PATHS) do
        if instance.hooks[path] == nil then
            return false, "native-hook-unavailable:" .. path
        end
    end
    return true, nil
end

local function launch_native_invasion(instance)
    local controller, pawn, context_error = find_local_player()
    if not is_valid(controller) or not is_valid(pawn) then
        instance.lastError = context_error
        instance.active = false
        return false, context_error
    end

    local player_location = actor_location(pawn)
    if player_location == nil then
        instance.lastError = "player-location-unavailable"
        instance.active = false
        return false, instance.lastError
    end

    local camp, camp_error = nearest_base_camp(pawn, player_location)
    if not is_valid(camp) then
        instance.lastError = camp_error
        instance.active = false
        return false, camp_error
    end

    local camp_id_ok, camp_id = safe_call(camp, "GetId")
    if not camp_id_ok or camp_id == nil then
        instance.lastError = "base-camp-id-unavailable"
        instance.active = false
        return false, instance.lastError
    end

    -- Blueprint incident functions are registered only after their assets have
    -- entered the runtime object table. Make one final synchronous attempt at
    -- the end of the countdown instead of treating an early startup miss as a
    -- permanent incompatibility.
    attempt_native_hook_registration(instance, "pre-launch")
    local hooks_ready, hooks_error = native_hooks_ready(instance)
    if not hooks_ready then
        instance.lastError = hooks_error
        instance.active = false
        return false, hooks_error
    end

    local invader_manager, manager_error = native_invader_manager(pawn)
    if not is_valid(invader_manager) then
        instance.lastError = manager_error
        instance.active = false
        return false, manager_error
    end
    local existing_info_ok, existing_info = safe_call(
        invader_manager,
        "GetInvaderInfo"
    )
    if existing_info_ok and is_valid(existing_info) then
        instance.lastError = "native-invasion-already-active"
        instance.active = false
        return false, instance.lastError
    end

    instance.nativeRedirectActive = true
    instance.nativeRedirectArmed = true
    instance.nativePhase = "manager-requested"
    set_native_invader_disabled(instance, false, "native-launch")

    local night_now, night_error = is_night(pawn)
    local observer_count,
        observer_match,
        observer_error,
        observer,
        observer_key =
        native_map_diagnostics(
            safe_property(invader_manager, "Observers"),
            camp_id
        )
    local incident_count_before, _, incident_map_error =
        native_map_diagnostics(
            safe_property(invader_manager, "Incidents"),
            camp_id
        )
    local current_hour, current_day_type, time_debug =
        native_time_diagnostics(pawn)
    log(string.format(
        "NATIVE_MANAGER_PREFLIGHT night=%s nightError=%s hour=%s dayType=%s timeDebug=%s campId=%s observers=%d observerMatch=%s observerKey=%s observerTarget=%s observerError=%s observer=%s observerInvading=%s observerPathSearching=%s observerCooldown=%s cooldownFinish=%s cooldownElapsed=%s playerInCampTimer=%s incidentsBefore=%d incidentMapError=%s",
        tostring(night_now),
        tostring(night_error),
        current_hour,
        current_day_type,
        time_debug,
        safe_guid_string(camp_id),
        observer_count,
        tostring(observer_match),
        safe_guid_string(observer_key),
        safe_guid_string(safe_property(observer, "TargetBaseCampID")),
        tostring(observer_error),
        safe_full_name(observer),
        tostring(safe_property(observer, "bIsInvading")),
        tostring(safe_property(observer, "bIsInvaderPathSearching")),
        tostring(safe_property(observer, "bIsCoolTime")),
        tostring(safe_property(observer, "CoolTimeFinish")),
        tostring(safe_property(observer, "CoolTimeElapsed")),
        tostring(safe_property(observer, "PlayerInBaseCampTimer")),
        incident_count_before,
        tostring(incident_map_error)
    ))

    if instance.lastTriggerSource == "qa-hotkey"
        and is_valid(observer)
        and safe_property(observer, "bIsCoolTime") == true then
        local reset_ok, reset_error = pcall(function()
            observer.bIsCoolTime = false
            observer.CoolTimeFinish = 0.0
            observer.CoolTimeElapsed = 0.0
        end)
        log(string.format(
            "QA_OBSERVER_COOLDOWN_RESET ok=%s error=%s observer=%s saveWrites=0",
            tostring(reset_ok),
            reset_ok and "nil" or tostring(reset_error),
            safe_full_name(observer)
        ))
    end

    local group_name = instance.config.nativeInvaderGroupName
    local launch_ok, launch_error = pcall(function()
        invader_manager:StartInvaderMarchForBaseCamp(camp_id)
    end)
    if not launch_ok then
        instance.nativeRedirectActive = false
        instance.nativeRedirectArmed = false
        instance.active = false
        instance.lastError = "native-invasion-launch-failed:"
            .. tostring(launch_error)
        set_native_invader_disabled(
            instance,
            instance.config.replaceNativePlayerBaseInvasion == true,
            "native-launch-failed"
        )
        return false, instance.lastError
    end

    instance.lastNativeManagerSource = safe_full_name(invader_manager)
    instance.nativeLaunchCount = instance.nativeLaunchCount + 1
    log(string.format(
        "NATIVE_INVASION_LAUNCHED group=%s camp=%s campId=%s launcher=PalInvaderManager.StartInvaderMarchForBaseCamp manager=%s launchCount=%d",
        group_name,
        safe_full_name(camp),
        safe_to_string(camp_id),
        instance.lastNativeManagerSource,
        instance.nativeLaunchCount
    ))
    if instance.config.nativeFallbackLaunchEnabled == true then
        log(string.format(
            "NATIVE_MANAGER_FALLBACKS_SCHEDULED randomAfterMs=%d allAfterMs=%d confirmationAfterMs=%d generation=%d",
            instance.config.nativeRandomFallbackDelayMs,
            instance.config.nativeAllFallbackDelayMs,
            instance.config.nativeIncidentConfirmationDelayMs,
            instance.generation
        ))

        schedule(
            instance,
            "native-random-fallback-g" .. tostring(instance.generation),
            instance.config.nativeRandomFallbackDelayMs,
            function()
                if instance.nativeVisitorCount > 0
                    or instance.nativeIncidentCount > 0 then
                    return
                end
                local info_ok, info = safe_call(
                    invader_manager,
                    "GetInvaderInfo"
                )
                if info_ok and is_valid(info) then
                    return
                end
                local fallback_ok, fallback_error = pcall(function()
                    invader_manager:StartInvaderMarchRandom()
                end)
                log(string.format(
                    "NATIVE_RANDOM_FALLBACK attempted=true ok=%s afterMs=%d error=%s",
                    tostring(fallback_ok),
                    instance.config.nativeRandomFallbackDelayMs,
                    fallback_ok and "nil" or tostring(fallback_error)
                ))
            end
        )

        schedule(
            instance,
            "native-all-fallback-g" .. tostring(instance.generation),
            instance.config.nativeAllFallbackDelayMs,
            function()
                if instance.nativeVisitorCount > 0
                    or instance.nativeIncidentCount > 0 then
                    return
                end
                local info_ok, info = safe_call(
                    invader_manager,
                    "GetInvaderInfo"
                )
                if info_ok and is_valid(info) then
                    return
                end
                local fallback_ok, fallback_error = pcall(function()
                    invader_manager:StartInvaderMarchAll()
                end)
                log(string.format(
                    "NATIVE_ALL_FALLBACK attempted=true ok=%s afterMs=%d error=%s",
                    tostring(fallback_ok),
                    instance.config.nativeAllFallbackDelayMs,
                    fallback_ok and "nil" or tostring(fallback_error)
                ))
            end
        )
    else
        log(string.format(
            "NATIVE_MANAGER_FALLBACKS_DISABLED policy=single-base-camp-request confirmationAfterMs=%d negotiatorTimeoutMs=%d generation=%d",
            instance.config.nativeIncidentConfirmationDelayMs,
            instance.config.nativeNegotiatorTimeoutMs,
            instance.generation
        ))
    end

    schedule(
        instance,
        "native-gate-close-g" .. tostring(instance.generation),
        instance.config.nativeIncidentConfirmationDelayMs,
        function()
            local info_ok, info = safe_call(
                invader_manager,
                "GetInvaderInfo"
            )
            instance.nativeManagerInfoObserved =
                info_ok and is_valid(info)
            if instance.nativeIncidentCount > 0
                and instance.selectionOverrideCount > 0 then
                instance.nativePhase = "assault-confirmed"
                log(string.format(
                    "NATIVE_ASSAULT_CONFIRMED incidents=%d visitors=%d managerInfo=%s selectionOverrides=%d spawned=%d startOverrides=%d targetOverrides=%d",
                    instance.nativeIncidentCount,
                    instance.nativeVisitorCount,
                    tostring(instance.nativeManagerInfoObserved),
                    instance.selectionOverrideCount,
                    instance.nativeSpawnedCount,
                    instance.startPointOverrideCount,
                    instance.targetPositionOverrideCount
                ))
                return
            end
            if instance.nativeVisitorCount > 0
                or instance.negotiatorObserved == true
                or instance.nativeManagerInfoObserved == true then
                instance.nativePhase = "negotiation"
                log(string.format(
                    "NATIVE_NEGOTIATION_CONFIRMED visitors=%d negotiatorObserved=%s managerInfo=%s assaultGateOpen=%s confirmationAfterMs=%d",
                    instance.nativeVisitorCount,
                    tostring(instance.negotiatorObserved),
                    tostring(instance.nativeManagerInfoObserved),
                    tostring(instance.nativeRedirectArmed == true),
                    instance.config.nativeIncidentConfirmationDelayMs
                ))
                return
            end

            instance.lastError =
                "native-negotiator-not-created:check-open-ground-near-target-base-camp"
            if instance.config.nativeDirectIncidentFallbackEnabled == true
                and is_valid(observer) then
                local function request_direct_enemy(source)
                    local enemy_ok, enemy_result = pcall(function()
                        return invader_manager:RequestIncidentInvaderEnemy(
                            camp_id,
                            observer
                        )
                    end)
                    local enemy_accepted = enemy_ok
                        and enemy_result == true
                    log(string.format(
                        "NATIVE_DIRECT_ENEMY_REQUESTED attempted=true accepted=%s callOk=%s result=%s source=%s campId=%s observer=%s saveWrites=0 error=%s",
                        tostring(enemy_accepted),
                        tostring(enemy_ok),
                        tostring(enemy_result),
                        tostring(source),
                        safe_guid_string(camp_id),
                        safe_full_name(observer),
                        enemy_ok and "nil" or tostring(enemy_result)
                    ))
                    if not enemy_accepted then
                        return false, enemy_ok
                                and "native-direct-enemy-rejected"
                            or tostring(enemy_result)
                    end

                    instance.nativeDirectIncidentRequestCount =
                        instance.nativeDirectIncidentRequestCount + 1
                    instance.nativePhase = "direct-enemy-requested"
                    instance.lastError = nil
                    schedule(
                        instance,
                        "native-direct-enemy-confirm-g"
                            .. tostring(instance.generation),
                        instance.config
                            .nativeDirectIncidentConfirmationDelayMs,
                        function()
                            if not instance.active then
                                return
                            end
                            local direct_info_ok, direct_info = safe_call(
                                invader_manager,
                                "GetInvaderInfo"
                            )
                            instance.nativeManagerInfoObserved =
                                direct_info_ok and is_valid(direct_info)
                            if instance.nativeIncidentCount > 0
                                and instance.selectionOverrideCount > 0 then
                                instance.nativePhase =
                                    "direct-assault-confirmed"
                                log(string.format(
                                    "NATIVE_DIRECT_ENEMY_CONFIRMED incidents=%d managerInfo=%s selectionOverrides=%d spawned=%d startOverrides=%d targetOverrides=%d afterMs=%d",
                                    instance.nativeIncidentCount,
                                    tostring(
                                        instance.nativeManagerInfoObserved
                                    ),
                                    instance.selectionOverrideCount,
                                    instance.nativeSpawnedCount,
                                    instance.startPointOverrideCount,
                                    instance.targetPositionOverrideCount,
                                    instance.config
                                        .nativeDirectIncidentConfirmationDelayMs
                                ))
                                return
                            end

                            instance.lastError =
                                "native-direct-enemy-not-created"
                            local fallback_started, fallback_error =
                                attempt_rampaging_pal_fallback(
                                    instance,
                                    "direct-enemy-missing"
                                )
                            if fallback_started then
                                set_native_invader_disabled(
                                    instance,
                                    instance.config
                                        .replaceNativePlayerBaseInvasion
                                        == true,
                                    "rampaging-fallback"
                                )
                                return
                            end
                            instance.nativePhase = "failed"
                            instance.nativeRedirectActive = false
                            instance.nativeRedirectArmed = false
                            instance.active = false
                            set_native_invader_disabled(
                                instance,
                                instance.config
                                    .replaceNativePlayerBaseInvasion == true,
                                "direct-enemy-missing"
                            )
                            log(string.format(
                                "NATIVE_DIRECT_ENEMY_MISSING afterMs=%d incidents=%d managerInfo=%s selectionOverrides=%d fallback=%s fallbackError=%s lastError=%s",
                                instance.config
                                    .nativeDirectIncidentConfirmationDelayMs,
                                instance.nativeIncidentCount,
                                tostring(
                                    instance.nativeManagerInfoObserved
                                ),
                                instance.selectionOverrideCount,
                                tostring(instance.rampagingFallbackStatus),
                                tostring(fallback_error),
                                instance.lastError
                            ))
                        end
                    )
                    return true, nil
                end

                local visitor_ok, visitor_result = pcall(function()
                    return invader_manager:RequestIncidentVisitorNPC(
                        camp_id,
                        observer,
                        true
                    )
                end)
                local visitor_accepted = visitor_ok
                    and visitor_result == true
                log(string.format(
                    "NATIVE_DIRECT_VISITOR_REQUESTED attempted=true accepted=%s callOk=%s result=%s ignoreDeclaration=true source=negotiator-open-ground-missing campId=%s observer=%s saveWrites=0 error=%s",
                    tostring(visitor_accepted),
                    tostring(visitor_ok),
                    tostring(visitor_result),
                    safe_guid_string(camp_id),
                    safe_full_name(observer),
                    visitor_ok and "nil" or tostring(visitor_result)
                ))
                if visitor_accepted then
                    instance.nativeDirectIncidentRequestCount =
                        instance.nativeDirectIncidentRequestCount + 1
                    instance.nativePhase = "direct-visitor-requested"
                    instance.lastError = nil
                    schedule(
                        instance,
                        "native-direct-visitor-confirm-g"
                            .. tostring(instance.generation),
                        instance.config
                            .nativeDirectIncidentConfirmationDelayMs,
                        function()
                            if not instance.active then
                                return
                            end
                            local visitor_info_ok, visitor_info = safe_call(
                                invader_manager,
                                "GetInvaderInfo"
                            )
                            instance.nativeManagerInfoObserved =
                                visitor_info_ok and is_valid(visitor_info)
                            if instance.nativeVisitorCount > 0
                                or instance.negotiatorObserved == true
                                or instance.nativeManagerInfoObserved == true then
                                instance.nativePhase =
                                    "direct-negotiation-confirmed"
                                log(string.format(
                                    "NATIVE_DIRECT_VISITOR_CONFIRMED visitors=%d negotiatorObserved=%s managerInfo=%s startOverrides=%d afterMs=%d",
                                    instance.nativeVisitorCount,
                                    tostring(instance.negotiatorObserved),
                                    tostring(
                                        instance.nativeManagerInfoObserved
                                    ),
                                    instance.startPointOverrideCount,
                                    instance.config
                                        .nativeDirectIncidentConfirmationDelayMs
                                ))
                                return
                            end

                            instance.lastError =
                                "native-direct-visitor-not-created"
                            log(string.format(
                                "NATIVE_DIRECT_VISITOR_MISSING afterMs=%d visitors=%d negotiatorObserved=%s managerInfo=%s startOverrides=%d lastError=%s",
                                instance.config
                                    .nativeDirectIncidentConfirmationDelayMs,
                                instance.nativeVisitorCount,
                                tostring(instance.negotiatorObserved),
                                tostring(
                                    instance.nativeManagerInfoObserved
                                ),
                                instance.startPointOverrideCount,
                                instance.lastError
                            ))
                            request_direct_enemy(
                                "direct-visitor-accepted-but-missing"
                            )
                        end
                    )
                    return
                end
                local enemy_started = request_direct_enemy(
                    "direct-visitor-request-rejected"
                )
                if enemy_started then
                    return
                end
            end
            local fallback_started, fallback_error =
                attempt_rampaging_pal_fallback(
                    instance,
                    "negotiator-missing"
                )
            if fallback_started then
                set_native_invader_disabled(
                    instance,
                    instance.config.replaceNativePlayerBaseInvasion
                        == true,
                    "rampaging-fallback"
                )
                return
            end
            instance.nativePhase = "failed"
            instance.nativeRedirectActive = false
            instance.nativeRedirectArmed = false
            instance.active = false
            set_native_invader_disabled(
                instance,
                instance.config.replaceNativePlayerBaseInvasion == true,
                "negotiator-missing"
            )
            log(string.format(
                "NATIVE_NEGOTIATOR_MISSING afterMs=%d visitors=%d managerInfo=%s startOverrides=%d fallback=%s fallbackError=%s lastError=%s",
                instance.config.nativeIncidentConfirmationDelayMs,
                instance.nativeVisitorCount,
                tostring(instance.nativeManagerInfoObserved),
                instance.startPointOverrideCount,
                tostring(instance.rampagingFallbackStatus),
                tostring(fallback_error),
                instance.lastError
            ))
        end
    )

    schedule(
        instance,
        "native-negotiator-timeout-g" .. tostring(instance.generation),
        instance.config.nativeNegotiatorTimeoutMs,
        function()
            if not instance.active
                or instance.nativeIncidentCount > 0 then
                return
            end
            local info_ok, info = safe_call(
                invader_manager,
                "GetInvaderInfo"
            )
            instance.nativeManagerInfoObserved =
                info_ok and is_valid(info)
            instance.lastError =
                "native-negotiator-timeout-or-unreachable-target"
            local fallback_started, fallback_error =
                attempt_rampaging_pal_fallback(
                    instance,
                    "negotiator-timeout"
                )
            if fallback_started then
                set_native_invader_disabled(
                    instance,
                    instance.config.replaceNativePlayerBaseInvasion
                        == true,
                    "rampaging-fallback"
                )
                return
            end
            instance.nativePhase = "failed"
            instance.nativeRedirectActive = false
            instance.nativeRedirectArmed = false
            instance.active = false
            set_native_invader_disabled(
                instance,
                instance.config.replaceNativePlayerBaseInvasion == true,
                "negotiator-timeout"
            )
            log(string.format(
                "NATIVE_NEGOTIATOR_TIMEOUT afterMs=%d visitors=%d negotiatorObserved=%s managerInfo=%s startOverrides=%d targetOverrides=%d fallback=%s fallbackError=%s lastError=%s",
                instance.config.nativeNegotiatorTimeoutMs,
                instance.nativeVisitorCount,
                tostring(instance.negotiatorObserved),
                tostring(instance.nativeManagerInfoObserved),
                instance.startPointOverrideCount,
                instance.targetPositionOverrideCount,
                tostring(instance.rampagingFallbackStatus),
                tostring(fallback_error),
                instance.lastError
            ))
        end
    )

    for pulse_index, delay_ms in ipairs(
        instance.config.retargetDelaysMs
    ) do
        schedule(
            instance,
            string.format(
                "retarget-g%d-%d",
                instance.generation,
                pulse_index
            ),
            delay_ms,
            function()
                retarget_attackers(
                    instance,
                    "pulse-" .. tostring(pulse_index)
                )
            end
        )
    end
    schedule(
        instance,
        "cleanup-g" .. tostring(instance.generation),
        instance.config.cleanupDelayMs,
        function()
            instance.nativeRedirectActive = false
            instance.nativeRedirectArmed = false
            instance.active = false
            instance.nativePhase = "complete"
            set_native_invader_disabled(
                instance,
                instance.config.replaceNativePlayerBaseInvasion == true,
                "event-complete"
            )
            log(string.format(
                "EVENT_COMPLETE nativeOwned=true visitors=%d incidents=%d spawned=%d targets=%d saveWrites=0",
                instance.nativeVisitorCount,
                instance.nativeIncidentCount,
                instance.nativeSpawnedCount,
                instance.targetAssignments
            ))
        end
    )
    return true, nil
end

local function destroy_attendance_attackers(instance, source)
    local actors = {}
    local actor_names = {}
    local function remember(actor)
        if not is_valid(actor) then
            return
        end
        local name = safe_full_name(actor)
        if instance.attendanceSpawnedActorNames[name] == true
            and actor_names[name] ~= true then
            actor_names[name] = true
            table.insert(actors, actor)
        end
    end

    for _, actor in ipairs(instance.attackers) do
        remember(actor)
    end
    for _, handle in ipairs(instance.attendanceNativeSpawnHandles) do
        local actor_ok, actor = safe_call(
            handle,
            "TryGetIndividualActor"
        )
        if actor_ok then
            -- A handle that resolves after the engagement batch was built is
            -- still owned by this transient wave and must not leak into the
            -- world after the event ends.
            if is_valid(actor) then
                instance.attendanceSpawnedActorNames[
                    safe_full_name(actor)
                ] = true
            end
            remember(actor)
        end
    end

    local destroyed = 0
    local failed = 0
    for _, actor in ipairs(actors) do
        local destroy_ok = safe_call(
            actor,
            TRANSIENT_ATTACKER_DESTROY_METHOD
        )
        if destroy_ok then
            destroyed = destroyed + 1
        else
            failed = failed + 1
        end
    end
    instance.attendanceDestroyedCount =
        instance.attendanceDestroyedCount + destroyed
    instance.attendanceDestroyFailureCount =
        instance.attendanceDestroyFailureCount + failed
    instance.attendanceNativeSpawnHandles = {}
    instance.attendanceSpawnedActorNames = {}
    log(string.format(
        "ATTENDANCE_ATTACKERS_DESTROYED source=%s candidates=%d destroyed=%d failed=%d destroyedTotal=%d failureTotal=%d method=%s saveWrites=0",
        tostring(source),
        #actors,
        destroyed,
        failed,
        instance.attendanceDestroyedCount,
        instance.attendanceDestroyFailureCount,
        "Actor." .. TRANSIENT_ATTACKER_DESTROY_METHOD
    ))
    return destroyed, failed
end

local function prepare_attendance_attacker(
    instance,
    pawn,
    attacker,
    source,
    attempt
)
    if not instance.active
        or (instance.nativePhase ~= "attendance-spawn-pending"
            and instance.nativePhase ~= "attendance-active") then
        return false, false, false, false
    end
    if not is_valid(attacker) or not is_valid(pawn) then
        return false, false, false, false
    end

    local configured = configure_native_attacker(
        instance,
        attacker,
        source
    )
    local combat_activated = activate_attacker_combat(
        attacker,
        source .. "-combat"
    )
    local player_targeted = target_player_for_attendance(
        instance,
        attacker,
        pawn,
        source .. "-player"
    )
    local residents_targeted = target_residents(
        instance,
        attacker,
        source .. "-residents",
        instance.config.attendanceSimulation.targetResidentHate
    )
    local ready = configured
        and player_targeted
        and residents_targeted
        and combat_activated
    local attacker_name = safe_full_name(attacker)
    local spawn_config = instance.config.attendanceSimulation
        .nativeCountdownSpawn

    if ready then
        if instance.attendanceReadyActors[attacker_name] ~= true then
            instance.attendanceReadyActors[attacker_name] = true
            instance.attendanceReadyCount =
                instance.attendanceReadyCount + 1
        end
    elseif attempt < spawn_config.attackerReadyMaxAttempts then
        schedule(
            instance,
            string.format(
                "attendance-attacker-ready-g%d-%s-%d",
                instance.generation,
                attacker_name,
                attempt + 1
            ),
            spawn_config.attackerReadyRetryMs,
            function()
                prepare_attendance_attacker(
                    instance,
                    pawn,
                    attacker,
                    "attendance-ready-retry-" .. tostring(attempt + 1),
                    attempt + 1
                )
            end
        )
    elseif instance.attendanceReadyFailures[attacker_name] ~= true then
        instance.attendanceReadyFailures[attacker_name] = true
        instance.attendanceReadyFailureCount =
            instance.attendanceReadyFailureCount + 1
        instance.lastError =
            "attendance-attacker-readiness-exhausted:"
                .. attacker_name
    end

    log(string.format(
        "ATTENDANCE_ATTACKER_READINESS source=%s attempt=%d/%d attacker=%s configured=%s playerTargeted=%s residentsTargeted=%s combatActivated=%s ready=%s readyTotal=%d failedTotal=%d",
        tostring(source),
        attempt,
        spawn_config.attackerReadyMaxAttempts,
        attacker_name,
        tostring(configured),
        tostring(player_targeted),
        tostring(residents_targeted),
        tostring(combat_activated),
        tostring(ready),
        instance.attendanceReadyCount,
        instance.attendanceReadyFailureCount
    ))
    return configured, player_targeted, residents_targeted,
        combat_activated
end

local function engage_attendance_candidates(
    instance,
    pawn,
    player_distance,
    candidates,
    actor_spawns,
    source
)
    local attendance = instance.config.attendanceSimulation
    local configured_count = 0
    local player_target_count = 0
    local resident_target_count = 0
    local combat_activated_count = 0
    instance.nativePhase = "attendance-active"
    for _, attacker in ipairs(candidates) do
        local name = safe_full_name(attacker)
        if actor_spawns > 0 then
            instance.attendanceSpawnedActorNames[name] = true
        end
        if instance.attackerNames[name] ~= true then
            instance.attackerNames[name] = true
            table.insert(instance.attackers, attacker)
        end
    end

    if attendance.resultBindingEnabled == true then
        if instance.attendanceResultBridge == nil then
            instance.lastError =
                "attendance-result-bridge-unavailable"
            instance.nativePhase = "failed"
            instance.active = false
            destroy_attendance_attackers(
                instance,
                "result-bridge-unavailable"
            )
            return false, instance.lastError
        end
        local begun = instance.attendanceResultBridge:begin(
            instance.generation,
            candidates
        )
        if not begun.ok then
            instance.lastError = "attendance-result-begin:"
                .. tostring(begun.reason)
            instance.nativePhase = "failed"
            instance.active = false
            destroy_attendance_attackers(
                instance,
                "result-bridge-begin-failed"
            )
            return false, instance.lastError
        end
    end

    for _, attacker in ipairs(candidates) do
        local configured, player_targeted, residents_targeted,
            combat_activated = prepare_attendance_attacker(
            instance,
            pawn,
            attacker,
            source,
            1
        )
        if configured then
            configured_count = configured_count + 1
        end
        if player_targeted then
            player_target_count = player_target_count + 1
        end
        if residents_targeted then
            resident_target_count = resident_target_count + 1
        end
        if combat_activated then
            combat_activated_count = combat_activated_count + 1
        end
    end

    instance.attendanceEngagedCount =
        instance.attendanceEngagedCount + #candidates
    instance.attendanceNativeSpawnedCount =
        instance.attendanceNativeSpawnedCount + actor_spawns
    log(string.format(
        "ATTENDANCE_RAID_STARTED source=%s playerPresent=true playerDistance=%.1f aggroRadius=%.1f candidates=%d configured=%d playerTargets=%d residentTargets=%d combatActivated=%d ready=%d readinessRetries=%d targetPlayerHate=%.1f targetResidentHate=%.1f actorSpawns=%d saveWrites=0",
        tostring(source),
        player_distance,
        attendance.aggroRadius,
        #candidates,
        configured_count,
        player_target_count,
        resident_target_count,
        combat_activated_count,
        instance.attendanceReadyCount,
        instance.config.attendanceSimulation.nativeCountdownSpawn
            .attackerReadyMaxAttempts,
        attendance.targetPlayerHate,
        attendance.targetResidentHate,
        actor_spawns
    ))

    for pulse_index, delay_ms in ipairs(
        attendance.retargetDelaysMs
    ) do
        schedule(
            instance,
            string.format(
                "attendance-retarget-g%d-%d",
                instance.generation,
                pulse_index
            ),
            delay_ms,
            function()
                if not instance.active
                    or instance.nativePhase ~= "attendance-active" then
                    return
                end
                for _, attacker in ipairs(instance.attackers) do
                    if is_valid(attacker) then
                        target_player_for_attendance(
                            instance,
                            attacker,
                            pawn,
                            "attendance-pulse-"
                                .. tostring(pulse_index)
                        )
                        activate_attacker_combat(
                            attacker,
                            "attendance-pulse-"
                                .. tostring(pulse_index)
                        )
                    end
                end
                retarget_attackers(
                    instance,
                    "attendance-pulse-"
                        .. tostring(pulse_index),
                    attendance.targetResidentHate
                )
            end
        )
    end
    schedule(
        instance,
        "attendance-cleanup-g" .. tostring(instance.generation),
        instance.config.cleanupDelayMs,
        function()
            if instance.attendanceResultBridge ~= nil then
                instance.attendanceResultBridge:cancel(
                    "attendance-event-timeout"
                )
            end
            destroy_attendance_attackers(
                instance,
                "attendance-event-complete"
            )
            instance.active = false
            instance.nativePhase = "complete"
            log(string.format(
                "ATTENDANCE_RAID_COMPLETE engaged=%d ready=%d readinessFailures=%d targets=%d actorSpawns=%d saveWrites=0",
                instance.attendanceEngagedCount,
                instance.attendanceReadyCount,
                instance.attendanceReadyFailureCount,
                instance.targetAssignments,
                instance.attendanceNativeSpawnedCount
            ))
        end
    )
    return true, nil
end

local function spawn_native_attendance_wave(
    instance,
    controller,
    player_location
)
    local attendance = instance.config.attendanceSimulation
    local spawn_config = attendance.nativeCountdownSpawn
    if spawn_config.enabled ~= true then
        return {}, "native-countdown-spawn-disabled"
    end
    local utility = load_pal_utility()
    if not is_valid(utility) then
        return {}, "PalUtility-unavailable"
    end
    local manager_ok, npc_manager = safe_call(
        utility,
        "GetNPCManager",
        controller
    )
    if not manager_ok or not is_valid(npc_manager) then
        return {}, "NPC-manager-unavailable"
    end
    local controller_class = safe_property(
        npc_manager,
        "NPCAIControllerBaseClass"
    )
    if not is_valid(controller_class) then
        return {}, "NPC-controller-class-unavailable"
    end

    local handles = {}
    local failures = 0
    for index, pal_id in ipairs(spawn_config.palIds) do
        local offset = spawn_config.offsets[index]
        local character_id, name_error = make_native_name(pal_id)
        local location = {
            X = player_location.X + offset.X,
            Y = player_location.Y + offset.Y,
            Z = player_location.Z + offset.Z,
        }
        local requested, handle = false, name_error
        if character_id ~= nil then
            requested, handle = pcall(function()
                return npc_manager:SpawnNPCForServer({
                    ControllerClass = controller_class,
                    CharacterID = character_id,
                    Level = instance.config.level,
                    Location = location,
                    Yaw = 0.0,
                    Squad = nil,
                }, nil)
            end)
        end
        if requested and is_valid(handle) then
            table.insert(handles, handle)
            log(string.format(
                "COUNTDOWN_NATIVE_PAL_REQUESTED index=%d palId=%s level=%d location=(%.1f,%.1f,%.1f) handle=%s saveWrites=0",
                index,
                pal_id,
                instance.config.level,
                location.X,
                location.Y,
                location.Z,
                safe_full_name(handle)
            ))
        else
            failures = failures + 1
            log(string.format(
                "COUNTDOWN_NATIVE_PAL_FAILED index=%d palId=%s error=%s",
                index,
                pal_id,
                requested and "invalid-handle" or tostring(handle)
            ))
        end
    end
    log(string.format(
        "COUNTDOWN_NATIVE_WAVE_REQUESTED requested=%d handles=%d failures=%d manager=%s spawnCall=SpawnNPCForServer saveWrites=0",
        #spawn_config.palIds,
        #handles,
        failures,
        safe_full_name(npc_manager)
    ))
    if #handles == 0 then
        return handles, "native-countdown-spawn-no-valid-handles"
    end
    instance.attendanceNativeSpawnHandles = handles
    return handles, nil
end

local function resolve_native_attendance_wave(
    instance,
    pawn,
    player_distance,
    handles,
    attempt
)
    if not instance.active
        or instance.nativePhase ~= "attendance-spawn-pending" then
        return
    end
    local actors = {}
    local actor_names = {}
    for _, handle in ipairs(handles) do
        local actor_ok, actor = safe_call(
            handle,
            "TryGetIndividualActor"
        )
        if actor_ok and is_valid(actor) then
            local actor_name = safe_full_name(actor)
            if actor_names[actor_name] ~= true then
                actor_names[actor_name] = true
                table.insert(actors, actor)
            end
        end
    end
    local spawn_config = instance.config.attendanceSimulation
        .nativeCountdownSpawn
    if #actors < #handles
        and attempt < spawn_config.maxResolveAttempts then
        schedule(
            instance,
            string.format(
                "attendance-native-resolve-g%d-%d",
                instance.generation,
                attempt + 1
            ),
            spawn_config.resolveIntervalMs,
            function()
                resolve_native_attendance_wave(
                    instance,
                    pawn,
                    player_distance,
                    handles,
                    attempt + 1
                )
            end
        )
        return
    end

    log(string.format(
        "COUNTDOWN_NATIVE_WAVE_RESOLVED handles=%d actors=%d attempts=%d saveWrites=0",
        #handles,
        #actors,
        attempt
    ))
    if #actors == 0 then
        instance.lastError = "native-countdown-spawn-actors-unresolved"
        instance.nativePhase = "failed"
        instance.active = false
        schedule(
            instance,
            "attendance-native-failed-cleanup-g"
                .. tostring(instance.generation),
            5000,
            function()
                destroy_attendance_attackers(
                    instance,
                    "actor-resolution-failed"
                )
            end
        )
        log(string.format(
            "ATTENDANCE_RAID_FAILED playerPresent=true playerDistance=%.1f aggroRadius=%.1f reason=%s",
            player_distance,
            instance.config.attendanceSimulation.aggroRadius,
            instance.lastError
        ))
        return
    end
    if #actors < #handles then
        instance.lastError = string.format(
            "native-countdown-spawn-partial:%d/%d",
            #actors,
            #handles
        )
        log(string.format(
            "COUNTDOWN_NATIVE_WAVE_PARTIAL handles=%d actors=%d unresolved=%d attempts=%d action=engage-resolved-actors",
            #handles,
            #actors,
            #handles - #actors,
            attempt
        ))
    end
    engage_attendance_candidates(
        instance,
        pawn,
        player_distance,
        actors,
        #actors,
        "attendance-native-countdown"
    )
end

local function launch_attendance_simulation(instance)
    local attendance = instance.config.attendanceSimulation
    if attendance.enabled ~= true then
        instance.lastError = "attendance-simulation-disabled"
        instance.active = false
        instance.nativePhase = "failed"
        return false, instance.lastError
    end

    local controller, pawn, player_error = find_local_player()
    if not is_valid(controller) or not is_valid(pawn) then
        instance.lastError = player_error
        instance.active = false
        instance.nativePhase = "failed"
        return false, player_error
    end
    local player_location = actor_location(pawn)
    if player_location == nil then
        instance.lastError = "player-location-unavailable"
        instance.active = false
        instance.nativePhase = "failed"
        return false, instance.lastError
    end
    local center = instance.config.settlement.location
    local player_distance = math.sqrt(squared_distance(
        player_location,
        center
    ))
    local player_present =
        player_distance <= attendance.playerPresentRadius
    instance.attendanceLastPlayerDistance = player_distance
    instance.attendanceLastPlayerPresent = player_present

    if not player_present then
        if attendance.backgroundResolveWhenAbsent ~= true
            or attendance.noActorSpawnWhenAbsent ~= true then
            instance.lastError =
                "attendance-absent-policy-not-fail-closed"
            instance.active = false
            instance.nativePhase = "failed"
            return false, instance.lastError
        end
        record_background_raid(
            instance,
            "countdown-complete-player-absent",
            player_distance
        )
        instance.nativePhase = "background-resolved"
        instance.attendanceBackgroundResolvedCount =
            instance.attendanceBackgroundResolvedCount + 1
        instance.active = false
        instance.lastError = nil
        return true, "background-resolved"
    end

    local candidates = {}
    local scan_error = "loaded-world-fallback-disabled"
    if attendance.nativeCountdownSpawn.loadedWorldFallbackEnabled
        == true then
        candidates, scan_error = find_attendance_pals(instance)
    end
    local handles, spawn_error = spawn_native_attendance_wave(
        instance,
        controller,
        player_location
    )
    if #handles > 0 then
        instance.nativePhase = "attendance-spawn-pending"
        schedule(
            instance,
            "attendance-native-resolve-g"
                .. tostring(instance.generation) .. "-1",
            attendance.nativeCountdownSpawn.resolveIntervalMs,
            function()
                resolve_native_attendance_wave(
                    instance,
                    pawn,
                    player_distance,
                    handles,
                    1
                )
            end
        )
        return true, "native-countdown-spawn-pending"
    end

    if attendance.nativeCountdownSpawn.loadedWorldFallbackEnabled
        == true and #candidates > 0 then
        log(string.format(
            "COUNTDOWN_NATIVE_WAVE_FALLBACK loadedCandidates=%d spawnError=%s",
            #candidates,
            tostring(spawn_error)
        ))
        return engage_attendance_candidates(
            instance,
            pawn,
            player_distance,
            candidates,
            0,
            "attendance-loaded-world-fallback"
        )
    end

    instance.lastError = spawn_error
        or "native-countdown-spawn-failed:"
            .. tostring(scan_error)
    instance.nativePhase = "failed"
    instance.active = false
    log(string.format(
        "ATTENDANCE_RAID_FAILED playerPresent=true playerDistance=%.1f aggroRadius=%.1f reason=%s",
        player_distance,
        attendance.aggroRadius,
        instance.lastError
    ))
    return false, instance.lastError
end

local function execute_countdown_route(instance)
    if instance.config.executionMode == "native-negotiator" then
        return launch_native_invasion(instance)
    end
    if instance.config.executionMode == "attendance-simulation" then
        return launch_attendance_simulation(instance)
    end
    instance.lastError = "unsupported-execution-mode:"
        .. tostring(instance.config.executionMode)
    instance.active = false
    instance.nativePhase = "failed"
    return false, instance.lastError
end

local function make_native_ftext(message)
    if type(StaticFindObject) == "function" then
        local found, text_library = pcall(function()
            return StaticFindObject(
                "/Script/Engine.Default__KismetTextLibrary"
            )
        end)
        if found and is_valid(text_library) then
            local converted, warning_text = pcall(function()
                return text_library:Conv_StringToText(message)
            end)
            if converted and warning_text ~= nil then
                return warning_text, nil
            end
        end
    end
    if type(FText) == "function" then
        local constructed, warning_text = pcall(function()
            return FText(message)
        end)
        if constructed and warning_text ~= nil then
            return warning_text, nil
        end
    end
    return nil, "native-ftext-construction-unavailable"
end

local function set_live_common_warning_text(warning_text)
    if type(FindAllOf) ~= "function" then
        return 0
    end
    local found_ok, warnings = pcall(function()
        return FindAllOf("WBP_CommonWarning_C")
    end)
    if not found_ok or warnings == nil then
        return 0
    end
    local updated = 0
    for _, warning in pairs(warnings) do
        if is_valid(warning) then
            local text_block =
                safe_property(warning, "BP_PalRichTextBlock")
            if is_valid(text_block) then
                local set_ok = pcall(function()
                    text_block:SetText(warning_text)
                    text_block:SetVisibility(0)
                end)
                if set_ok then
                    updated = updated + 1
                end
            end
        end
    end
    return updated
end

local function show_native_warning(instance, message, source)
    if type(FindAllOf) ~= "function" then
        return false, "FindAllOf-unavailable"
    end
    local warning_text, text_error = make_native_ftext(message)
    if warning_text == nil then
        return false, text_error
    end

    local surfaces = {}
    for _, class_name in ipairs({
        "PalHUDService",
        "WBP_PalOverallUILayout_C",
    }) do
        local found_ok, found = pcall(function()
            return FindAllOf(class_name)
        end)
        if found_ok and found ~= nil then
            for _, object in pairs(found) do
                if is_valid(object) then
                    table.insert(surfaces, object)
                end
            end
        end
        if #surfaces > 0 then
            break
        end
    end

    for _, surface in ipairs(surfaces) do
        local shown = pcall(function()
            surface:ShowCommonWarning({
                Message = warning_text,
                DisplayType = 0,
            })
        end)
        if shown then
            set_live_common_warning_text(warning_text)
            instance.warningSerial = instance.warningSerial + 1
            schedule(
                instance,
                "warning-text-" .. tostring(instance.warningSerial),
                100,
                function()
                    set_live_common_warning_text(warning_text)
                end
            )
            log(string.format(
                "COUNTDOWN_WARNING source=%s message=%s",
                tostring(source),
                tostring(message)
            ))
            return true, nil
        end
    end
    return false, "warning-surface-unavailable"
end

local function load_blueprint_class(asset_path, class_path)
    if type(StaticFindObject) ~= "function" then
        return nil
    end
    local found, blueprint_class = pcall(function()
        return StaticFindObject(class_path)
    end)
    if found and is_valid(blueprint_class) then
        return blueprint_class
    end
    if type(LoadAsset) == "function" then
        pcall(function()
            LoadAsset(asset_path)
        end)
        found, blueprint_class = pcall(function()
            return StaticFindObject(class_path)
        end)
        if found and is_valid(blueprint_class) then
            return blueprint_class
        end
    end
    return nil
end

local function remove_countdown_widget(instance, source)
    if is_valid(instance.countdownWidget) then
        safe_call(instance.countdownWidget, "RemoveFromViewport")
        safe_call(instance.countdownWidget, "RemoveFromParent")
        log("COUNTDOWN_UI_REMOVED source=" .. tostring(source))
    end
    instance.countdownWidget = nil
end

local function ensure_countdown_widget(instance, controller, pawn)
    if is_valid(instance.countdownWidget) then
        return instance.countdownWidget, nil
    end
    local widget_class = load_blueprint_class(
        COUNTDOWN_WIDGET_ASSET_PATH,
        COUNTDOWN_WIDGET_CLASS_PATH
    )
    if not is_valid(widget_class) then
        return nil, "countdown-widget-class-unavailable"
    end
    local found, widget_library = pcall(function()
        return StaticFindObject(
            "/Script/UMG.Default__WidgetBlueprintLibrary"
        )
    end)
    if not found or not is_valid(widget_library) then
        return nil, "WidgetBlueprintLibrary-unavailable"
    end
    local created, widget = pcall(function()
        return widget_library:Create(pawn, widget_class, controller)
    end)
    if not created or not is_valid(widget) then
        return nil, "countdown-widget-create-failed"
    end
    if not safe_call(widget, "AddToViewport", 80) then
        return nil, "countdown-widget-add-failed"
    end
    safe_call(widget, "SetVisibility", 0)
    pcall(function()
        widget.bSimpleDetail = false
        widget.bFirstAnimation = true
    end)
    instance.countdownWidget = widget
    return widget, nil
end

local function countdown_message(seconds)
    if seconds >= 60 and seconds % 60 == 0 then
        return string.format(
            "小型聚落将在%d分钟后遭到狂暴帕鲁袭击。",
            math.floor(seconds / 60)
        )
    end
    return string.format(
        "小型聚落将在%d秒后遭到狂暴帕鲁袭击。",
        seconds
    )
end

local function maybe_show_countdown_milestone(
    instance,
    remaining_seconds
)
    for _, milestone in ipairs({
        { seconds = 600, key = "10m" },
        { seconds = 300, key = "5m" },
        { seconds = 60, key = "1m" },
        { seconds = 10, key = "10s" },
    }) do
        if remaining_seconds <= milestone.seconds
            and instance.countdownMilestones[milestone.key] ~= true
            and instance.currentCountdownSeconds > milestone.seconds then
            instance.countdownMilestones[milestone.key] = true
            show_native_warning(
                instance,
                countdown_message(milestone.seconds),
                "milestone-" .. milestone.key
            )
        end
    end
end

local update_countdown
update_countdown = function(instance, generation)
    if not instance.active or generation ~= instance.generation then
        remove_countdown_widget(instance, "inactive")
        return
    end
    local remaining = math.max(0, instance.countdownEndsAt - os.time())
    instance.countdownRemainingSeconds = remaining

    local controller, pawn = find_local_player()
    if is_valid(controller) and is_valid(pawn) then
        local widget, widget_error = ensure_countdown_widget(
            instance,
            controller,
            pawn
        )
        if is_valid(widget) then
            safe_call(widget, "SetRemainTime", remaining + 0.0)
        elseif instance.countdownUiError ~= widget_error then
            instance.countdownUiError = widget_error
            log("COUNTDOWN_UI_UNAVAILABLE error=" .. tostring(widget_error))
        end
    end

    maybe_show_countdown_milestone(instance, remaining)
    if remaining <= 0 then
        remove_countdown_widget(instance, "countdown-complete")
        local launched, reason = execute_countdown_route(instance)
        log(string.format(
            "COUNTDOWN_COMPLETE mode=%s launched=%s reason=%s generation=%d",
            instance.config.executionMode,
            tostring(launched),
            tostring(reason),
            generation
        ))
        return
    end
    schedule(
        instance,
        "countdown-tick-g" .. tostring(generation),
        1000,
        function()
            update_countdown(instance, generation)
        end
    )
end

is_night = function(world_context)
    local utility = load_pal_utility()
    if not is_valid(utility) then
        return nil, "PalUtility-unavailable"
    end
    local ok, result = safe_call(utility, "IsNight", world_context)
    if not ok then
        return nil, "IsNight-failed"
    end
    return result == true, nil
end

local function force_qa_night(instance, controller, world_context)
    local target_hour = tonumber(instance.config.qaForceNightHour)
    if target_hour == nil then
        return true, "disabled"
    end
    -- A real next-night transition updates Palworld's authoritative day type,
    -- while SetGameTime_FixDay only changes the reported clock hour.  Preserve
    -- an already-native night during QA so the helper cannot turn a valid
    -- invasion precondition back into a visually-dark Day state.
    local already_night, existing_night_error = is_night(world_context)
    if already_night == true then
        local current_hour, current_day_type, time_debug =
            native_time_diagnostics(world_context)
        log(string.format(
            "QA_NIGHT_PRESERVED target=%d currentHour=%s dayType=%s timeDebug=%s isNight=true nightError=%s saveRestoreRequired=true",
            math.floor(target_hour),
            current_hour,
            current_day_type,
            time_debug,
            tostring(existing_night_error)
        ))
        return true, "already-native-night"
    end
    local rpc_ok = false
    local rpc_error = "disabled"
    if instance.config.qaAuthoritativeNightRpcEnabled == true then
        rpc_ok, rpc_error = safe_call(
            controller,
            "Debug_SetPalWorldTime",
            math.floor(target_hour)
        )
    end
    local utility = load_pal_utility()
    if not is_valid(utility) then
        return false, "PalUtility-unavailable"
    end
    local manager_ok, manager = safe_call(
        utility,
        "GetTimeManager",
        world_context
    )
    if not manager_ok or not is_valid(manager) then
        return false, "PalTimeManager-unavailable"
    end
    local before_ok, before_hour = safe_call(
        manager,
        "GetCurrentPalWorldTime_Hour"
    )
    local set_ok, set_error = safe_call(
        manager,
        "SetGameTime_FixDay",
        math.floor(target_hour)
    )
    if not set_ok then
        return false, "SetGameTime_FixDay-failed:"
            .. tostring(set_error)
    end
    local after_ok, after_hour = safe_call(
        manager,
        "GetCurrentPalWorldTime_Hour"
    )
    local night, night_error = is_night(world_context)
    local current_hour, current_day_type, time_debug =
        native_time_diagnostics(world_context)
    log(string.format(
        "QA_NIGHT_SET target=%d rpc=%s rpcError=%s before=%s beforeOk=%s after=%s afterOk=%s currentHour=%s dayType=%s timeDebug=%s isNight=%s nightError=%s manager=%s saveRestoreRequired=true",
        math.floor(target_hour),
        tostring(rpc_ok),
        tostring(rpc_error),
        tostring(before_hour),
        tostring(before_ok),
        tostring(after_hour),
        tostring(after_ok),
        current_hour,
        current_day_type,
        time_debug,
        tostring(night),
        tostring(night_error),
        safe_full_name(manager)
    ))
    return true, nil
end

local function begin_event(
    instance,
    source,
    bypass_night_and_cooldown,
    countdown_override_seconds
)
    if instance.active then
        return false, "event-active"
    end
    local controller, pawn, context_error = find_local_player()
    if not is_valid(controller) or not is_valid(pawn) then
        return false, context_error
    end
    local player_location = actor_location(pawn)
    if player_location == nil then
        return false, "player-location-unavailable"
    end
    if not bypass_night_and_cooldown
        and not player_is_near_settlement(instance, player_location) then
        return false, "player-outside-small-settlement"
    end

    if not bypass_night_and_cooldown
        and instance.config.nightOnly == true then
        local night, night_error = is_night(pawn)
        if night == nil then
            return false, night_error
        end
        if not night then
            return false, "daytime"
        end
    end

    local current_time = os.time()
    if not bypass_night_and_cooldown
        and instance.lastTriggerWallClock ~= nil
        and current_time - instance.lastTriggerWallClock
            < instance.config.cooldownSeconds then
        return false, "cooldown"
    end

    instance.generation = instance.generation + 1
    instance.active = true
    instance.triggerCount = instance.triggerCount + 1
    instance.lastTriggerWallClock = current_time
    instance.lastTriggerSource = source
    instance.lastError = nil
    instance.eventAnchor = player_location
    instance.attackers = {}
    instance.attackerNames = {}
    instance.nativeIncidentNames = {}
    instance.nativeVisitorNames = {}
    instance.nativeIncidentCount = 0
    instance.nativeVisitorCount = 0
    instance.nativeSpawnedCount = 0
    instance.selectionOverrideCount = 0
    instance.nativeDirectIncidentRequestCount = 0
    instance.nativeManagerInfoObserved = false
    instance.negotiatorObserved = false
    instance.negotiatorSpawnCallbackCount = 0
    instance.nativePhase = "countdown"
    instance.lastNativeManagerSource = "none"
    instance.lastVisitorIncidentName = "none"
    instance.startPointOverrideCount = 0
    instance.targetPositionOverrideCount = 0
    instance.targetAssignments = 0
    instance.nativeRedirectActive = false
    instance.nativeRedirectArmed = false
    instance.countdownMilestones = {}
    instance.countdownUiError = nil
    instance.rampagingFallbackStatus =
        instance.config.rampagingPalFallback.enabled
            and "provider-pending"
        or "disabled"
    instance.rampagingFallbackAttemptCount = 0
    instance.rampagingFallbackStartCount = 0
    instance.rampagingFallbackLastError = nil
    instance.attendanceEngagedCount = 0
    instance.attendanceNativeSpawnedCount = 0
    instance.attendanceLastPlayerDistance = -1
    instance.attendanceLastPlayerPresent = false
    instance.attendanceReadyActors = {}
    instance.attendanceReadyFailures = {}
    instance.attendanceReadyCount = 0
    instance.attendanceReadyFailureCount = 0
    instance.attendanceNativeSpawnHandles = {}
    instance.attendanceSpawnedActorNames = {}
    instance.attendanceDestroyedCount = 0
    instance.attendanceDestroyFailureCount = 0

    local countdown_seconds = instance.config.countdownSeconds
    if bypass_night_and_cooldown
        and countdown_override_seconds ~= nil then
        countdown_seconds = math.max(
            5,
            math.min(
                instance.config.countdownSeconds,
                math.floor(countdown_override_seconds)
            )
        )
    end
    instance.currentCountdownSeconds = countdown_seconds
    instance.countdownRemainingSeconds = countdown_seconds
    instance.countdownEndsAt = current_time + countdown_seconds

    show_native_warning(
        instance,
        countdown_message(countdown_seconds),
        "event-declared"
    )
    update_countdown(instance, instance.generation)
    log(string.format(
        "EVENT_DECLARED trigger=%d source=%s settlement=%s nativeGroup=%s countdownSeconds=%d level=%d nightOnly=%s cooldownSeconds=%d generation=%d",
        instance.triggerCount,
        tostring(source),
        instance.config.settlement.displayNameZhHans,
        instance.config.nativeInvaderGroupName,
        countdown_seconds,
        instance.config.level,
        tostring(instance.config.nightOnly),
        instance.config.cooldownSeconds,
        instance.generation
    ))
    return true, nil
end

local function log_to_console(output_device, message)
    log(message)
    if output_device ~= nil then
        pcall(function()
            output_device:Log(
                string.format("%s %s", PREFIX, tostring(message))
            )
        end)
    end
end

function SettlementRaid.validate_config(config)
    assert(type(config) == "table", "settlement raid configuration is required")
    assert(config.enabled == true, "settlement raid must be explicitly enabled")
    assert(
        config.executionMode == "native-negotiator"
            or config.executionMode == "attendance-simulation",
        "settlement raid execution mode is unsupported"
    )
    assert(config.level == 80, "settlement attackers must use level 80")
    assert(
        config.replaceNativePlayerBaseInvasion == true,
        "native player-base invasion replacement must be explicit"
    )
    assert(config.nightOnly == true, "dark nocturnal tribe raid must remain night-only")
    if config.qaHotkeyEnabled == true then
        assert(
            type(config.qaForceNightHour) == "number"
                and config.qaForceNightHour >= 0
                and config.qaForceNightHour <= 23,
            "QA force-night hour must be a valid hour"
        )
        assert(
            type(config.qaAuthoritativeNightRpcEnabled) == "boolean",
            "QA authoritative-night RPC gate must be explicit"
        )
        assert(
            type(config.qaNightSettleDelayMs) == "number"
                and config.qaNightSettleDelayMs >= 500
                and config.qaNightSettleDelayMs <= 5000,
            "QA night settle delay must be bounded"
        )
    end
    assert(
        type(config.nativeIncidentConfirmationDelayMs) == "number"
            and config.nativeIncidentConfirmationDelayMs >= 5000
            and config.nativeIncidentConfirmationDelayMs <= 60000,
        "native incident confirmation window must be bounded"
    )
    assert(
        type(config.nativeNegotiatorTimeoutMs) == "number"
            and config.nativeNegotiatorTimeoutMs
                > config.nativeIncidentConfirmationDelayMs
            and config.nativeNegotiatorTimeoutMs <= 5 * 60 * 1000,
        "native negotiator timeout must follow confirmation and stay bounded"
    )
    assert(
        type(config.nativeDirectIncidentFallbackEnabled) == "boolean",
        "native direct-incident fallback gate must be explicit"
    )
    assert(
        type(config.nativeDirectIncidentConfirmationDelayMs) == "number"
            and config.nativeDirectIncidentConfirmationDelayMs >= 5000
            and config.nativeDirectIncidentConfirmationDelayMs <= 60000,
        "native direct-incident confirmation window must be bounded"
    )
    assert(
        type(config.nativeFallbackLaunchEnabled) == "boolean",
        "native fallback launch gate must be explicit"
    )
    assert(
        type(config.nativeRandomFallbackDelayMs) == "number"
            and config.nativeRandomFallbackDelayMs >= 1000
            and config.nativeRandomFallbackDelayMs
                < config.nativeIncidentConfirmationDelayMs,
        "native random fallback delay must precede confirmation"
    )
    assert(
        type(config.nativeAllFallbackDelayMs) == "number"
            and config.nativeAllFallbackDelayMs
                > config.nativeRandomFallbackDelayMs
            and config.nativeAllFallbackDelayMs
                < config.nativeIncidentConfirmationDelayMs,
        "native all fallback delay must follow random and precede confirmation"
    )
    assert(
        type(config.rampagingPalFallback) == "table",
        "rampaging-Pal fallback contract is required"
    )
    assert(
        type(config.rampagingPalFallback.enabled) == "boolean"
            and type(config.rampagingPalFallback.liveValidated)
                == "boolean",
        "rampaging-Pal fallback gates must be explicit"
    )
    assert(
        config.rampagingPalFallback.enabled ~= true
            or config.rampagingPalFallback.liveValidated == true,
        "unproven rampaging-Pal fallback must remain fail-closed"
    )
    assert(
        config.rampagingPalFallback.activationPolicy
            == "only-after-native-negotiator-route-live-fails",
        "rampaging-Pal fallback activation policy mismatch"
    )
    assert(
        config.rampagingPalFallback.spawnMode
            == "native-predator-spawner-provider-required",
        "rampaging-Pal fallback must require a native spawner provider"
    )
    assert(
        config.rampagingPalFallback.predator == true
            and config.rampagingPalFallback.targetHate
                == config.targetHate
            and config.rampagingPalFallback.makeUncapturable == true,
        "rampaging-Pal fallback aggression contract mismatch"
    )
    assert(
        config.rampagingPalFallback.saveWrites == false,
        "rampaging-Pal fallback must not write Palworld saves"
    )
    assert(
        type(config.attendanceSimulation) == "table",
        "attendance simulation configuration is required"
    )
    local attendance = config.attendanceSimulation
    assert(
        type(attendance.enabled) == "boolean"
            and type(attendance.qaOnly) == "boolean"
            and type(attendance.liveValidated) == "boolean",
        "attendance simulation gates must be explicit"
    )
    assert(
        type(attendance.resultBindingEnabled) == "boolean",
        "attendance raid-result binding gate is required"
    )
    if attendance.resultBindingEnabled then
        assert(
            attendance.liveValidated == true
                and attendance.nativeCountdownSpawn
                    .loadedWorldFallbackEnabled == false,
            "attendance result binding requires the live-validated native-spawn route"
        )
    end
    if config.executionMode == "attendance-simulation" then
        assert(
            attendance.enabled == true,
            "attendance execution mode requires its feature gate"
        )
        assert(
            attendance.liveValidated == true
                or attendance.qaOnly == true
                    and config.qaHotkeyEnabled == true,
            "unvalidated attendance simulation is QA-only"
        )
    end
    assert(
        type(attendance.playerPresentRadius) == "number"
            and attendance.playerPresentRadius >= 1000
            and attendance.playerPresentRadius
                <= config.settlement.triggerRadius,
        "attendance player-presence radius must stay inside the settlement trigger"
    )
    assert(
        type(attendance.aggroRadius) == "number"
            and attendance.aggroRadius
                > attendance.playerPresentRadius
            and attendance.aggroRadius <= 100000,
        "attendance aggro radius must be larger but bounded"
    )
    assert(
        type(attendance.targetPlayerHate) == "number"
            and type(attendance.targetResidentHate) == "number"
            and attendance.targetPlayerHate > 0
            and attendance.targetResidentHate
                > attendance.targetPlayerHate,
        "settlement residents must outrank the player in siege hate"
    )
    assert(
        attendance.backgroundResolveWhenAbsent == true
            and attendance.noActorSpawnWhenAbsent == true,
        "absent-player attendance route must be background-only"
    )
    assert(
        type(attendance.maxHistory) == "number"
            and attendance.maxHistory >= 1
            and attendance.maxHistory <= 128,
        "attendance background history must be bounded"
    )
    assert(
        type(attendance.retargetDelaysMs) == "table"
            and #attendance.retargetDelaysMs >= 1,
        "attendance retarget schedule is required"
    )
    local countdown_spawn = attendance.nativeCountdownSpawn
    assert(
        type(countdown_spawn) == "table"
            and type(countdown_spawn.enabled) == "boolean"
            and type(countdown_spawn.loadedWorldFallbackEnabled)
                == "boolean"
            and type(countdown_spawn.palIds) == "table"
            and #countdown_spawn.palIds >= 1
            and #countdown_spawn.palIds <= 16
            and type(countdown_spawn.offsets) == "table"
            and #countdown_spawn.offsets == #countdown_spawn.palIds,
        "attendance native countdown wave must be explicitly bounded"
    )
    assert(
        countdown_spawn.loadedWorldFallbackEnabled == false,
        "native countdown spawn must not reuse unrelated loaded world Pals"
    )
    for index, pal_id in ipairs(countdown_spawn.palIds) do
        local offset = countdown_spawn.offsets[index]
        assert(
            type(pal_id) == "string"
                and pal_id ~= ""
                and type(offset) == "table"
                and type(offset.X) == "number"
                and type(offset.Y) == "number"
                and type(offset.Z) == "number",
            "attendance native countdown spawn entry is invalid"
        )
    end
    assert(
        type(countdown_spawn.resolveIntervalMs) == "number"
            and countdown_spawn.resolveIntervalMs >= 100
            and countdown_spawn.resolveIntervalMs <= 2000
            and type(countdown_spawn.maxResolveAttempts) == "number"
            and countdown_spawn.maxResolveAttempts >= 1
            and countdown_spawn.maxResolveAttempts <= 40,
        "attendance native spawn resolution must be bounded"
    )
    assert(
        type(countdown_spawn.attackerReadyRetryMs) == "number"
            and countdown_spawn.attackerReadyRetryMs >= 100
            and countdown_spawn.attackerReadyRetryMs <= 2000
            and type(countdown_spawn.attackerReadyMaxAttempts)
                == "number"
            and countdown_spawn.attackerReadyMaxAttempts >= 1
            and countdown_spawn.attackerReadyMaxAttempts <= 40,
        "attendance attacker readiness retry must be bounded"
    )
    assert(
        countdown_spawn.saveWrites == false,
        "attendance native countdown spawn declares no explicit save writes"
    )
    assert(
        type(attendance.qaCandidateBlueprints) == "table"
            and #attendance.qaCandidateBlueprints >= 1
            and type(attendance.qaSpawnAnchor) == "table"
            and type(attendance.qaSpawnAnchor.X) == "number"
            and type(attendance.qaSpawnAnchor.Y) == "number"
            and type(attendance.qaSpawnAnchor.Z) == "number"
            and type(attendance.qaSpawnRadius) == "number"
            and attendance.qaSpawnRadius >= 1000
            and attendance.qaSpawnRadius <= attendance.aggroRadius,
        "attendance QA candidates must be explicitly bounded"
    )
    assert(
        config.countdownSeconds == 15 * 60,
        "small settlement raid warning must remain fifteen minutes"
    )
    assert(
        config.nearestPalFactionId
            == "pwft.faction.dark_nocturnal_pal_tribe",
        "small settlement nearest Pal faction mismatch"
    )
    assert(
        config.nativeInvaderGroupName
            == "Invader_Group_Monster_Grade5_Basic",
        "small settlement must reuse the native Grade 5 meadow Pal invasion"
    )
    assert(type(config.settlement) == "table", "small settlement binding is required")
    assert(
        config.settlement.nativeRegionNameId == "Grass_Village_001",
        "small settlement native region mismatch"
    )
    assert(
        config.settlement.fastTravelPointId == "FTPoint24",
        "small settlement fast-travel binding mismatch"
    )
    assert(
        type(config.retargetDelaysMs) == "table"
            and #config.retargetDelaysMs >= 1,
        "native raid retarget schedule is required"
    )
    return true
end

function SettlementRaid.classify_incident_name(name)
    return incident_kind_from_name(name)
end

function SettlementRaid.native_contract(config)
    SettlementRaid.validate_config(config)
    return {
        groupName = config.nativeInvaderGroupName,
        executionMode = config.executionMode,
        managerAccessor = "PalUtility.GetInvaderManager",
        managerLaunch = "PalInvaderManager.StartInvaderMarchForBaseCamp",
        selectionPath = NATIVE_SELECT_INVADERS_PATH,
        selectionGrade = config.level,
        selectionBiome = "Meadow",
        targetPositionPath = NATIVE_TARGET_POSITION_PATH,
        startPointPath = NATIVE_START_POINT_PATH,
        visitorStartPointPath = NATIVE_VISITOR_START_POINT_PATH,
        visitorAllSpawnedPath = NATIVE_VISITOR_ALL_SPAWNED_PATH,
        lifecyclePhases = {
            "manager-requested",
            "negotiator-created",
            "negotiator-active",
            "assault",
        },
        startPointOverridesSuccessFlag = true,
        fallbackLaunchEnabled = config.nativeFallbackLaunchEnabled,
        negotiatorTimeoutMs = config.nativeNegotiatorTimeoutMs,
        directIncidentFallback = {
            enabled = config.nativeDirectIncidentFallbackEnabled,
            request = table.concat({
                "PalInvaderManager.RequestIncidentVisitorNPC(campId, observer, true)",
                "PalInvaderManager.RequestIncidentInvaderEnemy(campId, observer)",
            }, " -> "),
            activationPolicy =
                "after-native-negotiator-open-ground-confirmation-fails",
            confirmationDelayMs =
                config.nativeDirectIncidentConfirmationDelayMs,
            ownsCharacterLifecycle = false,
            saveWrites = false,
        },
        rampagingPalFallback = {
            enabled = config.rampagingPalFallback.enabled,
            liveValidated =
                config.rampagingPalFallback.liveValidated,
            activationPolicy =
                config.rampagingPalFallback.activationPolicy,
            spawnMode = config.rampagingPalFallback.spawnMode,
            predator = config.rampagingPalFallback.predator,
            targetHate = config.rampagingPalFallback.targetHate,
            makeUncapturable =
                config.rampagingPalFallback.makeUncapturable,
            saveWrites = config.rampagingPalFallback.saveWrites,
            providerInterface =
                "spawn_wave(request, on_spawn_actor)",
        },
        attendanceSimulation = {
            enabled = config.attendanceSimulation.enabled,
            qaOnly = config.attendanceSimulation.qaOnly,
            liveValidated =
                config.attendanceSimulation.liveValidated,
            resultBindingEnabled =
                config.attendanceSimulation.resultBindingEnabled,
            resultBridge = {
                eventAuthority = "pwft-attendance-event-v1",
                spawnAuthority = "pwft-npc-manager-spawn-v1",
                deathAuthority =
                    "pal-character-on-dead-character-v1",
                outcomeAuthority =
                    "pwft-attendance-all-members-dead-v1",
                deathPath = ATTENDANCE_DEATH_PATH,
                participationRule =
                    "designated-leader-killed-by-local-player-or-owned-pal",
                victoryRule = "all-registered-attackers-dead",
                timerCleanupMaySettleRaid = false,
            },
            playerPresentRadius =
                config.attendanceSimulation.playerPresentRadius,
            aggroRadius = config.attendanceSimulation.aggroRadius,
            qaCandidateBlueprints =
                config.attendanceSimulation.qaCandidateBlueprints,
            qaSpawnAnchor = config.attendanceSimulation.qaSpawnAnchor,
            qaSpawnRadius = config.attendanceSimulation.qaSpawnRadius,
            nativeCountdownSpawn = {
                enabled = config.attendanceSimulation
                    .nativeCountdownSpawn.enabled,
                loadedWorldFallbackEnabled = config.attendanceSimulation
                    .nativeCountdownSpawn.loadedWorldFallbackEnabled,
                count = #config.attendanceSimulation
                    .nativeCountdownSpawn.palIds,
                managerAccessor = "PalUtility.GetNPCManager",
                spawnCall = "PalNPCManager.SpawnNPCForServer",
                actorResolution =
                    "PalIndividualCharacterHandle.TryGetIndividualActor",
                nameConstruction =
                    "KismetStringLibrary.Conv_StringToName",
                readinessRetryMs = config.attendanceSimulation
                    .nativeCountdownSpawn.attackerReadyRetryMs,
                readinessMaxAttempts = config.attendanceSimulation
                    .nativeCountdownSpawn.attackerReadyMaxAttempts,
                cleanupMethod =
                    "Actor." .. TRANSIENT_ATTACKER_DESTROY_METHOD,
                playerAbsentPolicy = "no-spawn",
                saveWrites = false,
            },
            combatActivation = {
                initializer =
                    "PalAIController.SetInitialValue(false, true)",
                controller = "PalAIController.SetActiveAI(true)",
                actor = "PalCharacter.ChangeBattleModeFlag_ToAll(true)",
            },
            targetPlayerHate =
                config.attendanceSimulation.targetPlayerHate,
            targetResidentHate =
                config.attendanceSimulation.targetResidentHate,
            absentResolution = "background-record-only",
            actorSpawnsWhenAbsent = false,
            recorderInterface = "record(background_raid_record)",
            saveWrites = false,
        },
        spawnedPaths = {
            NATIVE_BASE_SPAWNED_PATH,
            NATIVE_ENEMY_SPAWNED_PATH,
        },
        ownsCharacterLifecycle =
            config.executionMode == "attendance-simulation",
        saveWrites = false,
    }
end

function SettlementRaid.start(config, options)
    SettlementRaid.validate_config(config)
    options = options or {}
    local attendance_result_bridge = nil
    if config.attendanceSimulation.resultBindingEnabled == true then
        assert(
            type(options.palRaidResultAdapter) == "table",
            "attendance raid-result adapter is required"
        )
        attendance_result_bridge =
            AttendanceRaidResultBridge.create(
                options.palRaidResultAdapter,
                {
                    palFactionId = config.nearestPalFactionId,
                    nativeGroupName = config.nativeInvaderGroupName,
                    settlementId = config.settlement.id,
                    expectedAttackerCount =
                        #config.attendanceSimulation
                            .nativeCountdownSpawn.palIds,
                },
                {
                    logger = log,
                    attributionResolver =
                        options.attendanceAttributionResolver,
                }
            )
    end
    local instance = {
        config = config,
        callbacks = {},
        hooks = {},
        hookErrors = {},
        generation = 0,
        active = false,
        triggerCount = 0,
        lastTriggerWallClock = nil,
        lastTriggerSource = "none",
        lastError = nil,
        eventAnchor = nil,
        attackers = {},
        attackerNames = {},
        nativeIncidentNames = {},
        nativeVisitorNames = {},
        nativeIncidentCount = 0,
        nativeVisitorCount = 0,
        nativeSpawnedCount = 0,
        selectionOverrideCount = 0,
        nativeLaunchCount = 0,
        nativeDirectIncidentRequestCount = 0,
        nativeRedirectActive = false,
        nativeRedirectArmed = false,
        startPointOverrideCount = 0,
        targetPositionOverrideCount = 0,
        targetAssignments = 0,
        lastIncidentName = "none",
        lastVisitorIncidentName = "none",
        lastNativeManagerSource = "none",
        nativeManagerInfoObserved = false,
        negotiatorObserved = false,
        negotiatorSpawnCallbackCount = 0,
        nativePhase = "idle",
        nativeInvaderDisabled = false,
        nativeInvaderDisableError = nil,
        originalNativeInvaderDisabled = nil,
        countdownWidget = nil,
        countdownEndsAt = 0,
        countdownRemainingSeconds = 0,
        currentCountdownSeconds = config.countdownSeconds,
        countdownMilestones = {},
        countdownUiError = nil,
        warningSerial = 0,
        hookRegistrationAttempts = 0,
        nativeHookReadyCount = 0,
        rampagingPalSpawnerProvider =
            options.rampagingPalSpawnerProvider,
        rampagingFallbackStatus = config.rampagingPalFallback.enabled
                and "provider-pending"
            or "disabled",
        rampagingFallbackAttemptCount = 0,
        rampagingFallbackStartCount = 0,
        rampagingFallbackLastError = nil,
        backgroundRaidRecorder = options.backgroundRaidRecorder,
        backgroundRaidHistory = {},
        backgroundRaidCount = 0,
        attendanceBackgroundResolvedCount = 0,
        attendanceEngagedCount = 0,
        attendanceNativeSpawnedCount = 0,
        attendanceLastPlayerDistance = -1,
        attendanceLastPlayerPresent = false,
        attendanceReadyActors = {},
        attendanceReadyFailures = {},
        attendanceReadyCount = 0,
        attendanceReadyFailureCount = 0,
        attendanceNativeSpawnHandles = {},
        attendanceSpawnedActorNames = {},
        attendanceDestroyedCount = 0,
        attendanceDestroyFailureCount = 0,
        attendanceResultBridge = attendance_result_bridge,
        attendanceDeathObserver = options.attendanceDeathObserver,
    }

    function instance:on_world_loaded(source)
        if self.attendanceResultBridge ~= nil then
            self.attendanceResultBridge:cancel(
                source or "world-loaded"
            )
        end
        destroy_attendance_attackers(
            self,
            source or "world-loaded"
        )
        remove_countdown_widget(self, source or "world-loaded")
        self.generation = self.generation + 1
        self.active = false
        self.nativeRedirectActive = false
        self.nativeRedirectArmed = false
        self.attackers = {}
        self.attackerNames = {}
        self.nativeIncidentNames = {}
        self.nativeVisitorNames = {}
        self.nativeIncidentCount = 0
        self.nativeVisitorCount = 0
        self.nativeSpawnedCount = 0
        self.attendanceNativeSpawnedCount = 0
        self.attendanceReadyActors = {}
        self.attendanceReadyFailures = {}
        self.attendanceReadyCount = 0
        self.attendanceReadyFailureCount = 0
        self.attendanceNativeSpawnHandles = {}
        self.attendanceSpawnedActorNames = {}
        self.selectionOverrideCount = 0
        self.nativeDirectIncidentRequestCount = 0
        self.startPointOverrideCount = 0
        self.targetPositionOverrideCount = 0
        self.targetAssignments = 0
        self.nativeManagerInfoObserved = false
        self.negotiatorObserved = false
        self.negotiatorSpawnCallbackCount = 0
        self.nativePhase = "idle"
        self.rampagingFallbackStatus =
            self.config.rampagingPalFallback.enabled
                and "provider-pending"
            or "disabled"
        self.rampagingFallbackLastError = nil
        schedule_native_hook_registration(
            self,
            source or "world-loaded"
        )
        set_native_invader_disabled(
            self,
            self.config.replaceNativePlayerBaseInvasion == true,
            source or "world-loaded"
        )
    end

    function instance:on_region_display(region_name_id)
        if region_name_id
            ~= self.config.settlement.nativeRegionNameId then
            return false, "different-region"
        end
        local started, reason = begin_event(
            self,
            "native-region:" .. region_name_id,
            false
        )
        if not started then
            log(string.format(
                "ENTRY_SKIPPED region=%s reason=%s active=%s",
                tostring(region_name_id),
                tostring(reason),
                tostring(self.active)
            ))
        end
        return started, reason
    end

    function instance:force_start(source, countdown_override_seconds)
        return begin_event(
            self,
            source or "force",
            true,
            countdown_override_seconds
        )
    end

    function instance:try_rampaging_pal_fallback(source)
        return attempt_rampaging_pal_fallback(
            self,
            source or "manual"
        )
    end

    function instance:status()
        local result_bridge_status = self.attendanceResultBridge
            and self.attendanceResultBridge:status() or nil
        return {
            version = "1.0.0",
            executionMode = self.config.executionMode,
            active = self.active,
            phase = self.nativePhase,
            backgroundRaidCount = self.backgroundRaidCount,
            backgroundHistoryCount = #self.backgroundRaidHistory,
            attendanceEngagedCount = self.attendanceEngagedCount,
            attendanceNativeSpawnedCount =
                self.attendanceNativeSpawnedCount,
            attendanceReadyCount = self.attendanceReadyCount,
            attendanceReadyFailureCount =
                self.attendanceReadyFailureCount,
            attendanceDestroyedCount =
                self.attendanceDestroyedCount,
            attendanceDestroyFailureCount =
                self.attendanceDestroyFailureCount,
            attendanceLastPlayerPresent =
                self.attendanceLastPlayerPresent,
            attendanceLastPlayerDistance =
                self.attendanceLastPlayerDistance,
            attendanceResultBindingActive = result_bridge_status
                and result_bridge_status.active == true or false,
            attendanceResultSettlements = result_bridge_status
                and result_bridge_status.settlements or 0,
            attendanceResultCancellations = result_bridge_status
                and result_bridge_status.cancellations or 0,
            attendanceResultFailures = result_bridge_status
                and result_bridge_status.failures or 0,
            nativeVisitorCount = self.nativeVisitorCount,
            nativeIncidentCount = self.nativeIncidentCount,
            nativeSpawnedCount = self.nativeSpawnedCount,
            targetAssignments = self.targetAssignments,
            saveWrites = false,
            lastError = self.lastError,
        }
    end

    function instance:background_history()
        local copy = {}
        for index, record in ipairs(self.backgroundRaidHistory) do
            copy[index] = {
                schemaVersion = record.schemaVersion,
                settlementId = record.settlementId,
                source = record.source,
                generation = record.generation,
                resolvedAt = record.resolvedAt,
                playerPresent = record.playerPresent,
                playerDistance = record.playerDistance,
                outcome = record.outcome,
                actorSpawns = record.actorSpawns,
                worldCombat = record.worldCombat,
                saveWrites = false,
            }
        end
        return copy
    end

    schedule_native_hook_registration(instance, "startup")
    set_native_invader_disabled(
        instance,
        config.replaceNativePlayerBaseInvasion == true,
        "startup"
    )

    if type(RegisterConsoleCommandGlobalHandler) == "function" then
        RegisterConsoleCommandGlobalHandler(
            "pwft.raid",
            function(_, parts, output_device)
                local action = parts and parts[2] or "status"
                if action == "start" then
                    local countdown_override = parts
                        and tonumber(parts[3])
                        or nil
                    local started, reason = instance:force_start(
                        "console",
                        countdown_override
                    )
                    log_to_console(output_device, string.format(
                        "RAID_START started=%s reason=%s countdownSeconds=%d",
                        tostring(started),
                        tostring(reason),
                        instance.currentCountdownSeconds
                    ))
                    return true
                end
                log_to_console(output_device, string.format(
                    "RAID_STATUS mode=%s active=%s phase=%s countdownRemaining=%d triggers=%d group=%s launches=%d visitors=%d negotiatorObserved=%s incidents=%d selectionOverrides=%d managerInfo=%s spawned=%d startOverrides=%d targetOverrides=%d targets=%d nativeInvaderDisabled=%s fallbackLaunches=%s rampagingFallback=%s rampagingStatus=%s rampagingAttempts=%d rampagingStarts=%d attendanceEnabled=%s attendancePresent=%s attendanceDistance=%.1f attendanceEngaged=%d backgroundResolved=%d backgroundHistory=%d lastSource=%s lastError=%s",
                    instance.config.executionMode,
                    tostring(instance.active),
                    tostring(instance.nativePhase),
                    instance.countdownRemainingSeconds,
                    instance.triggerCount,
                    instance.config.nativeInvaderGroupName,
                    instance.nativeLaunchCount,
                    instance.nativeVisitorCount,
                    tostring(instance.negotiatorObserved),
                    instance.nativeIncidentCount,
                    instance.selectionOverrideCount,
                    tostring(instance.nativeManagerInfoObserved),
                    instance.nativeSpawnedCount,
                    instance.startPointOverrideCount,
                    instance.targetPositionOverrideCount,
                    instance.targetAssignments,
                    tostring(instance.nativeInvaderDisabled),
                    tostring(
                        instance.config.nativeFallbackLaunchEnabled
                            == true
                    ),
                    tostring(
                        instance.config.rampagingPalFallback.enabled
                            == true
                    ),
                    tostring(instance.rampagingFallbackStatus),
                    instance.rampagingFallbackAttemptCount,
                    instance.rampagingFallbackStartCount,
                    tostring(
                        instance.config.attendanceSimulation.enabled
                            == true
                    ),
                    tostring(instance.attendanceLastPlayerPresent),
                    instance.attendanceLastPlayerDistance,
                    instance.attendanceEngagedCount,
                    instance.attendanceBackgroundResolvedCount,
                    #instance.backgroundRaidHistory,
                    tostring(instance.lastTriggerSource),
                    tostring(instance.lastError)
                ))
                return true
            end
        )
    end

    if config.qaHotkeyEnabled == true
        and type(RegisterKeyBind) == "function"
        and Key ~= nil
        and Key.F8 ~= nil
        and ModifierKey ~= nil
        and ModifierKey.CONTROL ~= nil then
        local callback = function()
            local apply = function()
                local controller, pawn, player_error = find_local_player()
                if not is_valid(pawn) then
                    log(
                        "QA_HOTKEY_TRIGGER started=false reason="
                            .. tostring(player_error)
                    )
                    return
                end
                local forced, force_error = force_qa_night(
                    instance,
                    controller,
                    pawn
                )
                if not forced then
                    log(
                        "QA_HOTKEY_TRIGGER started=false reason="
                            .. tostring(force_error)
                    )
                    return
                end
                schedule(
                    instance,
                    "qa-night-settle",
                    instance.config.qaNightSettleDelayMs,
                    function()
                        local authoritative_night, night_error =
                            is_night(pawn)
                        local current_hour,
                            current_day_type,
                            time_debug =
                            native_time_diagnostics(pawn)
                        log(string.format(
                            "QA_NIGHT_CONFIRMED isNight=%s nightError=%s hour=%s dayType=%s timeDebug=%s",
                            tostring(authoritative_night),
                            tostring(night_error),
                            current_hour,
                            current_day_type,
                            time_debug
                        ))
                        if authoritative_night ~= true then
                            log(
                                "QA_HOTKEY_TRIGGER started=false reason=authoritative-night-not-ready"
                            )
                            return
                        end
                        -- Entering the settlement legitimately starts its
                        -- normal 15-minute event before a tester can press
                        -- the hotkey.  Only in the explicit QA path, replace
                        -- that transient event with the five-second probe so
                        -- the native incident lifecycle can be accepted in a
                        -- bounded live-test window.
                        if instance.active then
                            destroy_attendance_attackers(
                                instance,
                                "qa-hotkey-reset"
                            )
                            remove_countdown_widget(
                                instance,
                                "qa-hotkey-reset"
                            )
                            instance.generation =
                                instance.generation + 1
                            instance.active = false
                            instance.nativeRedirectActive = false
                            instance.nativeRedirectArmed = false
                            instance.attackers = {}
                            instance.attackerNames = {}
                            instance.nativeIncidentNames = {}
                            log(
                                "QA_ACTIVE_EVENT_RESET saveWrites=0"
                            )
                        end
                        local started, reason = instance:force_start(
                            "qa-hotkey",
                            5
                        )
                        log(string.format(
                            "QA_HOTKEY_TRIGGER started=%s reason=%s countdownSeconds=%d directSpawn=false saveWrites=0 qaNightHour=%d",
                            tostring(started),
                            tostring(reason),
                            instance.currentCountdownSeconds,
                            instance.config.qaForceNightHour
                        ))
                    end
                )
            end
            if type(ExecuteInGameThread) == "function" then
                ExecuteInGameThread(apply)
            else
                apply()
            end
        end
        instance.callbacks.qaHotkey = callback
        RegisterKeyBind(
            Key.F8,
            { ModifierKey.CONTROL },
            callback
        )
        log(string.format(
            "QA_HOTKEY_READY key=Ctrl+F8 countdownSeconds=5 qaNightHour=%d qaNightSettleMs=%d directSpawn=false saveWrites=0",
            config.qaForceNightHour,
            config.qaNightSettleDelayMs
        ))
    end

    log(string.format(
        "READY settlement=%s region=%s fastTravel=%s nearestFaction=%s nativeGroup=%s executionMode=%s countdownSeconds=%d nightOnly=%s nativeLifecycle=true negotiatorLifecycle=true requiredHooks=%d duplicateFallbackLaunches=%s rageHatePerResident=%.1f rampagingFallback=%s rampagingLiveValidated=%s attendanceEnabled=%s attendanceLiveValidated=%s attendanceAggroRadius=%.1f backgroundApi=PWFT_SETTLEMENT_RAID_API_V1 customSpawner=false noTick=true saveWrites=0",
        config.settlement.displayNameZhHans,
        config.settlement.nativeRegionNameId,
        config.settlement.fastTravelPointId,
        config.nearestPalFactionId,
        config.nativeInvaderGroupName,
        config.executionMode,
        config.countdownSeconds,
        tostring(config.nightOnly),
        #NATIVE_REQUIRED_HOOK_PATHS,
        tostring(config.nativeFallbackLaunchEnabled == true),
        config.targetHate,
        tostring(config.rampagingPalFallback.enabled == true),
        tostring(
            config.rampagingPalFallback.liveValidated == true
        ),
        tostring(config.attendanceSimulation.enabled == true),
        tostring(
            config.attendanceSimulation.liveValidated == true
        ),
        config.attendanceSimulation.aggroRadius
    ))
    _G.PWFT_SETTLEMENT_RAID_API_V1 = {
        version = "1.0.0",
        status = function()
            return instance:status()
        end,
        backgroundHistory = function()
            return instance:background_history()
        end,
    }
    return instance
end

SettlementRaid._test = {
    make_native_name = make_native_name,
    spawn_native_attendance_wave = spawn_native_attendance_wave,
    destroy_attendance_attackers = destroy_attendance_attackers,
    arm_resident_defender = arm_resident_defender,
}

return SettlementRaid
