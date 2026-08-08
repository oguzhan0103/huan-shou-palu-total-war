local WorldBalance = {}
local IslandMask = require("pwft.pal_faction_island_mask")

local PREFIX = "[PalFactionTerritory0][WorldBalance]"
local PREDATOR_SPAWNED_CHARACTER_TYPE = 8

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
    local arguments = { ... }
    local ok, value = pcall(function()
        return object[method_name](object, table.unpack(arguments))
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

local function method_is_true(object, method_name)
    local ok, value = safe_call(object, method_name)
    return ok and value == true
end

local function parse_group_type(individual)
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

local function is_standalone_enemy_pal(component, individual)
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

    -- Neutral, ResidentEnemy, and RaidBoss are world enemies. Undefined is
    -- also accepted during the short spawn-initialization window, but only
    -- after every ownership and work assignment check above has passed.
    local group_type = parse_group_type(individual)
    if group_type == nil or group_type == 0 or group_type == 1
        or group_type == 5 or group_type == 6 then
        return true, "world-enemy"
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

local function apply_level(instance, actor, component, individual)
    if instance.config.levelOverride.enabled ~= true then
        return false, "disabled"
    end
    if is_player_character(actor) then
        return false, "player-character"
    end
    if not is_valid_object(individual) then
        return false, "individual-unavailable"
    end

    local already_override = method_is_true(individual, "IsOverrideLevel")
    local level_ok, current_override = safe_call(individual, "GetOverrideLevel")
    if already_override and level_ok and tonumber(current_override) == instance.config.targetLevel then
        return true, "already-applied"
    end

    local ok = safe_call(individual, "SetOverrideLevel", instance.config.targetLevel)
    if ok then
        instance.levelAppliedCount = instance.levelAppliedCount + 1
        return true, "applied"
    end
    return false, "SetOverrideLevel-failed"
end

local function apply_pal_faction_rage(instance, actor, component, individual)
    local rage = instance.config.palFactionRage
    if rage.enabled ~= true then
        return false, "disabled"
    end

    local is_pal, static_component = is_pal_actor(actor)
    if not is_pal then
        return false, "not-pal"
    end

    local standalone, standalone_reason = is_standalone_enemy_pal(component, individual)
    if not standalone then
        return false, standalone_reason
    end

    local island_id = classify_actor_island(actor)
    if island_id == nil then
        return false, "outside-pal-faction-island"
    end

    local actor_name = safe_full_name(actor)
    local first_application = instance.rageActors[actor_name] ~= island_id

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
        return false, "native-predator-parameter-failed"
    end

    instance.rageActors[actor_name] = island_id
    if first_application then
        instance.rageAppliedCount = instance.rageAppliedCount + 1
        if instance.rageDetailLogCount < instance.config.maxDetailLogCount then
            instance.rageDetailLogCount = instance.rageDetailLogCount + 1
            log(string.format(
                "PAL_FACTION_RAGE_APPLIED island=%s actor=%s level=%d hpRate=%.2f damageRate=%.2f predator=true uncapturable=%s",
                island_id,
                actor_name,
                instance.config.targetLevel,
                rage.hpMultiplier,
                rage.damageMultiplier,
                tostring(rage.makeUncapturable == true)
            ))
        end
    end
    return true, island_id
end

local function apply_actor(instance, actor, hinted_component, source)
    if not is_valid_object(actor) then
        return false
    end
    if is_player_character(actor) then
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

    apply_level(instance, actor, component, individual)
    apply_pal_faction_rage(instance, actor, component, individual)
    instance.lastApplySource = source
    return true
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
        levelAppliedCount = 0,
        rageAppliedCount = 0,
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

    log(string.format(
        "READY targetLevel=%d levelEnabled=%s rageEnabled=%s loadedActorReconcile=%s palFactionIslands=%d predatorType=%d hpRate=%.2f damageRate=%.2f noTick=true",
        config.targetLevel,
        tostring(config.levelOverride.enabled == true),
        tostring(config.palFactionRage.enabled == true),
        tostring(reconcile.enabled == true),
        #IslandMask.islands,
        PREDATOR_SPAWNED_CHARACTER_TYPE,
        config.palFactionRage.hpMultiplier,
        config.palFactionRage.damageMultiplier
    ))
    return instance
end

WorldBalance.classify_world = IslandMask.classify_world
WorldBalance.islandMask = IslandMask

return WorldBalance
