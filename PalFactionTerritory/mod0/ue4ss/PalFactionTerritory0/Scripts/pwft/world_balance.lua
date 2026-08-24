local WorldBalance = {}
local IslandMask = require("pwft.pal_faction_island_mask")

local PREFIX = "[PalFactionTerritory0][WorldBalance]"
local PREDATOR_SPAWNED_CHARACTER_TYPE = 8

local UEHelpers = nil
pcall(function()
    UEHelpers = require("UEHelpers")
end)

local function log(message)
    print(string.format("%s %s\n", PREFIX, tostring(message)))
end

local function safe_to_string(value)
    if value == nil then
        return "<nil>"
    end
    if type(value) == "string" or type(value) == "number" or type(value) == "boolean" then
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

local function safe_property(object, name)
    if object == nil then
        return nil
    end
    local ok, value = pcall(function()
        return object[name]
    end)
    return ok and value or nil
end

-- RegisterHook arguments are RemoteUnrealParam values, while objects returned
-- by properties, functions, FindAllOf, and the hook Context are already
-- UObject values. Calling :get() on an ordinary UObject makes UE4SS raise a
-- Lua userdata error; in UE4SS 1.0 the traceback path itself can crash. Keep
-- unwrapping at the one boundary where the value is known to be a hook param.
local function unwrap_hook_param(value)
    if value == nil then
        return nil
    end
    return value:get()
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

local function safe_full_name(object)
    if not is_valid_object(object) then
        return "<invalid>"
    end
    local ok, value = pcall(function()
        return object:GetFullName()
    end)
    return ok and safe_to_string(value) or "<unreadable>"
end

local function safe_call(object, method_name, ...)
    if not is_valid_object(object) then
        return false, nil
    end
    local arguments = table.pack(...)
    local ok, value = pcall(function()
        return object[method_name](
            object,
            table.unpack(arguments, 1, arguments.n)
        )
    end)
    return ok, value
end

local function safe_assign(object, property_name, value)
    if not is_valid_object(object) then
        return false
    end
    return pcall(function()
        object[property_name] = value
    end)
end

local function safe_struct_assign(value, property_name, assigned_value)
    if value == nil then
        return false
    end
    return pcall(function()
        value[property_name] = assigned_value
    end)
end

local function safe_number(value)
    if type(value) == "number" then
        return value
    end
    local ok, numeric = pcall(tonumber, value)
    if ok and numeric ~= nil then
        return numeric
    end
    return tonumber(safe_to_string(value))
end

local function fixed_point_raw(value)
    if value == nil then
        return nil
    end
    return safe_number(safe_property(value, "Value"))
end

local function guid_has_nonzero_parts(value)
    if value == nil then
        return nil
    end
    for _, field_name in ipairs({ "A", "B", "C", "D" }) do
        local part = safe_number(safe_property(value, field_name))
        if part == nil then
            return nil
        end
        if part ~= 0 then
            return true
        end
    end
    return false
end

local function save_owner_assigned(individual)
    local save_parameter = safe_property(individual, "SaveParameter")
    if save_parameter == nil then
        return nil
    end
    return guid_has_nonzero_parts(
        safe_property(save_parameter, "OwnerPlayerUId")
    )
end

local function spawned_character_type_number(value)
    local numeric = safe_number(value)
    if numeric ~= nil then
        return numeric
    end
    local text = safe_to_string(value)
    local names = {
        Common = 0,
        Rare = 1,
        FieldBoss = 2,
        RandomDungeonBoss = 3,
        ImprisonmentBoss = 4,
        TowerBoss = 5,
        RaidBoss = 6,
        RaidBossServant = 7,
        Predator = 8,
    }
    for name, number in pairs(names) do
        if string.find(text, name, 1, true) ~= nil then
            return number
        end
    end
    return nil
end

local function is_player_character(actor)
    local full_name = safe_full_name(actor)
    return string.find(full_name, "PalPlayerCharacter", 1, true) ~= nil
        or string.find(full_name, "BP_PlayerBase", 1, true) ~= nil
        or string.find(full_name, "BP_Player_", 1, true) ~= nil
        or string.find(full_name, "BP_PlayerMale", 1, true) ~= nil
        or string.find(full_name, "BP_PlayerFemale", 1, true) ~= nil
end

local function get_component(actor)
    local component = safe_property(actor, "CharacterParameterComponent")
    if is_valid_object(component) then
        return component
    end
    local ok, result = safe_call(actor, "GetCharacterParameterComponent")
    return ok and is_valid_object(result) and result or nil
end

local function get_individual_parameter(component)
    local individual = safe_property(component, "IndividualParameter")
    if is_valid_object(individual) then
        return individual
    end
    local ok, result = safe_call(component, "GetIndividualParameter")
    return ok and is_valid_object(result) and result or nil
end

local function get_actor_from_component(component, hinted_actor)
    if is_valid_object(hinted_actor) then
        return hinted_actor
    end
    local individual = get_individual_parameter(component)
    local ok, actor = safe_call(individual, "GetIndividualActor")
    return ok and is_valid_object(actor) and actor or nil
end

local function is_pal_actor(actor)
    local static_component = safe_property(actor, "StaticCharacterParameterComponent")
    if not is_valid_object(static_component) then
        return false, nil
    end
    return safe_property(static_component, "IsPal") == true, static_component
end

local method_is_true
local parse_group_type
local level_group_is_world_managed
local rage_group_is_world_enemy
local is_level_managed_pal
local is_standalone_enemy_pal

local function read_level_state(component, individual)
    local component_ok, component_effective = safe_call(component, "GetLevel")
    local individual_ok, individual_effective = safe_call(individual, "GetLevel")
    local override_ok, override = safe_call(individual, "GetOverrideLevel")
    local effective = component_ok and component_effective or individual_effective
    return {
        effective = (component_ok or individual_ok) and tonumber(effective) or nil,
        componentEffective = component_ok and tonumber(component_effective) or nil,
        individualEffective = individual_ok and tonumber(individual_effective) or nil,
        override = override_ok and tonumber(override) or nil,
        isOverride = method_is_true(individual, "IsOverrideLevel"),
    }
end

local function static_flag_is_true(component, property_name, method_name)
    if safe_property(component, property_name) == true then
        return true
    end
    return method_name ~= nil and method_is_true(component, method_name)
end

local function classify_level_target(actor, component, individual)
    local full_name = safe_full_name(actor)
    local lower_name = string.lower(full_name)
    if is_player_character(actor) then
        return "player-character", "player-character"
    end

    local is_pal, static_component = is_pal_actor(actor)
    local is_boss = is_valid_object(static_component) and (
        static_flag_is_true(static_component, "IsBoss_Database", "IsBossPal_Database")
        or static_flag_is_true(static_component, "IsTowerBoss_Database", "IsTowerBossPal")
        or static_flag_is_true(static_component, "IsRaidBoss_Database", "IsRaidBossPal")
        or static_flag_is_true(static_component, "IsPredatorBoss_Database", "IsPredatorBossPal")
    )
    if is_pal then
        local level_managed, reason = is_level_managed_pal(component, individual)
        if not level_managed then
            return "pal-owned-or-friendly", reason
        end
        return is_boss and "pal-boss" or "pal-world", "eligible"
    end

    if string.find(lower_name, "merchant", 1, true) ~= nil
        or string.find(lower_name, "trader", 1, true) ~= nil
        or string.find(lower_name, "salesperson", 1, true) ~= nil
        or string.find(lower_name, "shop", 1, true) ~= nil then
        return "npc-merchant", "eligible"
    end
    if is_boss then
        return "npc-boss", "eligible"
    end
    local group_type = parse_group_type(individual)
    if group_type == 5 or group_type == 6 then
        return "npc-hostile", "eligible"
    end
    return "npc-friendly", "eligible"
end

local function record_level_observation(instance, actor, category, outcome)
    local actor_name = safe_full_name(actor)
    local observation_key = actor_name .. "|" .. category .. "|" .. outcome
    if instance.levelObservations[observation_key] == true then
        return false
    end
    instance.levelObservations[observation_key] = true
    instance.levelCategoryCounts[category] =
        (instance.levelCategoryCounts[category] or 0) + 1
    instance.levelOutcomeCounts[outcome] =
        (instance.levelOutcomeCounts[outcome] or 0) + 1
    return true
end

local function log_level_detail(instance, message)
    if instance.levelDetailLogCount >= instance.config.maxDetailLogCount then
        return
    end
    instance.levelDetailLogCount = instance.levelDetailLogCount + 1
    log(message)
end

local function write_runtime_level_once(instance, actor, individual)
    local actor_name = safe_full_name(actor)
    if instance.levelWriteActors[actor_name] == true then
        return true, "already-written"
    end
    instance.levelWriteActors[actor_name] = true

    -- Build 24575825 exposes SaveParameter.Level as a reflected ByteProperty.
    -- SetOverrideLevel alone remains a flag after native initialization, while
    -- the exact eligible actor's SaveParameter is the value read by GetLevel.
    -- This event-scoped write never scans or touches player-owned parameters.
    local save_parameter = safe_property(individual, "SaveParameter")
    if save_parameter == nil then
        return false, "save-parameter-unavailable"
    end
    if not safe_struct_assign(
        save_parameter,
        "Level",
        instance.config.targetLevel
    ) then
        return false, "save-parameter-level-write-failed"
    end
    instance.levelWriteCount = instance.levelWriteCount + 1
    return true, "save-parameter-level-written"
end

method_is_true = function(object, method_name)
    local ok, value = safe_call(object, method_name)
    return ok and value == true
end

parse_group_type = function(individual)
    local ok, value = safe_call(individual, "GetGroupType")
    if not ok then
        return nil
    end
    if type(value) == "number" then
        return value
    end
    local text = safe_to_string(value)
    local numeric = tonumber(text)
    if numeric ~= nil then
        return numeric
    end
    if string.find(text, "Undefined", 1, true) ~= nil then
        return 0
    end
    if string.find(text, "Neutral", 1, true) ~= nil then
        return 1
    end
    if string.find(text, "Organization", 1, true) ~= nil then
        return 2
    end
    if string.find(text, "IndependentGuild", 1, true) ~= nil then
        return 3
    end
    if string.find(text, "Guild", 1, true) ~= nil then
        return 4
    end
    if string.find(text, "ResidentEnemy", 1, true) ~= nil then
        return 5
    end
    if string.find(text, "RaidBoss", 1, true) ~= nil then
        return 6
    end
    return nil
end

level_group_is_world_managed = function(group_type)
    -- Native initialization reports ordinary wild Pals as Undefined (0)
    -- before their final group is assigned. B1 must accept that event while
    -- still protecting both guild-backed player Pal representations.
    return group_type == 0
        or group_type == 1
        or group_type == 2
        or group_type == 5
        or group_type == 6
end

is_level_managed_pal = function(component, individual)
    if method_is_true(component, "IsPlayersOtomo")
        or method_is_true(component, "IsOtomo")
        or method_is_true(component, "IsInactiveOtomo")
        or method_is_true(component, "IsAssignedToAnyWork") then
        return false, "owned-or-worker"
    end

    if is_valid_object(safe_property(component, "Trainer"))
        or is_valid_object(safe_property(component, "NPCSpawnedOtomoTrainer")) then
        return false, "trainer-owned"
    end

    local group_type = parse_group_type(individual)
    if level_group_is_world_managed(group_type) then
        return true, "world-managed-group:" .. tostring(group_type)
    end
    if group_type == 3 or group_type == 4 then
        return false, "player-guild-group:" .. tostring(group_type)
    end
    return false, "group-unavailable:" .. tostring(group_type)
end

is_standalone_enemy_pal = function(component, individual)
    if method_is_true(component, "IsPlayersOtomo")
        or method_is_true(component, "IsOtomo")
        or method_is_true(component, "IsInactiveOtomo")
        or method_is_true(component, "IsAssignedToAnyWork") then
        return false, "owned-or-worker"
    end

    if is_valid_object(safe_property(component, "Trainer"))
        or is_valid_object(safe_property(component, "NPCSpawnedOtomoTrainer")) then
        return false, "trainer-owned"
    end

    local group_type = parse_group_type(individual)
    return rage_group_is_world_enemy(
        group_type,
        save_owner_assigned(individual)
    )
end

rage_group_is_world_enemy = function(group_type, owner_assigned)
    if owner_assigned == true then
        return false, "save-owner-assigned"
    end

    -- Build 24575825 keeps ordinary wild Pals in Undefined (0), including
    -- well after native initialization. Only accept that group when the
    -- reflected save owner GUID is readable and empty. This protects caught
    -- Pals in display/storage states that are neither Otomo nor base workers.
    if group_type == 0 then
        if owner_assigned == false then
            return true, "world-ungrouped-owner-empty"
        end
        return false, "owner-state-unavailable"
    end

    -- Neutral, ResidentEnemy, and RaidBoss are exact world-enemy groups.
    if group_type == 1 or group_type == 5 or group_type == 6 then
        return true, "world-enemy-group:" .. tostring(group_type)
    end
    return false, "non-world-group:" .. tostring(group_type)
end

local function classify_actor_island(actor)
    local ok, location = safe_call(actor, "K2_GetActorLocation")
    if not ok or location == nil then
        return nil
    end
    local world_x = tonumber(safe_property(location, "X"))
    local world_y = tonumber(safe_property(location, "Y"))
    if world_x == nil or world_y == nil then
        return nil
    end
    return IslandMask.classify_world(world_x, world_y)
end

local function read_rage_state(actor, component, individual, static_component)
    local is_pal = false
    if not is_valid_object(static_component) then
        is_pal, static_component = is_pal_actor(actor)
    else
        is_pal = safe_property(static_component, "IsPal") == true
    end
    local spawn_ok, spawned_type = safe_call(
        static_component,
        "GetSpawnedCharacterType"
    )
    local uncapturable_ok, uncapturable = safe_call(
        individual,
        "IsUncapturable"
    )
    local max_hp_ok, max_hp = safe_call(component, "GetMaxHP")
    return {
        island = classify_actor_island(actor),
        groupType = parse_group_type(individual),
        ownerAssigned = save_owner_assigned(individual),
        isPal = is_pal,
        isPlayerCharacter = is_player_character(actor),
        isPredator = safe_property(component, "IsPredator") == true,
        hpRate = safe_number(safe_property(component, "AdditionalEnemyMaxHPRate")),
        damageRate = safe_number(safe_property(component, "AdditionalEnemyInflictDamageRate")),
        spawnedType = spawn_ok and spawned_character_type_number(spawned_type) or nil,
        uncapturable = uncapturable_ok and uncapturable == true,
        maxHpRaw = max_hp_ok and fixed_point_raw(max_hp) or nil,
    }
end

local function rage_state_is_verified(state, rage)
    local hp_rate = tonumber(state.hpRate)
    local damage_rate = tonumber(state.damageRate)
    return state.island ~= nil
        and state.isPal == true
        and state.isPredator == true
        and hp_rate ~= nil
        and math.abs(hp_rate - rage.hpMultiplier) < 0.001
        and damage_rate ~= nil
        and math.abs(damage_rate - rage.damageMultiplier) < 0.001
        and state.spawnedType == PREDATOR_SPAWNED_CHARACTER_TYPE
        and (
            rage.makeUncapturable ~= true
            or state.uncapturable == true
        )
end

local function record_rage_observation(instance, actor, outcome)
    local observation_key = safe_full_name(actor) .. "|" .. outcome
    if instance.rageObservations[observation_key] == true then
        return false
    end
    instance.rageObservations[observation_key] = true
    instance.rageOutcomeCounts[outcome] =
        (instance.rageOutcomeCounts[outcome] or 0) + 1
    return true
end

local function log_rage_detail(instance, message)
    if instance.rageDetailLogCount >= instance.config.maxDetailLogCount then
        return
    end
    instance.rageDetailLogCount = instance.rageDetailLogCount + 1
    log(message)
end

local function record_rage_exclusion(
    instance,
    actor,
    component,
    individual,
    static_component,
    reason
)
    local rage_audit = instance.config.palFactionRage.liveAudit
    if type(rage_audit) ~= "table" or rage_audit.enabled ~= true then
        return
    end
    local outcome = "excluded:" .. tostring(reason)
    if not record_rage_observation(instance, actor, outcome) then
        return
    end
    instance.rageExcludedCount = instance.rageExcludedCount + 1
    local state = read_rage_state(
        actor,
        component,
        individual,
        static_component
    )
    log_rage_detail(instance, string.format(
        "PAL_FACTION_RAGE_EXCLUDED actor=%s reason=%s isPal=%s player=%s group=%s ownerAssigned=%s island=%s predator=%s hpRate=%s damageRate=%s spawnedType=%s uncapturable=%s maxHpRaw=%s source=%s broadScan=false",
        safe_full_name(actor),
        tostring(reason),
        tostring(state.isPal),
        tostring(state.isPlayerCharacter),
        tostring(state.groupType),
        tostring(state.ownerAssigned),
        tostring(state.island),
        tostring(state.isPredator),
        tostring(state.hpRate),
        tostring(state.damageRate),
        tostring(state.spawnedType),
        tostring(state.uncapturable),
        tostring(state.maxHpRaw),
        tostring(instance.lastApplySource)
    ))
end

local function record_rage_failure(instance, actor, state, reason)
    local outcome = "failed:" .. tostring(reason)
    if not record_rage_observation(instance, actor, outcome) then
        return
    end
    instance.rageFailureCount = instance.rageFailureCount + 1
    log_rage_detail(instance, string.format(
        "PAL_FACTION_RAGE_FAILED actor=%s reason=%s group=%s island=%s predator=%s hpRate=%s damageRate=%s spawnedType=%s uncapturable=%s maxHpRaw=%s source=%s broadScan=false",
        safe_full_name(actor),
        tostring(reason),
        tostring(state.groupType),
        tostring(state.island),
        tostring(state.isPredator),
        tostring(state.hpRate),
        tostring(state.damageRate),
        tostring(state.spawnedType),
        tostring(state.uncapturable),
        tostring(state.maxHpRaw),
        tostring(instance.lastApplySource)
    ))
end

local function apply_level(instance, actor, component, individual)
    if instance.config.levelOverride.enabled ~= true then
        return false, "disabled"
    end
    if not is_valid_object(individual) then
        return false, "individual-unavailable"
    end

    local category, eligibility =
        classify_level_target(actor, component, individual)
    if eligibility ~= "eligible" then
        local level = read_level_state(component, individual)
        if record_level_observation(
            instance,
            actor,
            category,
            "excluded:" .. eligibility
        ) then
            log_level_detail(instance, string.format(
                "LEVEL_OVERRIDE_EXCLUDED actor=%s category=%s reason=%s effective=%s componentEffective=%s individualEffective=%s override=%s source=%s",
                safe_full_name(actor),
                category,
                eligibility,
                tostring(level.effective),
                tostring(level.componentEffective),
                tostring(level.individualEffective),
                tostring(level.override),
                tostring(instance.lastApplySource)
            ))
        end
        return false, eligibility
    end

    local already_override = method_is_true(individual, "IsOverrideLevel")
    local level_ok, current_override = safe_call(individual, "GetOverrideLevel")
    if already_override and level_ok and tonumber(current_override) == instance.config.targetLevel then
        local level = read_level_state(component, individual)
        if level.effective ~= instance.config.targetLevel
            and instance.lastApplySource == "native-initialize-post" then
            local write_ok, write_reason =
                write_runtime_level_once(instance, actor, individual)
            level = read_level_state(component, individual)
            log_level_detail(instance, string.format(
                "LEVEL_OVERRIDE_NATIVE_LEVEL_WRITE actor=%s category=%s written=%s reason=%s componentEffective=%s individualEffective=%s override=%s source=%s count=%d",
                safe_full_name(actor),
                category,
                tostring(write_ok == true),
                tostring(write_reason),
                tostring(level.componentEffective),
                tostring(level.individualEffective),
                tostring(level.override),
                tostring(instance.lastApplySource),
                instance.levelWriteCount
            ))
        end
        local verified = level.effective == instance.config.targetLevel
        local outcome = verified and "verified" or "override-only"
        if record_level_observation(instance, actor, category, outcome) then
            if verified then
                instance.levelVerifiedCount = instance.levelVerifiedCount + 1
            end
            local marker = verified
                and "LEVEL_OVERRIDE_VERIFIED"
                or "LEVEL_OVERRIDE_READBACK_PENDING"
            log_level_detail(instance, string.format(
                "%s actor=%s category=%s target=%d effective=%s componentEffective=%s individualEffective=%s override=%s source=%s",
                marker,
                safe_full_name(actor),
                category,
                instance.config.targetLevel,
                tostring(level.effective),
                tostring(level.componentEffective),
                tostring(level.individualEffective),
                tostring(level.override),
                tostring(instance.lastApplySource)
            ))
        end
        return true, "already-applied"
    end

    local before = read_level_state(component, individual)
    local override_ok = safe_call(
        individual,
        "SetOverrideLevel",
        instance.config.targetLevel
    )
    local write_ok = true
    local write_reason = "effective-level-already-target"
    if before.effective ~= instance.config.targetLevel then
        write_ok, write_reason =
            write_runtime_level_once(instance, actor, individual)
    end
    if override_ok and write_ok then
        instance.levelAppliedCount = instance.levelAppliedCount + 1
        if record_level_observation(instance, actor, category, "applied") then
            local after = read_level_state(component, individual)
            log_level_detail(instance, string.format(
                "LEVEL_OVERRIDE_APPLIED actor=%s category=%s target=%d beforeEffective=%s beforeComponentEffective=%s beforeIndividualEffective=%s beforeOverride=%s afterEffective=%s afterComponentEffective=%s afterIndividualEffective=%s afterOverride=%s nativeLevelWrite=%s writeReason=%s source=%s count=%d",
                safe_full_name(actor),
                category,
                instance.config.targetLevel,
                tostring(before.effective),
                tostring(before.componentEffective),
                tostring(before.individualEffective),
                tostring(before.override),
                tostring(after.effective),
                tostring(after.componentEffective),
                tostring(after.individualEffective),
                tostring(after.override),
                tostring(write_ok == true),
                tostring(write_reason),
                tostring(instance.lastApplySource or "native-initialize"),
                instance.levelAppliedCount
            ))
        end
        return true, "applied"
    end
    if not override_ok then
        return false, "SetOverrideLevel-failed"
    end
    return false, write_reason
end

local function apply_pal_faction_rage(instance, actor, component, individual)
    local rage = instance.config.palFactionRage
    if rage.enabled ~= true then
        return false, "disabled"
    end

    local is_pal, static_component = is_pal_actor(actor)
    if not is_pal then
        record_rage_exclusion(
            instance,
            actor,
            component,
            individual,
            static_component,
            "not-pal"
        )
        return false, "not-pal"
    end

    local standalone, standalone_reason = is_standalone_enemy_pal(component, individual)
    if not standalone then
        record_rage_exclusion(
            instance,
            actor,
            component,
            individual,
            static_component,
            standalone_reason
        )
        return false, standalone_reason
    end

    local island_id = classify_actor_island(actor)
    if island_id == nil then
        record_rage_exclusion(
            instance,
            actor,
            component,
            individual,
            static_component,
            "outside-pal-faction-island"
        )
        return false, "outside-pal-faction-island"
    end

    local actor_name = safe_full_name(actor)
    local first_application = instance.rageActors[actor_name] ~= island_id
    local before = read_rage_state(
        actor,
        component,
        individual,
        static_component
    )

    local predator_flag_ok = safe_assign(component, "IsPredator", true)
    local hp_rate_ok = safe_assign(
        component,
        "AdditionalEnemyMaxHPRate",
        rage.hpMultiplier
    )
    local damage_rate_ok = safe_assign(
        component,
        "AdditionalEnemyInflictDamageRate",
        rage.damageMultiplier
    )
    local spawn_type_ok = safe_call(
        static_component,
        "SetSpawnedCharacterType",
        PREDATOR_SPAWNED_CHARACTER_TYPE
    )
    local uncapturable_ok = true
    if rage.makeUncapturable == true then
        uncapturable_ok = safe_call(individual, "SetUncapturable", true)
    end

    if not predator_flag_ok or not hp_rate_ok or not damage_rate_ok
        or not spawn_type_ok or not uncapturable_ok then
        local failed_state = read_rage_state(
            actor,
            component,
            individual,
            static_component
        )
        record_rage_failure(
            instance,
            actor,
            failed_state,
            "native-predator-parameter-failed"
        )
        return false, "native-predator-parameter-failed"
    end

    local after = read_rage_state(
        actor,
        component,
        individual,
        static_component
    )
    if not rage_state_is_verified(after, rage) then
        record_rage_failure(
            instance,
            actor,
            after,
            "native-predator-readback-failed"
        )
        return false, "native-predator-readback-failed"
    end

    instance.rageActors[actor_name] = island_id
    if first_application then
        instance.rageAppliedCount = instance.rageAppliedCount + 1
        instance.rageVerifiedCount = instance.rageVerifiedCount + 1
        record_rage_observation(instance, actor, "verified:" .. island_id)
        log_rage_detail(instance, string.format(
            "PAL_FACTION_RAGE_VERIFIED island=%s actor=%s group=%s ownerAssigned=%s level=%d beforePredator=%s beforeHpRate=%s beforeDamageRate=%s beforeSpawnedType=%s beforeUncapturable=%s afterPredator=%s afterHpRate=%s afterDamageRate=%s afterSpawnedType=%s afterUncapturable=%s beforeMaxHpRaw=%s afterMaxHpRaw=%s source=%s broadScan=false",
            island_id,
            actor_name,
            tostring(after.groupType),
            tostring(after.ownerAssigned),
            instance.config.targetLevel,
            tostring(before.isPredator),
            tostring(before.hpRate),
            tostring(before.damageRate),
            tostring(before.spawnedType),
            tostring(before.uncapturable),
            tostring(after.isPredator),
            tostring(after.hpRate),
            tostring(after.damageRate),
            tostring(after.spawnedType),
            tostring(after.uncapturable),
            tostring(before.maxHpRaw),
            tostring(after.maxHpRaw),
            tostring(instance.lastApplySource)
        ))
    end
    return true, island_id
end

local function apply_actor(instance, actor, hinted_component, source)
    if not is_valid_object(actor) then
        return false
    end
    local component = hinted_component
    if not is_valid_object(component) then
        component = get_component(actor)
    end
    if not is_valid_object(component) then
        return false
    end
    local individual = get_individual_parameter(component)
    if not is_valid_object(individual) then
        return false
    end

    instance.lastApplySource = source
    apply_level(instance, actor, component, individual)
    apply_pal_faction_rage(instance, actor, component, individual)
    return true
end

local function sorted_count_text(counts)
    local keys = {}
    for key in pairs(counts) do
        table.insert(keys, key)
    end
    table.sort(keys)
    local values = {}
    for _, key in ipairs(keys) do
        table.insert(values, key .. ":" .. tostring(counts[key]))
    end
    return table.concat(values, ",")
end

local function emit_level_audit_summary(instance, source)
    log(string.format(
        "LEVEL_AUDIT_SUMMARY source=%s applied=%d verified=%d categories=%s outcomes=%s broadScan=false rageApplied=%d",
        tostring(source),
        instance.levelAppliedCount,
        instance.levelVerifiedCount,
        sorted_count_text(instance.levelCategoryCounts),
        sorted_count_text(instance.levelOutcomeCounts),
        instance.rageAppliedCount
    ))
end

local function emit_rage_audit_summary(instance, source)
    log(string.format(
        "RAGE_AUDIT_SUMMARY source=%s applied=%d verified=%d excluded=%d failed=%d outcomes=%s probeSamples=%d broadScan=false levelEnabled=%s loadedActorReconcile=false",
        tostring(source),
        instance.rageAppliedCount,
        instance.rageVerifiedCount,
        instance.rageExcludedCount,
        instance.rageFailureCount,
        sorted_count_text(instance.rageOutcomeCounts),
        #instance.rageProbeSamples,
        tostring(instance.config.levelOverride.enabled == true)
    ))
end

local function make_name(value)
    if type(FName) == "function" then
        local ok, name = pcall(FName, value)
        if ok and name ~= nil then
            return name
        end
    end
    if type(StaticFindObject) == "function" then
        local ok, library = pcall(
            StaticFindObject,
            "/Script/Engine.Default__KismetStringLibrary"
        )
        if ok and is_valid_object(library) then
            local converted, name = safe_call(library, "Conv_StringToName", value)
            if converted then
                return name
            end
        end
    end
    return value
end

local function resolve_local_controller()
    if UEHelpers ~= nil
        and type(UEHelpers.GetPlayerController) == "function" then
        local ok, controller = pcall(function()
            return UEHelpers.GetPlayerController()
        end)
        if ok and is_valid_object(controller) then
            return controller
        end
    end
    if type(FindFirstOf) == "function" then
        for _, class_name in ipairs({
            "PalPlayerController",
            "PalPlayerController_C",
        }) do
            local ok, controller = pcall(FindFirstOf, class_name)
            if ok and is_valid_object(controller) then
                return controller
            end
        end
    end
    return nil
end

local function spawn_boss_probe(instance)
    local probe = instance.config.liveAudit.bossProbe
    local controller = resolve_local_controller()
    if not is_valid_object(controller) then
        log("LEVEL_BOSS_PROBE_FAILED reason=local-player-controller-unavailable")
        return
    end
    local player = safe_property(controller, "Pawn")
    if not is_valid_object(player) then
        player = safe_property(controller, "AcknowledgedPawn")
    end
    if not is_valid_object(player) then
        local player_ok
        player_ok, player = safe_call(controller, "K2_GetPawn")
        if not player_ok then
            player = nil
        end
    end
    if not is_valid_object(player) then
        log("LEVEL_BOSS_PROBE_FAILED reason=local-player-character-unavailable")
        return
    end
    local utility = nil
    if type(StaticFindObject) == "function" then
        local ok, value = pcall(
            StaticFindObject,
            "/Script/Pal.Default__PalUtility"
        )
        if ok and is_valid_object(value) then
            utility = value
        end
    end
    local manager_ok, manager = safe_call(utility, "GetNPCManager", controller)
    if not manager_ok or not is_valid_object(manager) then
        log("LEVEL_BOSS_PROBE_FAILED reason=npc-manager-unavailable")
        return
    end
    local controller_class = safe_property(manager, "NPCAIControllerBaseClass")
    local location_ok, location = safe_call(player, "K2_GetActorLocation")
    if not is_valid_object(controller_class) or not location_ok or location == nil then
        log("LEVEL_BOSS_PROBE_FAILED reason=spawn-context-unavailable")
        return
    end
    local offset = probe.spawnOffset
    local spawn_location = {
        X = (tonumber(safe_property(location, "X")) or 0) + offset.X,
        Y = (tonumber(safe_property(location, "Y")) or 0) + offset.Y,
        Z = (tonumber(safe_property(location, "Z")) or 0) + offset.Z,
    }
    local handle_ok, handle = safe_call(
        manager,
        "SpawnNPCForServer",
        {
            ControllerClass = controller_class,
            CharacterID = make_name(probe.characterId),
            Level = probe.spawnLevel,
            Location = spawn_location,
            Yaw = 0,
            Squad = nil,
        },
        nil
    )
    if not handle_ok or not is_valid_object(handle) then
        log("LEVEL_BOSS_PROBE_FAILED reason=native-spawn-not-accepted")
        return
    end
    instance.bossProbeHandle = handle
    log(string.format(
        "LEVEL_BOSS_PROBE_SPAWN_ACCEPTED character=%s requestedLevel=%d targetLevel=%d saveWrites=false",
        probe.characterId,
        probe.spawnLevel,
        instance.config.targetLevel
    ))
    local observe_callback = function()
        local actor_ok, actor = safe_call(handle, "TryGetIndividualActor")
        if not actor_ok or not is_valid_object(actor) then
            log("LEVEL_BOSS_PROBE_OBSERVE_PENDING actor=unavailable")
            return
        end
        local component = get_component(actor)
        local individual = get_individual_parameter(component)
        local level = read_level_state(component, individual)
        local category = classify_level_target(actor, component, individual)
        log(string.format(
            "LEVEL_BOSS_PROBE_OBSERVED actor=%s category=%s effective=%s componentEffective=%s individualEffective=%s override=%s target=%d",
            safe_full_name(actor),
            tostring(category),
            tostring(level.effective),
            tostring(level.componentEffective),
            tostring(level.individualEffective),
            tostring(level.override),
            instance.config.targetLevel
        ))
    end
    table.insert(instance.callbacks, observe_callback)
    ExecuteWithDelay(1000, observe_callback)

    local cleanup_callback = function()
        local actor_ok, actor = safe_call(handle, "TryGetIndividualActor")
        local destroyed = false
        if actor_ok and is_valid_object(actor) then
            destroyed = safe_call(actor, "K2_DestroyActor")
        end
        instance.bossProbeHandle = nil
        log(string.format(
            "LEVEL_BOSS_PROBE_CLEANUP destroyed=%s saveWrites=false",
            tostring(destroyed == true)
        ))
    end
    table.insert(instance.callbacks, cleanup_callback)
    ExecuteWithDelay(probe.cleanupDelayMs, cleanup_callback)
end

local function rage_probe_control_is_unchanged(state)
    local hp_rate = tonumber(state.hpRate)
    local damage_rate = tonumber(state.damageRate)
    return state.island == nil
        and state.isPal == true
        and state.isPredator ~= true
        and hp_rate ~= nil
        and math.abs(hp_rate - 1.0) < 0.001
        and damage_rate ~= nil
        and math.abs(damage_rate - 1.0) < 0.001
        and state.spawnedType == 0
        and state.uncapturable ~= true
end

local function emit_rage_probe_comparison(instance)
    local control = nil
    local target = nil
    for _, sample in ipairs(instance.rageProbeSamples) do
        if sample.targetIsland == true and target == nil then
            target = sample
        elseif sample.targetIsland == false and control == nil then
            control = sample
        end
    end
    if control == nil or target == nil then
        return
    end
    log(string.format(
        "PAL_FACTION_RAGE_PROBE_COMPARISON character=%s level=%d controlPass=%s targetPass=%s controlIsland=%s targetIsland=%s controlPredator=%s targetPredator=%s controlHpRate=%s targetHpRate=%s controlDamageRate=%s targetDamageRate=%s controlSpawnedType=%s targetSpawnedType=%s controlUncapturable=%s targetUncapturable=%s controlMaxHpRaw=%s targetMaxHpRaw=%s broadScan=false saveWrites=false",
        tostring(control.characterId),
        tonumber(control.spawnLevel) or 0,
        tostring(control.passed),
        tostring(target.passed),
        tostring(control.state.island),
        tostring(target.state.island),
        tostring(control.state.isPredator),
        tostring(target.state.isPredator),
        tostring(control.state.hpRate),
        tostring(target.state.hpRate),
        tostring(control.state.damageRate),
        tostring(target.state.damageRate),
        tostring(control.state.spawnedType),
        tostring(target.state.spawnedType),
        tostring(control.state.uncapturable),
        tostring(target.state.uncapturable),
        tostring(control.state.maxHpRaw),
        tostring(target.state.maxHpRaw)
    ))
end

local function spawn_rage_probe(instance)
    local rage = instance.config.palFactionRage
    local audit = rage.liveAudit
    local probe = audit.probe
    if is_valid_object(instance.rageProbeHandle) then
        log("PAL_FACTION_RAGE_PROBE_SKIPPED reason=probe-already-active")
        return
    end

    local controller = resolve_local_controller()
    if not is_valid_object(controller) then
        log("PAL_FACTION_RAGE_PROBE_FAILED reason=local-player-controller-unavailable")
        return
    end
    local player = safe_property(controller, "Pawn")
    if not is_valid_object(player) then
        player = safe_property(controller, "AcknowledgedPawn")
    end
    if not is_valid_object(player) then
        local player_ok
        player_ok, player = safe_call(controller, "K2_GetPawn")
        if not player_ok then
            player = nil
        end
    end
    if not is_valid_object(player) then
        log("PAL_FACTION_RAGE_PROBE_FAILED reason=local-player-character-unavailable")
        return
    end

    local utility = nil
    if type(StaticFindObject) == "function" then
        local ok, value = pcall(
            StaticFindObject,
            "/Script/Pal.Default__PalUtility"
        )
        if ok and is_valid_object(value) then
            utility = value
        end
    end
    local manager_ok, manager = safe_call(utility, "GetNPCManager", controller)
    if not manager_ok or not is_valid_object(manager) then
        log("PAL_FACTION_RAGE_PROBE_FAILED reason=npc-manager-unavailable")
        return
    end
    local controller_class = safe_property(manager, "NPCAIControllerBaseClass")
    local location_ok, location = safe_call(player, "K2_GetActorLocation")
    if not is_valid_object(controller_class) or not location_ok or location == nil then
        log("PAL_FACTION_RAGE_PROBE_FAILED reason=spawn-context-unavailable")
        return
    end
    local offset = probe.spawnOffset
    local spawn_location = {
        X = (tonumber(safe_property(location, "X")) or 0) + offset.X,
        Y = (tonumber(safe_property(location, "Y")) or 0) + offset.Y,
        Z = (tonumber(safe_property(location, "Z")) or 0) + offset.Z,
    }
    local expected_island = IslandMask.classify_world(
        spawn_location.X,
        spawn_location.Y
    )
    local handle_ok, handle = safe_call(
        manager,
        "SpawnNPCForServer",
        {
            ControllerClass = controller_class,
            CharacterID = make_name(probe.characterId),
            Level = probe.spawnLevel,
            Location = spawn_location,
            Yaw = 0,
            Squad = nil,
        },
        nil
    )
    if not handle_ok or not is_valid_object(handle) then
        log("PAL_FACTION_RAGE_PROBE_FAILED reason=native-spawn-not-accepted")
        return
    end
    instance.rageProbeHandle = handle
    log(string.format(
        "PAL_FACTION_RAGE_PROBE_SPAWN_ACCEPTED character=%s requestedLevel=%d expectedIsland=%s targetExpected=%s levelOverride=%s loadedActorReconcile=false broadScan=false saveWrites=false",
        probe.characterId,
        probe.spawnLevel,
        tostring(expected_island),
        tostring(expected_island ~= nil),
        tostring(instance.config.levelOverride.enabled == true)
    ))

    for index, delay_ms in ipairs(probe.observeDelaysMs) do
        local observe_callback = function()
            local actor_ok, actor = safe_call(handle, "TryGetIndividualActor")
            if not actor_ok or not is_valid_object(actor) then
                log(string.format(
                    "PAL_FACTION_RAGE_PROBE_OBSERVE_PENDING delayIndex=%d actor=unavailable",
                    index
                ))
                return
            end
            local component = get_component(actor)
            local individual = get_individual_parameter(component)
            apply_actor(instance, actor, component, "rage-probe-observe")
            local state = read_rage_state(actor, component, individual, nil)
            local target_island = state.island ~= nil
            local passed = target_island
                    and rage_state_is_verified(state, rage)
                or rage_probe_control_is_unchanged(state)
            log(string.format(
                "PAL_FACTION_RAGE_PROBE_OBSERVED delayIndex=%d actor=%s character=%s level=%d targetIsland=%s island=%s group=%s ownerAssigned=%s passed=%s predator=%s hpRate=%s damageRate=%s spawnedType=%s uncapturable=%s maxHpRaw=%s broadScan=false saveWrites=false",
                index,
                safe_full_name(actor),
                probe.characterId,
                probe.spawnLevel,
                tostring(target_island),
                tostring(state.island),
                tostring(state.groupType),
                tostring(state.ownerAssigned),
                tostring(passed),
                tostring(state.isPredator),
                tostring(state.hpRate),
                tostring(state.damageRate),
                tostring(state.spawnedType),
                tostring(state.uncapturable),
                tostring(state.maxHpRaw)
            ))
            local actor_name = safe_full_name(actor)
            local is_last = index == #probe.observeDelaysMs
            if instance.rageProbeObservedActors[actor_name] ~= true
                and (passed or is_last) then
                instance.rageProbeObservedActors[actor_name] = true
                table.insert(instance.rageProbeSamples, {
                    characterId = probe.characterId,
                    spawnLevel = probe.spawnLevel,
                    targetIsland = target_island,
                    passed = passed,
                    state = state,
                })
                emit_rage_probe_comparison(instance)
            end
        end
        table.insert(instance.callbacks, observe_callback)
        ExecuteWithDelay(delay_ms, observe_callback)
    end

    local cleanup_callback = function()
        local actor_ok, actor = safe_call(handle, "TryGetIndividualActor")
        local destroyed = false
        if actor_ok and is_valid_object(actor) then
            destroyed = safe_call(actor, "K2_DestroyActor")
        end
        instance.rageProbeHandle = nil
        log(string.format(
            "PAL_FACTION_RAGE_PROBE_CLEANUP destroyed=%s broadScan=false saveWrites=false",
            tostring(destroyed == true)
        ))
    end
    table.insert(instance.callbacks, cleanup_callback)
    ExecuteWithDelay(probe.cleanupDelayMs, cleanup_callback)
end

local function schedule_actor_reapply(instance, actor, component, delay_ms, source)
    if type(ExecuteWithDelay) ~= "function" then
        return
    end
    local callback = function()
        if type(ExecuteInGameThread) == "function" then
            ExecuteInGameThread(function()
                apply_actor(instance, actor, component, source)
            end)
        else
            apply_actor(instance, actor, component, source)
        end
    end
    table.insert(instance.callbacks, callback)
    ExecuteWithDelay(delay_ms, callback)
end

local function register_hook(instance, path, callback)
    if type(RegisterHook) ~= "function" then
        log("HOOK_UNAVAILABLE path=" .. path)
        return false
    end
    table.insert(instance.callbacks, callback)
    local ok, first_id, second_id = pcall(function()
        return RegisterHook(path, callback)
    end)
    if not ok then
        log(string.format("HOOK_FAILED path=%s error=%s", path, tostring(first_id)))
        return false
    end
    table.insert(instance.hookIds, first_id)
    table.insert(instance.hookIds, second_id)
    log("HOOK_READY path=" .. path)
    return true
end

local function reconcile_loaded_characters(instance, source)
    if type(FindAllOf) ~= "function" then
        log("RECONCILE_UNAVAILABLE source=" .. source .. " reason=FindAllOf-missing")
        return
    end

    local seen = {}
    local scanned = 0
    local applied = 0
    for _, class_name in ipairs({ "PalCharacter", "PalNPC", "PalMonsterCharacter" }) do
        local ok, actors = pcall(function()
            return FindAllOf(class_name)
        end)
        if ok and actors ~= nil then
            for _, actor in pairs(actors) do
                local actor_name = safe_full_name(actor)
                if seen[actor_name] ~= true then
                    seen[actor_name] = true
                    scanned = scanned + 1
                    if apply_actor(instance, actor, nil, source) then
                        applied = applied + 1
                    end
                end
            end
        end
    end
    log(string.format(
        "RECONCILE_COMPLETE source=%s scanned=%d applied=%d totalLevel=%d totalRage=%d",
        source,
        scanned,
        applied,
        instance.levelAppliedCount,
        instance.rageAppliedCount
    ))
end

local function schedule_reconcile(instance, delay_ms, source)
    if type(ExecuteWithDelay) ~= "function" then
        return
    end
    local callback = function()
        if type(ExecuteInGameThread) == "function" then
            ExecuteInGameThread(function()
                reconcile_loaded_characters(instance, source)
            end)
        else
            reconcile_loaded_characters(instance, source)
        end
    end
    table.insert(instance.callbacks, callback)
    ExecuteWithDelay(delay_ms, callback)
end

function WorldBalance.has_enabled_feature(config)
    return type(config) == "table"
        and config.enabled == true
        and (
            type(config.levelOverride) == "table"
                and config.levelOverride.enabled == true
            or type(config.palFactionRage) == "table"
                and config.palFactionRage.enabled == true
        )
end

function WorldBalance.start(config)
    assert(type(config) == "table", "world balance configuration is required")
    assert(config.enabled == true, "world balance must be explicitly enabled")
    assert(config.targetLevel == 80, "world balance target level must be 80")
    assert(type(config.levelOverride) == "table", "level-override configuration is required")
    assert(type(config.palFactionRage) == "table", "Pal-faction rage configuration is required")
    assert(type(config.loadedActorReconcile) == "table", "loaded-actor reconciliation configuration is required")
    assert(type(config.liveAudit) == "table", "world-balance live-audit configuration is required")
    assert(type(config.liveAudit.enabled) == "boolean", "world-balance live-audit gate is required")
    assert(type(config.palFactionRage.liveAudit) == "table", "Pal-faction rage live-audit configuration is required")
    assert(type(config.palFactionRage.liveAudit.enabled) == "boolean", "Pal-faction rage live-audit gate is required")
    assert(config.palFactionRage.hpMultiplier == 2.0, "Pal-faction HP multiplier must be 2.0")
    assert(config.palFactionRage.damageMultiplier == 2.0, "Pal-faction damage multiplier must be 2.0")
    assert(
        WorldBalance.has_enabled_feature(config),
        "at least one world-balance capability must be explicitly enabled"
    )

    local instance = {
        config = config,
        callbacks = {},
        hookIds = {},
        rageActors = {},
        rageObservations = {},
        rageOutcomeCounts = {},
        rageProbeSamples = {},
        rageProbeObservedActors = {},
        levelObservations = {},
        levelCategoryCounts = {},
        levelOutcomeCounts = {},
        levelWriteActors = {},
        levelAppliedCount = 0,
        levelVerifiedCount = 0,
        levelWriteCount = 0,
        levelDetailLogCount = 0,
        rageAppliedCount = 0,
        rageVerifiedCount = 0,
        rageExcludedCount = 0,
        rageFailureCount = 0,
        rageDetailLogCount = 0,
        lastApplySource = "startup",
    }

    local initialization_callback = function(context, owner_character)
        local component = context
        owner_character = unwrap_hook_param(owner_character)
        local actor = get_actor_from_component(component, owner_character)
        apply_actor(instance, actor, component, "native-initialize")
        -- The native initializer may apply world difficulty values after the
        -- hook entry. One bounded follow-up reapplies the final requested
        -- rates after that initializer has returned; this is not a Tick poll.
        schedule_actor_reapply(
            instance,
            actor,
            component,
            config.initializationReapplyDelayMs,
            "native-initialize-post"
        )
    end
    register_hook(
        instance,
        "/Script/Pal.PalCharacterParameterComponent:OnInitialize_AfterSetIndividualParameter",
        initialization_callback
    )

    local initialized_character_callback = function(context, owner_character)
        local component = context
        owner_character = unwrap_hook_param(owner_character)
        local actor = get_actor_from_component(component, owner_character)
        apply_actor(instance, actor, component, "native-character-ready")
    end
    register_hook(
        instance,
        "/Script/Pal.PalCharacterParameterComponent:OnInitializedCharacter",
        initialized_character_callback
    )

    local reconcile = config.loadedActorReconcile
    if reconcile.enabled == true then
        schedule_reconcile(instance, reconcile.delaysMs[1], "startup-pass-1")
        schedule_reconcile(instance, reconcile.delaysMs[2], "startup-pass-2")
    end

    if reconcile.enabled == true
        and type(RegisterLoadMapPostHook) == "function" then
        local load_map_callback = function()
            schedule_reconcile(instance, reconcile.delaysMs[1], "world-load-pass-1")
            schedule_reconcile(instance, reconcile.delaysMs[2], "world-load-pass-2")
        end
        instance.loadMapCallback = load_map_callback
        table.insert(instance.callbacks, load_map_callback)
        RegisterLoadMapPostHook(load_map_callback)
    end

    local live_audit = config.liveAudit
    if live_audit.enabled == true then
        local schedule_audit_summaries = function(source)
            for index, delay_ms in ipairs(live_audit.summaryDelaysMs) do
                local summary_callback = function()
                    emit_level_audit_summary(
                        instance,
                        source .. "-delay-" .. tostring(index)
                    )
                    emit_rage_audit_summary(
                        instance,
                        source .. "-delay-" .. tostring(index)
                    )
                end
                table.insert(instance.callbacks, summary_callback)
                ExecuteWithDelay(delay_ms, summary_callback)
            end
        end
        schedule_audit_summaries("startup")
        if type(RegisterLoadMapPostHook) == "function" then
            local audit_load_map_callback = function()
                log("LEVEL_AUDIT_LOAD_MAP_READY broadScan=false")
                schedule_audit_summaries("world-load")
            end
            instance.auditLoadMapCallback = audit_load_map_callback
            table.insert(instance.callbacks, audit_load_map_callback)
            RegisterLoadMapPostHook(audit_load_map_callback)
        end
        local boss_probe = live_audit.bossProbe
        if boss_probe.enabled == true
            and type(RegisterKeyBind) == "function"
            and type(Key) == "table"
            and Key[boss_probe.key] ~= nil then
            local boss_callback = function()
                if type(ExecuteInGameThread) == "function" then
                    ExecuteInGameThread(function()
                        spawn_boss_probe(instance)
                    end)
                else
                    spawn_boss_probe(instance)
                end
            end
            table.insert(instance.callbacks, boss_callback)
            RegisterKeyBind(Key[boss_probe.key], boss_callback)
            log(string.format(
                "LEVEL_BOSS_PROBE_READY key=%s character=%s requestedLevel=%d cleanupMs=%d qaOnly=true saveWrites=false",
                boss_probe.key,
                boss_probe.characterId,
                boss_probe.spawnLevel,
                boss_probe.cleanupDelayMs
            ))
        end
    end

    local rage_live_audit = config.palFactionRage.liveAudit
    local rage_probe = rage_live_audit.probe
    if rage_live_audit.enabled == true
        and rage_probe.enabled == true
        and type(RegisterKeyBind) == "function"
        and type(Key) == "table"
        and Key[rage_probe.key] ~= nil then
        local rage_probe_callback = function()
            if type(ExecuteInGameThread) == "function" then
                ExecuteInGameThread(function()
                    spawn_rage_probe(instance)
                end)
            else
                spawn_rage_probe(instance)
            end
        end
        table.insert(instance.callbacks, rage_probe_callback)
        RegisterKeyBind(Key[rage_probe.key], rage_probe_callback)
        log(string.format(
            "PAL_FACTION_RAGE_PROBE_READY key=%s character=%s requestedLevel=%d cleanupMs=%d qaOnly=true broadScan=false saveWrites=false",
            rage_probe.key,
            rage_probe.characterId,
            rage_probe.spawnLevel,
            rage_probe.cleanupDelayMs
        ))
    end

    log(string.format(
        "READY targetLevel=%d levelEnabled=%s rageEnabled=%s loadedActorReconcile=%s liveAudit=%s rageAudit=%s palFactionIslands=%d predatorType=%d hpRate=%.2f damageRate=%.2f noTick=true",
        config.targetLevel,
        tostring(config.levelOverride.enabled == true),
        tostring(config.palFactionRage.enabled == true),
        tostring(reconcile.enabled == true),
        tostring(live_audit.enabled == true),
        tostring(rage_live_audit.enabled == true),
        #IslandMask.islands,
        PREDATOR_SPAWNED_CHARACTER_TYPE,
        config.palFactionRage.hpMultiplier,
        config.palFactionRage.damageMultiplier
    ))
    return instance
end

WorldBalance.classify_world = IslandMask.classify_world
WorldBalance.islandMask = IslandMask
WorldBalance.level_group_is_world_managed = level_group_is_world_managed
WorldBalance.guid_has_nonzero_parts = guid_has_nonzero_parts
WorldBalance.rage_group_is_world_enemy = rage_group_is_world_enemy
WorldBalance.rage_state_is_verified = rage_state_is_verified
WorldBalance.rage_probe_control_is_unchanged = rage_probe_control_is_unchanged

return WorldBalance
