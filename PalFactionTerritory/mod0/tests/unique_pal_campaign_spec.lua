package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local Registry = require("pwft.registry")
local Progression = require("pwft.faction_progression")
local StrategicWorld = require("pwft.strategic_world")
local UniquePalCampaign = require("pwft.unique_pal_campaign")

local rayne = "pwft.faction.rayne_syndicate"
local pidf = "pwft.faction.pidf"
local genetics = "pwft.faction.pal_genetic_research_unit"
local player_id = "campaign-test-player"

local strategic_pack = {
    schemaVersion = "pwft.strategic-world.pack.v1",
    contentPackId = "sample.unique-pal-campaign",
    contentVersion = "1.0.0",
    uniquePals = {
        {
            id = "sample.unique.opening",
            speciesId = "SampleOpeningPal",
            displayNameKey = "sample.loc.unique.opening.name",
            initialOwner = { kind = "wild" },
        },
        {
            id = "sample.unique.guardian",
            speciesId = "SampleGuardianPal",
            displayNameKey = "sample.loc.unique.guardian.name",
            initialOwner = { kind = "faction", id = genetics },
        },
        {
            id = "sample.unique.capture",
            speciesId = "SampleCapturePal",
            displayNameKey = "sample.loc.unique.capture.name",
            initialOwner = { kind = "wild" },
        },
    },
    cities = {
        {
            id = "sample.city.rayne",
            factionId = rayne,
            displayNameKey = "sample.loc.city.rayne.name",
            requiredUniquePalId = "sample.unique.opening",
        },
        {
            id = "sample.city.pidf",
            factionId = pidf,
            displayNameKey = "sample.loc.city.pidf.name",
            requiredUniquePalId = "sample.unique.guardian",
        },
    },
}

local campaign_pack = {
    schemaVersion = "pwft.unique-pal-campaign.pack.v1",
    contentPackId = "sample.unique-pal-campaign",
    contentVersion = "1.0.0",
    uniquePals = {
        {
            id = "sample.unique.opening",
            target = {
                kind = "faction",
                id = rayne,
                affectedFactionIds = { rayne },
            },
            boss = {
                speciesId = "SampleOpeningPal",
                nativeBossAvailable = false,
                nativeBossSlotId = "BOSS_SampleOpeningReplacement",
                bindingStatus = "bound",
                strengthProfile = "raid-slab",
            },
            schedule = {
                minimumIntervalTicks = 2,
                maximumIntervalTicks = 4,
                noticeTicks = 3,
                openTicks = 5,
            },
            ransomPrice = 99999999,
            candidateFactionIds = { genetics },
        },
        {
            id = "sample.unique.guardian",
            target = {
                kind = "faction",
                id = pidf,
                affectedFactionIds = { pidf },
            },
            boss = {
                speciesId = "SampleGuardianPal",
                nativeBossAvailable = true,
                bindingStatus = "bound",
                strengthProfile = "raid-slab",
            },
            schedule = {
                minimumIntervalTicks = 2,
                maximumIntervalTicks = 4,
                noticeTicks = 3,
                openTicks = 5,
            },
            ransomPrice = 88888888,
            candidateFactionIds = { genetics },
        },
        {
            id = "sample.unique.capture",
            target = {
                kind = "strategic-target",
                id = "sample.target.future-island",
                affectedFactionIds = {},
            },
            boss = {
                speciesId = "SampleCapturePal",
                nativeBossAvailable = false,
                bindingStatus = "pending",
                strengthProfile = "raid-slab",
            },
            schedule = {
                minimumIntervalTicks = 1,
                maximumIntervalTicks = 1,
                noticeTicks = 2,
                openTicks = 4,
            },
            ransomPrice = 77777777,
            candidateFactionIds = { genetics },
        },
    },
}

local function create_runtime(snapshot)
    local progression = Progression.create(Registry.progression, snapshot)
    local world = StrategicWorld.create(progression)
    assert(world:register_pack(strategic_pack).ok)
    local events = {}
    local campaign = UniquePalCampaign.create(progression, world, {
        playerId = player_id,
        maxHistory = 64,
        onChange = function(event)
            events[#events + 1] = event.type
        end,
    })
    local registered = campaign:register_pack(campaign_pack)
    assert(registered.ok,
        tostring(registered.reason) .. ":" .. tostring(registered.error))
    return progression, world, campaign, events
end

local progression, world, campaign, events = create_runtime()
assert(campaign.version == "1.1.0")
assert(campaign:status().uniquePalCount == 3)
assert(campaign:status().destroyedTargetCount == 0)
assert(campaign.capabilities.uniquePalBossWhitelist)
assert(campaign.capabilities.authoritativeBossDefeat)
assert(campaign.capabilities.nativeBossMutation == false)
assert(campaign.capabilities.PalworldSaveMutation == false)

-- The whitelist suppresses every other Pal Boss, while a unique Pal is still
-- unavailable until its deterministic opening window reaches `open`.
local non_unique = campaign:boss_spawn_policy("SomeOtherBossPal")
assert(not non_unique.ok)
assert(non_unique.reason == "non-unique-pal-boss-suppressed")
assert(non_unique.suppressNativeBossSpawn == true)
local capture_closed = campaign:boss_spawn_policy("SampleCapturePal")
assert(not capture_closed.ok and capture_closed.phase == "closed")

-- A one-tick deterministic schedule emits notice first, then authorizes the
-- raid-slab-strength Boss. Only the exact native capture authority can claim
-- the single StrategicWorld owner.
local capture_schedule = campaign:schedule_next(
    "sample.unique.capture",
    0,
    "schedule-capture-1"
)
assert(capture_schedule.ok and capture_schedule.noticeTick == 1)
assert(capture_schedule.openTick == 3 and capture_schedule.closeTick == 7)
local notice = campaign:advance(1, "advance-capture-notice")
assert(notice.ok and notice.transitionCount == 1)
assert(notice.transitions[1].phase == "announced")
local opened = campaign:advance(3, "advance-capture-open")
assert(opened.ok and opened.transitions[1].phase == "activation-pending")
assert(campaign:status().activationPendingCount == 1)
assert(campaign:boss_spawn_policy("SampleCapturePal").ok)
local rejected_spawn = campaign:confirm_boss_spawn({
    spawnId = "spawn-capture-wrong-authority",
    uniquePalId = "sample.unique.capture",
    eventId = capture_schedule.eventId,
    actorBindingId = "BP_SampleCapturePal_C_1",
    logicalTick = 3,
    authoritySource = "untrusted-test",
})
assert(not rejected_spawn.ok)
assert(rejected_spawn.reason
    == "unique-pal-boss-spawn-authority-rejected")
local confirmed_spawn = campaign:confirm_boss_spawn({
    spawnId = "spawn-capture-authoritative-1",
    uniquePalId = "sample.unique.capture",
    eventId = capture_schedule.eventId,
    actorBindingId = "BP_SampleCapturePal_C_1",
    logicalTick = 3,
    authoritySource = "pwft.native-unique-pal-boss-spawn.v1",
})
assert(confirmed_spawn.ok and confirmed_spawn.reason
    == "unique-pal-opening-started")
local capture_open = campaign:boss_spawn_policy("SampleCapturePal")
assert(capture_open.ok and capture_open.boss.strengthProfile == "raid-slab")
local rejected_capture = campaign:capture({
    captureId = "capture-wrong-authority",
    uniquePalId = "sample.unique.capture",
    eventId = capture_schedule.eventId,
    playerId = player_id,
    authoritySource = "untrusted-test",
})
assert(not rejected_capture.ok)
assert(rejected_capture.reason == "unique-pal-capture-authority-rejected")
local captured = campaign:capture({
    captureId = "capture-authoritative-1",
    uniquePalId = "sample.unique.capture",
    eventId = capture_schedule.eventId,
    playerId = player_id,
    authoritySource = "pwft.native-unique-pal-capture.v1",
})
assert(captured.ok and captured.reason == "unique-pal-captured-by-player")
assert(world:unique_pal_status("sample.unique.capture").owner.kind == "player")
local duplicate_capture = campaign:capture({
    captureId = "capture-authoritative-1",
    uniquePalId = "sample.unique.capture",
    eventId = capture_schedule.eventId,
    playerId = player_id,
    authoritySource = "pwft.native-unique-pal-capture.v1",
})
assert(duplicate_capture.ok and duplicate_capture.reason == "duplicate-operation")

-- If the player misses the window, the saved event deterministically assigns
-- the Pal to a surviving human faction rather than rerolling on restart.
local opening_schedule = campaign:schedule_next(
    "sample.unique.opening",
    3,
    "schedule-opening-1"
)
assert(opening_schedule.ok)
assert(opening_schedule.noticeTick >= 5
    and opening_schedule.noticeTick <= 7)
local opening_requested = campaign:advance(
    opening_schedule.openTick,
    "advance-opening-request"
)
assert(opening_requested.ok)
assert(campaign:campaign_status("sample.unique.opening").phase
    == "activation-pending")
-- No timeout assignment is allowed until an exact native actor binding has
-- confirmed that the Boss really existed in the world.
assert(campaign:advance(
    opening_schedule.closeTick + 50,
    "advance-unconfirmed-opening"
).transitionCount == 0)
assert(world:unique_pal_status("sample.unique.opening").owner.kind
    == "wild")
local opening_spawned = campaign:confirm_boss_spawn({
    spawnId = "spawn-opening-authoritative-1",
    uniquePalId = "sample.unique.opening",
    eventId = opening_schedule.eventId,
    actorBindingId = "BP_SampleOpeningPal_C_1",
    logicalTick = opening_schedule.closeTick + 50,
    authoritySource = "pwft.native-unique-pal-boss-spawn.v1",
})
assert(opening_spawned.ok)
opening_schedule.closeTick = opening_spawned.closeTick
assert(campaign:advance(
    opening_schedule.closeTick,
    "advance-opening-timeout"
).ok)
local assigned_owner = world:unique_pal_status(
    "sample.unique.opening"
).owner
assert(assigned_owner.kind == "faction" and assigned_owner.id == genetics)
assert(campaign:campaign_status(
    "sample.unique.opening"
).timeoutAssignmentCount == 1)

-- A target with no joined player faction resolves entirely in the background.
-- Text presentation is required, but no fake off-screen actors are requested.
local background = campaign:declare_destruction_war(
    "sample.unique.opening",
    "war-background-rayne-1",
    opening_schedule.closeTick,
    "declare-background-rayne-1"
)
assert(background.ok and background.war.route == "background")
assert(background.backgroundPresentationOnly == true)
local bad_background = campaign:settle_destruction_war({
    warId = "war-background-rayne-1",
    resolutionId = "resolve-background-bad-1",
    authoritySource = "pwft.unique-pal-war-result.v1",
    attackerWon = false,
    playerParticipated = false,
})
assert(not bad_background.ok)
assert(bad_background.reason == "background-war-cannot-contain-player-result")
local survived = campaign:settle_destruction_war({
    warId = "war-background-rayne-1",
    resolutionId = "resolve-background-rayne-1",
    authoritySource = "pwft.unique-pal-war-result.v1",
    attackerWon = false,
})
assert(survived.ok and survived.targetDestroyed == false)
assert(world:city_status("sample.city.rayne").status == "active")

local background_two = campaign:declare_destruction_war(
    "sample.unique.opening",
    "war-background-rayne-2",
    opening_schedule.closeTick + 1,
    "declare-background-rayne-2"
)
assert(background_two.ok)
local destroyed_rayne = campaign:settle_destruction_war({
    warId = "war-background-rayne-2",
    resolutionId = "resolve-background-rayne-2",
    authoritySource = "pwft.unique-pal-war-result.v1",
    attackerWon = true,
})
assert(destroyed_rayne.ok and destroyed_rayne.targetDestroyed == true)
assert(world:city_status("sample.city.rayne").status == "destroyed")
assert(campaign:target_status("faction", rayne).status == "destroyed")
assert(campaign:faction_spawn_policy(rayne, "settlement-npc").suppressSpawn)
assert(campaign:merchant_spawn_policy(rayne).suppressSpawn)
assert(campaign:faction_spawn_policy(pidf, "settlement-npc").ok)

-- Joining the threatened faction routes the next war to a real player
-- defense. A qualified victory preserves it. A later pending war can be
-- cancelled only after an exact native high-price payment confirmation.
local joined = progression:join(pidf)
assert(joined.ok and progression:status(pidf).joined == true)
local defense = campaign:declare_destruction_war(
    "sample.unique.guardian",
    "war-defense-pidf-1",
    opening_schedule.closeTick + 2,
    "declare-defense-pidf-1"
)
assert(defense.ok and defense.war.route == "player-defense",
    tostring(defense.reason))
assert(defense.nativeRaidRequired == true)
local defended = campaign:settle_destruction_war({
    warId = "war-defense-pidf-1",
    resolutionId = "resolve-defense-pidf-1",
    authoritySource = "pwft.unique-pal-war-result.v1",
    playerParticipated = true,
    playerSideWon = true,
})
assert(defended.ok and defended.reason
    == "unique-pal-destruction-war-defended")
assert(world:city_status("sample.city.pidf").status == "active")

local defense_two = campaign:declare_destruction_war(
    "sample.unique.guardian",
    "war-defense-pidf-2",
    opening_schedule.closeTick + 3,
    "declare-defense-pidf-2"
)
assert(defense_two.ok)
local quote = campaign:ransom_quote("sample.unique.guardian", player_id)
assert(quote.ok and quote.amount == 88888888)
assert(quote.currency == "Gold")
assert(quote.activeWarId == "war-defense-pidf-2")
local unpaid = campaign:settle_ransom({
    transactionId = "ransom-unpaid-1",
    uniquePalId = "sample.unique.guardian",
    playerId = player_id,
    authoritySource = "pwft.native-ransom-payment.v1",
    currency = "Gold",
    amount = 88888888,
    paid = false,
})
assert(not unpaid.ok and unpaid.reason == "ransom-payment-not-confirmed")
local wrong_price = campaign:settle_ransom({
    transactionId = "ransom-wrong-price-1",
    uniquePalId = "sample.unique.guardian",
    playerId = player_id,
    authoritySource = "pwft.native-ransom-payment.v1",
    currency = "Gold",
    amount = 1,
    paid = true,
})
assert(not wrong_price.ok)
assert(wrong_price.reason == "ransom-payment-amount-mismatch")
local ransom = campaign:settle_ransom({
    transactionId = "ransom-confirmed-1",
    uniquePalId = "sample.unique.guardian",
    playerId = player_id,
    authoritySource = "pwft.native-ransom-payment.v1",
    currency = "Gold",
    amount = 88888888,
    paid = true,
})
assert(ransom.ok and ransom.reason == "unique-pal-ransom-settled")
assert(ransom.cancelledWarId == "war-defense-pidf-2")
assert(ransom.commerceReputationAward == 0)
assert(world:unique_pal_status("sample.unique.guardian").owner.kind
    == "player")
assert(campaign:war_status("war-defense-pidf-2").status == "cancelled")
local duplicate_ransom = campaign:settle_ransom({
    transactionId = "ransom-confirmed-1",
    uniquePalId = "sample.unique.guardian",
    playerId = player_id,
    authoritySource = "pwft.native-ransom-payment.v1",
    currency = "Gold",
    amount = 88888888,
    paid = true,
})
assert(duplicate_ransom.ok and duplicate_ransom.reason
    == "duplicate-operation")

-- Campaign ownership, extinction, cancelled wars and deterministic scheduling
-- all live in the progression sidecar and survive a clean runtime rebuild.
local snapshot = progression:export_snapshot()
local restored_progression, restored_world, restored_campaign =
    create_runtime(snapshot)
assert(restored_campaign:target_status("faction", rayne).status
    == "destroyed")
assert(restored_campaign:merchant_spawn_policy(rayne).suppressSpawn)
assert(restored_world:unique_pal_status("sample.unique.opening").owner.id
    == genetics)
assert(restored_world:unique_pal_status("sample.unique.guardian").owner.kind
    == "player")
assert(restored_campaign:war_status("war-defense-pidf-2").status
    == "cancelled")
assert(restored_campaign:register_pack(campaign_pack).reason
    == "unique-pal-campaign-pack-already-registered")
assert(restored_progression:restore_listener_status().count >= 2)

-- Delayed sidecar restore replaces the progression root in-place. The
-- campaign restore listener must leave the old table detached and make every
-- subsequent transition write only to the restored root.
local rebind_progression, _, rebind_campaign = create_runtime()
local rebind_baseline = rebind_progression:export_snapshot()
local stale_campaign_state = rebind_campaign.state
assert(rebind_campaign:schedule_next(
    "sample.unique.capture",
    0,
    "rebind-schedule-before-restore"
).ok)
assert(stale_campaign_state.campaigns["sample.unique.capture"].phase
    == "scheduled")
local rebound = rebind_progression:restore_snapshot(rebind_baseline)
assert(rebound.ok and rebind_campaign.state ~= stale_campaign_state)
assert(rebind_campaign:campaign_status("sample.unique.capture").phase
    == "closed")
assert(rebind_campaign:schedule_next(
    "sample.unique.capture",
    0,
    "rebind-schedule-after-restore"
).ok)
assert(rebind_campaign:campaign_status("sample.unique.capture").phase
    == "scheduled")
assert(stale_campaign_state.campaigns["sample.unique.capture"].phase
    == "scheduled")

-- A player-defense loss (including absence) destroys the target and suppresses
-- all future faction/merchant spawns. This is isolated from the ransom path.
local loss_progression, loss_world, loss_campaign = create_runtime()
assert(loss_progression:join(pidf).ok)
local loss_war = loss_campaign:declare_destruction_war(
    "sample.unique.guardian",
    "war-defense-loss-1",
    1,
    "declare-defense-loss-1"
)
assert(loss_war.ok and loss_war.war.route == "player-defense")
local loss = loss_campaign:settle_destruction_war({
    warId = "war-defense-loss-1",
    resolutionId = "resolve-defense-loss-1",
    authoritySource = "pwft.unique-pal-war-result.v1",
    playerParticipated = false,
    playerSideWon = false,
})
assert(loss.ok and loss.targetDestroyed == true)
assert(loss_world:city_status("sample.city.pidf").status == "destroyed")
assert(loss_campaign:merchant_spawn_policy(pidf).suppressSpawn)
assert(loss_campaign:ransom_quote("sample.unique.guardian", player_id)
    .reason == "ransom-too-late-target-destroyed")

assert(#events >= 12)
print("PASS unique-Pal campaign schedules and announces raid-slab Boss windows, arbitrates authoritative capture/timeout ownership, routes NPC destruction wars through background or player defense, persists extinction spawn filters, and settles exact-price merchant ransoms idempotently")
