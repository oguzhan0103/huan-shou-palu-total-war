local ProgressionIdentity = require("pwft.progression_identity")

local UniquePalBossNativeProduction = {}

local API_VERSION = "1.0.0"
local CAPTURE_HOOK = "/Script/Pal.PalUtility:PalCaptureSuccess"
local DEATH_HOOK = "/Script/Pal.PalCharacter:OnDeadCharacter"
local CHARACTER_READY_HOOK =
    "/Script/Pal.PalCharacterParameterComponent:OnInitializedCharacter"

local function copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] ~= nil then return seen[value] end
    local output = {}
    seen[value] = output
    for key, child in pairs(value) do
        output[copy(key, seen)] = copy(child, seen)
    end
    return output
end

local function result(ok, reason, extra)
    local value = extra or {}
    value.ok = ok
    value.reason = reason
    return value
end

local function require_text(value, name)
    assert(type(value) == "string" and value ~= "",
        name .. " must be a non-empty string")
    return value
end

local function stable_id(value, name)
    require_text(value, name)
    assert(string.match(value, "^[a-z0-9][a-z0-9_.-]+$") ~= nil,
        name .. " must be a stable namespaced ID")
    assert(string.find(value, "..", 1, true) == nil,
        name .. " cannot contain an empty namespace segment")
    return value
end

local function unwrap(value)
    if value == nil then return nil end
    local ok, unwrapped = pcall(function()
        if value.get ~= nil then return value:get() end
        return value
    end)
    return ok and unwrapped or value
end

local function hook_value(value)
    if value == nil then return nil end
    local ok, unwrapped = pcall(function()
        return value:get()
    end)
    return ok and unwrapped or value
end

local function is_valid_object(object)
    if object == nil then return false end
    local ok, valid = pcall(function()
        if object.IsValid ~= nil then return object:IsValid() end
        return true
    end)
    return ok and valid ~= false
end

local function safe_property(object, name)
    if not is_valid_object(object) then return nil end
    local ok, value = pcall(function() return object[name] end)
    return ok and unwrap(value) or nil
end

local function safe_assign(object, name, value)
    if not is_valid_object(object) then return false end
    local ok = pcall(function() object[name] = value end)
    return ok
end

local function safe_call(object, method_name, ...)
    if not is_valid_object(object) then
        return nil, "object-unavailable"
    end
    local arguments = table.pack(...)
    local ok, value = pcall(function()
        local method = object[method_name]
        if method == nil then error("method-unavailable") end
        return method(
            object,
            table.unpack(arguments, 1, arguments.n)
        )
    end)
    if not ok then return nil, tostring(value) end
    return unwrap(value), nil
end

local function safe_invoke(object, method_name, ...)
    if not is_valid_object(object) then
        return false, "object-unavailable"
    end
    local arguments = table.pack(...)
    local ok, value = pcall(function()
        local method = object[method_name]
        if method == nil then error("method-unavailable") end
        return method(
            object,
            table.unpack(arguments, 1, arguments.n)
        )
    end)
    return ok, ok and unwrap(value) or tostring(value)
end

local function safe_full_name(object)
    if not is_valid_object(object) then return "<invalid>" end
    local value = safe_call(object, "GetFullName")
    return value ~= nil and tostring(value) or "<unreadable>"
end

local function native_text(value)
    value = unwrap(value)
    if value == nil then return nil end
    local ok, text = pcall(tostring, value)
    if not ok or text == nil or text == "" then return nil end
    return text
end

local function true_property_or_method(object, property_name, method_name)
    if safe_property(object, property_name) == true then return true end
    if method_name == nil then return false end
    local value = safe_call(object, method_name)
    return value == true
end

local function character_component(actor, hinted_component)
    if is_valid_object(hinted_component) then return hinted_component end
    local component = safe_property(actor, "CharacterParameterComponent")
    if is_valid_object(component) then return component end
    component = safe_call(actor, "GetCharacterParameterComponent")
    return is_valid_object(component) and component or nil
end

local function individual_parameter(component)
    if not is_valid_object(component) then return nil end
    local individual = safe_property(component, "IndividualParameter")
    if is_valid_object(individual) then return individual end
    individual = safe_call(component, "GetIndividualParameter")
    return is_valid_object(individual) and individual or nil
end

local function actor_from_component(component, hinted_actor)
    if is_valid_object(hinted_actor) then return hinted_actor end
    local individual = individual_parameter(component)
    local actor = safe_call(individual, "GetIndividualActor")
    return is_valid_object(actor) and actor or nil
end

local function boss_identity(actor, hinted_component)
    if not is_valid_object(actor) then
        return nil, nil, false, "actor-unavailable"
    end
    local component = character_component(actor, hinted_component)
    local individual = individual_parameter(component)
    local static_component = safe_property(
        actor,
        "StaticCharacterParameterComponent"
    )
    if not is_valid_object(component)
        or not is_valid_object(individual)
        or not is_valid_object(static_component) then
        return nil, nil, false, "boss-parameter-not-ready"
    end
    local is_pal = safe_property(static_component, "IsPal") == true
    local spawned_type = tonumber((safe_call(
        individual,
        "GetSpawnedCharacterType"
    )))
    local is_boss = true_property_or_method(
            static_component,
            "IsBoss_Database",
            "IsBossPal_Database"
        )
        or true_property_or_method(
            static_component,
            "IsTowerBoss_Database",
            "IsTowerBossPal"
        )
        or true_property_or_method(
            static_component,
            "IsRaidBoss_Database",
            "IsRaidBossPal"
        )
        or true_property_or_method(
            static_component,
            "IsPredatorBoss_Database",
            "IsPredatorBossPal"
        )
        or (spawned_type ~= nil
            and spawned_type >= 2 and spawned_type <= 7)
    local character_id = native_text(safe_call(
        individual,
        "GetCharacterID"
    ))
    return character_id, individual, is_pal and is_boss, is_pal
            and "pal-boss" or "not-pal-boss"
end

local function same_object(first, second)
    if not is_valid_object(first) or not is_valid_object(second) then
        return false
    end
    if first == second then return true end
    local first_name = safe_full_name(first)
    return first_name ~= "<invalid>"
        and first_name ~= "<unreadable>"
        and first_name == safe_full_name(second)
end

local function individual_key(handle)
    local id, id_error = safe_call(handle, "GetIndividualID")
    if id == nil then
        return nil, "boss-individual-id-unavailable:"
            .. tostring(id_error)
    end
    local player_uid = ProgressionIdentity.normalize_guid(
        safe_property(id, "PlayerUId")
    )
    local instance_id = ProgressionIdentity.normalize_guid(
        safe_property(id, "InstanceId")
    )
    if player_uid == nil or instance_id == nil then
        return nil, "boss-individual-id-invalid"
    end
    return "pal-" .. player_uid .. "-" .. instance_id, nil
end

local function normalize_offset(value)
    value = value or {}
    return {
        X = tonumber(value.X) or 1200,
        Y = tonumber(value.Y) or 0,
        Z = tonumber(value.Z) or 80,
    }
end

local function normalize_binding(definition, build_id)
    assert(type(definition) == "table",
        "native unique-Pal Boss production binding is required")
    assert(definition.buildId == build_id,
        "native unique-Pal Boss production Build ID drifted")
    local actor_class = require_text(
        definition.expectedActorClassKey,
        "native unique-Pal Boss actor class"
    )
    local actor_class_token = string.match(actor_class, "([^./]+_C)$")
        or actor_class
    return {
        bindingId = stable_id(definition.bindingId,
            "native unique-Pal Boss binding ID"),
        providerId = stable_id(definition.providerId,
            "native unique-Pal Boss provider ID"),
        uniquePalId = stable_id(definition.uniquePalId,
            "native unique-Pal ID"),
        speciesId = require_text(definition.speciesId,
            "native unique-Pal species ID"),
        bossCharacterId = require_text(definition.bossCharacterId,
            "native unique-Pal Boss character ID"),
        displayNameZhHans = require_text(
            definition.displayNameZhHans,
            "native unique-Pal display name"
        ),
        route = "native-existing",
        nativeBossSlotId = nil,
        bossSpawnerKey = require_text(definition.bossSpawnerKey,
            "native unique-Pal Boss spawner route"),
        expectedActorClassKey = actor_class,
        expectedActorClassToken = actor_class_token,
        locationKey = require_text(definition.locationKey,
            "native unique-Pal event location"),
        buildId = build_id,
        verification = {
            speciesId = definition.verification
                    and definition.verification.speciesId == true,
            spawnerKey = definition.verification
                    and definition.verification.spawnerKey == true,
            actorClassKey = definition.verification
                    and definition.verification.actorClassKey == true,
        },
        balance = copy(definition.balance),
    }
end

local function local_controller(adapters)
    if type(adapters.getPlayerController) == "function" then
        local ok, controller = pcall(adapters.getPlayerController)
        if ok and is_valid_object(controller) then return controller end
    end
    if _G.UEHelpers ~= nil
        and type(_G.UEHelpers.GetPlayerController) == "function" then
        local ok, controller = pcall(
            _G.UEHelpers.GetPlayerController
        )
        if ok and is_valid_object(controller) then return controller end
    end
    local find_first = adapters.findFirstOf or _G.FindFirstOf
    if type(find_first) == "function" then
        for _, class_name in ipairs({
            "PalPlayerController",
            "PalPlayerController_C",
        }) do
            local ok, controller = pcall(find_first, class_name)
            if ok and is_valid_object(controller) then return controller end
        end
    end
    return nil
end

local function player_character(controller)
    for _, method_name in ipairs({
        "GetDefaultPlayerCharacter",
        "K2_GetPawn",
    }) do
        local character = safe_call(controller, method_name)
        if is_valid_object(character) then return character end
    end
    local character = safe_property(controller, "AcknowledgedPawn")
        or safe_property(controller, "Pawn")
    return is_valid_object(character) and character or nil
end

local function pal_utility(adapters)
    if type(adapters.getPalUtility) == "function" then
        local ok, utility = pcall(adapters.getPalUtility)
        if ok and is_valid_object(utility) then return utility end
    end
    local finder = adapters.staticFindObject or _G.StaticFindObject
    if type(finder) ~= "function" then return nil end
    local ok, utility = pcall(
        finder,
        "/Script/Pal.Default__PalUtility"
    )
    return ok and is_valid_object(utility) and utility or nil
end

local function make_name(adapters, value)
    if type(adapters.fName) == "function" then
        local ok, name = pcall(adapters.fName, value)
        if ok and name ~= nil then return name end
    end
    if type(_G.FName) == "function" then
        local ok, name = pcall(_G.FName, value)
        if ok and name ~= nil then return name end
    end
    local finder = adapters.staticFindObject or _G.StaticFindObject
    if type(finder) == "function" then
        local ok, library = pcall(
            finder,
            "/Script/Engine.Default__KismetStringLibrary"
        )
        if ok and is_valid_object(library) then
            local name = safe_call(library, "Conv_StringToName", value)
            if name ~= nil then return name end
        end
    end
    return value
end

local function default_native_notification(adapters, message)
    if type(adapters.notify) == "function" then
        local ok, shown = pcall(adapters.notify, message)
        return ok and shown ~= false
    end
    local finder = adapters.staticFindObject or _G.StaticFindObject
    local find_all = adapters.findAllOf or _G.FindAllOf
    if type(finder) ~= "function" or type(find_all) ~= "function" then
        return false
    end
    local text_ok, text_library = pcall(
        finder,
        "/Script/Engine.Default__KismetTextLibrary"
    )
    if not text_ok or not is_valid_object(text_library) then
        return false
    end
    local warning_text = safe_call(
        text_library,
        "Conv_StringToText",
        message
    )
    if warning_text == nil then return false end
    local found, surfaces = pcall(find_all, "PalHUDService")
    if not found or type(surfaces) ~= "table" then return false end
    for _, surface in pairs(surfaces) do
        if is_valid_object(surface) then
            local ok = pcall(function()
                surface:ShowCommonWarning({
                    Message = warning_text,
                    DisplayType = 0,
                })
            end)
            if ok then return true end
        end
    end
    return false
end

function UniquePalBossNativeProduction.create(
    boss_bus,
    campaign,
    configuration,
    options
)
    assert(type(boss_bus) == "table"
            and type(boss_bus.register_provider) == "function"
            and type(boss_bus.bind) == "function"
            and type(boss_bus.confirm_spawn) == "function",
        "unique-Pal Boss provider bus is required")
    assert(type(campaign) == "table"
            and type(campaign.campaign_status) == "function"
            and type(campaign.schedule_next) == "function"
            and type(campaign.advance) == "function",
        "unique-Pal campaign is required")
    configuration = configuration or {}
    options = options or {}
    assert(type(configuration.enabled) == "boolean",
        "native unique-Pal Boss production enabled flag is required")
    assert(type(configuration.automaticSchedulerEnabled) == "boolean",
        "native unique-Pal Boss scheduler flag is required")
    assert(type(configuration.tickIntervalMs) == "number"
            and configuration.tickIntervalMs >= 1000,
        "native unique-Pal Boss tick interval is invalid")
    assert(type(configuration.spawnResolveDelaysMs) == "table"
            and #configuration.spawnResolveDelaysMs > 0,
        "native unique-Pal Boss resolve delays are required")
    local build_id = require_text(configuration.buildId,
        "native unique-Pal Boss Build ID")
    local provider_id = stable_id(configuration.providerId,
        "native unique-Pal Boss provider ID")
    local authority_source = stable_id(configuration.authoritySource,
        "native unique-Pal Boss authority source")
    return setmetatable({
        version = API_VERSION,
        bus = boss_bus,
        campaign = campaign,
        enabled = configuration.enabled == true,
        automaticSchedulerEnabled =
            configuration.automaticSchedulerEnabled == true,
        tickIntervalMs = configuration.tickIntervalMs,
        spawnResolveDelaysMs = copy(
            configuration.spawnResolveDelaysMs
        ),
        spawnOffset = normalize_offset(configuration.spawnOffset),
        buildId = build_id,
        providerId = provider_id,
        authoritySource = authority_source,
        playerId = stable_id(configuration.playerId or "local-player",
            "native unique-Pal Boss player ID"),
        adapters = options.adapters or {},
        strategicWorldNativeProduction =
            options.strategicWorldNativeProduction,
        logger = options.logger,
        bindingsByUniquePalId = {},
        recordsByUniquePalId = {},
        recordsByActorName = {},
        pendingSpawnRecords = {},
        authorizedActorNames = {},
        spawnRetryTokenByDeliveryId = {},
        -- UE4SS may consult a delayed callback's registry reference while
        -- unwinding the shared EngineTick hook. Keep every callback strongly
        -- referenced for this runtime instance; releasing it from inside its
        -- own callback can remove the global hook with "Ref was not function".
        scheduledCallbackRefs = {},
        spawnRetrySequence = 0,
        spawnRetryScheduledCount = 0,
        spawnRetryAttemptCount = 0,
        hookRecords = {},
        hooksRegistered = false,
        active = false,
        worldGeneration = 0,
        schedulerGeneration = 0,
        activationCount = 0,
        schedulerPulseCount = 0,
        scheduleCount = 0,
        spawnRequestCount = 0,
        spawnConfirmedCount = 0,
        captureConfirmedCount = 0,
        defeatConfirmedCount = 0,
        timeoutConfirmedCount = 0,
        suppressedBossCount = 0,
        allowedUniqueBossCount = 0,
        bossSuppressionDeferredCount = 0,
        suppressionProbeCount = 0,
        suppressionProbePassCount = 0,
        cleanupCount = 0,
        notificationCount = 0,
        notificationFailureCount = 0,
        rejectionCount = 0,
        lastError = nil,
    }, { __index = UniquePalBossNativeProduction })
end

function UniquePalBossNativeProduction:_log(message)
    if type(self.logger) == "function" then
        pcall(self.logger,
            "[UniquePalBossNativeProduction] " .. tostring(message))
    end
end

function UniquePalBossNativeProduction:_run(callback)
    if type(self.adapters.runInGameThread) == "function" then
        return self.adapters.runInGameThread(callback)
    end
    if type(_G.ExecuteInGameThread) == "function" then
        return _G.ExecuteInGameThread(callback)
    end
    return callback()
end

function UniquePalBossNativeProduction:_schedule(delay_ms, callback)
    self.scheduledCallbackRefs[#self.scheduledCallbackRefs + 1] = callback
    if type(self.adapters.schedule) == "function" then
        local ok, scheduled = pcall(
            self.adapters.schedule,
            delay_ms,
            callback
        )
        return ok and scheduled ~= false
    end
    if type(_G.ExecuteWithDelay) ~= "function" then return false end
    _G.ExecuteWithDelay(delay_ms, callback)
    return true
end

function UniquePalBossNativeProduction:_queue_spawn_delivery_retries(
    payload,
    first_reason
)
    local delivery_id = payload and payload.deliveryId
    if type(delivery_id) ~= "string" or delivery_id == "" then
        return false
    end
    if self.spawnRetryTokenByDeliveryId[delivery_id] ~= nil then
        return true
    end
    self.spawnRetrySequence = self.spawnRetrySequence + 1
    local token = self.spawnRetrySequence
    local world_generation = self.worldGeneration
    local scheduler_generation = self.schedulerGeneration
    self.spawnRetryTokenByDeliveryId[delivery_id] = token
    self.spawnRetryScheduledCount = self.spawnRetryScheduledCount + 1
    self:_log(string.format(
        "SPAWN_RETRY_QUEUED uniquePal=%s delivery=%s attempts=%d firstReason=%s generation=%d",
        tostring(payload.uniquePalId),
        delivery_id,
        #self.spawnResolveDelaysMs,
        tostring(first_reason),
        world_generation
    ))
    for index, delay_ms in ipairs(self.spawnResolveDelaysMs) do
        self:_schedule(delay_ms, function()
            if self.active ~= true
                or self.worldGeneration ~= world_generation
                or self.schedulerGeneration ~= scheduler_generation
                or self.spawnRetryTokenByDeliveryId[delivery_id]
                    ~= token then
                return
            end
            self.spawnRetryAttemptCount =
                self.spawnRetryAttemptCount + 1
            self:_run(function()
                local retried = self.bus:retry_pending(
                    payload.uniquePalId
                )
                self:_log(string.format(
                    "SPAWN_RETRY_ATTEMPT uniquePal=%s delivery=%s attempt=%d/%d ok=%s pending=%s reason=%s generation=%d",
                    tostring(payload.uniquePalId),
                    delivery_id,
                    index,
                    #self.spawnResolveDelaysMs,
                    tostring(retried.ok == true),
                    tostring(retried.pendingCount or 0),
                    tostring(retried.reason),
                    world_generation
                ))
                if index == #self.spawnResolveDelaysMs
                    and self.spawnRetryTokenByDeliveryId[delivery_id]
                        == token then
                    self.spawnRetryTokenByDeliveryId[delivery_id] = nil
                end
            end)
        end)
    end
    return true
end

function UniquePalBossNativeProduction:_notify(message, marker)
    local shown = default_native_notification(self.adapters, message)
    if shown then
        self.notificationCount = self.notificationCount + 1
    else
        self.notificationFailureCount =
            self.notificationFailureCount + 1
    end
    self:_log(string.format(
        "NOTIFICATION marker=%s shown=%s text=%s",
        tostring(marker),
        tostring(shown),
        tostring(message)
    ))
    return shown
end

function UniquePalBossNativeProduction:_binding(unique_pal_id)
    return self.bindingsByUniquePalId[unique_pal_id]
end

function UniquePalBossNativeProduction:_callback(
    record,
    callback_kind,
    logical_tick
)
    local binding = record.binding
    return {
        callbackId = table.concat({
            "pwft.native-boss",
            callback_kind,
            record.payload.eventId,
        }, "."),
        providerId = self.providerId,
        authoritySource = self.authoritySource,
        bindingId = binding.bindingId,
        uniquePalId = binding.uniquePalId,
        eventId = record.payload.eventId,
        speciesId = binding.speciesId,
        bossSpawnerKey = binding.bossSpawnerKey,
        actorBindingId = record.actorBindingId,
        actorClassKey = binding.expectedActorClassKey,
        worldGeneration = self.worldGeneration,
        logicalTick = logical_tick,
        playerId = self.playerId,
    }
end

function UniquePalBossNativeProduction:_campaign_tick()
    local status = self.campaign:status()
    return tonumber(status.logicalTick) or 0
end

function UniquePalBossNativeProduction:_sorted_binding_ids()
    local values = {}
    for unique_pal_id in pairs(self.bindingsByUniquePalId) do
        values[#values + 1] = unique_pal_id
    end
    table.sort(values)
    return values
end

function UniquePalBossNativeProduction:_active_window()
    for _, unique_pal_id in ipairs(self:_sorted_binding_ids()) do
        local status = self.campaign:campaign_status(unique_pal_id)
        if status ~= nil and (
            status.phase == "scheduled"
            or status.phase == "announced"
            or status.phase == "activation-pending"
            or status.phase == "open"
        ) then
            return unique_pal_id, status
        end
    end
    return nil, nil
end

function UniquePalBossNativeProduction:_schedule_closed(unique_pal_id)
    local status = self.campaign:campaign_status(unique_pal_id)
    if status == nil or status.phase ~= "closed" then
        return result(true, "unique-pal-production-schedule-not-required")
    end
    local active_unique_pal_id, active_status = self:_active_window()
    if active_unique_pal_id ~= nil then
        return result(true,
            "unique-pal-production-global-window-occupied", {
            activeUniquePalId = active_unique_pal_id,
            activePhase = active_status.phase,
        })
    end
    local next_sequence = (tonumber(status.scheduleSequence) or 0) + 1
    local operation_id = string.format(
        "pwft.production.schedule.%s.%d",
        unique_pal_id,
        next_sequence
    )
    local scheduled = self.campaign:schedule_next(
        unique_pal_id,
        self:_campaign_tick(),
        operation_id
    )
    if scheduled.ok then
        self.scheduleCount = self.scheduleCount + 1
        self:_log(string.format(
            "OPENING_SCHEDULED uniquePal=%s event=%s notice=%s open=%s close=%s",
            unique_pal_id,
            tostring(scheduled.eventId),
            tostring(scheduled.noticeTick),
            tostring(scheduled.openTick),
            tostring(scheduled.closeTick)
        ))
    end
    return scheduled
end

function UniquePalBossNativeProduction:_resolve_context()
    if type(self.adapters.spawnBoss) == "function" then
        return { adapterSpawn = true }, nil
    end
    local controller = local_controller(self.adapters)
    if not is_valid_object(controller) then
        return nil, "local-player-controller-not-ready"
    end
    local player = player_character(controller)
    if not is_valid_object(player) then
        return nil, "local-player-character-not-ready"
    end
    local utility = pal_utility(self.adapters)
    if not is_valid_object(utility) then
        return nil, "pal-utility-not-ready"
    end
    local manager, manager_error = safe_call(
        utility,
        "GetNPCManager",
        controller
    )
    if not is_valid_object(manager) then
        return nil, "pal-npc-manager-not-ready:"
            .. tostring(manager_error)
    end
    local controller_class = safe_property(
        manager,
        "NPCAIControllerBaseClass"
    )
    if not is_valid_object(controller_class) then
        return nil, "pal-npc-controller-class-not-ready"
    end
    local location, location_error = safe_call(
        player,
        "K2_GetActorLocation"
    )
    if location == nil then
        return nil, "local-player-location-not-ready:"
            .. tostring(location_error)
    end
    return {
        controller = controller,
        player = player,
        utility = utility,
        manager = manager,
        controllerClass = controller_class,
        location = location,
    }, nil
end

function UniquePalBossNativeProduction:_spawn_record(record)
    local context, context_error = self:_resolve_context()
    if context == nil then
        return result(false, context_error, { retryable = true })
    end
    local binding = record.binding
    -- Authorize this exact request before calling SpawnNPCForServer.  The
    -- character-ready callback can run synchronously inside that call, so a
    -- later allow-list update would race and delete the Mod's own Boss.
    self.pendingSpawnRecords[record.requestId] = record
    local handle, spawn_error
    if type(self.adapters.spawnBoss) == "function" then
        local ok, value, error_value = pcall(
            self.adapters.spawnBoss,
            binding,
            self.spawnOffset,
            record.payload
        )
        handle = ok and value or nil
        spawn_error = ok and error_value or value
    else
        local location = context.location
        local spawn_location = {
            X = (tonumber(safe_property(location, "X")) or 0)
                + self.spawnOffset.X,
            Y = (tonumber(safe_property(location, "Y")) or 0)
                + self.spawnOffset.Y,
            Z = (tonumber(safe_property(location, "Z")) or 0)
                + self.spawnOffset.Z,
        }
        handle, spawn_error = safe_call(
            context.manager,
            "SpawnNPCForServer",
            {
                ControllerClass = context.controllerClass,
                CharacterID = make_name(
                    self.adapters,
                    binding.bossCharacterId
                ),
                Level = binding.balance.level,
                Location = spawn_location,
                Yaw = 0,
                Squad = nil,
            },
            nil
        )
    end
    if not is_valid_object(handle) then
        self.pendingSpawnRecords[record.requestId] = nil
        return result(false,
            "native-unique-pal-boss-spawn-not-accepted:"
                .. tostring(spawn_error), {
            retryable = true,
        })
    end
    record.handle = handle
    record.status = "spawn-accepted"
    self.spawnRequestCount = self.spawnRequestCount + 1
    self:_log(string.format(
        "SPAWN_ACCEPTED uniquePal=%s character=%s event=%s generation=%d",
        binding.uniquePalId,
        binding.bossCharacterId,
        record.payload.eventId,
        self.worldGeneration
    ))
    return result(true, "native-unique-pal-boss-spawn-accepted")
end

function UniquePalBossNativeProduction:_apply_balance(record, actor)
    if type(self.adapters.applyBalance) == "function" then
        local ok, applied, detail = pcall(
            self.adapters.applyBalance,
            actor,
            copy(record.binding.balance),
            record.binding
        )
        return ok and applied == true,
            ok and detail or tostring(applied)
    end
    local component = safe_property(
        actor,
        "CharacterParameterComponent"
    )
    if not is_valid_object(component) then
        component = safe_call(actor, "GetCharacterParameterComponent")
    end
    if not is_valid_object(component) then
        return false, "character-parameter-component-not-ready"
    end
    local individual = safe_property(component, "IndividualParameter")
    if not is_valid_object(individual) then
        individual = safe_call(component, "GetIndividualParameter")
    end
    if not is_valid_object(individual) then
        return false, "individual-parameter-not-ready"
    end
    local balance = record.binding.balance
    local level_ok = safe_invoke(
        individual,
        "SetOverrideLevel",
        balance.level
    )
    local hp_ok = safe_assign(
        component,
        "AdditionalEnemyMaxHPRate",
        balance.healthMultiplier
    )
    local damage_ok = safe_assign(
        component,
        "AdditionalEnemyInflictDamageRate",
        balance.damageMultiplier
    )
    local capture_ok = safe_invoke(
        individual,
        "SetUncapturable",
        false
    )
    local hp_read = tonumber(safe_property(
        component,
        "AdditionalEnemyMaxHPRate"
    ))
    local damage_read = tonumber(safe_property(
        component,
        "AdditionalEnemyInflictDamageRate"
    ))
    local uncapturable = safe_call(individual, "IsUncapturable")
    local override_level = tonumber((safe_call(
        individual,
        "GetOverrideLevel"
    )))
    local effective_level = tonumber((safe_call(individual, "GetLevel")))
    local override_enabled = safe_call(individual, "IsOverrideLevel")
    local level_readback = override_enabled == true
        and override_level == balance.level
        and (effective_level == nil or effective_level == balance.level)
    local verified = level_ok and level_readback
        and hp_ok and damage_ok and capture_ok
        and hp_read ~= nil
        and math.abs(hp_read - balance.healthMultiplier) < 0.001
        and damage_read ~= nil
        and math.abs(damage_read - balance.damageMultiplier) < 0.001
        and uncapturable == false
    return verified, verified and "raid-slab-runtime-readback"
        or string.format(
            "raid-slab-runtime-readback-failed:override=%s effective=%s enabled=%s hp=%s damage=%s capturable=%s",
            tostring(override_level),
            tostring(effective_level),
            tostring(override_enabled),
            tostring(hp_read),
            tostring(damage_read),
            tostring(uncapturable == false)
        )
end

function UniquePalBossNativeProduction:_resolve_spawn(record)
    if record.worldGeneration ~= self.worldGeneration
        or record.status == "captured"
        or record.status == "defeated"
        or record.status == "cleaned" then
        return result(false, "native-unique-pal-boss-record-stale")
    end
    local actor, actor_error
    if type(self.adapters.resolveActor) == "function" then
        local ok, value, detail = pcall(
            self.adapters.resolveActor,
            record.handle,
            record.binding
        )
        actor = ok and value or nil
        actor_error = ok and detail or value
    else
        actor, actor_error = safe_call(
            record.handle,
            "TryGetIndividualActor"
        )
    end
    if not is_valid_object(actor) then
        return result(false,
            "native-unique-pal-boss-actor-not-ready:"
                .. tostring(actor_error), {
            retryable = true,
        })
    end
    local actor_name = safe_full_name(actor)
    if string.find(
        actor_name,
        record.binding.expectedActorClassToken,
        1,
        true
    ) == nil then
        self.rejectionCount = self.rejectionCount + 1
        self.lastError = "native-unique-pal-boss-class-mismatch"
        safe_call(actor, "K2_DestroyActor")
        self.pendingSpawnRecords[record.requestId] = nil
        self.authorizedActorNames[actor_name] = nil
        record.status = "rejected"
        return result(false, self.lastError, {
            actorName = actor_name,
            expectedClass = record.binding.expectedActorClassKey,
        })
    end
    local applied, balance_reason = self:_apply_balance(record, actor)
    if not applied then
        self.lastError = balance_reason
        safe_call(actor, "K2_DestroyActor")
        self.pendingSpawnRecords[record.requestId] = nil
        self.authorizedActorNames[actor_name] = nil
        record.status = "rejected"
        return result(false, balance_reason)
    end
    local native_key = individual_key(record.handle)
    record.actor = actor
    record.actorName = actor_name
    record.actorBindingId = table.concat({
        "pwft.actor",
        record.binding.uniquePalId,
        tostring(native_key or record.payload.eventId),
    }, ".")
    record.status = "spawn-resolved"
    self.pendingSpawnRecords[record.requestId] = nil
    self.authorizedActorNames[actor_name] = record.binding.uniquePalId
    self.recordsByActorName[actor_name] = record
    local logical_tick = self:_campaign_tick()
    local confirmed = self.bus:confirm_spawn(
        self:_callback(record, "spawn", logical_tick)
    )
    if confirmed.ok then
        record.status = "open"
        self.spawnConfirmedCount = self.spawnConfirmedCount + 1
        local strategic_binding_ok = true
        if self.strategicWorldNativeProduction ~= nil then
            local strategic_bound =
                self.strategicWorldNativeProduction
                    :bind_unique_pal_actor(
                        record.binding.uniquePalId,
                        record.actorBindingId,
                        record.binding.expectedActorClassKey
                    )
            record.strategicNativeBinding = strategic_bound
            if not strategic_bound.ok then
                strategic_binding_ok = false
                self.lastError = strategic_bound.reason
                self:_log(string.format(
                    "STRATEGIC_BIND_DEFERRED uniquePal=%s reason=%s",
                    record.binding.uniquePalId,
                    tostring(strategic_bound.reason)
                ))
            end
        end
        if strategic_binding_ok then self.lastError = nil end
        self:_log(string.format(
            "SPAWN_CONFIRMED uniquePal=%s actor=%s actorBinding=%s level=%d hp=%.3f damage=%.3f capture=true event=%s",
            record.binding.uniquePalId,
            actor_name,
            record.actorBindingId,
            record.binding.balance.level,
            record.binding.balance.healthMultiplier,
            record.binding.balance.damageMultiplier,
            record.payload.eventId
        ))
    else
        self.lastError = confirmed.reason
        safe_call(actor, "K2_DestroyActor")
        self.authorizedActorNames[actor_name] = nil
        record.status = "rejected"
    end
    return confirmed
end

function UniquePalBossNativeProduction:_queue_spawn_resolution(record)
    local generation = self.schedulerGeneration
    for _, delay_ms in ipairs(self.spawnResolveDelaysMs) do
        local callback = function()
            if generation ~= self.schedulerGeneration
                or record.status == "open"
                or record.status == "rejected" then
                return
            end
            self:_run(function()
                local resolved = self:_resolve_spawn(record)
                if not resolved.ok and resolved.retryable ~= true then
                    self:_log("SPAWN_RESOLVE_FAILED reason="
                        .. tostring(resolved.reason))
                end
            end)
        end
        self:_schedule(delay_ms, callback)
    end
end

function UniquePalBossNativeProduction:_cleanup_record(record, source)
    if record == nil or record.status == "cleaned"
        or record.status == "captured"
        or record.status == "defeated" then
        return false
    end
    local actor = record.actor
    if not is_valid_object(actor) and is_valid_object(record.handle) then
        actor = safe_call(record.handle, "TryGetIndividualActor")
    end
    local destroyed = false
    if is_valid_object(actor) then
        destroyed = safe_invoke(actor, "K2_DestroyActor")
    end
    if record.actorName ~= nil then
        self.recordsByActorName[record.actorName] = nil
        self.authorizedActorNames[record.actorName] = nil
    end
    if record.requestId ~= nil then
        self.pendingSpawnRecords[record.requestId] = nil
    end
    if self.strategicWorldNativeProduction ~= nil then
        pcall(
            self.strategicWorldNativeProduction
                .unbind_unique_pal_actor,
            self.strategicWorldNativeProduction,
            record.binding.uniquePalId
        )
    end
    record.actor = nil
    record.handle = nil
    record.status = "cleaned"
    self.cleanupCount = self.cleanupCount + 1
    self:_log(string.format(
        "BOSS_CLEANUP uniquePal=%s source=%s destroyed=%s",
        record.binding.uniquePalId,
        tostring(source),
        tostring(destroyed)
    ))
    return destroyed
end

function UniquePalBossNativeProduction:_handle_delivery(payload, context)
    if self.active ~= true or self.enabled ~= true then
        self:_log("DELIVERY_REJECTED reason=production-inactive delivery="
            .. tostring(payload and payload.deliveryId))
        return result(false,
            "native-unique-pal-boss-production-inactive", {
            deliveryId = payload and payload.deliveryId,
        })
    end
    if type(payload) ~= "table"
        or payload.worldGeneration ~= self.worldGeneration
        or context.worldGeneration ~= self.worldGeneration then
        self:_log(string.format(
            "DELIVERY_REJECTED reason=generation-stale delivery=%s payloadGeneration=%s contextGeneration=%s serviceGeneration=%s",
            tostring(payload and payload.deliveryId),
            tostring(payload and payload.worldGeneration),
            tostring(context and context.worldGeneration),
            tostring(self.worldGeneration)
        ))
        return result(false,
            "native-unique-pal-boss-delivery-generation-stale", {
            deliveryId = payload and payload.deliveryId,
        })
    end
    local binding = self:_binding(payload.uniquePalId)
    if binding == nil
        or binding.bindingId ~= context.bindingId
        or payload.speciesId ~= binding.speciesId
        or payload.bossSpawnerKey ~= binding.bossSpawnerKey then
        self:_log("DELIVERY_REJECTED reason=binding-rejected delivery="
            .. tostring(payload.deliveryId))
        return result(false,
            "native-unique-pal-boss-delivery-binding-rejected", {
            deliveryId = payload.deliveryId,
        })
    end
    if payload.deliveryKind == "announce" then
        self:_notify(string.format(
            "唯一帕鲁【%s】即将开放，请准备迎战。",
            binding.displayNameZhHans
        ), "announce")
        return result(true, "native-unique-pal-boss-announced", {
            applied = true,
            deliveryId = payload.deliveryId,
        })
    end
    if payload.deliveryKind == "spawn" then
        local existing = self.recordsByUniquePalId[payload.uniquePalId]
        if existing ~= nil and existing.payload.deliveryId
                == payload.deliveryId then
            return result(true,
                "native-unique-pal-boss-spawn-already-accepted", {
                accepted = true,
                deliveryId = payload.deliveryId,
                requestId = existing.requestId,
                idempotent = true,
            })
        end
        if existing ~= nil then
            self:_cleanup_record(existing, "superseded-opening")
        end
        local record = {
            binding = binding,
            payload = copy(payload),
            worldGeneration = self.worldGeneration,
            requestId = "pwft.native-boss-request."
                .. payload.eventId,
            status = "requesting",
        }
        local spawned = self:_spawn_record(record)
        if not spawned.ok then
            self.lastError = spawned.reason
            self:_log(string.format(
                "SPAWN_REQUEST_DEFERRED uniquePal=%s delivery=%s reason=%s retryable=%s generation=%d",
                tostring(payload.uniquePalId),
                tostring(payload.deliveryId),
                tostring(spawned.reason),
                tostring(spawned.retryable == true),
                self.worldGeneration
            ))
            if spawned.retryable == true then
                self:_queue_spawn_delivery_retries(
                    payload,
                    spawned.reason
                )
            end
            return result(false, spawned.reason, {
                deliveryId = payload.deliveryId,
                retryable = spawned.retryable,
            })
        end
        self.spawnRetryTokenByDeliveryId[payload.deliveryId] = nil
        self.recordsByUniquePalId[payload.uniquePalId] = record
        self:_queue_spawn_resolution(record)
        return result(true, "native-unique-pal-boss-spawn-requested", {
            accepted = true,
            deliveryId = payload.deliveryId,
            requestId = record.requestId,
        })
    end
    if payload.deliveryKind == "open" then
        self:_notify(string.format(
            "唯一帕鲁【%s】已经出现，可在开放时间内挑战并捕获。",
            binding.displayNameZhHans
        ), "open")
        return result(true, "native-unique-pal-boss-open-presented", {
            applied = true,
            deliveryId = payload.deliveryId,
        })
    end
    if payload.deliveryKind == "close" then
        local record = self.recordsByUniquePalId[payload.uniquePalId]
        if record ~= nil
            and record.payload.eventId == payload.eventId then
            self:_cleanup_record(record, payload.eventType or "close")
        end
        self:_notify(string.format(
            "唯一帕鲁【%s】本轮开放已经结束。",
            binding.displayNameZhHans
        ), "close")
        return result(true, "native-unique-pal-boss-closed", {
            applied = true,
            deliveryId = payload.deliveryId,
        })
    end
    if payload.deliveryKind == "cooldown" then
        return result(true, "native-unique-pal-boss-cooldown-recorded", {
            applied = true,
            deliveryId = payload.deliveryId,
        })
    end
    return result(false,
        "native-unique-pal-boss-delivery-kind-unsupported", {
        deliveryId = payload.deliveryId,
    })
end

function UniquePalBossNativeProduction:_record_for_actor(actor)
    if not is_valid_object(actor) then return nil end
    local name = safe_full_name(actor)
    local direct = self.recordsByActorName[name]
    if direct ~= nil and same_object(direct.actor, actor) then
        return direct
    end
    for _, record in pairs(self.recordsByUniquePalId) do
        if same_object(record.actor, actor) then return record end
    end
    return nil
end

function UniquePalBossNativeProduction:observe_capture(actor)
    local record = self:_record_for_actor(actor)
    if record == nil or record.status ~= "open" then
        return result(false,
            "capture-not-from-active-unique-pal-boss")
    end
    local confirmed = self.bus:confirm_capture(
        self:_callback(record, "capture", self:_campaign_tick())
    )
    if confirmed.ok then
        if self.strategicWorldNativeProduction ~= nil then
            pcall(
                self.strategicWorldNativeProduction
                    .unbind_unique_pal_actor,
                self.strategicWorldNativeProduction,
                record.binding.uniquePalId
            )
        end
        record.status = "captured"
        record.actor = nil
        record.handle = nil
        if record.actorName ~= nil then
            self.recordsByActorName[record.actorName] = nil
            self.authorizedActorNames[record.actorName] = nil
        end
        self.captureConfirmedCount =
            self.captureConfirmedCount + 1
        self:_notify(string.format(
            "你已捕获唯一帕鲁【%s】。",
            record.binding.displayNameZhHans
        ), "captured")
        self:_log(string.format(
            "CAPTURE_CONFIRMED uniquePal=%s actorBinding=%s event=%s",
            record.binding.uniquePalId,
            record.actorBindingId,
            record.payload.eventId
        ))
    else
        self.lastError = confirmed.reason
    end
    return confirmed
end

function UniquePalBossNativeProduction:observe_death(actor)
    local record = self:_record_for_actor(actor)
    if record == nil or record.status ~= "open" then
        return result(false,
            "death-not-from-active-unique-pal-boss")
    end
    local confirmed = self.bus:confirm_defeat(
        self:_callback(record, "defeat", self:_campaign_tick())
    )
    if confirmed.ok then
        if self.strategicWorldNativeProduction ~= nil then
            pcall(
                self.strategicWorldNativeProduction
                    .unbind_unique_pal_actor,
                self.strategicWorldNativeProduction,
                record.binding.uniquePalId
            )
        end
        record.status = "defeated"
        record.actor = nil
        record.handle = nil
        if record.actorName ~= nil then
            self.recordsByActorName[record.actorName] = nil
            self.authorizedActorNames[record.actorName] = nil
        end
        self.defeatConfirmedCount = self.defeatConfirmedCount + 1
        self:_notify(string.format(
            "唯一帕鲁【%s】已被击败，但归属没有转移。",
            record.binding.displayNameZhHans
        ), "defeated")
        self:_log(string.format(
            "DEFEAT_CONFIRMED uniquePal=%s actorBinding=%s event=%s",
            record.binding.uniquePalId,
            record.actorBindingId,
            record.payload.eventId
        ))
    else
        self.lastError = confirmed.reason
    end
    return confirmed
end

function UniquePalBossNativeProduction:_pending_authorization(
    actor,
    character_id
)
    local actor_name = safe_full_name(actor)
    local authorized = self.authorizedActorNames[actor_name]
    if authorized ~= nil then return authorized, "recorded-actor" end
    for _, record in pairs(self.pendingSpawnRecords) do
        local binding = record.binding
        if binding ~= nil
            and string.find(
                actor_name,
                binding.expectedActorClassToken,
                1,
                true
            ) ~= nil then
            self.authorizedActorNames[actor_name] = binding.uniquePalId
            record.pendingActorName = actor_name
            return binding.uniquePalId,
                "pending-exact-request-class-authorized"
        end
    end
    for unique_pal_id, record in pairs(self.recordsByUniquePalId) do
        if record.status ~= "cleaned"
            and record.status ~= "captured"
            and record.status ~= "defeated"
            and same_object(record.actor, actor) then
            self.authorizedActorNames[actor_name] = unique_pal_id
            return unique_pal_id, "resolved-exact-record"
        end
    end
    return nil, "not-authorized"
end

function UniquePalBossNativeProduction:observe_initialized_character(
    actor,
    hinted_component,
    attempt
)
    attempt = tonumber(attempt) or 1
    local character_id, _, is_boss, classification = boss_identity(
        actor,
        hinted_component
    )
    if character_id == nil or classification == "boss-parameter-not-ready" then
        if attempt < 3 and is_valid_object(actor) then
            self.bossSuppressionDeferredCount =
                self.bossSuppressionDeferredCount + 1
            self:_schedule(attempt == 1 and 100 or 500, function()
                self:_run(function()
                    self:observe_initialized_character(
                        actor,
                        hinted_component,
                        attempt + 1
                    )
                end)
            end)
        end
        return result(true, "boss-suppression-inspection-deferred", {
            ignored = true,
            attempt = attempt,
        })
    end
    if is_boss ~= true then
        return result(true, "non-boss-character-ignored", {
            ignored = true,
            characterId = character_id,
        })
    end
    local unique_pal_id, authorization = self:_pending_authorization(
        actor,
        character_id
    )
    if unique_pal_id ~= nil then
        self.allowedUniqueBossCount = self.allowedUniqueBossCount + 1
        self:_log(string.format(
            "BOSS_ALLOWED uniquePal=%s character=%s actor=%s authorization=%s",
            unique_pal_id,
            character_id,
            safe_full_name(actor),
            authorization
        ))
        return result(true, "active-unique-pal-boss-allowed", {
            uniquePalId = unique_pal_id,
            characterId = character_id,
            actorName = safe_full_name(actor),
        })
    end
    local actor_name = safe_full_name(actor)
    local destroyed = safe_invoke(actor, "K2_DestroyActor")
    if destroyed then
        self.suppressedBossCount = self.suppressedBossCount + 1
        self:_log(string.format(
            "BOSS_SUPPRESSED character=%s actor=%s reason=not-active-unique-pal broadScan=false",
            character_id,
            actor_name
        ))
        return result(true, "non-unique-pal-boss-destroyed", {
            suppressed = true,
            characterId = character_id,
        })
    end
    self.rejectionCount = self.rejectionCount + 1
    self.lastError = "non-unique-pal-boss-destroy-failed"
    return result(false, self.lastError, {
        characterId = character_id,
        actorName = actor_name,
    })
end

function UniquePalBossNativeProduction:weaken_active(unique_pal_id)
    local record = self.recordsByUniquePalId[unique_pal_id]
    if record == nil or record.status ~= "open"
        or not is_valid_object(record.actor) then
        return result(false, "active-unique-pal-boss-unavailable")
    end
    if type(self.adapters.weakenBoss) == "function" then
        local ok, weakened, detail = pcall(
            self.adapters.weakenBoss,
            record.actor,
            record.binding
        )
        if not ok or weakened ~= true then
            return result(false, "native-unique-pal-boss-weaken-failed", {
                detail = tostring(detail or weakened),
            })
        end
        return result(true, "native-unique-pal-boss-weakened-for-death-hook", {
            qaOnly = true,
            currentHp = 1,
        })
    end
    local component = character_component(record.actor)
    local finder = self.adapters.staticFindObject or _G.StaticFindObject
    if not is_valid_object(component) or type(finder) ~= "function" then
        return result(false, "native-unique-pal-boss-weaken-context-unavailable")
    end
    local ok, fixed_math = pcall(
        finder,
        "/Script/Pal.Default__FixedPoint64MathLibrary"
    )
    if not ok or not is_valid_object(fixed_math) then
        return result(false, "fixed-point-math-library-unavailable")
    end
    local one = safe_call(fixed_math, "Convert_IntToFixedPoint64", 1)
    if one == nil then return result(false, "fixed-point-one-unavailable") end
    local set_ok, set_detail = safe_invoke(component, "SetHP", one)
    local hp = safe_call(component, "GetHP")
    local hp_int = hp ~= nil and safe_call(
        fixed_math,
        "Convert_FixedPoint64ToInt",
        hp
    ) or nil
    local verified = set_ok and tonumber(hp_int) == 1
    self:_log(string.format(
        "BOSS_WEAKEN uniquePal=%s actor=%s set=%s hp=%s qaOnly=true deathHookStillRequired=true",
        unique_pal_id,
        safe_full_name(record.actor),
        tostring(set_ok),
        tostring(hp_int)
    ))
    return result(verified, verified
            and "native-unique-pal-boss-weakened-for-death-hook"
        or "native-unique-pal-boss-weaken-readback-failed", {
        qaOnly = true,
        currentHp = tonumber(hp_int),
        setDetail = set_detail,
    })
end

function UniquePalBossNativeProduction:spawn_suppression_probe(character_id)
    character_id = require_text(character_id, "suppression probe character ID")
    local context, context_error = self:_resolve_context()
    if context == nil then return result(false, context_error) end
    local location = context.location
    local handle, spawn_error = safe_call(
        context.manager,
        "SpawnNPCForServer",
        {
            ControllerClass = context.controllerClass,
            CharacterID = make_name(self.adapters, character_id),
            Level = 1,
            Location = {
                X = (tonumber(safe_property(location, "X")) or 0) + 900,
                Y = (tonumber(safe_property(location, "Y")) or 0) + 500,
                Z = (tonumber(safe_property(location, "Z")) or 0) + 80,
            },
            Yaw = 0,
            Squad = nil,
        },
        nil
    )
    if not is_valid_object(handle) then
        return result(false, "boss-suppression-probe-spawn-failed:" .. tostring(spawn_error))
    end
    self.suppressionProbeCount = self.suppressionProbeCount + 1
    local suppressed_before = self.suppressedBossCount
    local completed = false
    for index, delay_ms in ipairs(self.spawnResolveDelaysMs) do
        self:_schedule(delay_ms, function()
            self:_run(function()
                if completed then return end
                local actor = safe_call(handle, "TryGetIndividualActor")
                local observed = nil
                if is_valid_object(actor) then
                    observed = self:observe_initialized_character(actor)
                end
                local valid_after = is_valid_object(actor)
                local passed = not valid_after
                    and self.suppressedBossCount > suppressed_before
                if passed then
                    completed = true
                    self.suppressionProbePassCount =
                        self.suppressionProbePassCount + 1
                end
                self:_log(string.format(
                    "BOSS_SUPPRESSION_PROBE character=%s attempt=%d ok=%s reason=%s actorValidAfter=%s suppressedDelta=%d broadScan=false",
                    character_id,
                    index,
                    tostring(passed),
                    tostring(observed and observed.reason or "actor-unavailable"),
                    tostring(valid_after),
                    self.suppressedBossCount - suppressed_before
                ))
            end)
        end)
    end
    return result(true, "boss-suppression-probe-requested", {
        characterId = character_id,
        qaOnly = true,
    })
end

function UniquePalBossNativeProduction:_register_hooks()
    if self.hooksRegistered then
        return result(true, "native-unique-pal-boss-hooks-already-ready")
    end
    local register = self.adapters.registerHook or _G.RegisterHook
    if type(register) ~= "function" then
        return result(false, "RegisterHook-unavailable")
    end
    local capture_pre = function()
        -- Confirmation belongs to the native post callback.
    end
    local capture_post = function(_, _, actor_parameter)
        local actor = hook_value(actor_parameter)
        if is_valid_object(actor) then
            self:observe_capture(actor)
        end
    end
    local death_callback = function(context, dead_info_parameter)
        local dead_info = hook_value(dead_info_parameter)
        local actor = safe_property(dead_info, "SelfActor")
        if not is_valid_object(actor) then actor = hook_value(context) end
        if is_valid_object(actor) then self:observe_death(actor) end
    end
    local character_ready_callback = function(context, owner_character)
        local component = hook_value(context)
        local actor = actor_from_component(
            component,
            hook_value(owner_character)
        )
        if is_valid_object(actor) then
            self:observe_initialized_character(actor, component)
        end
    end
    local capture_ok, capture_first, capture_second = pcall(
        register,
        CAPTURE_HOOK,
        capture_pre,
        capture_post
    )
    if capture_ok then
        self.hookRecords[CAPTURE_HOOK] = {
            firstId = capture_first,
            secondId = capture_second,
            pre = capture_pre,
            post = capture_post,
        }
    end
    local death_ok, death_first, death_second = pcall(
        register,
        DEATH_HOOK,
        death_callback
    )
    if death_ok then
        self.hookRecords[DEATH_HOOK] = {
            firstId = death_first,
            secondId = death_second,
            callback = death_callback,
        }
    end
    local ready_ok, ready_first, ready_second = pcall(
        register,
        CHARACTER_READY_HOOK,
        character_ready_callback
    )
    if ready_ok then
        self.hookRecords[CHARACTER_READY_HOOK] = {
            firstId = ready_first,
            secondId = ready_second,
            callback = character_ready_callback,
        }
    end
    self.hooksRegistered = capture_ok and death_ok and ready_ok
    self:_log(string.format(
        "HOOK_REGISTRATION capture=%s death=%s bossSuppression=%s",
        tostring(capture_ok),
        tostring(death_ok),
        tostring(ready_ok)
    ))
    return result(self.hooksRegistered,
        self.hooksRegistered
                and "native-unique-pal-boss-hooks-ready"
            or "native-unique-pal-boss-hook-registration-incomplete", {
        captureReady = capture_ok,
        deathReady = death_ok,
        bossSuppressionReady = ready_ok,
    })
end

function UniquePalBossNativeProduction:_schedule_next_pulse()
    if self.active ~= true or self.automaticSchedulerEnabled ~= true then
        return false
    end
    local generation = self.schedulerGeneration
    return self:_schedule(self.tickIntervalMs, function()
        if self.active ~= true
            or generation ~= self.schedulerGeneration then
            return
        end
        self:_run(function() self:pulse("automatic") end)
    end)
end

function UniquePalBossNativeProduction:activate(definitions)
    if self.enabled ~= true then
        return result(false,
            "native-unique-pal-boss-production-disabled")
    end
    assert(type(definitions) == "table"
            and type(definitions.bindings) == "table"
            and #definitions.bindings > 0,
        "native unique-Pal Boss production bindings are required")
    local bus_status = self.bus:status()
    self.worldGeneration = bus_status.worldGeneration
    self.schedulerGeneration = self.schedulerGeneration + 1
    self.bindingsByUniquePalId = {}
    self.recordsByUniquePalId = {}
    self.recordsByActorName = {}
    self.pendingSpawnRecords = {}
    self.authorizedActorNames = {}
    self.spawnRetryTokenByDeliveryId = {}
    -- The bus may retry a restored activation-pending delivery while each
    -- binding is registered. Mark the provider active before registration so
    -- that generation rebinds cannot reject their own pending delivery.
    self.active = true
    local registered = self.bus:register_provider({
        providerId = self.providerId,
        authoritySource = self.authoritySource,
        deliveryKinds = {
            "announce", "spawn", "open", "close", "cooldown",
        },
        idempotentDeliveryIds = true,
        generationFencedCallbacks = true,
        enabled = true,
    }, function(payload, context)
        return self:_handle_delivery(payload, context)
    end)
    if not registered.ok then
        self.active = false
        self.lastError = registered.reason
        return registered
    end
    local bound = 0
    for _, definition in ipairs(definitions.bindings) do
        local binding = normalize_binding(definition, self.buildId)
        assert(binding.providerId == self.providerId,
            "native unique-Pal Boss provider ID mismatch")
        local activated = self.bus:bind(binding)
        if not activated.ok then
            self.active = false
            self.lastError = activated.reason
            return result(false,
                "native-unique-pal-boss-binding-failed", {
                uniquePalId = binding.uniquePalId,
                bindingReason = activated.reason,
            })
        end
        self.bindingsByUniquePalId[binding.uniquePalId] = binding
        bound = bound + 1
    end
    local hooks = self:_register_hooks()
    if not hooks.ok then
        self.active = false
        self.lastError = hooks.reason
        return hooks
    end
    self.activationCount = self.activationCount + 1
    self.bus:retry_pending()
    for _, unique_pal_id in ipairs(self:_sorted_binding_ids()) do
        self:_schedule_closed(unique_pal_id)
    end
    self:_schedule_next_pulse()
    self.lastError = nil
    self:_log(string.format(
        "ACTIVATED bindings=%d generation=%d scheduler=%s tickMs=%d",
        bound,
        self.worldGeneration,
        tostring(self.automaticSchedulerEnabled),
        self.tickIntervalMs
    ))
    return result(true,
        "native-unique-pal-boss-production-activated", {
        bindingCount = bound,
        worldGeneration = self.worldGeneration,
        automaticSchedulerEnabled = self.automaticSchedulerEnabled,
        storyContentIncluded = false,
    })
end

function UniquePalBossNativeProduction:pulse(source)
    if self.active ~= true then
        return result(false,
            "native-unique-pal-boss-production-inactive")
    end
    self.schedulerPulseCount = self.schedulerPulseCount + 1
    local next_tick = self:_campaign_tick() + 1
    local timeout_record = nil
    for unique_pal_id, record in pairs(self.recordsByUniquePalId) do
        local status = self.campaign:campaign_status(unique_pal_id)
        if status ~= nil and status.phase == "open"
            and tonumber(status.closeTick) ~= nil
            and next_tick >= status.closeTick
            and record.status == "open" then
            timeout_record = record
            break
        end
    end
    if timeout_record ~= nil then
        local timed_out = self.bus:confirm_timeout(
            self:_callback(timeout_record, "timeout", next_tick)
        )
        if timed_out.ok then
            self.timeoutConfirmedCount =
                self.timeoutConfirmedCount + 1
        else
            self.lastError = timed_out.reason
        end
    end
    local current = self:_campaign_tick()
    if current < next_tick then
        local advanced = self.campaign:advance(
            next_tick,
            "pwft.production.advance."
                .. tostring(next_tick)
        )
        if not advanced.ok then
            self.lastError = advanced.reason
            return advanced
        end
    end
    self.bus:retry_pending()
    for _, unique_pal_id in ipairs(self:_sorted_binding_ids()) do
        self:_schedule_closed(unique_pal_id)
    end
    self:_log(string.format(
        "PULSE source=%s tick=%d generation=%d",
        tostring(source or "manual"),
        self:_campaign_tick(),
        self.worldGeneration
    ))
    self:_schedule_next_pulse()
    return result(true, "native-unique-pal-boss-production-pulsed", {
        logicalTick = self:_campaign_tick(),
    })
end

function UniquePalBossNativeProduction:force_open(unique_pal_id)
    stable_id(unique_pal_id, "forced unique-Pal ID")
    if self.active ~= true
        or self.bindingsByUniquePalId[unique_pal_id] == nil then
        return result(false,
            "forced-unique-pal-boss-binding-unavailable")
    end
    local status = self.campaign:campaign_status(unique_pal_id)
    if status.phase == "closed" then
        local active_unique_pal_id = self:_active_window()
        if active_unique_pal_id ~= nil
            and active_unique_pal_id ~= unique_pal_id then
            return result(false,
                "another-unique-pal-window-already-active", {
                activeUniquePalId = active_unique_pal_id,
            })
        end
        local scheduled = self:_schedule_closed(unique_pal_id)
        if not scheduled.ok then return scheduled end
        status = self.campaign:campaign_status(unique_pal_id)
    end
    if status.phase == "scheduled" then
        local announced = self.campaign:advance(
            status.noticeTick,
            "pwft.production.force-announce."
                .. status.eventId
        )
        if not announced.ok then return announced end
        status = self.campaign:campaign_status(unique_pal_id)
    end
    if status.phase == "announced" then
        local opened = self.campaign:advance(
            status.openTick,
            "pwft.production.force-open."
                .. status.eventId
        )
        if not opened.ok then return opened end
        self.bus:retry_pending(unique_pal_id)
    end
    status = self.campaign:campaign_status(unique_pal_id)
    if status.phase == "activation-pending" then
        local retried = self.bus:retry_pending(unique_pal_id)
        if self.recordsByUniquePalId[unique_pal_id] == nil then
            local delivery_id = "unique-pal-native."
                .. tostring(status.eventId) .. ".spawn"
            self:_queue_spawn_delivery_retries({
                deliveryId = delivery_id,
                uniquePalId = unique_pal_id,
            }, retried.reason)
        end
    end
    return result(true, "native-unique-pal-boss-force-open-requested", {
        uniquePalId = unique_pal_id,
        campaign = self.campaign:campaign_status(unique_pal_id),
    })
end

function UniquePalBossNativeProduction:capture_active(unique_pal_id)
    local record = self.recordsByUniquePalId[unique_pal_id]
    local campaign_status = self.campaign:campaign_status(unique_pal_id)
    -- UE4SS shares its delayed-callback dispatcher across Mods.  If an
    -- unrelated callback fails after SpawnNPCForServer accepted our request,
    -- the normal resolution retry can be lost even though the native actor is
    -- already ready.  Player/QA actions are authoritative game-thread entry
    -- points, so opportunistically complete that pending readback here.
    if record ~= nil and record.status ~= "open"
        and campaign_status ~= nil
        and campaign_status.phase == "activation-pending" then
        local resolved = self:_resolve_spawn(record)
        if not resolved.ok then return resolved end
    end
    if record == nil or record.status ~= "open"
        or not is_valid_object(record.actor) then
        return result(false, "active-unique-pal-boss-unavailable")
    end
    if type(self.adapters.captureBoss) == "function" then
        local ok, accepted = pcall(
            self.adapters.captureBoss,
            record.actor,
            record.binding
        )
        if not ok or accepted == false then
            return result(false, "native-unique-pal-boss-capture-failed")
        end
        return self:observe_capture(record.actor)
    end
    local controller = local_controller(self.adapters)
    local player = controller and player_character(controller) or nil
    local utility = pal_utility(self.adapters)
    if not is_valid_object(player) or not is_valid_object(utility) then
        return result(false, "native-capture-context-unavailable")
    end
    local _, capture_error = safe_call(
        utility,
        "PalCaptureSuccess",
        player,
        record.actor
    )
    if capture_error ~= nil then
        return result(false,
            "native-unique-pal-boss-capture-call-failed:"
                .. tostring(capture_error))
    end
    return result(true,
        "native-unique-pal-boss-capture-call-accepted", {
        authoritativePostHookRequired = true,
    })
end

function UniquePalBossNativeProduction:force_timeout(unique_pal_id)
    local record = self.recordsByUniquePalId[unique_pal_id]
    local status = self.campaign:campaign_status(unique_pal_id)
    if record ~= nil and record.status ~= "open"
        and status ~= nil and status.phase == "activation-pending" then
        local resolved = self:_resolve_spawn(record)
        if not resolved.ok then return resolved end
        status = self.campaign:campaign_status(unique_pal_id)
    end
    if record == nil or record.status ~= "open"
        or status == nil or status.phase ~= "open" then
        return result(false, "active-unique-pal-boss-unavailable")
    end
    local timed_out = self.bus:confirm_timeout(
        self:_callback(record, "timeout", status.closeTick)
    )
    if timed_out.ok then
        self.timeoutConfirmedCount = self.timeoutConfirmedCount + 1
    end
    return timed_out
end

function UniquePalBossNativeProduction:unbind_world(reason)
    self.active = false
    self.schedulerGeneration = self.schedulerGeneration + 1
    local cleaned = 0
    for _, record in pairs(self.recordsByUniquePalId) do
        if self:_cleanup_record(record, reason or "world-unload") then
            cleaned = cleaned + 1
        end
    end
    self.recordsByUniquePalId = {}
    self.recordsByActorName = {}
    self.pendingSpawnRecords = {}
    self.authorizedActorNames = {}
    self.bindingsByUniquePalId = {}
    self.spawnRetryTokenByDeliveryId = {}
    if self.strategicWorldNativeProduction ~= nil then
        self.strategicWorldNativeProduction:unbind_world(
            reason or "world-unload"
        )
    end
    self.worldGeneration = self.bus:status().worldGeneration
    return result(true,
        "native-unique-pal-boss-production-world-unbound", {
        cleanedCount = cleaned,
        reason = reason or "world-unload",
    })
end

function UniquePalBossNativeProduction:status()
    local active_records = 0
    for _, record in pairs(self.recordsByUniquePalId) do
        if record.status ~= "cleaned"
            and record.status ~= "captured"
            and record.status ~= "defeated" then
            active_records = active_records + 1
        end
    end
    local binding_count = 0
    for _ in pairs(self.bindingsByUniquePalId) do
        binding_count = binding_count + 1
    end
    local hook_count = 0
    for _ in pairs(self.hookRecords) do hook_count = hook_count + 1 end
    return {
        apiVersion = self.version,
        enabled = self.enabled,
        active = self.active,
        buildId = self.buildId,
        providerId = self.providerId,
        authoritySource = self.authoritySource,
        worldGeneration = self.worldGeneration,
        automaticSchedulerEnabled = self.automaticSchedulerEnabled,
        tickIntervalMs = self.tickIntervalMs,
        bindingCount = binding_count,
        activeRecordCount = active_records,
        hooksRegistered = self.hooksRegistered,
        hookCount = hook_count,
        activationCount = self.activationCount,
        schedulerPulseCount = self.schedulerPulseCount,
        scheduleCount = self.scheduleCount,
        spawnRequestCount = self.spawnRequestCount,
        spawnConfirmedCount = self.spawnConfirmedCount,
        spawnRetryScheduledCount = self.spawnRetryScheduledCount,
        spawnRetryAttemptCount = self.spawnRetryAttemptCount,
        captureConfirmedCount = self.captureConfirmedCount,
        defeatConfirmedCount = self.defeatConfirmedCount,
        timeoutConfirmedCount = self.timeoutConfirmedCount,
        suppressedBossCount = self.suppressedBossCount,
        allowedUniqueBossCount = self.allowedUniqueBossCount,
        bossSuppressionDeferredCount = self.bossSuppressionDeferredCount,
        suppressionProbeCount = self.suppressionProbeCount,
        suppressionProbePassCount = self.suppressionProbePassCount,
        cleanupCount = self.cleanupCount,
        notificationCount = self.notificationCount,
        notificationFailureCount = self.notificationFailureCount,
        rejectionCount = self.rejectionCount,
        lastError = self.lastError,
        nativeSpawnRoute = "PalNPCManager.SpawnNPCForServer",
        nativeBossSuppressionRoute = CHARACTER_READY_HOOK,
        onlyActiveUniqueBossesAllowed = true,
        exactActorCallbacks = true,
        broadActorScan = false,
        storyContentIncluded = false,
        directContainerMutation = false,
        PalworldSaveMutation = false,
    }
end

return UniquePalBossNativeProduction
