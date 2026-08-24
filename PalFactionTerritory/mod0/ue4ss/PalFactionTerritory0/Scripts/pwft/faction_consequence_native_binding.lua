local FactionConsequenceNativeBinding = {}

local API_VERSION = "1.0.0"
local PROVIDER_ID = "pwft.consequence.native-actor.v1"
local AUTHORITY_SOURCE = "pwft.native-faction-consequence.v1"
local PREFIX = "[PalFactionTerritory0][FactionConsequenceNative]"

local ROLE_REASON = {
    ["faction-member"] = "friendly-fire",
    civilian = "civilian-harm",
}

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
    local arguments = { ... }
    return pcall(function()
        return object[method](object, table.unpack(arguments))
    end)
end

local function hook_value(parameter)
    if parameter == nil then return nil end
    local ok, value = pcall(function()
        return parameter:get()
    end)
    return ok and value or parameter
end

local function full_name(object)
    if object == nil then return nil end
    if type(object) == "string" then return object end
    local ok, name = pcall(function()
        return object:GetFullName()
    end)
    if ok and name ~= nil and non_empty(tostring(name)) then
        return tostring(name)
    end
    return tostring(object)
end

local function class_key(object)
    local ok, class = call(object, "GetClass")
    if not ok or class == nil then return nil end
    return full_name(class)
end

local function count(values)
    local total = 0
    for _ in pairs(values or {}) do total = total + 1 end
    return total
end

local function default_local_player_actor()
    local helpers_ok, helpers = pcall(require, "UEHelpers")
    if not helpers_ok or helpers == nil then return nil end
    local controller_ok, controller = pcall(function()
        return helpers:GetPlayerController()
    end)
    if not controller_ok or not valid(controller) then return nil end
    local pawn = property(controller, "Pawn")
    if not valid(pawn) then
        pawn = property(controller, "AcknowledgedPawn")
    end
    return valid(pawn) and pawn or nil
end

local function read_policy(router)
    local progression = assert(router.factionApi
            and router.factionApi.progression,
        "native consequence binding requires progression")
    local routing = progression.contract.reputationSources
        .consequence.routingPolicy
    local policy = assert(routing.nativeDamageBinding,
        "native damage consequence policy is required")
    assert(policy.schemaVersion == "1.0.0",
        "unsupported native damage consequence policy")
    return policy
end

function FactionConsequenceNativeBinding.create(router, dependencies)
    assert(type(router) == "table",
        "faction consequence router is required")
    assert(type(router.bind_actor) == "function",
        "faction consequence router lacks bind_actor")
    assert(type(router.unbind_actor) == "function",
        "faction consequence router lacks unbind_actor")
    assert(type(router.dispatch) == "function",
        "faction consequence router lacks dispatch")
    assert(type(router.allocate_event_identity) == "function",
        "faction consequence router lacks event identity allocation")
    dependencies = dependencies or {}
    local policy = read_policy(router)
    local instance = setmetatable({
        version = API_VERSION,
        router = router,
        dependencies = dependencies,
        policy = policy,
        targetsByActor = {},
        targetsByBinding = {},
        lastObservedAt = {},
        hook = nil,
        hookError = nil,
        started = false,
        observedCount = 0,
        settledCount = 0,
        gatedCount = 0,
        ignoredUnregisteredCount = 0,
        rejectedSourceCount = 0,
        debouncedCount = 0,
        dispatchFailureCount = 0,
        capabilities = {
            exactRegisteredDefenderOnly = true,
            directLocalPlayerOnly = true,
            positiveActualDamageOnly = true,
            worldGenerationFencing = true,
            modelMayDispatch = false,
            broadActorScan = false,
            PalworldSaveMutation = false,
        },
    }, { __index = FactionConsequenceNativeBinding })
    local progression = router.factionApi.progression
    if type(progression.register_restore_listener) == "function" then
        local registered = progression:register_restore_listener(
            "pwft.faction-consequence-native-binding.v1",
            function()
                return instance:unbind_world("progression-restored")
            end
        )
        assert(registered.ok, registered.reason)
    end
    return instance
end

function FactionConsequenceNativeBinding:_log(message)
    local logger = self.dependencies.logger
    if type(logger) == "function" then
        logger(PREFIX .. " " .. tostring(message))
    else
        print(PREFIX .. " " .. tostring(message) .. "\n")
    end
end

function FactionConsequenceNativeBinding:_clock()
    local provider = self.dependencies.clock
    if type(provider) == "function" then
        local ok, value = pcall(provider)
        if ok and type(value) == "number" then return value end
    end
    return os.time()
end

function FactionConsequenceNativeBinding:_local_player_actor()
    local provider = self.dependencies.localPlayerActor
    if type(provider) == "function" then
        local ok, actor = pcall(provider)
        return ok and actor or nil
    end
    return default_local_player_actor()
end

function FactionConsequenceNativeBinding:_actor_key(actor)
    local provider = self.dependencies.objectKey
    if type(provider) == "function" then
        local ok, key = pcall(provider, actor)
        if ok and non_empty(key) then return key end
    end
    return full_name(actor)
end

function FactionConsequenceNativeBinding:_class_key(actor)
    local provider = self.dependencies.objectClassKey
    if type(provider) == "function" then
        local ok, key = pcall(provider, actor)
        if ok and non_empty(key) then return key end
    end
    return class_key(actor)
end

function FactionConsequenceNativeBinding:register_actor(definition)
    if type(definition) ~= "table" then
        return result(false, "native-consequence-actor-definition-required")
    end
    local actor = definition.actorRef
    if not valid(actor) then
        return result(false, "native-consequence-actor-invalid")
    end
    if not non_empty(definition.bindingId) then
        return result(false, "native-consequence-binding-id-required")
    end
    if not non_empty(definition.factionId) then
        return result(false, "native-consequence-faction-id-required")
    end
    local reason_code = ROLE_REASON[definition.actorRole]
    if reason_code == nil then
        return result(false, "native-consequence-actor-role-unsupported")
    end
    local actor_key = self:_actor_key(actor)
    local actor_class_key = self:_class_key(actor)
    if not non_empty(actor_key) or not non_empty(actor_class_key) then
        return result(false, "native-consequence-actor-identity-unavailable")
    end
    if definition.actorKey ~= nil
        and definition.actorKey ~= actor_key then
        return result(false, "native-consequence-actor-key-mismatch")
    end
    if definition.actorClassKey ~= nil
        and definition.actorClassKey ~= actor_class_key then
        return result(false, "native-consequence-actor-class-mismatch")
    end
    local existing_actor = self.targetsByActor[actor]
    if existing_actor ~= nil
        and existing_actor.bindingId ~= definition.bindingId then
        return result(false, "native-consequence-actor-already-bound")
    end
    local existing_binding = self.targetsByBinding[definition.bindingId]
    if existing_binding ~= nil and existing_binding.actorRef ~= actor then
        return result(false, "native-consequence-binding-id-conflict")
    end
    local generation = self.router:status().worldGeneration
    local bound = self.router:bind_actor({
        schemaVersion = "1.0.0",
        bindingId = definition.bindingId,
        providerId = PROVIDER_ID,
        reasonCode = reason_code,
        factionId = definition.factionId,
        actorRole = definition.actorRole,
        actorKey = actor_key,
        actorClassKey = actor_class_key,
        worldGeneration = generation,
        actorRef = actor,
    })
    if not bound.ok then return bound end
    local target = {
        bindingId = definition.bindingId,
        factionId = definition.factionId,
        actorRole = definition.actorRole,
        reasonCode = reason_code,
        actorRef = actor,
        actorKey = actor_key,
        actorClassKey = actor_class_key,
        worldGeneration = generation,
    }
    self.targetsByActor[actor] = target
    self.targetsByBinding[target.bindingId] = target
    return result(true, "native-consequence-actor-registered", {
        bindingId = target.bindingId,
        factionId = target.factionId,
        actorRole = target.actorRole,
        actorKey = target.actorKey,
        actorClassKey = target.actorClassKey,
        worldGeneration = generation,
    })
end

function FactionConsequenceNativeBinding:unregister_actor(
    binding_id,
    actor_ref
)
    if not non_empty(binding_id) then
        return result(false, "native-consequence-binding-id-required")
    end
    local target = self.targetsByBinding[binding_id]
    if target == nil then
        return result(true, "native-consequence-actor-already-unregistered", {
            bindingId = binding_id,
            removed = false,
        })
    end
    if actor_ref ~= nil and actor_ref ~= target.actorRef then
        return result(false, "native-consequence-actor-reference-mismatch")
    end
    local unbound = self.router:unbind_actor(
        binding_id,
        target.actorRef
    )
    if not unbound.ok then return unbound end
    self.targetsByActor[target.actorRef] = nil
    self.targetsByBinding[binding_id] = nil
    self.lastObservedAt[target.actorRef] = nil
    return result(true, "native-consequence-actor-unregistered", {
        bindingId = binding_id,
        removed = true,
    })
end

function FactionConsequenceNativeBinding:_component_owner(component)
    local ok, owner = call(component, "GetOwner")
    if ok and owner ~= nil then return owner end
    return property(component, "Owner")
end

function FactionConsequenceNativeBinding:_on_damage(
    component,
    damage_result
)
    if damage_result == nil then
        return result(false, "native-consequence-damage-result-missing")
    end
    local defender = property(
        damage_result,
        self.policy.defenderField
    )
    local target = self.targetsByActor[defender]
    if target == nil then
        self.ignoredUnregisteredCount =
            self.ignoredUnregisteredCount + 1
        return result(false, "native-consequence-defender-unregistered")
    end
    if target.worldGeneration ~= self.router:status().worldGeneration then
        self.rejectedSourceCount = self.rejectedSourceCount + 1
        return result(false, "native-consequence-target-generation-stale")
    end
    local owner = self:_component_owner(component)
    if owner ~= nil and owner ~= defender then
        self.rejectedSourceCount = self.rejectedSourceCount + 1
        return result(false, "native-consequence-component-owner-mismatch")
    end
    local actual_damage = tonumber(property(
        damage_result,
        self.policy.actualDamageField
    ))
    if actual_damage == nil or actual_damage <= 0 then
        self.rejectedSourceCount = self.rejectedSourceCount + 1
        return result(false, "native-consequence-positive-damage-required")
    end
    local attacker = property(
        damage_result,
        self.policy.attackerField
    )
    local local_player = self:_local_player_actor()
    if not valid(local_player) or attacker ~= local_player then
        self.rejectedSourceCount = self.rejectedSourceCount + 1
        return result(false, "native-consequence-direct-local-player-required")
    end
    local now = self:_clock()
    local previous = self.lastObservedAt[defender]
    if previous ~= nil
        and now - previous
            < self.policy.minimumIntervalSecondsPerTarget then
        self.debouncedCount = self.debouncedCount + 1
        return result(false, "native-consequence-target-debounced", {
            actualDamage = actual_damage,
            stateChanged = false,
        })
    end
    self.lastObservedAt[defender] = now
    self.observedCount = self.observedCount + 1
    if self.policy.settlementEnabled ~= true then
        self.gatedCount = self.gatedCount + 1
        self:_log(string.format(
            "DAMAGE_PROBE_OBSERVED binding=%s faction=%s role=%s damage=%s attacker=direct-local-player settlement=false gate=%s",
            target.bindingId,
            target.factionId,
            target.actorRole,
            tostring(actual_damage),
            tostring(self.policy.settlementGate)
        ))
        return result(false, "native-consequence-settlement-gated", {
            observed = true,
            bindingId = target.bindingId,
            actualDamage = actual_damage,
            stateChanged = false,
        })
    end
    local identity = self.router:allocate_event_identity(
        "native-damage"
    )
    local penalty = self.policy.penaltyByActorRole[target.actorRole]
    local dispatched = self.router:dispatch({
        schemaVersion = "1.0.0",
        authoritative = true,
        eventId = identity.eventId,
        operationId = identity.operationId,
        providerId = PROVIDER_ID,
        authoritySource = AUTHORITY_SOURCE,
        reasonCode = target.reasonCode,
        factionId = target.factionId,
        penalty = penalty,
        contextId = identity.nativeEventId,
        nativeConfirmed = true,
        playerInitiated = true,
        worldGeneration = target.worldGeneration,
        bindingId = target.bindingId,
        actorRef = defender,
        actorKey = target.actorKey,
        actorClassKey = target.actorClassKey,
        nativeEventId = identity.nativeEventId,
    })
    if dispatched.ok then
        self.settledCount = self.settledCount + 1
    else
        self.dispatchFailureCount = self.dispatchFailureCount + 1
    end
    return dispatched
end

function FactionConsequenceNativeBinding:_register_hook()
    if self.hook ~= nil then return true end
    local provider = self.dependencies.registerHook or RegisterHook
    if type(provider) ~= "function" then
        self.hookError = "RegisterHook-unavailable"
        return false
    end
    local callback = function(context, damage_parameter)
        local ok, response = pcall(function()
            return self:_on_damage(
                hook_value(context),
                hook_value(damage_parameter)
            )
        end)
        if not ok then
            self.dispatchFailureCount =
                self.dispatchFailureCount + 1
            self:_log("DAMAGE_HOOK_EXCEPTION error="
                .. tostring(response))
        end
    end
    local ok, first, second = pcall(
        provider,
        self.policy.hookPath,
        callback
    )
    if not ok then
        self.hookError = tostring(first)
        self:_log("DAMAGE_HOOK_FAILED path="
            .. self.policy.hookPath
            .. " error=" .. tostring(first))
        return false
    end
    self.hook = {
        firstId = first,
        secondId = second,
        callback = callback,
    }
    self.hookError = nil
    self:_log("DAMAGE_HOOK_READY path="
        .. self.policy.hookPath
        .. " probe=true settlement="
        .. tostring(self.policy.settlementEnabled == true))
    return true
end

function FactionConsequenceNativeBinding:start()
    if self.started then
        return result(true, "native-consequence-binding-already-started",
            self:status())
    end
    if self.policy.probeEnabled ~= true then
        return result(false, "native-consequence-probe-disabled",
            self:status())
    end
    self.started = self:_register_hook()
    if not self.started then
        return result(false,
            "native-consequence-hook-registration-failed",
            self:status())
    end
    return result(true, "native-consequence-binding-started",
        self:status())
end

function FactionConsequenceNativeBinding:unbind_world(reason)
    local removed = count(self.targetsByBinding)
    for binding_id, target in pairs(self.targetsByBinding) do
        self.router:unbind_actor(binding_id, target.actorRef)
    end
    self.targetsByActor = {}
    self.targetsByBinding = {}
    self.lastObservedAt = {}
    return result(true, "native-consequence-world-unbound", {
        removedBindingCount = removed,
        detail = reason or "world-unload",
    })
end

function FactionConsequenceNativeBinding:status()
    return {
        apiVersion = self.version,
        started = self.started,
        hookReady = self.hook ~= nil,
        hookPath = self.policy.hookPath,
        hookError = self.hookError,
        sourceBuildId = self.policy.sourceBuildId,
        currentHostBuildId = self.policy.currentHostBuildId,
        currentHostSignatureVerified =
            self.policy.sourceBuildId
                == self.policy.currentHostBuildId,
        probeEnabled = self.policy.probeEnabled == true,
        settlementEnabled = self.policy.settlementEnabled == true,
        settlementGate = self.policy.settlementGate,
        registeredActorCount = count(self.targetsByBinding),
        observedCount = self.observedCount,
        settledCount = self.settledCount,
        gatedCount = self.gatedCount,
        ignoredUnregisteredCount = self.ignoredUnregisteredCount,
        rejectedSourceCount = self.rejectedSourceCount,
        debouncedCount = self.debouncedCount,
        dispatchFailureCount = self.dispatchFailureCount,
        exactRegisteredDefenderOnly = true,
        directLocalPlayerOnly = true,
        broadActorScan = false,
        modelMayDispatch = false,
        PalworldSaveMutation = false,
    }
end

FactionConsequenceNativeBinding.paths = {
    damage = "/Script/Pal.PalCharacterParameterComponent:OnDamage",
}

return FactionConsequenceNativeBinding
