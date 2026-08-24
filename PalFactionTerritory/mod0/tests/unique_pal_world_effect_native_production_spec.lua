package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local Registry = require("pwft.registry")
local Progression = require("pwft.faction_progression")
local StrategicWorld = require("pwft.strategic_world")
local UniquePalCampaign = require("pwft.unique_pal_campaign")
local WorldEffectBus = require("pwft.unique_pal_world_effect_bus")
local NativeProduction =
    require("pwft.unique_pal_world_effect_native_production")
local world_pack = require("pwft_b7_unique_pals.strategic_world")
local campaign_pack = require("pwft_b7_unique_pals.unique_pal_campaign")
local bindings = require("pwft_b7_unique_pals.world_effect_bindings")

local player_id = "local-player"
local anubis_id = "pwft.unique.anubis"
local pinkcat_id = "pwft.unique.pinkcat"
local pidf = "pwft.faction.pidf"
local rayne = "pwft.faction.rayne_syndicate"
local feybreak = "pwft.faction.feybreak_army"

local progression = Progression.create(Registry.progression)
local strategic_world = StrategicWorld.create(progression)
assert(strategic_world:register_pack(world_pack).ok)

local bus = nil
local production = nil
local campaign = UniquePalCampaign.create(
    progression,
    strategic_world,
    {
        playerId = player_id,
        onChange = function(event)
            if bus ~= nil then bus:handle_campaign_event(event) end
            if production ~= nil then
                production:observe_campaign_event(event)
            end
        end,
    }
)
assert(campaign:register_pack(campaign_pack).ok)
bus = WorldEffectBus.create(campaign)

local scheduled = {}
local native_delivery_registrations = {}
local native_delivery_calls = {}
local native_delivery_production = {}
function native_delivery_production:register(binding)
    native_delivery_registrations[#native_delivery_registrations + 1] = binding
    return { ok = true, reason = "spec-native-delivery-binding-registered" }
end
function native_delivery_production:handle_delivery(payload, context)
    native_delivery_calls[#native_delivery_calls + 1] = {
        payload = payload,
        context = context,
    }
    return {
        ok = true,
        accepted = true,
        deliveryId = payload.deliveryId,
        requestId = payload.deliveryId .. ":native",
        individualKey = payload.uniquePalId .. ":spec-individual",
        reason = "spec-native-unique-pal-delivery-requested",
    }
end

local ransom_accepts = {}
local ransom_shop_bridge = {}
function ransom_shop_bridge:accept_offer(payload, context, native_offer)
    ransom_accepts[#ransom_accepts + 1] = {
        payload = payload,
        context = context,
        nativeOffer = native_offer,
    }
    return {
        ok = true,
        accepted = true,
        deliveryId = payload.deliveryId,
        nativeOfferId = native_offer.nativeOfferId,
        reason = "spec-ransom-offer-accepted",
    }
end

production = NativeProduction.create(
    bus,
    campaign,
    native_delivery_production,
    ransom_shop_bridge,
    {
        enabled = true,
        buildId = "24575825",
        providerId = "pwft.native.unique-pal-world-effect.production",
        authoritySource =
            "pwft.native.unique-pal-world-effect.authority",
        autoWarEnabled = true,
        minimumWarDelayMs = 1000,
        maximumWarDelayMs = 1000,
        backgroundResolveDelayMs = 0,
        backgroundAttackerWinPercent = 100,
        defenseCountdownSeconds = 30,
        ransomInteractionKey = "F7",
        ransomInteractionRadius = 700,
        ransomProductItemId = "StainlessSteel",
    },
    {
        schedule = function(delay_ms, callback)
            scheduled[#scheduled + 1] = {
                delayMs = delay_ms,
                callback = callback,
            }
            return true
        end,
    }
)

local deactivated = {}
local ransom_configurations = {}
local cleared_ransoms = {}
local nearest_ransom_queries = {}
local ransom_shop_opens = {}
local economy_runtime = {}
function economy_runtime:deactivate_faction(faction_id, reason)
    deactivated[#deactivated + 1] = {
        runtime = "economy",
        factionId = faction_id,
        reason = reason,
    }
    return { ok = true, reason = "spec-economy-faction-deactivated" }
end
function economy_runtime:configure_unique_pal_ransom(faction_id, offer)
    ransom_configurations[#ransom_configurations + 1] = {
        factionId = faction_id,
        offer = offer,
    }
    local configured = {}
    for key, value in pairs(offer) do configured[key] = value end
    configured.ok = true
    configured.reason = "spec-ransom-product-configured"
    configured.nativeShopId = "00000001-00000002-00000003-00000004"
    configured.nativeProductId = "00000005-00000006-00000007-00000008"
    return configured
end
function economy_runtime:clear_unique_pal_ransom(faction_id, unique_pal_id)
    cleared_ransoms[#cleared_ransoms + 1] = {
        factionId = faction_id,
        uniquePalId = unique_pal_id,
    }
    return { ok = true, reason = "spec-ransom-product-cleared" }
end
function economy_runtime:nearest_faction(
    player_actor,
    radius,
    required_faction_id
)
    nearest_ransom_queries[#nearest_ransom_queries + 1] = {
        playerActor = player_actor,
        radius = radius,
        requiredFactionId = required_faction_id,
    }
    if required_faction_id == feybreak then
        return {
            ok = true,
            reason = "spec-holder-counter-resolved",
            factionId = feybreak,
            actor = "spec-feybreak-counter",
            distance = 600,
        }
    end
    return { ok = false, reason = "no-economy-merchant-in-range" }
end
function economy_runtime:interact_nearest(
    player_actor,
    radius,
    required_faction_id
)
    ransom_shop_opens[#ransom_shop_opens + 1] = {
        playerActor = player_actor,
        radius = radius,
        requiredFactionId = required_faction_id,
    }
    return {
        ok = required_faction_id == feybreak,
        reason = "spec-holder-item-shop-opened",
        factionId = required_faction_id,
    }
end

local legacy_runtime = {}
function legacy_runtime:deactivate_faction(faction_id, reason)
    deactivated[#deactivated + 1] = {
        runtime = "legacy",
        factionId = faction_id,
        reason = reason,
    }
    return { ok = true, reason = "spec-legacy-faction-deactivated" }
end

local forced_raids = {}
local settlement_raid = {}
function settlement_raid:force_start(reason, countdown_seconds)
    forced_raids[#forced_raids + 1] = {
        reason = reason,
        countdownSeconds = countdown_seconds,
    }
    return true, "spec-raid-started"
end

assert(production:set_merchant_runtimes(
    legacy_runtime, economy_runtime).ok)
assert(production:set_settlement_raid(settlement_raid).ok)
local activated = production:activate(bindings)
assert(activated.ok)
assert(activated.targetBindingCount == 5)
assert(activated.nativeDeliveryBindingCount == 5)
assert(#native_delivery_registrations == 5)
assert(bus:status().fullyOperationalTargetBindingCount == 5)

-- An NPC faction that receives a unique Pal schedules and resolves a
-- presentation-only background war. Winning permanently empties the target
-- and removes only that faction's Mod-owned merchant actors.
assert(strategic_world:transfer_unique_pal(
    anubis_id,
    { kind = "wild" },
    { kind = "faction", id = feybreak },
    "spec.assign.anubis",
    { reason = "spec-timeout-assignment" }
).ok)
assert(campaign:sync_owner(
    anubis_id,
    "spec.sync.anubis",
    "spec-timeout-assignment"
).ok)
assert(#scheduled == 1 and scheduled[1].delayMs == 1000,
    "unexpected Anubis war schedule count=" .. tostring(#scheduled)
        .. " delay=" .. tostring(scheduled[1] and scheduled[1].delayMs)
        .. " notificationError=" .. tostring(campaign.lastNotificationError))
table.remove(scheduled, 1).callback()
assert(campaign:campaign_status(anubis_id).activeWar.route == "background")
assert(#scheduled == 1 and scheduled[1].delayMs == 0)
table.remove(scheduled, 1).callback()
local destroyed_pidf = campaign:target_status("faction", pidf)
assert(destroyed_pidf.status == "destroyed")
assert(campaign:faction_spawn_policy(pidf, "settlement-npc").suppressSpawn)
assert(campaign:merchant_spawn_policy(pidf).suppressSpawn)
assert(#deactivated == 4)
for _, event in ipairs(deactivated) do assert(event.factionId == pidf) end

-- If the player has joined the threatened target, the same war declaration
-- starts the already live-validated settlement raid and waits for its
-- authoritative attendance result instead of resolving off-screen.
assert(progression:join(rayne).ok)
assert(strategic_world:transfer_unique_pal(
    pinkcat_id,
    { kind = "wild" },
    { kind = "faction", id = feybreak },
    "spec.assign.pinkcat",
    { reason = "spec-timeout-assignment" }
).ok)
assert(campaign:sync_owner(
    pinkcat_id,
    "spec.sync.pinkcat",
    "spec-timeout-assignment"
).ok)
local declared = production:declare_war(
    pinkcat_id,
    nil,
    "spec-player-defense"
)
assert(declared.ok and declared.war.route == "player-defense")
assert(#forced_raids == 1)
assert(forced_raids[1].countdownSeconds == 30)
local attributed = production:on_attendance_start({
    raidEventId = "spec-raid-event-1",
})
assert(attributed.ok and attributed.warId == declared.war.id)
local defended = production:on_attendance_result({
    raidEventId = "spec-raid-event-1",
    playerParticipated = true,
    playerSideWon = true,
})
assert(defended.ok and defended.targetDestroyed == false)
assert(campaign:target_status("faction", rayne).status == "active")

-- The holder's Merchant Guild counter receives one exact-price stock-one
-- product. A server-confirmed settlement then routes the same unique Pal to
-- native delivery and clears the transient ransom product without reputation.
local saved_ue_helpers = _G.UEHelpers
local ransom_player = { IsValid = function() return true end }
local ransom_controller = {
    IsValid = function() return true end,
    GetDefaultPlayerCharacter = function() return ransom_player end,
}
_G.UEHelpers = {
    GetPlayerController = function() return ransom_controller end,
}
local offered = production:request_nearest_ransom()
_G.UEHelpers = saved_ue_helpers
assert(offered.ok)
assert(offered.shopOpened == true)
assert(offered.shopReason == "spec-holder-item-shop-opened")
assert(#nearest_ransom_queries == 1)
assert(nearest_ransom_queries[1].playerActor == ransom_player)
assert(nearest_ransom_queries[1].radius == 700)
assert(nearest_ransom_queries[1].requiredFactionId == feybreak)
assert(#ransom_shop_opens == 1)
assert(ransom_shop_opens[1].requiredFactionId == feybreak)
assert(#ransom_configurations == 1)
assert(ransom_configurations[1].factionId == feybreak)
assert(ransom_configurations[1].offer.unitPrice == 100000000)
assert(ransom_configurations[1].offer.buyQuantity == 1)
assert(ransom_configurations[1].offer.singlePurchaseStock == true)
assert(#ransom_accepts == 1)
local settled = campaign:settle_ransom({
    transactionId = "pwft.spec.ransom.pinkcat.payment",
    uniquePalId = pinkcat_id,
    playerId = player_id,
    authoritySource = "pwft.native-ransom-payment.v1",
    currency = "Gold",
    amount = 100000000,
    paid = true,
})
assert(settled.ok and settled.commerceReputationAward == 0)
assert(#native_delivery_calls == 1)
assert(native_delivery_calls[1].payload.uniquePalId == pinkcat_id)
assert(#cleared_ransoms == 1)
assert(cleared_ransoms[1].factionId == feybreak)
assert(cleared_ransoms[1].uniquePalId == pinkcat_id)

local status = production:status()
assert(status.active)
assert(status.targetBindingCount == 5)
assert(status.nativeDeliveryBindingCount == 5)
assert(status.backgroundResolutionCount == 1)
assert(status.playerDefenseRequestCount == 1)
assert(status.playerDefenseResolutionCount == 1)
assert(status.spawnSuppressionCount == 1)
assert(status.emptyCityCount == 1)
assert(status.cleanupCount == 2)
assert(status.merchantFilterCount == 2)
assert(status.ransomOfferCount == 1)
assert(status.directMapActorDeletion == false)
assert(status.PalworldSaveMutation == false)

print("PASS B7 production unique-Pal world effects register five current-build targets, suppress a destroyed faction, resolve background and player-defense wars, configure one exact-price ransom product, and route one native Pal delivery")
