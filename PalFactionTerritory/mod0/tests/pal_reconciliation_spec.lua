package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local Registry = require("pwft.registry")
local Progression = require("pwft.faction_progression")
local PalReconciliation = require("pwft.pal_reconciliation")

local function unlock_all_human_lords(progression)
    for _, faction_id in ipairs(Registry.progression.humanFactionIds) do
        local status = progression:status(faction_id)
        for _, source_faction_id in ipairs(status.diplomacyHostilitySources or {}) do
            local clear_id = "pal-test-clear:" .. faction_id .. ":" .. source_faction_id
            assert(progression:clear_diplomacy_hostility(
                faction_id,
                source_faction_id,
                {
                    contextId = clear_id,
                    eventId = clear_id,
                }
            ).ok)
        end
        if not progression:status(faction_id).joined then
            assert(progression:join(faction_id).ok)
        end
        local serial = 0
        while progression:status(faction_id).reputation < 1200 do
            serial = serial + 1
            assert(progression:grant_reputation(
                faction_id,
                "task",
                300,
                {
                    contextId = "pal-test-rank:" .. faction_id .. ":" .. serial,
                    eventId = "pal-test-rank:" .. faction_id .. ":" .. serial,
                }
            ).ok)
        end
        assert(progression:status(faction_id).rankId == "Lord")
    end
    assert(progression:gate_status().palReconciliationUnlocked)
end

local random_values = { 1, 1, 2, 3, 4, 5, 6, 7 }
local random_cursor = 0
local function deterministic_random(maximum)
    random_cursor = random_cursor + 1
    local value = random_values[random_cursor]
    assert(value ~= nil and value <= maximum)
    return value
end

local progression = Progression.create(Registry.progression)
local service = PalReconciliation.create(
    Registry.palReconciliation,
    progression,
    { randomIndex = deterministic_random }
)

local desert = "pwft.faction.desert_pal_tribe"
local snow = "pwft.faction.snow_pal_tribe"
local fire = "pwft.faction.fire_pal_tribe"

assert(service.version == "1.0.0")
assert(service.capabilities.duplicateCityStateTokens)
assert(service.capabilities.technicalFailureRefund)
assert(service.capabilities.confirmedPlayerAbortConsumes)
assert(service.capabilities.permanentExhaustionLock)
assert(service:status().configuredFactionCount == 0)
assert(service:record_raid_result(desert, {
    raidEventId = "raid-before-content",
    playerSideWon = true,
    playerCreditedLeaderKill = true,
}).reason == "content-not-configured")

local registered = service:register_content(desert, {
    contentPackId = "fan.story.desert.v1",
    contentVersion = "1.0.0",
    tokenQuota = 3,
    maximumAffinityPerDiscourse = 50,
})
assert(registered.ok and registered.reason == "content-registered")
assert(service:register_content(desert, {
    contentPackId = "fan.story.desert.v1",
    contentVersion = "1.0.0",
    tokenQuota = 3,
    maximumAffinityPerDiscourse = 50,
}).reason == "content-already-registered")
assert(service:register_content(desert, {
    contentPackId = "fan.story.desert.v2",
    contentVersion = "2.0.0",
    tokenQuota = 4,
    maximumAffinityPerDiscourse = 50,
}).reason == "content-migration-required")

-- Losing or missing authoritative leader kill credit never awards a token.
local lost = service:record_raid_result(desert, {
    raidEventId = "raid-lost",
    playerSideWon = false,
    playerCreditedLeaderKill = true,
})
assert(lost.ok and lost.reason == "player-side-did-not-win")
assert(lost.tokenAwarded == false)
local missing_kill = service:record_raid_result(desert, {
    raidEventId = "raid-no-kill-credit",
    playerSideWon = true,
    playerCreditedLeaderKill = false,
})
assert(missing_kill.ok and missing_kill.reason == "raid-leader-kill-credit-required")
assert(service:record_raid_result(desert, {
    raidEventId = "raid-no-kill-credit",
    playerSideWon = true,
    playerCreditedLeaderKill = true,
}).reason == "duplicate-raid-event")

-- Three eligible wins award three independent tokens. The first two rolls
-- intentionally select the same city-state and must remain valid duplicates.
local token_results = {}
for index = 1, 3 do
    local awarded = service:record_raid_result(desert, {
        raidEventId = "raid-desert-" .. index,
        playerSideWon = true,
        playerCreditedLeaderKill = true,
    })
    assert(awarded.ok and awarded.reason == "token-awarded")
    assert(awarded.tokenAwarded == true)
    token_results[index] = awarded
end
assert(token_results[1].tokenInstanceId ~= token_results[2].tokenInstanceId)
assert(token_results[1].cityStateId == token_results[2].cityStateId)
assert(token_results[2].cityStateId ~= token_results[3].cityStateId)
assert(service:record_raid_result(desert, {
    raidEventId = "raid-desert-over-quota",
    playerSideWon = true,
    playerCreditedLeaderKill = true,
}).reason == "token-quota-exhausted")
assert(service:status(desert).tokensAwarded == 3)
assert(service:status(desert).futureDropsRemaining == 0)
assert(service:status(desert).totalAttemptsRemaining == 3)

local token_1 = token_results[1].tokenInstanceId
assert(service:complete_token_quest(
    desert,
    token_1,
    "quest-desert-token-1",
    {
        questId = "fan.quest.desert.token-1",
        topicKeys = { "human-fear", "pal-retaliation" },
    }
).ok)
assert(service:preview_discourse(desert, token_1).reason == "all-human-lords-required")
unlock_all_human_lords(progression)
assert(progression:reconcile_pal(desert).reason == "pal-discourse-service-required")

local preview = service:preview_discourse(desert, token_1)
assert(preview.ok and preview.irreversible)
assert(preview.totalAttemptsRemaining == 3)
assert(preview.attemptsRemainingAfterConsume == 2)

-- Provider readiness and pre-confirmation cancellation never reserve or
-- consume a token.
assert(service:begin_discourse(
    desert,
    token_1,
    "session-provider-fail",
    { providerReady = false, userConfirmed = true }
).reason == "discourse-provider-not-ready-token-preserved")
assert(service:begin_discourse(
    desert,
    token_1,
    "session-not-confirmed",
    { providerReady = true, userConfirmed = false }
).reason == "irreversible-confirmation-required")
assert(service:status(desert).tokensConsumed == 0)

-- A confirmed session reserves the token. Technical failure refunds it.
assert(service:begin_discourse(
    desert,
    token_1,
    "session-technical",
    {
        providerReady = true,
        userConfirmed = true,
        providerKind = "optional-agent",
    }
).reason == "discourse-started")
assert(service:token_status(desert, token_1).state == "reserved")
local refunded = service:resolve_discourse(
    desert,
    "session-technical",
    "technical_failure",
    0,
    "resolution-technical",
    { technicalReason = "model-timeout" }
)
assert(refunded.ok and refunded.reason == "technical-failure-token-refunded")
assert(service:token_status(desert, token_1).state == "quest-complete")
assert(service:status(desert).tokensConsumed == 0)
assert(service:status(desert).technicalRefunds == 1)

-- Confirmed voluntary abort consumes the chance without affinity.
assert(service:begin_discourse(
    desert,
    token_1,
    "session-player-abort",
    { providerReady = true, userConfirmed = true }
).ok)
local aborted = service:resolve_discourse(
    desert,
    "session-player-abort",
    "player_abort",
    0,
    "resolution-player-abort"
)
assert(aborted.ok and aborted.reason == "player-abort-token-consumed")
assert(service:status(desert).tokensConsumed == 1)
assert(service:status(desert).totalAttemptsRemaining == 2)
assert(progression:status(desert).reputation == -100)

-- Two successful discussions each add 50 and reconcile the faction. Awards
-- are deterministic and capped by content registration.
for index = 2, 3 do
    local token_id = token_results[index].tokenInstanceId
    assert(service:complete_token_quest(
        desert,
        token_id,
        "quest-desert-token-" .. index,
        { questId = "fan.quest.desert.token-" .. index }
    ).ok)
    local session_id = "session-desert-success-" .. index
    assert(service:begin_discourse(
        desert,
        token_id,
        session_id,
        { providerReady = true, userConfirmed = true }
    ).ok)
    local completed = service:resolve_discourse(
        desert,
        session_id,
        "completed",
        index == 2 and 80 or 50,
        "resolution-desert-success-" .. index,
        { resultTags = { "understanding" } }
    )
    assert(completed.ok)
    assert(completed.session.affinityRequested == 50)
    assert(completed.session.affinityApplied == 50)
end
assert(progression:status(desert).reputation == 0)
assert(progression:status(desert).relation == "Friendly")
assert(service:status(desert).reconciled == true)
assert(service:status(desert).permanentlyLocked == false)
local duplicate_resolution = service:resolve_discourse(
    desert,
    "session-desert-success-3",
    "completed",
    50,
    "resolution-desert-success-3"
)
assert(duplicate_resolution.ok)
assert(duplicate_resolution.reason == "duplicate-discourse-resolution")
assert(progression:status(desert).reputation == 0)

-- A one-attempt story with insufficient affinity permanently locks the Pal
-- faction in this world.
assert(service:register_content(snow, {
    contentPackId = "fan.story.snow.v1",
    contentVersion = "1.0.0",
    tokenQuota = 1,
    maximumAffinityPerDiscourse = 20,
}).ok)
local snow_token = service:record_raid_result(snow, {
    raidEventId = "raid-snow-1",
    playerSideWon = true,
    playerCreditedLeaderKill = true,
})
assert(snow_token.ok and snow_token.tokenAwarded)
assert(service:complete_token_quest(
    snow,
    snow_token.tokenInstanceId,
    "quest-snow-1",
    { questId = "fan.quest.snow.1" }
).ok)
assert(service:begin_discourse(
    snow,
    snow_token.tokenInstanceId,
    "session-snow-1",
    { providerReady = true, userConfirmed = true }
).ok)
local snow_result = service:resolve_discourse(
    snow,
    "session-snow-1",
    "completed",
    20,
    "resolution-snow-1"
)
assert(snow_result.ok)
assert(snow_result.reason == "reconciliation-locked-attempts-exhausted")
assert(progression:status(snow).reputation == -80)
assert(progression:status(snow).relation == "Hostile")
assert(service:status(snow).permanentlyLocked == true)
assert(service:record_raid_result(snow, {
    raidEventId = "raid-snow-after-lock",
    playerSideWon = true,
    playerCreditedLeaderKill = true,
}).reason == "pal-reconciliation-permanently-locked")

-- Quota changes require explicit migration and can never erase already
-- awarded token instances. Desert already awarded three tokens, so a quota
-- of two must be rejected without mutating the registered content.
local below_awarded = service:migrate_content(desert, {
    contentPackId = "fan.story.desert.v2",
    contentVersion = "2.0.0",
    tokenQuota = 2,
    maximumAffinityPerDiscourse = 50,
}, "desert-migration-below-awarded")
assert(not below_awarded.ok)
assert(below_awarded.reason == "quota-below-awarded-token-count")
assert(service:status(desert).tokenQuota == 3)

-- Active sessions restored after interruption are treated as technical
-- failures and refund their reserved token.
assert(service:register_content(fire, {
    contentPackId = "fan.story.fire.v1",
    contentVersion = "1.0.0",
    tokenQuota = 1,
    maximumAffinityPerDiscourse = 100,
}).ok)
local fire_token = service:record_raid_result(fire, {
    raidEventId = "raid-fire-1",
    playerSideWon = true,
    playerCreditedLeaderKill = true,
})
assert(service:complete_token_quest(
    fire,
    fire_token.tokenInstanceId,
    "quest-fire-1",
    { questId = "fan.quest.fire.1" }
).ok)
assert(service:begin_discourse(
    fire,
    fire_token.tokenInstanceId,
    "session-fire-interrupted",
    { providerReady = true, userConfirmed = true }
).ok)
local restored_progression = Progression.create(
    Registry.progression,
    progression:export_snapshot()
)
local restored_service = PalReconciliation.create(
    Registry.palReconciliation,
    restored_progression,
    { randomIndex = deterministic_random }
)
assert(restored_service.recoveredInterruptedSessionCount == 1)
assert(restored_service:token_status(fire, fire_token.tokenInstanceId).state == "quest-complete")
assert(restored_service:status(fire).tokensConsumed == 0)
assert(restored_service:status(fire).technicalRefunds == 1)
assert(restored_service:status(snow).permanentlyLocked == true)
assert(restored_service:status(desert).reconciled == true)

-- A quota increase is safe when it is explicit and not below awarded count.
local migrated = restored_service:migrate_content(snow, {
    contentPackId = "fan.story.snow.v2",
    contentVersion = "2.0.0",
    tokenQuota = 2,
    maximumAffinityPerDiscourse = 20,
}, "snow-migration-2")
assert(migrated.ok and migrated.reason == "content-migrated")
assert(restored_service:status(snow).tokenQuota == 2)
assert(restored_service:status(snow).permanentlyLocked == true)
assert(restored_service:migrate_content(snow, {
    contentPackId = "fan.story.snow.v2",
    contentVersion = "2.0.0",
    tokenQuota = 2,
    maximumAffinityPerDiscourse = 20,
}, "snow-migration-2").reason == "duplicate-content-migration")

print("PASS Pal raid tokens, duplicate cities, quests, finite discourse attempts, refunds, lockout, and snapshot recovery")
