package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local Registry = require("pwft.registry")
local Progression = require("pwft.faction_progression")
local StrategicWorld = require("pwft.strategic_world")
local UniquePalCampaign = require("pwft.unique_pal_campaign")
local UniquePalWorldEffectBus =
    require("pwft.unique_pal_world_effect_bus")

local rayne = "pwft.faction.rayne_syndicate"
local pidf = "pwft.faction.pidf"
local genetics = "pwft.faction.pal_genetic_research_unit"
local player_id = "local-player"

local world_pack = {
    schemaVersion = "pwft.strategic-world.pack.v1",
    contentPackId = "spec.unique-pal.effects.world",
    contentVersion = "1.0.0",
    uniquePals = {
        {
            id = "spec.unique-pal.effects.background",
            speciesId = "SheepBall",
            displayNameKey = "spec.loc.unique-pal.effects.background.name",
            initialOwner = { kind = "faction", id = genetics },
        },
        {
            id = "spec.unique-pal.effects.defense",
            speciesId = "Alpaca",
            displayNameKey = "spec.loc.unique-pal.effects.defense.name",
            initialOwner = { kind = "faction", id = genetics },
        },
    },
    cities = {
        {
            id = "spec.city.effects.rayne",
            factionId = rayne,
            displayNameKey = "spec.loc.city.effects.rayne.name",
            requiredUniquePalId = "spec.unique-pal.effects.background",
            restorable = true,
        },
        {
            id = "spec.city.effects.pidf",
            factionId = pidf,
            displayNameKey = "spec.loc.city.effects.pidf.name",
            requiredUniquePalId = "spec.unique-pal.effects.defense",
            restorable = true,
        },
    },
}

local campaign_pack = {
    schemaVersion = "pwft.unique-pal-campaign.pack.v1",
    contentPackId = "spec.unique-pal.effects.campaign",
    contentVersion = "1.0.0",
    uniquePals = {
        {
            id = "spec.unique-pal.effects.background",
            target = {
                kind = "faction",
                id = rayne,
                affectedFactionIds = { rayne },
            },
            boss = {
                speciesId = "SheepBall",
                nativeBossAvailable = false,
                bindingStatus = "pending",
                strengthProfile = "raid-slab",
            },
            schedule = {
                minimumIntervalTicks = 1,
                maximumIntervalTicks = 1,
                noticeTicks = 1,
                openTicks = 1,
            },
            ransomPrice = 99999999,
            candidateFactionIds = { genetics },
        },
        {
            id = "spec.unique-pal.effects.defense",
            target = {
                kind = "faction",
                id = pidf,
                affectedFactionIds = { pidf },
            },
            boss = {
                speciesId = "Alpaca",
                nativeBossAvailable = false,
                bindingStatus = "pending",
                strengthProfile = "raid-slab",
            },
            schedule = {
                minimumIntervalTicks = 1,
                maximumIntervalTicks = 1,
                noticeTicks = 1,
                openTicks = 1,
            },
            ransomPrice = 88888888,
            candidateFactionIds = { rayne },
        },
    },
}

local function create_runtime(snapshot)
    local progression = Progression.create(Registry.progression, snapshot)
    local world = StrategicWorld.create(progression)
    assert(world:register_pack(world_pack).ok)
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
    bus = UniquePalWorldEffectBus.create(campaign)
    return progression, world, campaign, bus
end

local progression, world, campaign, bus = create_runtime()
local deliveries = {}
local fail_pal_delivery_once = true
local provider = {
    providerId = "spec.unique-pal.effects.provider",
    authoritySource = "spec.unique-pal.effects.authority",
    deliveryKinds = {
        "war-notice",
        "player-defense-request",
        "world-spawn-suppression",
        "loaded-actor-cleanup",
        "empty-city",
        "merchant-filter",
        "ransom-offer",
        "pal-delivery",
    },
    idempotentDeliveryIds = true,
    generationFencedCallbacks = true,
}
local function handler(payload, context)
    deliveries[#deliveries + 1] = {
        deliveryId = payload.deliveryId,
        deliveryKind = payload.deliveryKind,
        targetKey = payload.targetKey,
        generation = context.worldGeneration,
        broadActorScanAllowed = payload.broadActorScanAllowed,
        deleteMapActors = payload.deleteMapActors,
        preserveBuildings = payload.preserveBuildings,
        cleanupActorBindings = payload.cleanupActorBindings,
        nativeRoutes = payload.nativeRoutes,
        speciesId = payload.speciesId,
    }
    if payload.deliveryKind == "pal-delivery"
        and fail_pal_delivery_once then
        fail_pal_delivery_once = false
        return {
            ok = false,
            delivered = false,
            deliveryId = payload.deliveryId,
            reason = "spec-injected-pal-delivery-failure",
        }
    end
    if payload.deliveryKind == "player-defense-request" then
        return {
            ok = true,
            accepted = true,
            deliveryId = payload.deliveryId,
            nativeRaidId = payload.deliveryId .. ":native-raid",
            reason = "spec-defense-request-accepted",
        }
    end
    if payload.deliveryKind == "ransom-offer" then
        return {
            ok = true,
            accepted = true,
            deliveryId = payload.deliveryId,
            nativeOfferId = payload.deliveryId .. ":native-offer",
            reason = "spec-ransom-offer-presented",
        }
    end
    if payload.deliveryKind == "pal-delivery" then
        return {
            ok = true,
            accepted = true,
            deliveryId = payload.deliveryId,
            requestId = payload.deliveryId .. ":native-pal-delivery",
            individualKey = payload.deliveryId .. ":individual",
            reason = "spec-pal-delivery-requested",
        }
    end
    return {
        ok = true,
        applied = true,
        deliveryId = payload.deliveryId,
        reason = "spec-world-effect-applied",
    }
end
assert(bus:register_provider(provider, handler).ok)
assert(bus:status().fullyCapableProviderCount == 1)

local function target_binding(target_id, city_id, faction_id, suffix)
    return {
        bindingId = "spec.unique-pal.effects.binding." .. suffix,
        providerId = provider.providerId,
        targetKind = "faction",
        targetId = target_id,
        buildId = "spec-build-24467282",
        nativeRoutes = {
            textPresenterKey = "TextPresenter:" .. suffix,
            defenseRaidKey = "DefenseRaid:" .. suffix,
            backgroundWarResolverKey = "BackgroundWarResolver:" .. suffix,
            ransomPaymentKey = "RansomPayment:" .. suffix,
            palDeliveryKey = "PalDelivery:" .. suffix,
        },
        spawnBindings = {
            {
                spawnKind = "settlement-npc",
                spawnerKey = "Spawner:Settlement:" .. suffix,
                actorClassKeys = {
                    "BP_SettlementNpc_" .. suffix .. "_C",
                },
            },
            {
                spawnKind = "faction-patrol",
                spawnerKey = "Spawner:Patrol:" .. suffix,
                actorClassKeys = {
                    "BP_FactionPatrol_" .. suffix .. "_C",
                },
            },
        },
        cleanupActorBindings = {
            {
                actorBindingId = "ActorBinding:SettlementNpc:" .. suffix,
                actorClassKey = "BP_SettlementNpc_" .. suffix .. "_C",
            },
        },
        cityBindings = {
            {
                cityId = city_id,
                cityAnchorKey = "CityAnchor:" .. suffix,
                residentSpawnerKeys = {
                    "Spawner:Residents:" .. suffix,
                },
                functionSpawnerKeys = {
                    "Spawner:FunctionNpcs:" .. suffix,
                },
            },
        },
        merchantCounterFactionIds = { faction_id },
        verification = {
            currentBuild = true,
            spawners = true,
            actorClasses = true,
            nativeRoutes = true,
            cityAnchors = true,
            merchantCounters = true,
        },
    }
end

local rayne_binding = target_binding(
    rayne,
    "spec.city.effects.rayne",
    rayne,
    "rayne"
)
local pidf_binding = target_binding(
    pidf,
    "spec.city.effects.pidf",
    pidf,
    "pidf"
)
local unsafe_binding = target_binding(
    rayne,
    "spec.city.effects.rayne",
    rayne,
    "unsafe"
)
unsafe_binding.bindingId = "spec.unique-pal.effects.binding.unsafe"
unsafe_binding.verification.actorClasses = false
assert(bus:bind_target(unsafe_binding).reason
    == "invalid-unique-pal-world-effect-binding")
assert(bus:bind_target(rayne_binding).ok)
assert(bus:bind_target(pidf_binding).ok)
assert(bus:status().fullyOperationalTargetBindingCount == 2)

local generation = bus:status().worldGeneration
local background = campaign:declare_destruction_war(
    "spec.unique-pal.effects.background",
    "spec.unique-pal.effects.war.background.1",
    1,
    "spec.unique-pal.effects.declare.background.1"
)
assert(background.ok and background.war.route == "background")
local background_result = {
    callbackId = "spec.unique-pal.effects.resolve.background.1",
    providerId = provider.providerId,
    authoritySource = provider.authoritySource,
    bindingId = rayne_binding.bindingId,
    worldGeneration = generation,
    warId = background.war.id,
    backgroundWarResolverKey =
        rayne_binding.nativeRoutes.backgroundWarResolverKey,
    attackerWon = true,
}
local destroyed = bus:confirm_background_war(background_result)
assert(destroyed.ok and destroyed.targetDestroyed == true)
assert(world:city_status("spec.city.effects.rayne").status
    == "destroyed")
assert(bus:faction_spawn_policy(rayne, "settlement-npc").suppressSpawn)
assert(bus:merchant_counter_policy(rayne).suppressSpawn)
assert(bus:faction_spawn_policy(pidf, "settlement-npc").ok)
local duplicate_background = bus:confirm_background_war(background_result)
assert(duplicate_background.ok and duplicate_background.reason
    == "duplicate-unique-pal-world-callback")

assert(progression:join(pidf).ok)
local defense = campaign:declare_destruction_war(
    "spec.unique-pal.effects.defense",
    "spec.unique-pal.effects.war.defense.1",
    2,
    "spec.unique-pal.effects.declare.defense.1"
)
assert(defense.ok and defense.war.route == "player-defense",
    tostring(defense.reason) .. ":" .. tostring(defense.war
        and defense.war.route))
local defense_delivery = bus.deliveries[
    "unique-pal-world." .. defense.war.id .. ".player-defense-request"
]
assert(defense_delivery.status == "applied")
local defense_result = {
    callbackId = "spec.unique-pal.effects.resolve.defense.1",
    providerId = provider.providerId,
    authoritySource = provider.authoritySource,
    bindingId = pidf_binding.bindingId,
    worldGeneration = generation,
    warId = defense.war.id,
    nativeRaidId = defense_delivery.providerRequestId,
    defenseRaidKey = pidf_binding.nativeRoutes.defenseRaidKey,
    playerParticipated = true,
    playerSideWon = true,
}
local defended = bus:confirm_player_defense(defense_result)
assert(defended.ok and defended.targetDestroyed == false)
assert(world:city_status("spec.city.effects.pidf").status == "active")

local ransom_war = campaign:declare_destruction_war(
    "spec.unique-pal.effects.defense",
    "spec.unique-pal.effects.war.defense.2",
    3,
    "spec.unique-pal.effects.declare.defense.2"
)
assert(ransom_war.ok and ransom_war.war.route == "player-defense")
local offered = bus:offer_ransom(
    "spec.unique-pal.effects.defense",
    player_id,
    "spec.unique-pal.effects.ransom.offer.1"
)
assert(offered.ok and offered.offer.amount == 88888888)
assert(offered.offer.nativeOfferId ~= nil)
local duplicate_offer = bus:offer_ransom(
    "spec.unique-pal.effects.defense",
    player_id,
    "spec.unique-pal.effects.ransom.offer.1"
)
assert(duplicate_offer.ok)
local payment = {
    callbackId = "spec.unique-pal.effects.ransom.transaction.1",
    providerId = provider.providerId,
    authoritySource = provider.authoritySource,
    bindingId = pidf_binding.bindingId,
    worldGeneration = generation,
    offerId = offered.offer.offerId,
    nativeOfferId = offered.offer.nativeOfferId,
    ransomPaymentKey = pidf_binding.nativeRoutes.ransomPaymentKey,
    uniquePalId = offered.offer.uniquePalId,
    playerId = player_id,
    currency = offered.offer.currency,
    amount = offered.offer.amount,
    paid = true,
}
local wrong_amount = {}
for key, value in pairs(payment) do wrong_amount[key] = value end
wrong_amount.callbackId = "spec.unique-pal.effects.ransom.transaction.wrong"
wrong_amount.amount = 1
assert(bus:confirm_ransom_payment(wrong_amount).reason
    == "unique-pal-ransom-payment-quote-mismatch")
local paid = bus:confirm_ransom_payment(payment)
assert(paid.ok and paid.reason == "unique-pal-ransom-settled")
assert(campaign:war_status(ransom_war.war.id).status == "cancelled")
assert(world:unique_pal_status(
    "spec.unique-pal.effects.defense"
).owner.kind == "player")
assert(bus:status().pendingDeliveryCount == 1)
local delivery_retry = bus:retry_pending("faction:" .. pidf)
assert(not delivery_retry.ok and delivery_retry.pendingCount == 1)
local pal_delivery_id = "unique-pal-world."
    .. payment.callbackId .. ".pal-delivery"
local pending_pal_delivery = bus:delivery_status(pal_delivery_id)
assert(pending_pal_delivery.status == "awaiting-confirmation")
assert(pending_pal_delivery.providerRequestId
    == pal_delivery_id .. ":native-pal-delivery")
assert(pending_pal_delivery.providerIndividualKey
    == pal_delivery_id .. ":individual")
local pal_delivery_callback = {
    callbackId = "spec.unique-pal.effects.pal.delivery.confirm.1",
    providerId = provider.providerId,
    authoritySource = provider.authoritySource,
    bindingId = pidf_binding.bindingId,
    worldGeneration = generation,
    deliveryId = pal_delivery_id,
    nativeDeliveryId = pending_pal_delivery.providerRequestId,
    nativeIndividualKey = pending_pal_delivery.providerIndividualKey,
    palDeliveryKey = pidf_binding.nativeRoutes.palDeliveryKey,
    uniquePalId = offered.offer.uniquePalId,
    speciesId = "Alpaca",
    playerId = player_id,
}
local wrong_individual = {}
for key, value in pairs(pal_delivery_callback) do
    wrong_individual[key] = value
end
wrong_individual.callbackId =
    "spec.unique-pal.effects.pal.delivery.confirm.wrong-individual"
wrong_individual.nativeIndividualKey = "spec:wrong-individual"
assert(bus:confirm_pal_delivery(wrong_individual).reason
    == "unique-pal-native-delivery-callback-rejected")
local wrong_species = {}
for key, value in pairs(pal_delivery_callback) do
    wrong_species[key] = value
end
wrong_species.callbackId =
    "spec.unique-pal.effects.pal.delivery.confirm.wrong-species"
wrong_species.speciesId = "SheepBall"
assert(bus:confirm_pal_delivery(wrong_species).reason
    == "unique-pal-native-delivery-species-rejected")
local pal_delivered = bus:confirm_pal_delivery(pal_delivery_callback)
assert(pal_delivered.ok and pal_delivered.reason
    == "unique-pal-native-delivery-confirmed")
assert(bus:status().pendingDeliveryCount == 0)
local duplicate_pal_delivery = bus:confirm_pal_delivery(
    pal_delivery_callback)
assert(duplicate_pal_delivery.ok and duplicate_pal_delivery.reason
    == "duplicate-unique-pal-world-callback")
local duplicate_payment = bus:confirm_ransom_payment(payment)
assert(duplicate_payment.ok and duplicate_payment.reason
    == "duplicate-unique-pal-world-callback")
local conflicting_payment = {}
for key, value in pairs(payment) do conflicting_payment[key] = value end
conflicting_payment.amount = payment.amount - 1
assert(bus:confirm_ransom_payment(conflicting_payment).reason
    == "unique-pal-world-callback-id-conflict")

local kind_counts = {}
for _, delivery in ipairs(deliveries) do
    kind_counts[delivery.deliveryKind] =
        (kind_counts[delivery.deliveryKind] or 0) + 1
    assert(delivery.broadActorScanAllowed == false)
    assert(delivery.deleteMapActors == false)
    if delivery.deliveryKind == "loaded-actor-cleanup" then
        assert(#delivery.cleanupActorBindings == 1)
    elseif delivery.deliveryKind == "empty-city" then
        assert(delivery.preserveBuildings == true)
    elseif delivery.deliveryKind == "pal-delivery" then
        assert(delivery.nativeRoutes.palDeliveryKey
            == pidf_binding.nativeRoutes.palDeliveryKey)
        assert(delivery.speciesId == "Alpaca")
    end
end
for _, kind in ipairs({
    "war-notice", "player-defense-request",
    "world-spawn-suppression", "loaded-actor-cleanup",
    "empty-city", "merchant-filter", "ransom-offer", "pal-delivery",
}) do
    assert((kind_counts[kind] or 0) >= 1, kind)
end

local before_restore_deliveries = #deliveries
local snapshot = progression:export_snapshot()
local _, restored_world, restored_campaign, restored_bus =
    create_runtime(snapshot)
local restored_status = restored_bus:status()
assert(restored_status.providerCount == 1)
assert(restored_status.activeProviderHandlerCount == 0)
assert(restored_status.activeTargetBindingCount == 0)
assert(restored_status.worldGeneration > generation)
assert(restored_world:city_status("spec.city.effects.rayne").status
    == "destroyed")
assert(restored_campaign:war_status(ransom_war.war.id).status
    == "cancelled")
assert(restored_bus:register_provider(provider, handler).reason
    == "unique-pal-world-effect-provider-rebound")
assert(restored_bus:bind_target(rayne_binding).ok)
assert(#deliveries == before_restore_deliveries + 4)
assert(restored_bus:status().pendingDeliveryCount == 0)

local before_unbind = restored_bus:status().worldGeneration
local stale_background = {}
for key, value in pairs(background_result) do
    stale_background[key] = value
end
stale_background.callbackId = "spec.unique-pal.effects.resolve.background.stale"
assert(restored_bus:confirm_background_war(stale_background).reason
    == "unique-pal-world-callback-generation-rejected")
assert(restored_bus:unbind_world("spec-world-unload").ok)
assert(restored_bus:status().worldGeneration == before_unbind + 1)
assert(restored_bus:status().activeProviderHandlerCount == 0)
assert(restored_bus:status().activeTargetBindingCount == 0)

-- A pending player-defense request is world-generation scoped. Restoring the
-- sidecar clears its old handler/binding, then re-binding replays the exact
-- request before a new-generation result can settle the war.
local pending_progression, _, pending_campaign, pending_bus =
    create_runtime()
assert(pending_progression:join(pidf).ok)
assert(pending_bus:register_provider(provider, handler).ok)
assert(pending_bus:bind_target(pidf_binding).ok)
local pending_war = pending_campaign:declare_destruction_war(
    "spec.unique-pal.effects.defense",
    "spec.unique-pal.effects.war.pending-restore",
    1,
    "spec.unique-pal.effects.declare.pending-restore"
)
assert(pending_war.ok and pending_war.war.route == "player-defense")
local pending_delivery_id = "unique-pal-world."
    .. pending_war.war.id .. ".player-defense-request"
local pending_before = pending_bus.deliveries[pending_delivery_id]
assert(pending_before.status == "applied")
local call_count_before_pending_restore = #deliveries
local pending_snapshot = pending_progression:export_snapshot()
local _, _, pending_restored_campaign, pending_restored_bus =
    create_runtime(pending_snapshot)
assert(pending_restored_bus:register_provider(provider, handler).reason
    == "unique-pal-world-effect-provider-rebound")
assert(pending_restored_bus:bind_target(pidf_binding).ok)
local pending_after = pending_restored_bus.deliveries[pending_delivery_id]
assert(pending_after.status == "applied")
assert(pending_after.appliedGeneration
    == pending_restored_bus:status().worldGeneration)
assert(#deliveries == call_count_before_pending_restore + 1)
local pending_defended = pending_restored_bus:confirm_player_defense({
    callbackId = "spec.unique-pal.effects.resolve.pending-restore",
    providerId = provider.providerId,
    authoritySource = provider.authoritySource,
    bindingId = pidf_binding.bindingId,
    worldGeneration = pending_restored_bus:status().worldGeneration,
    warId = pending_war.war.id,
    nativeRaidId = pending_after.providerRequestId,
    defenseRaidKey = pidf_binding.nativeRoutes.defenseRaidKey,
    playerParticipated = true,
    playerSideWon = true,
})
assert(pending_defended.ok and pending_defended.targetDestroyed == false)
assert(pending_restored_campaign:war_status(pending_war.war.id).status
    == "resolved")

print("PASS unique-Pal world-effect bus exact-binds spawn/cleanup/city/merchant routes, presents background/player-defense wars, filters destroyed factions, settles authoritative defense and exact-price ransom callbacks, retries and authoritatively confirms asynchronous Pal delivery, replays persistent empty-city effects, and rejects stale generations without broad scans or save writes")
