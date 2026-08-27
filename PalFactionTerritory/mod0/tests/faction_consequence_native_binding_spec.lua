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
        GetFullName = function()
            return "PalCharacterParameterComponent SpecComponent"
        end,
        GetOwner = function() return owner end,
    }
end

local policy = {
    schemaVersion = "1.0.0",
    sourceBuildId = "24575825",
    currentHostBuildId = "24575825",
    eventNotifyHookPath =
        "/Script/Pal.PalEventNotify_Character:OnCharacterDamaged_ServerInternal",
    actualProcessedHookPath =
        "/Script/Pal.PalDamageReactionComponent:CallOnActualDamageProcessed_ToAll",
    authoritativeHookPath =
        "/Script/Pal.PalPlayerController:DamageReactionComponent_ProcessDamage_ToServer_ToNPC",
    parameterDamageHookPath =
        "/Script/Pal.PalCharacterParameterComponent:OnDamage",
    parameterDamageHookRejected = true,
    attackerField = "Attacker",
    defenderField = "Defender",
    actualDamageField = "ActualDamage",
    authoritativeDamageField = "NativeDamageValue",
    noDamageField = "NoDamage",
    controllerPawnFields = { "Pawn", "AcknowledgedPawn" },
    playerActorClassTokens = { "PalPlayerCharacter", "BP_Player_" },
    minimumIntervalSecondsPerTarget = 5,
    penaltyByActorRole = {
        ["faction-member"] = 5,
        civilian = 10,
    },
    probeEnabled = true,
    settlementEnabled = false,
    settlementGate = "spec-live-player-attribution-required",
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

local remote_router = {
    factionApi = { progression = progression },
    generation = 4,
    sequence = 0,
    bindings = {},
    dispatched = {},
}
remote_router.status = router.status
remote_router.bind_actor = router.bind_actor
remote_router.unbind_actor = router.unbind_actor
remote_router.allocate_event_identity = router.allocate_event_identity
remote_router.dispatch = router.dispatch

local now = 100
local hooks = {}
local player = actor(
    "PalPlayerCharacter SpecPlayer",
    "Class /Script/Pal.PalPlayerCharacter"
)
local remote_player = actor(
    "BP_Player_C RemoteSpecPlayer",
    "BlueprintGeneratedClass /Game/Pal/Blueprint/Player/BP_Player.BP_Player_C"
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
local event_context = actor(
    "PalEventNotify_Character SpecEventNotify",
    "Class /Script/Pal.PalEventNotify_Character"
)
local player_controller = actor(
    "PalPlayerController SpecController",
    "Class /Script/Pal.PalPlayerController"
)
player_controller.Pawn = player
local remote_player_controller = actor(
    "PalPlayerController RemoteSpecController",
    "Class /Script/Pal.PalPlayerController"
)
remote_player_controller.Pawn = remote_player
local wrong_controller = actor(
    "PalAIController WrongSpecController",
    "Class /Script/Pal.PalAIController"
)
wrong_controller.Pawn = other
local unknown_player = actor(
    "PalPlayerCharacter UnknownSpecPlayer",
    "Class /Script/Pal.PalPlayerCharacter"
)
local unknown_controller = actor(
    "PalPlayerController UnknownSpecController",
    "Class /Script/Pal.PalPlayerController"
)
unknown_controller.Pawn = unknown_player
local player_rpc_wrapper = actor(
    "PalPlayerCharacter SpecPlayer",
    "Class /Script/Pal.PalPlayerCharacter"
)
local player_controller_rpc_wrapper = actor(
    "PalPlayerController SpecController",
    "Class /Script/Pal.PalPlayerController"
)
player_controller_rpc_wrapper.Pawn = player_rpc_wrapper
local guard_rpc_wrapper = actor(
    "BP_Guard_C SpecGuard",
    "BlueprintGeneratedClass /Game/Spec/BP_Guard.BP_Guard_C"
)

local binding = NativeBinding.create(router, {
    registerHook = function(path, callback)
        hooks[path] = callback
        return 31, 32
    end,
    clock = function() return now end,
    logger = function() end,
    resolvePlayerContext = function(controller)
        local name = controller:GetFullName()
        if string.find(name, "Unknown", 1, true) ~= nil then
            return nil, "spec-session-unavailable"
        end
        if string.find(name, "Remote", 1, true) ~= nil then
            return {
                playerUid = "A09AB288B1234567887654321ABCDEF0",
                factionConsequenceRouter = remote_router,
            }
        end
        return {
            playerUid = "D09AB288B1234567887654321ABCDEF0",
            factionConsequenceRouter = router,
        }
    end,
})

assert(type(restore_listener) == "function")
local started = binding:start()
assert(started.ok and binding:status().hookReady == true)
assert(hooks[NativeBinding.paths.characterDamagedServerEvent] == nil)
assert(hooks[NativeBinding.paths.actualProcessedDamage] == nil)
assert(hooks[NativeBinding.paths.parameterComponentDamage] == nil)
assert(hooks[NativeBinding.paths.damageDelegateAlways] == nil)
assert(type(hooks[NativeBinding.paths.authoritativeDamage])
    == "function")
assert(hooks[NativeBinding.paths.damage] == nil)

local initial_status = binding:status()
assert(initial_status.authoritativeHookReady == true)
assert(initial_status.eventNotifyHookReady == false)
assert(initial_status.parameterDamageHookReady == false)
assert(initial_status.damageDelegateAlwaysHookReady == false)
assert(initial_status.actualProcessedHookReady == false)
assert(initial_status.serverRpcHookReady == true)
assert(initial_status.diagnosticHookReady == false)
assert(initial_status.currentHostSignatureVerified == true)
assert(initial_status.settlementEnabled == false)
assert(initial_status.directPlayerActorOnly == true)
assert(initial_status.directLocalPlayerOnly == false)
assert(initial_status.directControllerPawnOnly == true)
assert(initial_status.remotePlayerControllerSupported == true)
assert(initial_status.exactServerPlayerContextAttribution == true)
assert(initial_status.unresolvedPlayerContextFailsClosed == true)
assert(initial_status.processedActualDamageSupported == false)
assert(initial_status.serverNpcDamageSupported == true)
assert(initial_status.parameterComponentDamageSupported == false)
assert(initial_status.broadActorScan == false)
assert(initial_status.exactActorPathIdentity == true)

local guard_registration = binding:register_actor({
    bindingId = "spec.native.guard.1",
    factionId = "pwft.faction.rayne_syndicate",
    actorRole = "faction-member",
    actorRef = guard,
})
assert(guard_registration.ok)
assert(guard_registration.actorKey == "BP_Guard_C SpecGuard")
assert(binding:status().registeredActorCount == 1)

local collision = binding:register_actor({
    bindingId = "spec.native.guard.collision",
    factionId = "pwft.faction.pidf",
    actorRole = "faction-member",
    actorRef = actor(
        "BP_Guard_C SpecGuard",
        "BlueprintGeneratedClass /Game/Spec/BP_Other.BP_Other_C"
    ),
})
assert(not collision.ok and collision.reason
    == "native-consequence-actor-identity-collision")
assert(binding:status().registeredActorCount == 1)

local ignored = binding:_on_server_npc_damage(
    player_controller,
    { Attacker = player, NativeDamageValue = 20, NoDamage = false },
    other
)
assert(not ignored.ok and ignored.reason
    == "native-consequence-defender-unregistered")

local wrong_source = binding:_on_server_npc_damage(
    wrong_controller,
    { Attacker = player, NativeDamageValue = 20, NoDamage = false },
    guard
)
assert(not wrong_source.ok and wrong_source.reason
    == "native-consequence-direct-controller-pawn-required")

local no_damage = binding:_on_server_npc_damage(
    player_controller,
    { Attacker = player, NativeDamageValue = 20, NoDamage = true },
    guard
)
assert(not no_damage.ok and no_damage.reason
    == "native-consequence-no-damage-rejected")

local zero = binding:_on_server_npc_damage(
    player_controller,
    { Attacker = player, NativeDamageValue = 0, NoDamage = false },
    guard
)
assert(not zero.ok and zero.reason
    == "native-consequence-positive-damage-required")

local gated = binding:_on_server_npc_damage(
    player_controller_rpc_wrapper,
    { Attacker = player, NativeDamageValue = 20, NoDamage = false },
    guard_rpc_wrapper
)
assert(not gated.ok and gated.observed == true)
assert(gated.authoritative == true)
assert(gated.route == "player-controller-server-npc-damage")
assert(#router.dispatched == 0)

local debounced = binding:_on_server_npc_damage(
    remote_player_controller,
    { Attacker = remote_player, NativeDamageValue = 21,
        NoDamage = false },
    guard
)
assert(not debounced.ok and debounced.reason
    == "native-consequence-target-debounced")

policy.settlementEnabled = true
now = 106
local applied = binding:_on_server_npc_damage(
    player_controller,
    { Attacker = player, NativeDamageValue = 25, NoDamage = false },
    guard
)
assert(applied.ok and applied.applied == -5)
assert(#router.dispatched == 1)
local guard_event = router.dispatched[1]
assert(guard_event.reasonCode == "friendly-fire")
assert(guard_event.penalty == 5)
assert(guard_event.actorRef == guard)
assert(guard_event.nativeConfirmed == true)
assert(guard_event.playerInitiated == true)
assert(guard_event.worldGeneration == 4)
assert(guard_event.damageRoute
    == "player-controller-server-npc-damage")

assert(binding:register_actor({
    bindingId = "spec.native.civilian.1",
    factionId = "pwft.faction.pidf",
    actorRole = "civilian",
    actorRef = civilian,
}).ok)
now = 112
local civilian_component = component(civilian)
local wrong_processed_source = binding:_on_actual_damage_processed(
    civilian_component,
    other,
    civilian,
    1
)
assert(not wrong_processed_source.ok
    and wrong_processed_source.reason
        == "native-consequence-direct-player-actor-required")

local zero_processed_damage = binding:_on_actual_damage_processed(
    civilian_component,
    remote_player,
    civilian,
    0
)
assert(not zero_processed_damage.ok
    and zero_processed_damage.reason
        == "native-consequence-positive-damage-required")

local wrong_owner = binding:_on_actual_damage_processed(
    component(other),
    remote_player,
    civilian,
    1
)
assert(not wrong_owner.ok and wrong_owner.reason
    == "native-consequence-component-owner-mismatch")

local diagnostic_gated = binding:_on_actual_damage_processed(
    civilian_component,
    remote_player,
    civilian,
    1
)
assert(not diagnostic_gated.ok
    and diagnostic_gated.authoritative == false)
assert(#router.dispatched == 1)

local civilian_applied = binding:_on_server_npc_damage(
    remote_player_controller,
    { Attacker = remote_player, NativeDamageValue = 1,
        NoDamage = false },
    civilian
)
assert(civilian_applied.ok and civilian_applied.applied == -10)
assert(#router.dispatched == 1)
assert(#remote_router.dispatched == 1)
assert(remote_router.dispatched[1].reasonCode == "civilian-harm")
assert(remote_router.dispatched[1].penalty == 10)
assert(remote_router.dispatched[1].damageRoute
    == "player-controller-server-npc-damage")
assert(civilian_applied.playerUid
    == "A09AB288B1234567887654321ABCDEF0")

now = 118
local unattributed = binding:_on_server_npc_damage(
    unknown_controller,
    { Attacker = unknown_player, NativeDamageValue = 1,
        NoDamage = false },
    guard
)
assert(not unattributed.ok and unattributed.reason
    == "native-consequence-player-context-unavailable")
assert(#router.dispatched == 1)
assert(#remote_router.dispatched == 1)
assert(binding:status().playerAttributionFailureCount == 1)

router.generation = 5
local stale = binding:_on_server_npc_damage(
    player_controller,
    { Attacker = player, NativeDamageValue = 1, NoDamage = false },
    guard
)
assert(not stale.ok and stale.reason
    == "native-consequence-target-generation-stale")
router.generation = 4

assert(not binding:unregister_actor(
    "spec.native.civilian.1",
    other
).ok)
assert(binding:unregister_actor(
    "spec.native.civilian.1",
    actor(
        "BP_Civilian_C SpecCivilian",
        "BlueprintGeneratedClass /Game/Spec/BP_Civilian.BP_Civilian_C"
    )
).ok)

local restored = restore_listener()
assert(restored.ok and restored.removedBindingCount == 1)
assert(binding:status().registeredActorCount == 0)

hooks[NativeBinding.paths.authoritativeDamage](
    { get = function() return player_controller end },
    { get = function()
        return {
            Attacker = player,
            NativeDamageValue = 1,
            NoDamage = false,
        }
    end },
    { get = function() return other end }
)
assert(binding:status().ignoredUnregisteredCount == 2)
assert(binding:status().settledCount == 2)
assert(binding:status().dispatchFailureCount == 1)

print("PASS current-Build faction-consequence binding registers only the player-controller server NPC damage route, settles exact registered defenders for direct local or remote controller pawns, rejects no-damage/zero/spoofed/stale sources, leaves rejected component routes diagnostic-only, debounces repeated hits, and clears transient actors on restore")
