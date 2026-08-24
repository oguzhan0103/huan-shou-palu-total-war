local FactionNpcAttitudeNativeProduction = {}

local API_VERSION = "1.0.0"

local function result(ok, reason, extra)
    local output = extra or {}
    output.ok = ok
    output.reason = reason
    return output
end

local function require_text(value, name)
    assert(type(value) == "string" and value ~= "",
        name .. " must be a non-empty string")
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

local function is_valid(object)
    if object == nil then return false end
    local ok, valid = pcall(function()
        if object.IsValid ~= nil then return object:IsValid() end
        return true
    end)
    return ok and valid ~= false
end

local function safe_call(object, method_name, ...)
    if not is_valid(object) then return nil, "object-unavailable" end
    local arguments = table.pack(...)
    local ok, value = pcall(function()
        local method = object[method_name]
        if method == nil then error("method-unavailable") end
        return method(object, table.unpack(arguments, 1, arguments.n))
    end)
    if not ok then return nil, tostring(value) end
    return unwrap(value), nil
end

local function safe_full_name(object)
    local value = safe_call(object, "GetFullName")
    return value ~= nil and tostring(value) or nil
end

local function default_actor_class_key(actor)
    local class = safe_call(actor, "GetClass")
    local class_name = class and safe_full_name(class) or nil
    if class_name ~= nil then return class_name end
    local actor_name = safe_full_name(actor)
    if actor_name == nil then return nil end
    return string.match(actor_name, "^([^ ]+)") or actor_name
end

local function default_local_player(adapters)
    if type(adapters.localPlayer) == "function" then
        local ok, player = pcall(adapters.localPlayer)
        if ok and is_valid(player) then return player end
    end
    if _G.UEHelpers ~= nil
        and type(_G.UEHelpers.GetPlayerController) == "function" then
        local ok, controller = pcall(
            _G.UEHelpers.GetPlayerController
        )
        if ok and is_valid(controller) then
            local player = safe_call(
                controller,
                "GetDefaultPlayerCharacter"
            ) or safe_call(controller, "K2_GetPawn")
            if is_valid(player) then return player end
        end
    end
    return nil
end

local function normalize_definition(definition)
    assert(type(definition) == "table",
        "NPC attitude native binding definition is required")
    local tokens = {}
    for _, token in ipairs(definition.allowedActorClassTokens or {}) do
        tokens[#tokens + 1] = require_text(token,
            "NPC attitude allowed actor class token")
    end
    assert(#tokens > 0,
        "NPC attitude allowed actor class tokens are required")
    return {
        bindingId = require_text(definition.bindingId,
            "NPC attitude native binding ID"),
        factionId = require_text(definition.factionId,
            "NPC attitude native faction ID"),
        allowedActorClassTokens = tokens,
        peacefulAiPolicy = definition.peacefulAiPolicy or "preserve",
        actorRole = definition.actorRole or "faction-member",
    }
end

function FactionNpcAttitudeNativeProduction.create(
    bus,
    configuration,
    options
)
    assert(type(bus) == "table"
            and type(bus.register_provider) == "function"
            and type(bus.bind_actor) == "function"
            and type(bus.unbind_actor) == "function"
            and type(bus.refresh) == "function",
        "NPC attitude bus is required")
    configuration = configuration or {}
    options = options or {}
    return setmetatable({
        version = API_VERSION,
        bus = bus,
        providerId = require_text(configuration.providerId,
            "NPC attitude production provider ID"),
        authoritySource = require_text(configuration.authoritySource,
            "NPC attitude production authority source"),
        enabled = configuration.enabled ~= false,
        adapters = options.adapters or {},
        logger = options.logger,
        definitionsById = {},
        bindingsById = {},
        active = false,
        activationCount = 0,
        bindCount = 0,
        unbindCount = 0,
        hostileApplyCount = 0,
        peacefulApplyCount = 0,
        rejectedApplyCount = 0,
        lastError = nil,
    }, { __index = FactionNpcAttitudeNativeProduction })
end

function FactionNpcAttitudeNativeProduction:_log(message)
    if type(self.logger) == "function" then
        pcall(self.logger,
            "[FactionNpcAttitudeNativeProduction] "
                .. tostring(message))
    end
end

function FactionNpcAttitudeNativeProduction:_actor_key(actor)
    if type(self.adapters.actorKey) == "function" then
        local ok, value = pcall(self.adapters.actorKey, actor)
        if ok and type(value) == "string" and value ~= "" then
            return value
        end
    end
    return safe_full_name(actor)
end

function FactionNpcAttitudeNativeProduction:_actor_class_key(actor)
    if type(self.adapters.actorClassKey) == "function" then
        local ok, value = pcall(self.adapters.actorClassKey, actor)
        if ok and type(value) == "string" and value ~= "" then
            return value
        end
    end
    return default_actor_class_key(actor)
end

function FactionNpcAttitudeNativeProduction:_apply_intent(
    intent,
    actor
)
    if type(self.adapters.applyDisposition) == "function" then
        local ok, outcome = pcall(
            self.adapters.applyDisposition,
            intent,
            actor
        )
        if ok and type(outcome) == "table" then return outcome end
        return result(false,
            "native-NPC-attitude-adapter-error", {
            detail = tostring(outcome),
        })
    end
    if not is_valid(actor) then
        self.rejectedApplyCount = self.rejectedApplyCount + 1
        return result(false, "native-NPC-attitude-actor-unavailable")
    end
    local controller = safe_call(actor, "GetController")
    if not is_valid(controller) then
        self.rejectedApplyCount = self.rejectedApplyCount + 1
        return result(false, "native-NPC-attitude-controller-unavailable")
    end
    if intent.disposition == "hostile" then
        local player = default_local_player(self.adapters)
        if not is_valid(player) then
            self.rejectedApplyCount = self.rejectedApplyCount + 1
            return result(false,
                "native-NPC-attitude-local-player-unavailable")
        end
        local _, ai_error = safe_call(controller, "SetActiveAI", true)
        local _, battle_error = safe_call(
            actor,
            "ChangeBattleModeFlag_ToAll",
            true
        )
        local _, target_error = safe_call(
            controller,
            "AddTargetPlayer_ForEnemy",
            player
        )
        if ai_error ~= nil or battle_error ~= nil
            or target_error ~= nil then
            self.rejectedApplyCount = self.rejectedApplyCount + 1
            return result(false,
                "native-NPC-attitude-hostile-route-failed", {
                aiError = ai_error,
                battleError = battle_error,
                targetError = target_error,
            })
        end
        self.hostileApplyCount = self.hostileApplyCount + 1
        return result(true, "native-NPC-attitude-hostile-applied", {
            nativeHandle = actor,
            combatActivated = true,
            playerTargeted = true,
        })
    end

    local record = self.bindingsById[intent.bindingId]
    local peaceful_policy = record
        and record.definition.peacefulAiPolicy or "preserve"
    if peaceful_policy == "suspend" then
        local _, ai_error = safe_call(controller, "SetActiveAI", false)
        local _, battle_error = safe_call(
            actor,
            "ChangeBattleModeFlag_ToAll",
            false
        )
        if ai_error ~= nil or battle_error ~= nil then
            self.rejectedApplyCount = self.rejectedApplyCount + 1
            return result(false,
                "native-NPC-attitude-peaceful-route-failed", {
                aiError = ai_error,
                battleError = battle_error,
            })
        end
    end
    self.peacefulApplyCount = self.peacefulApplyCount + 1
    return result(true, "native-NPC-attitude-peaceful-applied", {
        nativeHandle = actor,
        peacefulAiPolicy = peaceful_policy,
        targetClearPolicy = "exact-actor-respawn-on-hostile-to-peaceful",
    })
end

function FactionNpcAttitudeNativeProduction:activate(definitions)
    if not self.enabled then
        return result(false, "native-NPC-attitude-production-disabled")
    end
    assert(type(definitions) == "table" and #definitions > 0,
        "NPC attitude native definitions are required")
    self.definitionsById = {}
    self.bindingsById = {}
    for _, source in ipairs(definitions) do
        local definition = normalize_definition(source)
        assert(self.definitionsById[definition.bindingId] == nil,
            "duplicate NPC attitude native binding definition")
        self.definitionsById[definition.bindingId] = definition
    end
    local registered = self.bus:register_provider({
        providerId = self.providerId,
        authoritySource = self.authoritySource,
        enabled = true,
        applyIntent = function(intent, actor)
            return self:_apply_intent(intent, actor)
        end,
    })
    if not registered.ok then
        self.lastError = registered.reason
        return registered
    end
    self.active = true
    self.activationCount = self.activationCount + 1
    self.lastError = nil
    return result(true, "native-NPC-attitude-production-activated", {
        providerId = self.providerId,
        definitionCount = #definitions,
        activeBindingCount = 0,
        storyContentIncluded = false,
    })
end

function FactionNpcAttitudeNativeProduction:bind_actor(
    definition_id,
    actor
)
    if not self.active then
        return result(false, "native-NPC-attitude-production-inactive")
    end
    local definition = self.definitionsById[
        require_text(definition_id,
            "NPC attitude native definition ID")
    ]
    if definition == nil then
        return result(false, "native-NPC-attitude-definition-unavailable")
    end
    if not is_valid(actor) then
        return result(false, "native-NPC-attitude-actor-unavailable")
    end
    local actor_key = self:_actor_key(actor)
    local actor_class_key = self:_actor_class_key(actor)
    if type(actor_key) ~= "string" or actor_key == ""
        or type(actor_class_key) ~= "string"
        or actor_class_key == "" then
        return result(false, "native-NPC-attitude-identity-unavailable")
    end
    local class_allowed = false
    for _, token in ipairs(definition.allowedActorClassTokens) do
        if string.find(actor_class_key, token, 1, true) ~= nil
            or string.find(actor_key, token, 1, true) ~= nil then
            class_allowed = true
            break
        end
    end
    if not class_allowed then
        return result(false, "native-NPC-attitude-class-mismatch", {
            actorClassKey = actor_class_key,
        })
    end
    local existing = self.bindingsById[definition.bindingId]
    if existing ~= nil
        and (existing.actorKey ~= actor_key
            or existing.actorClassKey ~= actor_class_key) then
        local unbound = self:unbind_actor(definition.bindingId)
        if not unbound.ok then return unbound end
    end
    local binding = {
        bindingId = definition.bindingId,
        providerId = self.providerId,
        factionId = definition.factionId,
        actorKey = actor_key,
        actorClassKey = actor_class_key,
        actorRef = actor,
    }
    local bound = self.bus:bind_actor(binding)
    if not bound.ok then
        self.lastError = bound.reason
        return bound
    end
    self.bindingsById[definition.bindingId] = {
        definition = definition,
        actorKey = actor_key,
        actorClassKey = actor_class_key,
        actorRef = actor,
    }
    -- Let the progression-backed bus allocate its own monotonic refresh ID.
    -- A production-local sequence would restart after a process restart and
    -- collide with restored idempotency records.
    local refreshed = self.bus:refresh_faction(
        definition.factionId,
        {
            trigger = "actor-loaded",
            force = true,
        }
    )
    if not refreshed.ok then
        self.bus:unbind_actor({
            bindingId = definition.bindingId,
            providerId = self.providerId,
            actorKey = actor_key,
            actorClassKey = actor_class_key,
        })
        self.bindingsById[definition.bindingId] = nil
        self.lastError = refreshed.reason
        return refreshed
    end
    self.bindCount = self.bindCount + 1
    self.lastError = nil
    local disposition = nil
    for _, response in ipairs(refreshed.responses or {}) do
        if response.bindingId == definition.bindingId then
            disposition = response.disposition
            break
        end
    end
    self:_log(string.format(
        "ACTOR_BOUND binding=%s faction=%s actor=%s class=%s disposition=%s",
        definition.bindingId,
        definition.factionId,
        actor_key,
        actor_class_key,
        tostring(disposition)
    ))
    return result(true, "native-NPC-attitude-actor-bound", {
        bindingId = definition.bindingId,
        factionId = definition.factionId,
        actorKey = actor_key,
        actorClassKey = actor_class_key,
        disposition = disposition,
    })
end

function FactionNpcAttitudeNativeProduction:unbind_actor(
    definition_id
)
    require_text(definition_id,
        "NPC attitude native definition ID")
    local record = self.bindingsById[definition_id]
    if record == nil then
        return result(true,
            "native-NPC-attitude-actor-already-unbound")
    end
    local outcome = self.bus:unbind_actor({
        bindingId = definition_id,
        providerId = self.providerId,
        actorKey = record.actorKey,
        actorClassKey = record.actorClassKey,
    })
    if not outcome.ok then return outcome end
    self.bindingsById[definition_id] = nil
    self.unbindCount = self.unbindCount + 1
    return result(true, "native-NPC-attitude-actor-unbound", {
        bindingId = definition_id,
    })
end

function FactionNpcAttitudeNativeProduction:unbind_world(reason)
    self.bindingsById = {}
    self.active = false
    self.lastError = reason or "world-unloading"
    return result(true, "native-NPC-attitude-production-world-unbound")
end

function FactionNpcAttitudeNativeProduction:status()
    local definition_count = 0
    local binding_count = 0
    for _ in pairs(self.definitionsById) do
        definition_count = definition_count + 1
    end
    for _ in pairs(self.bindingsById) do
        binding_count = binding_count + 1
    end
    return {
        apiVersion = self.version,
        enabled = self.enabled,
        active = self.active,
        providerId = self.providerId,
        authoritySource = self.authoritySource,
        definitionCount = definition_count,
        activeBindingCount = binding_count,
        activationCount = self.activationCount,
        bindCount = self.bindCount,
        unbindCount = self.unbindCount,
        hostileApplyCount = self.hostileApplyCount,
        peacefulApplyCount = self.peacefulApplyCount,
        rejectedApplyCount = self.rejectedApplyCount,
        exactActorBindingsOnly = true,
        broadActorScan = false,
        peacefulTargetClearPolicy =
            "exact-actor-respawn-on-hostile-to-peaceful",
        storyContentIncluded = false,
        PalworldSaveMutation = false,
        lastError = self.lastError,
    }
end

return FactionNpcAttitudeNativeProduction
