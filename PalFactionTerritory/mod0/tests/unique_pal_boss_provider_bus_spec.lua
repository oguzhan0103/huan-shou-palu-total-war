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

local rayne = "pwft.faction.rayne_syndicate"
local pidf = "pwft.faction.pidf"
local player_id = "local-player"

local world_pack = {
    schemaVersion = "pwft.strategic-world.pack.v1",
    contentPackId = "spec.unique-pal.native.world",
    contentVersion = "1.0.0",
    uniquePals = {
        {
            id = "spec.unique-pal.native.existing",
            speciesId = "SheepBall",
            displayNameKey = "spec.loc.unique-pal.native.existing.name",
            initialOwner = { kind = "wild" },
        },
        {
            id = "spec.unique-pal.native.replacement",
            speciesId = "Alpaca",
            displayNameKey = "spec.loc.unique-pal.native.replacement.name",
            initialOwner = { kind = "wild" },
        },
    },
    cities = {},
}

local campaign_pack = {
    schemaVersion = "pwft.unique-pal-campaign.pack.v1",
    contentPackId = "spec.unique-pal.native.campaign",
    contentVersion = "1.0.0",
    uniquePals = {
        {
            id = "spec.unique-pal.native.existing",
            target = {
                kind = "faction",
                id = rayne,
                affectedFactionIds = { rayne },
            },
            boss = {
                speciesId = "SheepBall",
                nativeBossAvailable = true,
                bindingStatus = "bound",
                strengthProfile = "raid-slab",
            },
            schedule = {
                minimumIntervalTicks = 1,
                maximumIntervalTicks = 1,
                noticeTicks = 1,
                openTicks = 3,
            },
            ransomPrice = 99999999,
            candidateFactionIds = { pidf },
        },
        {
            id = "spec.unique-pal.native.replacement",
            target = {
                kind = "faction",
                id = pidf,
                affectedFactionIds = { pidf },
            },
            boss = {
                speciesId = "Alpaca",
                nativeBossAvailable = false,
                nativeBossSlotId = "BossSpawner:SpecUnusedSlot",
                bindingStatus = "bound",
                strengthProfile = "raid-slab",
            },
            schedule = {
                minimumIntervalTicks = 1,
                maximumIntervalTicks = 1,
                noticeTicks = 1,
                openTicks = 3,
            },
            ransomPrice = 88888888,
            candidateFactionIds = { rayne },
        },
    },
}

local function create_runtime(snapshot)
    local progression = Progression.create(Registry.progression, snapshot)
    local world = StrategicWorld.create(progression)
    local world_registration = world:register_pack(world_pack)
    assert(world_registration.ok,
        tostring(world_registration.reason) .. ":"
            .. tostring(world_registration.error))
    local bus
    local campaign = UniquePalCampaign.create(
        progression,
        world,
        {
            playerId = player_id,
            onChange = function(event)
                if bus ~= nil then bus:handle_campaign_event(event) end
            end,
        }
    )
    assert(campaign:register_pack(campaign_pack).ok)
    bus = UniquePalBossProviderBus.create(campaign)
    return progression, world, campaign, bus
end

local progression, world, campaign, bus = create_runtime()
local deliveries = {}
local fail_announce_once = true
local provider = {
    providerId = "spec.unique-pal.native.provider",
    authoritySource = "spec.unique-pal.native.authority",
    deliveryKinds = {
        "announce",
        "spawn",
        "open",
        "close",
        "cooldown",
    },
    idempotentDeliveryIds = true,
    generationFencedCallbacks = true,
}
local function handler(payload, context)
    deliveries[#deliveries + 1] = {
        deliveryId = payload.deliveryId,
        deliveryKind = payload.deliveryKind,
        uniquePalId = payload.uniquePalId,
        route = payload.nativeRoute,
        generation = context.worldGeneration,
        captureAllowed = payload.balance
            and payload.balance.captureAllowed or nil,
    }
    if payload.deliveryKind == "announce" and fail_announce_once then
        fail_announce_once = false
        return {
            ok = false,
            applied = false,
            deliveryId = payload.deliveryId,
            reason = "spec-injected-announcement-failure",
        }
    end
    return {
        ok = true,
        applied = payload.deliveryKind ~= "spawn",
        accepted = payload.deliveryKind == "spawn",
        deliveryId = payload.deliveryId,
        requestId = payload.deliveryKind == "spawn"
                and (payload.deliveryId .. ":native-request") or nil,
        reason = "spec-native-delivery-applied",
    }
end
assert(bus:register_provider(provider, handler).ok)

local balance = {
    profileId = "raid-slab",
    level = 55,
    healthMultiplier = 8,
    damageMultiplier = 2,
    damageReductionMultiplier = 1.5,
    statusResistanceMultiplier = 3,
    captureDifficultyMultiplier = 4,
    captureAllowed = true,
}
local existing_binding = {
    bindingId = "spec.unique-pal.native.binding.existing",
    providerId = provider.providerId,
    uniquePalId = "spec.unique-pal.native.existing",
    speciesId = "SheepBall",
    route = "native-existing",
    bossSpawnerKey = "BossSpawner:SpecExisting",
    expectedActorClassKey = "BP_SheepBallBoss_C",
    locationKey = "Location:SpecExistingBossArena",
    buildId = "spec-build-24467282",
    verification = {
        speciesId = true,
        spawnerKey = true,
        actorClassKey = true,
    },
    balance = balance,
}
local unverified = {}
for key, value in pairs(existing_binding) do unverified[key] = value end
unverified.bindingId = "spec.unique-pal.native.binding.unverified"
unverified.verification = {
    speciesId = true,
    spawnerKey = false,
    actorClassKey = true,
}
assert(bus:bind(unverified).reason == "invalid-unique-pal-boss-binding")
assert(bus:bind(existing_binding).ok)

assert(bus:boss_spawn_policy("NotWhitelistedSpecies").reason
    == "non-unique-pal-boss-suppressed")
assert(bus:boss_spawn_policy("SheepBall").reason
    == "unique-pal-boss-window-closed")

local opening = campaign:schedule_next(
    "spec.unique-pal.native.existing",
    0,
    "spec.native.schedule.existing.1"
)
assert(opening.ok)
assert(campaign:advance(
    opening.openTick,
    "spec.native.advance.existing.open"
).ok)
assert(bus:status().pendingDeliveryCount == 1)
assert(bus:retry_pending("spec.unique-pal.native.existing").ok)
assert(bus:status().pendingDeliveryCount == 0)
assert(campaign:campaign_status(
    "spec.unique-pal.native.existing"
).phase == "activation-pending")
local authorized = bus:boss_spawn_policy("SheepBall")
assert(authorized.ok and authorized.nativeRoute == "native-existing")
assert(authorized.balance.profileId == "raid-slab")
assert(authorized.balance.captureAllowed == true)

local generation = bus:status().worldGeneration
local function callback(callback_id, unique_pal_id, event_id, binding,
    actor_binding_id, actor_class_key, species_id, spawner_key, tick)
    return {
        callbackId = callback_id,
        providerId = provider.providerId,
        authoritySource = provider.authoritySource,
        bindingId = binding.bindingId,
        uniquePalId = unique_pal_id,
        eventId = event_id,
        speciesId = species_id,
        bossSpawnerKey = spawner_key,
        actorBindingId = actor_binding_id,
        actorClassKey = actor_class_key,
        worldGeneration = generation,
        logicalTick = tick,
        playerId = player_id,
    }
end

local existing_spawn = callback(
    "spec.native.spawn.existing.1",
    "spec.unique-pal.native.existing",
    opening.eventId,
    existing_binding,
    "ActorBinding:SpecExistingBoss:1",
    existing_binding.expectedActorClassKey,
    existing_binding.speciesId,
    existing_binding.bossSpawnerKey,
    opening.openTick
)
local stale_spawn = {}
for key, value in pairs(existing_spawn) do stale_spawn[key] = value end
stale_spawn.callbackId = "spec.native.spawn.existing.stale"
stale_spawn.worldGeneration = generation - 1
assert(bus:confirm_spawn(stale_spawn).reason
    == "native-unique-pal-callback-generation-rejected")
local spawned = bus:confirm_spawn(existing_spawn)
assert(spawned.ok and spawned.reason == "unique-pal-opening-started")
assert(campaign:campaign_status(
    "spec.unique-pal.native.existing"
).phase == "open")

local capture = callback(
    "spec.native.capture.existing.1",
    "spec.unique-pal.native.existing",
    opening.eventId,
    existing_binding,
    existing_spawn.actorBindingId,
    existing_binding.expectedActorClassKey,
    existing_binding.speciesId,
    existing_binding.bossSpawnerKey,
    spawned.openTick + 1
)
local captured = bus:confirm_capture(capture)
assert(captured.ok and captured.reason == "unique-pal-captured-by-player")
assert(world:unique_pal_status(
    "spec.unique-pal.native.existing"
).owner.kind == "player")
local duplicate_capture = bus:confirm_capture(capture)
assert(duplicate_capture.ok and duplicate_capture.reason
    == "duplicate-native-unique-pal-callback")
local conflicting_capture = {}
for key, value in pairs(capture) do conflicting_capture[key] = value end
conflicting_capture.playerId = "some-other-player"
assert(bus:confirm_capture(conflicting_capture).reason
    == "native-unique-pal-callback-id-conflict")

local replacement_binding = {
    bindingId = "spec.unique-pal.native.binding.replacement",
    providerId = provider.providerId,
    uniquePalId = "spec.unique-pal.native.replacement",
    speciesId = "Alpaca",
    route = "replacement-slot",
    nativeBossSlotId = "BossSpawner:SpecUnusedSlot",
    bossSpawnerKey = "BossSpawner:SpecUnusedSlot",
    expectedActorClassKey = "BP_AlpacaBossReplacement_C",
    locationKey = "Location:SpecReplacementBossArena",
    buildId = "spec-build-24467282",
    verification = {
        speciesId = true,
        spawnerKey = true,
        actorClassKey = true,
        slotId = true,
    },
    balance = balance,
}
assert(bus:bind(replacement_binding).ok)
local replacement_opening = campaign:schedule_next(
    "spec.unique-pal.native.replacement",
    spawned.openTick + 1,
    "spec.native.schedule.replacement.1"
)
assert(replacement_opening.ok)
assert(campaign:advance(
    replacement_opening.openTick,
    "spec.native.advance.replacement.open.1"
).ok)
local replacement_spawn = callback(
    "spec.native.spawn.replacement.1",
    "spec.unique-pal.native.replacement",
    replacement_opening.eventId,
    replacement_binding,
    "ActorBinding:SpecReplacementBoss:1",
    replacement_binding.expectedActorClassKey,
    replacement_binding.speciesId,
    replacement_binding.bossSpawnerKey,
    replacement_opening.openTick
)
assert(bus:confirm_spawn(replacement_spawn).ok)
local defeated = bus:confirm_defeat(callback(
    "spec.native.defeat.replacement.1",
    "spec.unique-pal.native.replacement",
    replacement_opening.eventId,
    replacement_binding,
    replacement_spawn.actorBindingId,
    replacement_binding.expectedActorClassKey,
    replacement_binding.speciesId,
    replacement_binding.bossSpawnerKey,
    replacement_opening.openTick + 1
))
assert(defeated.ok and defeated.reason
    == "unique-pal-boss-defeated-without-ownership-transfer")
assert(world:unique_pal_status(
    "spec.unique-pal.native.replacement"
).owner.kind == "wild")
assert(campaign:campaign_status(
    "spec.unique-pal.native.replacement"
).phase == "closed")

local timeout_opening = campaign:schedule_next(
    "spec.unique-pal.native.replacement",
    replacement_opening.openTick + 1,
    "spec.native.schedule.replacement.2"
)
assert(timeout_opening.ok)
assert(campaign:advance(
    timeout_opening.openTick,
    "spec.native.advance.replacement.open.2"
).ok)
local timeout_spawn = callback(
    "spec.native.spawn.replacement.2",
    "spec.unique-pal.native.replacement",
    timeout_opening.eventId,
    replacement_binding,
    "ActorBinding:SpecReplacementBoss:2",
    replacement_binding.expectedActorClassKey,
    replacement_binding.speciesId,
    replacement_binding.bossSpawnerKey,
    timeout_opening.openTick
)
local timeout_spawned = bus:confirm_spawn(timeout_spawn)
assert(timeout_spawned.ok)
local early_timeout = callback(
    "spec.native.timeout.replacement.early",
    "spec.unique-pal.native.replacement",
    timeout_opening.eventId,
    replacement_binding,
    timeout_spawn.actorBindingId,
    replacement_binding.expectedActorClassKey,
    replacement_binding.speciesId,
    replacement_binding.bossSpawnerKey,
    timeout_spawned.closeTick - 1
)
assert(bus:confirm_timeout(early_timeout).reason
    == "native-unique-pal-timeout-too-early")
local timeout = callback(
    "spec.native.timeout.replacement.1",
    "spec.unique-pal.native.replacement",
    timeout_opening.eventId,
    replacement_binding,
    timeout_spawn.actorBindingId,
    replacement_binding.expectedActorClassKey,
    replacement_binding.speciesId,
    replacement_binding.bossSpawnerKey,
    timeout_spawned.closeTick
)
local timed_out = bus:confirm_timeout(timeout)
assert(timed_out.ok)
assert(world:unique_pal_status(
    "spec.unique-pal.native.replacement"
).owner.kind == "faction")
assert(world:unique_pal_status(
    "spec.unique-pal.native.replacement"
).owner.id == rayne)

local kind_counts = {}
for _, delivery in ipairs(deliveries) do
    kind_counts[delivery.deliveryKind] =
        (kind_counts[delivery.deliveryKind] or 0) + 1
    assert(delivery.generation == generation)
    if delivery.deliveryKind == "spawn" then
        assert(delivery.captureAllowed == true)
    end
end
for _, kind in ipairs({ "announce", "spawn", "open", "close", "cooldown" }) do
    assert((kind_counts[kind] or 0) >= 3, kind)
end

local snapshot = progression:export_snapshot()
local _, _, restored_campaign, restored_bus = create_runtime(snapshot)
local restored_status = restored_bus:status()
assert(restored_status.providerCount == 1)
assert(restored_status.activeProviderHandlerCount == 0)
assert(restored_status.activeBindingCount == 0)
assert(restored_status.handlersPersisted == false)
assert(restored_status.bindingsPersisted == false)
assert(restored_status.worldGeneration > generation)
assert(restored_campaign:campaign_status(
    "spec.unique-pal.native.replacement"
).phase == "owned")
assert(restored_bus:register_provider(provider, handler).reason
    == "unique-pal-boss-provider-rebound")
assert(restored_bus:bind(replacement_binding).ok)

local before_unbind = restored_bus:status().worldGeneration
assert(restored_bus:unbind_world("spec-world-unload").ok)
assert(restored_bus:status().worldGeneration == before_unbind + 1)
assert(restored_bus:status().activeProviderHandlerCount == 0)
assert(restored_bus:status().activeBindingCount == 0)

print("PASS unique-Pal Boss provider bus enforces the whitelist and verified native/replacement bindings, delivers native opening presentation idempotently, accepts generation-fenced spawn/defeat/capture/timeout callbacks, preserves defeat ownership, and restores without handlers or bindings")
