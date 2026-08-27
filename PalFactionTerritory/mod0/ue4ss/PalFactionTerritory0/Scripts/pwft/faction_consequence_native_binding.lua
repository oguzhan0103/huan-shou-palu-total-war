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
    assert(dependencies.resolvePlayerContext == nil
            or type(dependencies.resolvePlayerContext) == "function",
        "native consequence player-context resolver must be a function")
    local policy = read_policy(router)
    local instance = setmetatable({
        version = API_VERSION,
        router = router,
        dependencies = dependencies,
        policy = policy,
        targetsByActor = {},
        targetsByActorKey = {},
        targetsByBinding = {},
        lastObservedAt = {},
        lastDiagnosticObservedAt = {},
        eventNotifyHook = nil,
        eventNotifyHookError = nil,
        parameterDamageHook = nil,
        parameterDamageHookError = nil,
        hook = nil,
        damageDelegateAlwaysHook = nil,
        actualProcessedHook = nil,
        serverRpcHook = nil,
        hookError = nil,
        damageDelegateAlwaysHookError = nil,
        actualProcessedHookError = nil,
        serverRpcHookError = nil,
        started = false,
        observedCount = 0,
        authoritativeObservedCount = 0,
        diagnosticObservedCount = 0,
        settledCount = 0,
        gatedCount = 0,
        ignoredUnregisteredCount = 0,
        rejectedSourceCount = 0,
        debouncedCount = 0,
        dispatchFailureCount = 0,
        playerAttributionFailureCount = 0,
        capabilities = {
            exactRegisteredDefenderOnly = true,
            exactActorPathIdentity = true,
            directPlayerActorOnly = true,
            directLocalPlayerOnly = false,
            directControllerPawnOnly = true,
            remotePlayerControllerSupported = true,
            exactServerPlayerContextAttribution =
                dependencies.resolvePlayerContext ~= nil,
            unresolvedPlayerContextFailsClosed =
                dependencies.resolvePlayerContext ~= nil,
            processedActualDamageSupported = false,
            serverNpcDamageSupported = true,
            parameterComponentDamageSupported = false,
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

function FactionConsequenceNativeBinding:_same_actor(left, right)
    if left == right then return true end
    if not valid(left) or not valid(right) then return false end
    local left_key = self:_actor_key(left)
    local right_key = self:_actor_key(right)
    if not non_empty(left_key) or left_key ~= right_key then
        return false
    end
    local left_class_key = self:_class_key(left)
    local right_class_key = self:_class_key(right)
    return non_empty(left_class_key)
        and left_class_key == right_class_key
end

function FactionConsequenceNativeBinding:_target_for_actor(actor)
    if actor == nil then return nil end
    local target = self.targetsByActor[actor]
    if target ~= nil then return target end
    local actor_key = self:_actor_key(actor)
    if not non_empty(actor_key) then return nil end
    target = self.targetsByActorKey[actor_key]
    if target == nil then return nil end
    if self:_class_key(actor) ~= target.actorClassKey then return nil end
    return target
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
    local existing_actor = self:_target_for_actor(actor)
    if existing_actor ~= nil
        and existing_actor.bindingId ~= definition.bindingId then
        return result(false, "native-consequence-actor-already-bound")
    end
    local existing_actor_key = self.targetsByActorKey[actor_key]
    if existing_actor_key ~= nil
        and existing_actor_key.actorClassKey ~= actor_class_key then
        return result(false, "native-consequence-actor-identity-collision")
    end
    if existing_actor_key ~= nil
        and existing_actor_key.bindingId ~= definition.bindingId then
        return result(false, "native-consequence-actor-already-bound")
    end
    local existing_binding = self.targetsByBinding[definition.bindingId]
    if existing_binding ~= nil
        and not self:_same_actor(existing_binding.actorRef, actor) then
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
    self.targetsByActorKey[actor_key] = target
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
    if actor_ref ~= nil
        and not self:_same_actor(actor_ref, target.actorRef) then
        return result(false, "native-consequence-actor-reference-mismatch")
    end
    local unbound = self.router:unbind_actor(
        binding_id,
        target.actorRef
    )
    if not unbound.ok then return unbound end
    self.targetsByActor[target.actorRef] = nil
    self.targetsByActorKey[target.actorKey] = nil
    self.targetsByBinding[binding_id] = nil
    self.lastObservedAt[target.actorKey] = nil
    self.lastDiagnosticObservedAt[target.actorKey] = nil
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

function FactionConsequenceNativeBinding:_controller_pawn(controller)
    local fields = self.policy.controllerPawnFields
        or { "Pawn", "AcknowledgedPawn" }
    for _, field in ipairs(fields) do
        local pawn = property(controller, field)
        if valid(pawn) then return pawn end
    end
    return nil
end

function FactionConsequenceNativeBinding:_is_direct_player_actor(actor)
    if not valid(actor) then return false end
    local actor_class = self:_class_key(actor)
    if not non_empty(actor_class) then return false end
    local tokens = self.policy.playerActorClassTokens
        or { "PalPlayerCharacter", "BP_Player_" }
    for _, token in ipairs(tokens) do
        if non_empty(token)
            and string.find(actor_class, token, 1, true) ~= nil then
            return true
        end
    end
    return false
end

function FactionConsequenceNativeBinding:_settle_damage(
    target,
    defender,
    attacker,
    actual_damage,
    owner,
    route,
    authoritative
)
    local now = self:_clock()
    local observation_clock = authoritative
        and self.lastObservedAt
        or self.lastDiagnosticObservedAt
    local observation_key = target.actorKey
    local previous = observation_clock[observation_key]
    if previous ~= nil
        and now - previous
            < self.policy.minimumIntervalSecondsPerTarget then
        self.debouncedCount = self.debouncedCount + 1
        return result(false, "native-consequence-target-debounced", {
            actualDamage = actual_damage,
            stateChanged = false,
            route = route,
        })
    end
    observation_clock[observation_key] = now
    self.observedCount = self.observedCount + 1
    if authoritative then
        self.authoritativeObservedCount =
            self.authoritativeObservedCount + 1
    else
        self.diagnosticObservedCount =
            self.diagnosticObservedCount + 1
    end
    if self.policy.settlementEnabled ~= true or not authoritative then
        self.gatedCount = self.gatedCount + 1
        local gate = self.policy.settlementGate
        if not authoritative then
            gate = "authoritative-server-route-required"
        end
        self:_log(string.format(
            "DAMAGE_PROBE_OBSERVED binding=%s faction=%s role=%s damage=%s attacker=%s defender=%s owner=%s route=%s authoritative=%s settlement=false gate=%s",
            target.bindingId,
            target.factionId,
            target.actorRole,
            tostring(actual_damage),
            tostring(full_name(attacker)),
            tostring(full_name(defender)),
            tostring(full_name(owner)),
            tostring(route),
            tostring(authoritative == true),
            tostring(gate)
        ))
        return result(false, "native-consequence-settlement-gated", {
            observed = true,
            bindingId = target.bindingId,
            actualDamage = actual_damage,
            stateChanged = false,
            route = route,
            authoritative = authoritative == true,
        })
    end
    local dispatch_router = self.router
    local dispatch_generation = target.worldGeneration
    local player_uid = "standalone-local-profile"
    if self.dependencies.resolvePlayerContext ~= nil then
        local called, resolved, resolve_error = pcall(
            self.dependencies.resolvePlayerContext,
            owner
        )
        if not called or type(resolved) ~= "table"
            or type(resolved.factionConsequenceRouter) ~= "table" then
            self.playerAttributionFailureCount =
                self.playerAttributionFailureCount + 1
            self.dispatchFailureCount = self.dispatchFailureCount + 1
            return result(false,
                "native-consequence-player-context-unavailable", {
                stateChanged = false,
                route = route,
                playerContextError = tostring(called
                    and resolve_error or resolved),
            })
        end
        dispatch_router = resolved.factionConsequenceRouter
        player_uid = tostring(resolved.playerUid)
        local router_status = dispatch_router:status()
        dispatch_generation = router_status.worldGeneration
        local rebound = dispatch_router:bind_actor({
            schemaVersion = "1.0.0",
            bindingId = target.bindingId,
            providerId = PROVIDER_ID,
            reasonCode = target.reasonCode,
            factionId = target.factionId,
            actorRole = target.actorRole,
            actorKey = target.actorKey,
            actorClassKey = target.actorClassKey,
            worldGeneration = dispatch_generation,
            actorRef = defender,
        })
        if not rebound.ok then
            self.playerAttributionFailureCount =
                self.playerAttributionFailureCount + 1
            self.dispatchFailureCount = self.dispatchFailureCount + 1
            return result(false,
                "native-consequence-player-router-bind-failed", {
                stateChanged = false,
                route = route,
                playerUid = player_uid,
                playerRouterReason = rebound.reason,
            })
        end
    end
    local identity = dispatch_router:allocate_event_identity(
        "native-damage"
    )
    local penalty = self.policy.penaltyByActorRole[target.actorRole]
    local dispatched = dispatch_router:dispatch({
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
        worldGeneration = dispatch_generation,
        bindingId = target.bindingId,
        actorRef = defender,
        actorKey = target.actorKey,
        actorClassKey = target.actorClassKey,
        nativeEventId = identity.nativeEventId,
        damageRoute = route,
    })
    dispatched.playerUid = player_uid
    if dispatched.ok then
        self.settledCount = self.settledCount + 1
        self:_log(string.format(
            "DAMAGE_SETTLED binding=%s faction=%s role=%s damage=%s penalty=%s operation=%s actor=%s route=%s player=%s",
            target.bindingId,
            target.factionId,
            target.actorRole,
            tostring(actual_damage),
            tostring(penalty),
            tostring(identity.operationId),
            tostring(target.actorKey),
            tostring(route),
            player_uid
        ))
    else
        self.dispatchFailureCount = self.dispatchFailureCount + 1
    end
    return dispatched
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
    local target = self:_target_for_actor(defender)
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
    if owner ~= nil and not self:_same_actor(owner, defender) then
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
    if not self:_is_direct_player_actor(attacker) then
        self.rejectedSourceCount = self.rejectedSourceCount + 1
        self:_log(string.format(
            "PARAMETER_DAMAGE_REJECTED binding=%s reason=direct-player-actor-required attacker=%s attackerClass=%s defender=%s damage=%s",
            target.bindingId,
            tostring(full_name(attacker)),
            tostring(self:_class_key(attacker)),
            tostring(full_name(defender)),
            tostring(actual_damage)
        ))
        return result(false,
            "native-consequence-direct-player-actor-required")
    end
    return self:_settle_damage(
        target,
        defender,
        attacker,
        actual_damage,
        owner,
        "parameter-component-on-damage",
        false
    )
end

function FactionConsequenceNativeBinding:_on_character_damaged_server_event(
    event_context,
    damage_result
)
    if damage_result == nil then
        return result(false, "native-consequence-damage-result-missing")
    end
    local defender = property(
        damage_result,
        self.policy.defenderField
    )
    local target = self:_target_for_actor(defender)
    if target == nil then
        self.ignoredUnregisteredCount =
            self.ignoredUnregisteredCount + 1
        return result(false, "native-consequence-defender-unregistered")
    end
    if target.worldGeneration ~= self.router:status().worldGeneration then
        self.rejectedSourceCount = self.rejectedSourceCount + 1
        return result(false, "native-consequence-target-generation-stale")
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
    if not self:_is_direct_player_actor(attacker) then
        self.rejectedSourceCount = self.rejectedSourceCount + 1
        self:_log(string.format(
            "CHARACTER_DAMAGE_EVENT_REJECTED binding=%s reason=direct-player-actor-required attacker=%s attackerClass=%s defender=%s damage=%s",
            target.bindingId,
            tostring(full_name(attacker)),
            tostring(self:_class_key(attacker)),
            tostring(full_name(defender)),
            tostring(actual_damage)
        ))
        return result(false,
            "native-consequence-direct-player-actor-required")
    end
    return self:_settle_damage(
        target,
        defender,
        attacker,
        actual_damage,
        event_context,
        "character-damaged-server-event",
        false
    )
end

function FactionConsequenceNativeBinding:_on_actual_damage_processed(
    component,
    attacker,
    defender,
    actual_damage
)
    local target = self:_target_for_actor(defender)
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
    if not self:_same_actor(owner, defender) then
        self.rejectedSourceCount = self.rejectedSourceCount + 1
        return result(false, "native-consequence-component-owner-mismatch")
    end
    local normalized_damage = tonumber(actual_damage)
    if normalized_damage == nil or normalized_damage <= 0 then
        self.rejectedSourceCount = self.rejectedSourceCount + 1
        return result(false, "native-consequence-positive-damage-required")
    end
    if not self:_is_direct_player_actor(attacker) then
        self.rejectedSourceCount = self.rejectedSourceCount + 1
        self:_log(string.format(
            "ACTUAL_DAMAGE_REJECTED binding=%s reason=direct-player-actor-required attacker=%s attackerClass=%s defender=%s damage=%s",
            target.bindingId,
            tostring(full_name(attacker)),
            tostring(self:_class_key(attacker)),
            tostring(full_name(defender)),
            tostring(normalized_damage)
        ))
        return result(false,
            "native-consequence-direct-player-actor-required")
    end
    return self:_settle_damage(
        target,
        defender,
        attacker,
        normalized_damage,
        owner,
        "damage-component-actual-processed",
        false
    )
end

function FactionConsequenceNativeBinding:_on_damage_delegate_always(
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
    local target = self:_target_for_actor(defender)
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
    if not self:_same_actor(owner, defender) then
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
    if not self:_is_direct_player_actor(attacker) then
        self.rejectedSourceCount = self.rejectedSourceCount + 1
        self:_log(string.format(
            "DAMAGE_DELEGATE_ALWAYS_REJECTED binding=%s reason=direct-player-actor-required attacker=%s attackerClass=%s defender=%s damage=%s",
            target.bindingId,
            tostring(full_name(attacker)),
            tostring(self:_class_key(attacker)),
            tostring(full_name(defender)),
            tostring(actual_damage)
        ))
        return result(false,
            "native-consequence-direct-player-actor-required")
    end
    return self:_settle_damage(
        target,
        defender,
        attacker,
        actual_damage,
        owner,
        "damage-component-delegate-always",
        false
    )
end

function FactionConsequenceNativeBinding:_on_server_npc_damage(
    controller,
    damage_info,
    defender
)
    if damage_info == nil then
        return result(false, "native-consequence-damage-info-missing")
    end
    local target = self:_target_for_actor(defender)
    if target == nil then
        self.ignoredUnregisteredCount =
            self.ignoredUnregisteredCount + 1
        return result(false, "native-consequence-defender-unregistered")
    end
    if target.worldGeneration ~= self.router:status().worldGeneration then
        self.rejectedSourceCount = self.rejectedSourceCount + 1
        return result(false, "native-consequence-target-generation-stale")
    end
    if property(damage_info, self.policy.noDamageField) == true then
        self.rejectedSourceCount = self.rejectedSourceCount + 1
        return result(false, "native-consequence-no-damage-rejected")
    end
    local actual_damage = tonumber(property(
        damage_info,
        self.policy.authoritativeDamageField
    ))
    if actual_damage == nil or actual_damage <= 0 then
        self.rejectedSourceCount = self.rejectedSourceCount + 1
        return result(false, "native-consequence-positive-damage-required")
    end
    local attacker = property(damage_info, self.policy.attackerField)
    local controller_pawn = self:_controller_pawn(controller)
    if not valid(controller_pawn)
        or not self:_same_actor(attacker, controller_pawn) then
        self.rejectedSourceCount = self.rejectedSourceCount + 1
        self:_log(string.format(
            "SERVER_DAMAGE_REJECTED binding=%s reason=direct-controller-pawn-required attacker=%s controllerPawn=%s defender=%s damage=%s",
            target.bindingId,
            tostring(full_name(attacker)),
            tostring(full_name(controller_pawn)),
            tostring(full_name(defender)),
            tostring(actual_damage)
        ))
        return result(false,
            "native-consequence-direct-controller-pawn-required")
    end
    return self:_settle_damage(
        target,
        defender,
        attacker,
        actual_damage,
        controller,
        "player-controller-server-npc-damage",
        true
    )
end

function FactionConsequenceNativeBinding:_register_hook()
    if self.serverRpcHook ~= nil then
        return true
    end
    local provider = self.dependencies.registerHook or RegisterHook
    if type(provider) ~= "function" then
        self.serverRpcHookError = "RegisterHook-unavailable"
        return false
    end
    local server_rpc_callback = function(
        context,
        damage_info_parameter,
        defender_parameter
    )
        local ok, response = pcall(function()
            return self:_on_server_npc_damage(
                hook_value(context),
                hook_value(damage_info_parameter),
                hook_value(defender_parameter)
            )
        end)
        if not ok then
            self.dispatchFailureCount =
                self.dispatchFailureCount + 1
            self:_log("SERVER_NPC_DAMAGE_HOOK_EXCEPTION error="
                .. tostring(response))
        end
    end
    local hook_ok, hook_first, hook_second = pcall(
        provider,
        self.policy.authoritativeHookPath,
        server_rpc_callback
    )
    if not hook_ok or hook_first == nil then
        self.serverRpcHookError = tostring(hook_first)
        self:_log("SERVER_NPC_DAMAGE_HOOK_FAILED path="
            .. tostring(self.policy.authoritativeHookPath)
            .. " error=" .. tostring(hook_first))
        return false
    end
    self.serverRpcHook = {
        firstId = hook_first,
        secondId = hook_second,
        callback = server_rpc_callback,
    }
    self.serverRpcHookError = nil
    self.eventNotifyHookError =
        "diagnostic-only-not-registered"
    self.actualProcessedHookError =
        "rejected-build-24575825-wrapper-not-observed"
    self.parameterDamageHookError =
        "rejected-build-24575825-stable-but-ineffective"
    self:_log("SERVER_NPC_DAMAGE_HOOK_READY path="
        .. tostring(self.policy.authoritativeHookPath)
        .. " settlement="
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
    self.targetsByActorKey = {}
    self.targetsByBinding = {}
    self.lastObservedAt = {}
    self.lastDiagnosticObservedAt = {}
    return result(true, "native-consequence-world-unbound", {
        removedBindingCount = removed,
        detail = reason or "world-unload",
    })
end

function FactionConsequenceNativeBinding:status()
    return {
        apiVersion = self.version,
        started = self.started,
        hookReady = self.serverRpcHook ~= nil,
        authoritativeHookReady = self.serverRpcHook ~= nil,
        eventNotifyHookReady = self.eventNotifyHook ~= nil,
        parameterDamageHookReady =
            self.parameterDamageHook ~= nil,
        damageDelegateAlwaysHookReady =
            self.damageDelegateAlwaysHook ~= nil,
        actualProcessedHookReady = self.actualProcessedHook ~= nil,
        serverRpcHookReady = self.serverRpcHook ~= nil,
        diagnosticHookReady = self.hook ~= nil,
        hookPath = self.policy.authoritativeHookPath,
        authoritativeHookPath =
            self.policy.authoritativeHookPath,
        eventNotifyHookPath = self.policy.eventNotifyHookPath,
        parameterDamageHookPath =
            self.policy.parameterDamageHookPath,
        damageDelegateAlwaysHookPath =
            self.policy.damageDelegateAlwaysHookPath,
        actualProcessedHookPath = self.policy.actualProcessedHookPath,
        serverRpcHookPath = self.policy.authoritativeHookPath,
        hookError = self.serverRpcHookError,
        authoritativeHookError = self.serverRpcHookError,
        eventNotifyHookError = self.eventNotifyHookError,
        parameterDamageHookError =
            self.parameterDamageHookError,
        damageDelegateAlwaysHookError =
            self.damageDelegateAlwaysHookError,
        actualProcessedHookError = self.actualProcessedHookError,
        serverRpcHookError = self.serverRpcHookError,
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
        authoritativeObservedCount = self.authoritativeObservedCount,
        diagnosticObservedCount = self.diagnosticObservedCount,
        settledCount = self.settledCount,
        gatedCount = self.gatedCount,
        ignoredUnregisteredCount = self.ignoredUnregisteredCount,
        rejectedSourceCount = self.rejectedSourceCount,
        debouncedCount = self.debouncedCount,
        dispatchFailureCount = self.dispatchFailureCount,
        playerAttributionFailureCount =
            self.playerAttributionFailureCount,
        exactRegisteredDefenderOnly = true,
        exactActorPathIdentity = true,
        directPlayerActorOnly = true,
        directLocalPlayerOnly = false,
        directControllerPawnOnly = true,
        remotePlayerControllerSupported = true,
        exactServerPlayerContextAttribution =
            self.capabilities.exactServerPlayerContextAttribution,
        unresolvedPlayerContextFailsClosed =
            self.capabilities.unresolvedPlayerContextFailsClosed,
        processedActualDamageSupported = false,
        serverNpcDamageSupported = true,
        parameterComponentDamageSupported = false,
        broadActorScan = false,
        modelMayDispatch = false,
        PalworldSaveMutation = false,
    }
end

FactionConsequenceNativeBinding.paths = {
    characterDamagedServerEvent =
        "/Script/Pal.PalEventNotify_Character:OnCharacterDamaged_ServerInternal",
    parameterComponentDamage =
        "/Script/Pal.PalCharacterParameterComponent:OnDamage",
    damage = "/Script/Pal.PalCharacterParameterComponent:OnDamage",
    damageDelegateAlways = "/Script/Pal.PalDamageReactionComponent:CallOnDamageDelegateAlways",
    actualProcessedDamage = "/Script/Pal.PalDamageReactionComponent:CallOnActualDamageProcessed_ToAll",
    authoritativeDamage = "/Script/Pal.PalPlayerController:DamageReactionComponent_ProcessDamage_ToServer_ToNPC",
}

return FactionConsequenceNativeBinding
