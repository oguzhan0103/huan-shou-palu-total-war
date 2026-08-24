package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local Registry = require("pwft.registry")
local Progression = require("pwft.faction_progression")
local StrategicWorld = require("pwft.strategic_world")
local UniquePalCampaign = require("pwft.unique_pal_campaign")
local UniquePalBossProviderBus =
    require("pwft.unique_pal_boss_provider_bus")
local UniquePalBossNativeProduction =
    require("pwft.unique_pal_boss_native_production")

local world_pack = require("pwft_b7_unique_pals.strategic_world")
local campaign_pack =
    require("pwft_b7_unique_pals.unique_pal_campaign")
local native_bindings =
    require("pwft_b7_unique_pals.native_bindings")

local function valid_object(name)
    local object = { name = name, destroyed = false }
    function object:IsValid()
        return self.destroyed ~= true
    end
    function object:GetFullName()
        return self.name
    end
    function object:K2_DestroyActor()
        self.destroyed = true
    end
    return object
end

local function guid(seed)
    return {
        A = seed,
        B = seed + 1,
        C = seed + 2,
        D = seed + 3,
    }
end

local function create_runtime(options)
    options = options or {}
    local progression = Progression.create(Registry.progression)
    local world = StrategicWorld.create(progression)
    assert(world:register_pack(world_pack).ok)
    local bus
    local campaign = UniquePalCampaign.create(
        progression,
        world,
        {
            playerId = "local-player",
            onChange = function(event)
                if bus ~= nil then
                    bus:handle_campaign_event(event)
                end
            end,
        }
    )
    assert(campaign:register_pack(campaign_pack).ok)
    bus = UniquePalBossProviderBus.create(campaign)

    local hooks = {}
    local notifications = {}
    local spawn_count = 0
    local actors = {}
    local handles = {}
    local scheduled_callbacks = {}
    local synchronous_initialization_result
    local service
    service = UniquePalBossNativeProduction.create(
        bus,
        campaign,
        {
            enabled = true,
            automaticSchedulerEnabled = false,
            tickIntervalMs = 60000,
            spawnResolveDelaysMs = { 1, 2 },
            spawnOffset = { X = 1200, Y = 0, Z = 80 },
            buildId = "24575825",
            providerId =
                "pwft.native.unique-pal-boss.production",
            authoritySource =
                "pwft.native.unique-pal-boss.authority",
            playerId = "local-player",
        },
        {
            adapters = {
                registerHook = function(path, first, second)
                    hooks[path] = { first = first, second = second }
                    return #hooks + 1, #hooks + 2
                end,
                schedule = function(_, callback)
                    if options.deferScheduled == true then
                        scheduled_callbacks[#scheduled_callbacks + 1] =
                            callback
                    else
                        callback()
                    end
                    return true
                end,
                runInGameThread = function(callback)
                    callback()
                    return true
                end,
                notify = function(message)
                    notifications[#notifications + 1] = message
                    return true
                end,
                spawnBoss = function(binding)
                    if options.spawnBlocked == true then
                        return nil, "spec-native-context-not-ready"
                    end
                    spawn_count = spawn_count + 1
                    local actor = valid_object(
                        binding.expectedActorClassKey
                            .. " Actor_" .. tostring(spawn_count)
                    )
                    if options.synchronousInitializeOnSpawn == true then
                        local individual = valid_object(
                            "SynchronousUniquePalIndividual"
                        )
                        function individual:GetCharacterID()
                            -- UE4SS returns an opaque FName userdata on the
                            -- live Build 24575825 hook, not a Lua string.
                            return {}
                        end
                        function individual:GetSpawnedCharacterType()
                            return 2
                        end
                        local component = valid_object(
                            "SynchronousUniquePalComponent"
                        )
                        component.IndividualParameter = individual
                        actor.CharacterParameterComponent = component
                        actor.StaticCharacterParameterComponent =
                            valid_object("SynchronousUniquePalStatic")
                        actor.StaticCharacterParameterComponent.IsPal = true
                        actor.StaticCharacterParameterComponent
                            .IsBoss_Database = true
                        synchronous_initialization_result = service
                            :observe_initialized_character(actor, component)
                        assert(synchronous_initialization_result.ok)
                        assert(actor.destroyed == false)
                    end
                    local handle = valid_object(
                        "Handle_" .. tostring(spawn_count)
                    )
                    handle.actor = actor
                    handle.individualId = {
                        PlayerUId = guid(spawn_count),
                        InstanceId = guid(spawn_count + 100),
                    }
                    function handle:GetIndividualID()
                        return self.individualId
                    end
                    function handle:TryGetIndividualActor()
                        return self.actor
                    end
                    actors[binding.uniquePalId] = actor
                    handles[binding.uniquePalId] = handle
                    return handle
                end,
                resolveActor = function(handle)
                    return handle.actor
                end,
                applyBalance = function(_, balance)
                    assert(balance.profileId == "raid-slab")
                    assert(balance.level == 80)
                    assert(balance.healthMultiplier == 12)
                    assert(balance.damageMultiplier == 2.5)
                    assert(balance.captureAllowed == true)
                    return true, "spec-balance-readback"
                end,
                captureBoss = function()
                    return true
                end,
                weakenBoss = function(actor, binding)
                    assert(actor ~= nil)
                    assert(binding.uniquePalId ~= nil)
                    return true, "spec-current-hp-one"
                end,
            },
        }
    )
    local activated = service:activate(native_bindings)
    assert(activated.ok, tostring(activated.reason))
    assert(activated.bindingCount == 5)
    return {
        progression = progression,
        world = world,
        campaign = campaign,
        bus = bus,
        service = service,
        hooks = hooks,
        notifications = notifications,
        actors = actors,
        handles = handles,
        synchronousInitializationResult = function()
            return synchronous_initialization_result
        end,
        flushScheduled = function()
            local safety = 0
            while #scheduled_callbacks > 0 do
                safety = safety + 1
                assert(safety < 100,
                    "scheduled callback loop did not settle")
                local callback = table.remove(scheduled_callbacks, 1)
                callback()
            end
        end,
    }
end

local synchronous_runtime = create_runtime({
    synchronousInitializeOnSpawn = true,
})
assert(synchronous_runtime.service:force_open(
    "pwft.unique.anubis"
).ok)
local synchronous_allowed =
    synchronous_runtime:synchronousInitializationResult()
assert(synchronous_allowed.uniquePalId == "pwft.unique.anubis")
assert(synchronous_runtime.service:status().allowedUniqueBossCount == 1)

local capture_runtime = create_runtime()
local capture_service = capture_runtime.service
local capture_opened = capture_service:force_open(
    "pwft.unique.anubis"
)
assert(capture_opened.ok, tostring(capture_opened.reason))
assert(capture_runtime.campaign:campaign_status(
    "pwft.unique.anubis"
).phase == "open")
assert(capture_service:status().spawnConfirmedCount == 1)
assert(capture_service:status().activeRecordCount == 1)
assert(capture_service:status().hooksRegistered == true)
assert(capture_service:status().hookCount == 3)
assert(capture_runtime.bus:status().activeBindingCount == 5)
assert(capture_runtime.bus:boss_spawn_policy("Anubis").ok)
assert(capture_runtime.bus:boss_spawn_policy("SheepBall").reason
    == "non-unique-pal-boss-suppressed")
local captured = capture_service:capture_active(
    "pwft.unique.anubis"
)
assert(captured.ok and captured.reason
    == "unique-pal-captured-by-player")
assert(capture_runtime.world:unique_pal_status(
    "pwft.unique.anubis"
).owner.kind == "player")
assert(capture_service:status().captureConfirmedCount == 1)

local defeat_runtime = create_runtime()
assert(defeat_runtime.service:force_open(
    "pwft.unique.anubis"
).ok)
local weakened = defeat_runtime.service:weaken_active(
    "pwft.unique.anubis"
)
assert(weakened.ok and weakened.currentHp == 1)
local defeated = defeat_runtime.service:observe_death(
    defeat_runtime.actors["pwft.unique.anubis"]
)
assert(defeated.ok and defeated.reason
    == "unique-pal-boss-defeated-without-ownership-transfer")
assert(defeat_runtime.world:unique_pal_status(
    "pwft.unique.anubis"
).owner.kind == "wild")
assert(defeat_runtime.service:status().defeatConfirmedCount == 1)

-- The production initializer gate destroys a Pal Boss that is not the exact
-- actor from an active unique-Pal request. Ordinary Pals remain untouched.
local suppressed_actor = valid_object(
    "/Game/Pal/BP_SheepBall_BOSS.BP_SheepBall_BOSS_C Actor"
)
local suppressed_individual = valid_object("SheepBallIndividual")
function suppressed_individual:GetCharacterID() return "BOSS_SheepBall" end
function suppressed_individual:GetSpawnedCharacterType() return 2 end
local suppressed_component = valid_object("SheepBallComponent")
suppressed_component.IndividualParameter = suppressed_individual
suppressed_actor.CharacterParameterComponent = suppressed_component
suppressed_actor.StaticCharacterParameterComponent = valid_object(
    "SheepBallStatic"
)
suppressed_actor.StaticCharacterParameterComponent.IsPal = true
suppressed_actor.StaticCharacterParameterComponent.IsBoss_Database = true
local suppression = defeat_runtime.service:observe_initialized_character(
    suppressed_actor,
    suppressed_component
)
assert(suppression.ok and suppression.suppressed == true)
assert(suppressed_actor.destroyed == true)
assert(defeat_runtime.service:status().suppressedBossCount == 1)

local timeout_runtime = create_runtime()
assert(timeout_runtime.service:force_open(
    "pwft.unique.anubis"
).ok)
local timed_out = timeout_runtime.service:force_timeout(
    "pwft.unique.anubis"
)
assert(timed_out.ok, tostring(timed_out.reason))
assert(timeout_runtime.world:unique_pal_status(
    "pwft.unique.anubis"
).owner.kind == "faction")
assert(timeout_runtime.service:status().timeoutConfirmedCount == 1)
assert(timeout_runtime.service:status().cleanupCount == 1,
    string.format(
        "timeout cleanup missing: cleanup=%d active=%d notifications=%d campaignError=%s busPending=%d",
        timeout_runtime.service:status().cleanupCount,
        timeout_runtime.service:status().activeRecordCount,
        timeout_runtime.service:status().notificationCount,
        tostring(timeout_runtime.campaign:status()
            .lastNotificationError),
        timeout_runtime.bus:status().pendingDeliveryCount
    ))

local before_generation = timeout_runtime.bus:status().worldGeneration
assert(timeout_runtime.service:unbind_world("spec-unload").ok)
assert(timeout_runtime.bus:unbind_world("spec-unload").ok)
assert(timeout_runtime.bus:status().worldGeneration
    == before_generation + 1)
assert(timeout_runtime.service:status().active == false)
assert(timeout_runtime.service:status().bindingCount == 0)

-- A spawn request may become activation-pending immediately before a map
-- change. Rebinding the next world generation must retry that exact event
-- after all five bindings are restored, without scheduling a second opening.
local rebound_options = {
    deferScheduled = true,
    spawnBlocked = true,
}
local rebound_runtime = create_runtime(rebound_options)
local pending_open = rebound_runtime.service:force_open(
    "pwft.unique.anubis"
)
assert(pending_open.ok)
assert(rebound_runtime.campaign:campaign_status(
    "pwft.unique.anubis"
).phase == "activation-pending")
assert(rebound_runtime.bus:status().pendingDeliveryCount == 1)
assert(rebound_runtime.service:status().activeRecordCount == 0)
assert(rebound_runtime.service:unbind_world("spec-pending-unload").ok)
assert(rebound_runtime.bus:unbind_world("spec-pending-unload").ok)
rebound_options.spawnBlocked = false
local rebound = rebound_runtime.service:activate(native_bindings)
assert(rebound.ok, tostring(rebound.reason))
rebound_runtime.flushScheduled()
assert(rebound_runtime.campaign:campaign_status(
    "pwft.unique.anubis"
).phase == "open")
assert(rebound_runtime.service:status().spawnConfirmedCount == 1)
assert(rebound_runtime.service:status().activeRecordCount == 1)
assert(rebound_runtime.bus:status().pendingDeliveryCount == 0)

assert(#capture_runtime.notifications >= 3)
print("PASS B7 native unique-Pal production activates five verified Build-24575825 Boss bindings, opens real scheduled windows, resolves exact actors, applies raid-slab balance with QA one-HP death-hook preparation, destroys non-active Pal Boss actors at native initialization, and confirms capture, defeat, timeout, cleanup, and generation fencing")
