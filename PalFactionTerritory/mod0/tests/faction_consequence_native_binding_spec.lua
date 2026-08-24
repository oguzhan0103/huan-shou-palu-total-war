package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?/init.lua",
    package.path,
}, ";")

local NativeBinding =
    require("pwft.faction_consequence_native_binding")

local function actor(name, class_name)
    local class = {
        GetFullName = function() return class_name end,
    }
    return {
        IsValid = function() return true end,
        GetFullName = function() return name end,
        GetClass = function() return class end,
    }
end

local function component(owner)
    return {
        IsValid = function() return true end,
        GetOwner = function() return owner end,
    }
end

local policy = {
    schemaVersion = "1.0.0",
    sourceBuildId = "historical-objectdump-pre-24575825",
    currentHostBuildId = "24575825",
    hookPath = "/Script/Pal.PalCharacterParameterComponent:OnDamage",
    attackerField = "Attacker",
    defenderField = "Defender",
    actualDamageField = "ActualDamage",
    minimumIntervalSecondsPerTarget = 5,
    penaltyByActorRole = {
        ["faction-member"] = 5,
        civilian = 10,
    },
    probeEnabled = true,
    settlementEnabled = false,
    settlementGate = "spec-current-build-verification-required",
}

local restore_listener = nil
local progression = {
    contract = {
        reputationSources = {
            consequence = {
                routingPolicy = {
                    nativeDamageBinding = policy,
                },
            },
        },
    },
    register_restore_listener = function(_, listener_id, callback)
        assert(listener_id
            == "pwft.faction-consequence-native-binding.v1")
        restore_listener = callback
        return { ok = true, reason = "registered" }
    end,
}

local router = {
    factionApi = { progression = progression },
    generation = 4,
    sequence = 0,
    bindings = {},
    dispatched = {},
}
function router:status()
    return { worldGeneration = self.generation }
end
function router:bind_actor(definition)
    assert(definition.actorRef ~= nil)
    assert(definition.actorClassKey ~= nil)
    self.bindings[definition.bindingId] = definition
    return { ok = true, reason = "bound" }
end
function router:unbind_actor(binding_id, actor_ref)
    local binding = self.bindings[binding_id]
    if binding ~= nil then assert(binding.actorRef == actor_ref) end
    self.bindings[binding_id] = nil
    return { ok = true, reason = "unbound" }
end
function router:allocate_event_identity(namespace)
    self.sequence = self.sequence + 1
    local event_id = namespace .. ":" .. tostring(self.sequence)
    return {
        eventId = event_id,
        operationId = "consequence:" .. event_id,
        nativeEventId = "native:" .. event_id,
        sequence = self.sequence,
    }
end
function router:dispatch(event)
    self.dispatched[#self.dispatched + 1] = event
    return {
        ok = true,
        reason = "reputation-delta-applied",
        applied = -event.penalty,
    }
end

local now = 100
local hook_path = nil
local hook_callback = nil
local player = actor(
    "PalPlayerCharacter SpecPlayer",
    "Class /Script/Pal.PalPlayerCharacter"
)
local guard = actor(
    "BP_Guard_C SpecGuard",
    "BlueprintGeneratedClass /Game/Spec/BP_Guard.BP_Guard_C"
)
local civilian = actor(
    "BP_Civilian_C SpecCivilian",
    "BlueprintGeneratedClass /Game/Spec/BP_Civilian.BP_Civilian_C"
)
local other = actor(
    "BP_Enemy_C SpecEnemy",
    "BlueprintGeneratedClass /Game/Spec/BP_Enemy.BP_Enemy_C"
)

local binding = NativeBinding.create(router, {
    registerHook = function(path, callback)
        hook_path = path
        hook_callback = callback
        return 31, 32
    end,
    localPlayerActor = function() return player end,
    clock = function() return now end,
    logger = function() end,
})

assert(type(restore_listener) == "function")
local started = binding:start()
assert(started.ok and binding:status().hookReady == true)
assert(hook_path == NativeBinding.paths.damage)
assert(
    binding:status().sourceBuildId
        == "historical-objectdump-pre-24575825"
)
assert(binding:status().currentHostBuildId == "24575825")
assert(binding:status().currentHostSignatureVerified == false)
assert(binding:status().settlementEnabled == false)
assert(binding:status().broadActorScan == false)

local guard_registration = binding:register_actor({
    bindingId = "spec.native.guard.1",
    factionId = "pwft.faction.rayne_syndicate",
    actorRole = "faction-member",
    actorRef = guard,
})
assert(guard_registration.ok)
assert(guard_registration.actorKey == "BP_Guard_C SpecGuard")
assert(guard_registration.actorClassKey
    == "BlueprintGeneratedClass /Game/Spec/BP_Guard.BP_Guard_C")
assert(binding:status().registeredActorCount == 1)

local bad_class = binding:register_actor({
    bindingId = "spec.native.guard.bad-class",
    factionId = "pwft.faction.rayne_syndicate",
    actorRole = "faction-member",
    actorRef = guard,
    actorClassKey = "BlueprintGeneratedClass /Game/Wrong.Wrong_C",
})
assert(not bad_class.ok and bad_class.reason
    == "native-consequence-actor-class-mismatch")

local ignored = binding:_on_damage(component(other), {
    Attacker = player,
    Defender = other,
    ActualDamage = 20,
})
assert(not ignored.ok and ignored.reason
    == "native-consequence-defender-unregistered")

local wrong_source = binding:_on_damage(component(guard), {
    Attacker = other,
    Defender = guard,
    ActualDamage = 20,
})
assert(not wrong_source.ok and wrong_source.reason
    == "native-consequence-direct-local-player-required")

local wrong_owner = binding:_on_damage(component(other), {
    Attacker = player,
    Defender = guard,
    ActualDamage = 20,
})
assert(not wrong_owner.ok and wrong_owner.reason
    == "native-consequence-component-owner-mismatch")

local zero = binding:_on_damage(component(guard), {
    Attacker = player,
    Defender = guard,
    ActualDamage = 0,
})
assert(not zero.ok and zero.reason
    == "native-consequence-positive-damage-required")

local gated = binding:_on_damage(component(guard), {
    Attacker = player,
    Defender = guard,
    ActualDamage = 20,
})
assert(not gated.ok and gated.observed == true)
assert(gated.reason == "native-consequence-settlement-gated")
assert(#router.dispatched == 0)

local debounced = binding:_on_damage(component(guard), {
    Attacker = player,
    Defender = guard,
    ActualDamage = 21,
})
assert(not debounced.ok and debounced.reason
    == "native-consequence-target-debounced")

-- The shipping contract remains settlement=false.  This local fake policy
-- enables the already-normalized route only to prove the dispatch envelope.
policy.settlementEnabled = true
now = 106
local applied = binding:_on_damage(component(guard), {
    Attacker = player,
    Defender = guard,
    ActualDamage = 25,
})
assert(applied.ok and applied.applied == -5)
assert(#router.dispatched == 1)
local guard_event = router.dispatched[1]
assert(guard_event.reasonCode == "friendly-fire")
assert(guard_event.penalty == 5)
assert(guard_event.actorRef == guard)
assert(guard_event.nativeConfirmed == true)
assert(guard_event.playerInitiated == true)
assert(guard_event.worldGeneration == 4)

assert(binding:register_actor({
    bindingId = "spec.native.civilian.1",
    factionId = "pwft.faction.pidf",
    actorRole = "civilian",
    actorRef = civilian,
}).ok)
now = 107
local civilian_applied = binding:_on_damage(component(civilian), {
    Attacker = player,
    Defender = civilian,
    ActualDamage = 1,
})
assert(civilian_applied.ok and civilian_applied.applied == -10)
assert(router.dispatched[2].reasonCode == "civilian-harm")
assert(router.dispatched[2].penalty == 10)

assert(not binding:unregister_actor(
    "spec.native.civilian.1",
    other
).ok)
assert(binding:unregister_actor(
    "spec.native.civilian.1",
    civilian
).ok)
assert(binding:status().registeredActorCount == 1)

local restored = restore_listener()
assert(restored.ok and restored.removedBindingCount == 1)
assert(binding:status().registeredActorCount == 0)

local status = binding:status()
assert(status.observedCount == 3)
assert(status.settledCount == 2)
assert(status.gatedCount == 1)
assert(status.debouncedCount == 1)
assert(status.ignoredUnregisteredCount == 1)
assert(status.rejectedSourceCount == 3)
assert(status.dispatchFailureCount == 0)

assert(type(hook_callback) == "function")
hook_callback(
    { get = function() return component(other) end },
    { get = function()
        return {
            Attacker = player,
            Defender = other,
            ActualDamage = 1,
        }
    end }
)
assert(binding:status().ignoredUnregisteredCount == 2)

print("PASS native faction-consequence damage binding probes only exact registered defenders, verifies component owner/direct local player/positive damage, debounces, fails closed on the unverified host build, dispatches the trusted envelope, and clears transient actors on restore")
