local ProgressionIdentity = require("pwft.progression_identity")

local PalRaidNativeBinding = {}

local API_VERSION = "1.0.0"
local PREFIX = "[PalFactionTerritory0][PalRaidNativeBinding]"

local START_PATH =
    "/Script/Pal.PalInvaderManager:BroadcastInvaderStart"
local END_PATH =
    "/Script/Pal.PalInvaderManager:BroadcastInvaderEnd"
local SPAWN_PATH =
    "/Game/Pal/Blueprint/Incident/Invader/BP_PalIncidentInvaderEnemy.BP_PalIncidentInvaderEnemy_C:OnCharacterSpawned"
local DEATH_PATH =
    "/Game/Pal/Blueprint/Incident/Invader/BP_PalIncidentInvaderEnemy.BP_PalIncidentInvaderEnemy_C:OnDeadEnemy"
local ENEMY_ASSET_PATH =
    "/Game/Pal/Blueprint/Incident/Invader/BP_PalIncidentInvaderEnemy.BP_PalIncidentInvaderEnemy"
local REQUIRED_HOOKS = {
    START_PATH,
    END_PATH,
    SPAWN_PATH,
    DEATH_PATH,
}

local EVENT_AUTHORITY = "pal-invader-incident-group-guid-v1"
local SPAWN_AUTHORITY = "pal-invader-on-character-spawned-v1"
local DEATH_AUTHORITY = "pal-damage-reaction-dead-info-v1"
local OUTCOME_AUTHORITY = "pal-invader-end-wave-clear-v1"
local PLAYER_UID_AUTHORITY = "pal-player-controller-uid-v1"
local OWNED_PAL_AUTHORITY = "pal-character-trainer-v1"

local function result(ok, reason, extra)
    local value = extra or {}
    value.ok = ok
    value.reason = reason
    return value
end

local function non_empty(value)
    return type(value) == "string" and value ~= ""
end

local function valid(object)
    if object == nil then return false end
    local ok, answer = pcall(function()
        return object:IsValid()
    end)
    return ok and answer == true
end

local function property(object, name)
    if object == nil then return nil end
    local ok, value = pcall(function()
        return object[name]
    end)
    return ok and value or nil
end

local function call(object, method, ...)
    if object == nil then return false, nil end
    local args = { ... }
    local ok, value = pcall(function()
        return object[method](object, table.unpack(args))
    end)
    return ok, value
end

local function hook_value(parameter)
    if parameter == nil then return nil end
    local ok, value = pcall(function()
        return parameter:get()
    end)
    return ok and value or nil
end

local function value_string(value)
    if value == nil then return nil end
    if type(value) == "string" or type(value) == "number" then
        return tostring(value)
    end
    local ok, text = pcall(function()
        return value:ToString()
    end)
    if ok and text ~= nil and tostring(text) ~= "" then
        return tostring(text)
    end
    return tostring(value)
end

local function full_name(object)
    if object == nil then return nil end
    if type(object) == "string" then return object end
    local ok, name = pcall(function()
        return object:GetFullName()
    end)
    if ok and name ~= nil and tostring(name) ~= "" then
        return tostring(name)
    end
    return tostring(object)
end

local function guid_key(guid)
    if guid == nil then return nil end
    if type(guid) == "string" then
        return guid ~= "" and guid or nil
    end
    local parts = {}
    for _, name in ipairs({ "A", "B", "C", "D" }) do
        local value = property(guid, name)
        if value == nil then
            parts = nil
            break
        end
        parts[#parts + 1] = tostring(value)
    end
    if parts ~= nil then
        return table.concat(parts, "-")
    end
    local text = value_string(guid)
    if text == nil or text == "" or text == "<nil>" then return nil end
    return text
end

local function positive_integer(value)
    return type(value) == "number"
        and value > 0
        and value == math.floor(value)
end

local function get_wave_info(parameter)
    local wave = property(parameter, "WaveInfo")
    if wave == nil then return nil end
    return {
        current = property(wave, "CurrentWave"),
        maximum = property(wave, "WaveMax"),
        complete = property(wave, "bCompleteAllWave") == true,
    }
end

local function get_group_name(parameter)
    local chosen = property(parameter, "ChosenInvaderData")
    return value_string(property(chosen, "GroupName"))
end

local function controller_uid(controller)
    local ok, uid = call(controller, "GetPlayerUId")
    return ok and ProgressionIdentity.normalize_guid(uid) or nil
end

local function incident_info(incident)
    local info = property(incident, "NewVar")
    if not valid(info) then return nil end
    return info
end

local function incident_wave(incident)
    local info = incident_info(incident)
    if info == nil then return nil end
    local ok, wave = call(info, "GetCurrentWave")
    if ok and positive_integer(wave) then return wave end
    wave = property(info, "CurrentWave")
    return positive_integer(wave) and wave or nil
end

local function default_player_controller()
    local ok, helpers = pcall(require, "UEHelpers")
    if not ok or helpers == nil then return nil end
    local controller_ok, controller = pcall(function()
        return helpers:GetPlayerController()
    end)
    return controller_ok and controller or nil
end

local function default_pal_utility()
    if type(StaticFindObject) ~= "function" then return nil end
    local ok, utility = pcall(function()
        return StaticFindObject("/Script/Pal.Default__PalUtility")
    end)
    return ok and utility or nil
end

local function public_status(instance)
    local hook_count = 0
    for _, path in ipairs(REQUIRED_HOOKS) do
        if instance.hooks[path] ~= nil then hook_count = hook_count + 1 end
    end
    local source_count = 0
    for _ in pairs(instance.sourcesByGroup) do
        source_count = source_count + 1
    end
    local event_count = 0
    for _ in pairs(instance.eventsByGuid) do
        event_count = event_count + 1
    end
    return {
        apiVersion = API_VERSION,
        enabled = instance.enabled,
        started = instance.started,
        ready = hook_count == #REQUIRED_HOOKS,
        hookCount = hook_count,
        requiredHookCount = #REQUIRED_HOOKS,
        sourceCount = source_count,
        activeEventCount = event_count,
        ignoredUnboundStarts = instance.ignoredUnboundStarts,
        settlements = instance.settlements,
        failures = instance.failures,
        PalworldSaveMutation = false,
    }
end

function PalRaidNativeBinding.create(adapter, config, dependencies)
    assert(type(adapter) == "table", "Pal raid-result adapter is required")
    assert(type(adapter.begin_event) == "function", "Pal raid-result adapter lacks begin_event")
    assert(type(adapter.register_member) == "function", "Pal raid-result adapter lacks register_member")
    assert(type(adapter.record_death) == "function", "Pal raid-result adapter lacks record_death")
    assert(type(adapter.finish_event) == "function", "Pal raid-result adapter lacks finish_event")
    assert(type(config) == "table", "Pal raid native binding configuration is required")
    assert(type(config.nativeRaidResultBindingEnabled) == "boolean",
        "native Pal raid binding flag is required")
    dependencies = dependencies or {}
    return setmetatable({
        version = API_VERSION,
        adapter = adapter,
        enabled = config.nativeRaidResultBindingEnabled == true,
        dependencies = dependencies,
        sourcesByGroup = {},
        eventsByGuid = {},
        hooks = {},
        hookErrors = {},
        started = false,
        ignoredUnboundStarts = 0,
        settlements = 0,
        failures = 0,
    }, { __index = PalRaidNativeBinding })
end

function PalRaidNativeBinding:_log(message)
    local logger = self.dependencies.logger
    if type(logger) == "function" then
        logger(PREFIX .. " " .. tostring(message))
    else
        print(PREFIX .. " " .. tostring(message) .. "\n")
    end
end

function PalRaidNativeBinding:_object_key(object)
    local provider = self.dependencies.objectKey
    if type(provider) == "function" then
        local ok, key = pcall(provider, object)
        if ok and non_empty(key) then return key end
    end
    return full_name(object)
end

function PalRaidNativeBinding:register_source(group_name, faction_id, metadata)
    if not non_empty(group_name) then
        return result(false, "native-raid-group-name-required")
    end
    if not non_empty(faction_id) then
        return result(false, "native-raid-pal-faction-id-required")
    end
    local known = self.adapter.service
        and self.adapter.service.palFactionIds
    if type(known) ~= "table" or known[faction_id] ~= true then
        return result(false, "native-raid-source-requires-pal-faction")
    end
    local existing = self.sourcesByGroup[group_name]
    if existing ~= nil then
        if existing.factionId == faction_id then
            return result(true, "native-raid-source-already-registered", existing)
        end
        return result(false, "native-raid-group-binding-conflict", {
            groupName = group_name,
            existingFactionId = existing.factionId,
            requestedFactionId = faction_id,
        })
    end
    local source = {
        groupName = group_name,
        factionId = faction_id,
        contentPackId = metadata and metadata.contentPackId or nil,
        contentVersion = metadata and metadata.contentVersion or nil,
    }
    self.sourcesByGroup[group_name] = source
    self:_log(string.format(
        "PAL_RAID_NATIVE_SOURCE_REGISTERED group=%s faction=%s pack=%s",
        group_name,
        faction_id,
        tostring(source.contentPackId)
    ))
    return result(true, "native-raid-source-registered", source)
end

function PalRaidNativeBinding:_event_from_guid(guid)
    local key = guid_key(guid)
    return key, key and self.eventsByGuid[key] or nil
end

function PalRaidNativeBinding:_on_start(parameter)
    local group_name = get_group_name(parameter)
    local source = group_name and self.sourcesByGroup[group_name] or nil
    if source == nil then
        self.ignoredUnboundStarts = self.ignoredUnboundStarts + 1
        self:_log(string.format(
            "PAL_RAID_NATIVE_START_IGNORED reason=unbound-group group=%s count=%d",
            tostring(group_name),
            self.ignoredUnboundStarts
        ))
        return result(false, "native-raid-group-unbound")
    end
    local group_guid = guid_key(property(parameter, "GroupGuid"))
    local wave = get_wave_info(parameter)
    if group_guid == nil or wave == nil or not positive_integer(wave.maximum) then
        self.failures = self.failures + 1
        return result(false, "native-raid-start-evidence-incomplete")
    end
    local event_id = "native-pal-raid:" .. group_guid
    local begun = self.adapter:begin_event({
        raidEventId = event_id,
        palFactionId = source.factionId,
        nativeGroupGuid = group_guid,
        waveMax = wave.maximum,
        sourceAuthority = EVENT_AUTHORITY,
    })
    if not begun.ok then
        self.failures = self.failures + 1
        self:_log(string.format(
            "PAL_RAID_NATIVE_START_FAILED event=%s group=%s reason=%s",
            event_id,
            group_name,
            tostring(begun.reason)
        ))
        return begun
    end
    self.eventsByGuid[group_guid] = {
        eventId = event_id,
        groupGuid = group_guid,
        groupName = group_name,
        factionId = source.factionId,
        waveMax = wave.maximum,
    }
    self:_log(string.format(
        "PAL_RAID_NATIVE_STARTED event=%s group=%s faction=%s waveMax=%d",
        event_id,
        group_name,
        source.factionId,
        wave.maximum
    ))
    return begun
end

function PalRaidNativeBinding:_on_spawn(incident, actor)
    local group_guid, event = self:_event_from_guid(
        property(incident, "GroupGuid")
    )
    if event == nil then
        return result(false, "native-raid-spawn-without-active-event")
    end
    local actor_key = self:_object_key(actor)
    local wave_index = incident_wave(incident)
    if not non_empty(actor_key) or not positive_integer(wave_index) then
        self.failures = self.failures + 1
        return result(false, "native-raid-spawn-evidence-incomplete")
    end
    local registered = self.adapter:register_member(event.eventId, {
        actorKey = actor_key,
        waveIndex = wave_index,
        spawnAuthority = SPAWN_AUTHORITY,
    })
    self:_log(string.format(
        "PAL_RAID_NATIVE_MEMBER event=%s guid=%s actor=%s wave=%d ok=%s reason=%s",
        event.eventId,
        group_guid,
        actor_key,
        wave_index,
        tostring(registered.ok),
        tostring(registered.reason)
    ))
    if not registered.ok then self.failures = self.failures + 1 end
    return registered
end

function PalRaidNativeBinding:_local_controller()
    local provider = self.dependencies.getLocalPlayerController
        or default_player_controller
    local ok, controller = pcall(provider)
    return ok and controller or nil
end

function PalRaidNativeBinding:_pal_utility()
    local provider = self.dependencies.getPalUtility
        or default_pal_utility
    local ok, utility = pcall(provider)
    return ok and utility or nil
end

function PalRaidNativeBinding:_death_attribution(attacker)
    local attacker_controller = nil
    local controller_ok, controller = call(attacker, "GetController")
    if controller_ok then attacker_controller = controller end
    if not valid(attacker_controller) then
        local local_controller = self:_local_controller()
        local pawn_ok, pawn = call(local_controller, "K2_GetPawn")
        if pawn_ok
            and self:_object_key(pawn) == self:_object_key(attacker) then
            attacker_controller = local_controller
        end
    end
    local attacker_uid = controller_uid(attacker_controller)
    if attacker_uid ~= nil then
        return {
            attackerKind = "player",
            playerUid = attacker_uid,
            attributionAuthority = PLAYER_UID_AUTHORITY,
        }
    end

    local utility = self:_pal_utility()
    local otomo_ok, is_otomo = call(
        utility,
        "IsPlayersOtomo",
        attacker
    )
    local trainer_ok, trainer_controller = call(
        utility,
        "GetTrainerPlayerController_ForServer",
        attacker
    )
    local trainer_uid = trainer_ok
        and controller_uid(trainer_controller)
        or nil
    if trainer_uid ~= nil then
        return {
            attackerKind = "pal",
            attackerIsPlayersOtomo = otomo_ok and is_otomo == true,
            trainerPlayerUid = trainer_uid,
            attributionAuthority = OWNED_PAL_AUTHORITY,
        }
    end
    return {
        attackerKind = "unresolved",
        attackerMatchesLocalPlayer = false,
        attackerIsPlayersOtomo = otomo_ok and is_otomo == true,
        trainerMatchesLocalPlayer = false,
        attributionAuthority = "unresolved-native-attacker",
    }
end

function PalRaidNativeBinding:attribute_attacker(attacker)
    return self:_death_attribution(attacker)
end

function PalRaidNativeBinding:_on_death(incident, dead_info)
    local _, event = self:_event_from_guid(property(incident, "GroupGuid"))
    if event == nil then
        return result(false, "native-raid-death-without-active-event")
    end
    local victim = property(dead_info, "SelfActor")
    local attacker = property(dead_info, "LastAttacker")
    local victim_key = self:_object_key(victim)
    if not non_empty(victim_key) or attacker == nil then
        self.failures = self.failures + 1
        return result(false, "native-raid-death-evidence-incomplete")
    end
    local attribution = self:_death_attribution(attacker)
    local recorded = self.adapter:record_death(event.eventId, {
        victimActorKey = victim_key,
        lastAttackerActorKey = self:_object_key(attacker),
        attackerKind = attribution.attackerKind,
        playerUid = attribution.playerUid,
        trainerPlayerUid = attribution.trainerPlayerUid,
        attackerMatchesLocalPlayer =
            attribution.attackerMatchesLocalPlayer,
        attackerIsPlayersOtomo =
            attribution.attackerIsPlayersOtomo,
        trainerMatchesLocalPlayer =
            attribution.trainerMatchesLocalPlayer,
        attributionAuthority = attribution.attributionAuthority,
        deathAuthority = DEATH_AUTHORITY,
    })
    self:_log(string.format(
        "PAL_RAID_NATIVE_DEATH event=%s victim=%s attacker=%s kind=%s ok=%s reason=%s",
        event.eventId,
        victim_key,
        tostring(self:_object_key(attacker)),
        tostring(attribution.attackerKind),
        tostring(recorded.ok),
        tostring(recorded.reason)
    ))
    if not recorded.ok then self.failures = self.failures + 1 end
    return recorded
end

function PalRaidNativeBinding:_on_end(parameter)
    local group_guid, event = self:_event_from_guid(
        property(parameter, "GroupGuid")
    )
    if event == nil then
        return result(false, "native-raid-end-without-active-event")
    end
    local wave = get_wave_info(parameter)
    if wave == nil
        or not positive_integer(wave.current)
        or not positive_integer(wave.maximum)
        or wave.maximum ~= event.waveMax then
        self.failures = self.failures + 1
        return result(false, "native-raid-end-evidence-incomplete")
    end
    local all_waves_cleared = wave.complete == true
        and wave.current >= wave.maximum
    local settled = self.adapter:finish_event(event.eventId, {
        nativeEnded = true,
        playerSideWon = all_waves_cleared,
        allWavesCleared = all_waves_cleared,
        outcomeAuthority = OUTCOME_AUTHORITY,
    })
    if settled.ok then
        self.eventsByGuid[group_guid] = nil
        self.settlements = self.settlements + 1
    else
        self.failures = self.failures + 1
    end
    local token = settled.settlement
        and settled.settlement.tokenAwarded == true
    self:_log(string.format(
        "PAL_RAID_NATIVE_SETTLED event=%s complete=%s current=%d waveMax=%d ok=%s reason=%s tokenAwarded=%s",
        event.eventId,
        tostring(all_waves_cleared),
        wave.current,
        wave.maximum,
        tostring(settled.ok),
        tostring(settled.reason),
        tostring(token == true)
    ))
    return settled
end

function PalRaidNativeBinding:_register_hook(path, callback)
    if self.hooks[path] ~= nil then return true end
    local provider = self.dependencies.registerHook or RegisterHook
    if type(provider) ~= "function" then
        self.hookErrors[path] = "RegisterHook-unavailable"
        return false
    end
    local ok, first, second = pcall(provider, path, callback)
    if not ok then
        self.hookErrors[path] = tostring(first)
        self:_log("PAL_RAID_NATIVE_HOOK_FAILED path=" .. path
            .. " error=" .. tostring(first))
        return false
    end
    self.hooks[path] = {
        firstId = first,
        secondId = second,
        callback = callback,
    }
    self:_log("PAL_RAID_NATIVE_HOOK_READY path=" .. path)
    return true
end

function PalRaidNativeBinding:start()
    if self.started then
        return result(true, "native-raid-binding-already-started",
            public_status(self))
    end
    if not self.enabled then
        return result(false, "native-raid-binding-disabled",
            public_status(self))
    end
    local load_asset = self.dependencies.loadAsset or LoadAsset
    if type(load_asset) == "function" then
        pcall(load_asset, ENEMY_ASSET_PATH)
    end
    self:_register_hook(START_PATH, function(_, parameter)
        local ok, error_value = pcall(function()
            return self:_on_start(hook_value(parameter))
        end)
        if not ok then
            self.failures = self.failures + 1
            self:_log("PAL_RAID_NATIVE_START_EXCEPTION error="
                .. tostring(error_value))
        end
    end)
    self:_register_hook(SPAWN_PATH, function(context, actor_parameter)
        local ok, error_value = pcall(function()
            return self:_on_spawn(
                hook_value(context),
                hook_value(actor_parameter)
            )
        end)
        if not ok then
            self.failures = self.failures + 1
            self:_log("PAL_RAID_NATIVE_SPAWN_EXCEPTION error="
                .. tostring(error_value))
        end
    end)
    self:_register_hook(DEATH_PATH, function(context, dead_parameter)
        local ok, error_value = pcall(function()
            return self:_on_death(
                hook_value(context),
                hook_value(dead_parameter)
            )
        end)
        if not ok then
            self.failures = self.failures + 1
            self:_log("PAL_RAID_NATIVE_DEATH_EXCEPTION error="
                .. tostring(error_value))
        end
    end)
    self:_register_hook(END_PATH, function(_, parameter)
        local ok, error_value = pcall(function()
            return self:_on_end(hook_value(parameter))
        end)
        if not ok then
            self.failures = self.failures + 1
            self:_log("PAL_RAID_NATIVE_END_EXCEPTION error="
                .. tostring(error_value))
        end
    end)
    local status = public_status(self)
    self.started = status.ready
    if not status.ready then
        return result(false, "native-raid-hook-registration-incomplete",
            status)
    end
    self:_log(string.format(
        "PAL_RAID_NATIVE_BINDING_READY hooks=%d sources=%d saveWrites=0",
        status.hookCount,
        status.sourceCount
    ))
    return result(true, "native-raid-binding-started", status)
end

function PalRaidNativeBinding:on_world_loaded(source)
    local response = self:start()
    local status = public_status(self)
    self:_log(string.format(
        "PAL_RAID_NATIVE_HOOK_REGISTRATION source=%s ready=%d required=%d started=%s reason=%s",
        tostring(source or "world-loaded"),
        status.hookCount,
        status.requiredHookCount,
        tostring(status.started),
        tostring(response.reason)
    ))
    return response
end

function PalRaidNativeBinding:status()
    return public_status(self)
end

PalRaidNativeBinding.paths = {
    start = START_PATH,
    finish = END_PATH,
    spawn = SPAWN_PATH,
    death = DEATH_PATH,
}

return PalRaidNativeBinding
