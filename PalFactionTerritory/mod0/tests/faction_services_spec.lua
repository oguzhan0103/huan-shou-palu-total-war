package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local Registry = require("pwft.registry")
local FactionApi = require("pwft.faction_api")
local FactionCommerce = require("pwft.faction_commerce")
local FactionDefense = require("pwft.faction_defense")
local FactionGuard = require("pwft.faction_guard")
local FactionProgression = require("pwft.faction_progression")
local FactionUiModel = require("pwft.faction_ui_model")
local PalReconciliation = require("pwft.pal_reconciliation")

local progression = FactionProgression.create(Registry.progression)
local api = FactionApi.create(progression)
local commerce = FactionCommerce.create(Registry.commerce, api)
local defense = FactionDefense.create(api)
local guard = FactionGuard.create(api)
local pal_reconciliation = PalReconciliation.create(
    Registry.palReconciliation,
    progression
)
local ui = FactionUiModel.create(
    Registry,
    progression,
    commerce,
    guard,
    pal_reconciliation
)

local rayne = "pwft.faction.rayne_syndicate"
local initial_model = ui:build()
assert(#initial_model.rows == 12)
assert(initial_model.humanFactionCount == 7)
assert(initial_model.palFactionCount == 5)
assert(initial_model.rows[1].relationLabelZhHans == "中立友好")
assert(initial_model.rows[1].commerce.nonNegativeRemaining == 20)
assert(initial_model.rows[1].guard.eligible == false)
assert(initial_model.rows[8].reconciliation.serviceReady == true)
assert(initial_model.rows[8].reconciliation.configured == false)
assert(initial_model.rows[8].reconciliation.tokenQuota == 0)

local hostile_snapshot = progression:export_snapshot()
hostile_snapshot.factions[rayne].reputation = -20
local hostile_progression = FactionProgression.create(
    Registry.progression,
    hostile_snapshot
)
local hostile_api = FactionApi.create(hostile_progression)
local hostile_defense = FactionDefense.create(hostile_api)
local started = hostile_defense:begin(
    "small-settlement-001",
    rayne,
    {
        settlementId = "pwft.settlement.small_settlement",
        allowHostileParticipation = true,
    }
)
assert(started.ok)
assert(started.temporaryTruce == true)
assert(hostile_defense:participate(
    "small-settlement-001",
    "local-player"
).ok)
local effective, reason = hostile_defense:effective_relation(
    rayne,
    "local-player"
)
assert(effective == "Friendly")
assert(reason == "temporary-defense-truce")
local resolved = hostile_defense:resolve(
    "small-settlement-001",
    true,
    50,
    "native-incident-resolved-001",
    "local-player"
)
assert(resolved.ok)
assert(resolved.applied == 50)
assert(resolved.temporaryTruceEnded == true)
assert(hostile_api:faction_status(rayne).relation == "Friendly")

assert(api:join_human(rayne, "join-rayne").ok)
local free_pal_row = ui:faction_row("pwft.faction.free_pal_alliance")
assert(free_pal_row.relation == "Hostile")
assert(free_pal_row.diplomacyBlocked == true)
assert(free_pal_row.diplomacyHostilitySources[1] == rayne)
assert(
    free_pal_row.commerce.diplomacyRecovery
        .activeSourceFactionId
        == rayne
)
assert(
    free_pal_row.commerce.diplomacyRecovery
        .requiredPerSource
        == 60
)
assert(
    free_pal_row.commerce.diplomacyRecovery
        .windowRemaining
        == 20
)
local ui_recovery = api:award_commerce(
    "pwft.faction.free_pal_alliance",
    20,
    "ui-recovery-trade-001",
    "ui-recovery-window-001",
    {
        diplomacyRecoveryEligible = true,
        venueMode = "fixed-market",
    }
)
assert(ui_recovery.commerceDiplomacyRecovery.current == 20)
free_pal_row = ui:faction_row(
    "pwft.faction.free_pal_alliance"
)
assert(
    free_pal_row.commerce.diplomacyRecovery
        .activeProgress
        == 20
)
assert(
    free_pal_row.commerce.diplomacyRecovery
        .activeRemaining
        == 40
)
assert(
    free_pal_row.commerce.diplomacyRecovery
        .windowRemaining
        == 0
)
api:award_task(rayne, 300, "task-guard-001")
api:award_task(rayne, 300, "task-guard-002")
api:award_task(rayne, 100, "task-guard-003")
assert(api:faction_status(rayne).rankId == "Leader")
assert(guard:entitlement(rayne).ok)
assert(guard:deploy(rayne, "guard-request-001").reason
    == "native-guard-provider-pending")

local deployed = false
local recalled = false
local guard_provider_context = nil
assert(guard:register_provider(rayne, {
    deploy = function(_, request_id, context)
        deployed = request_id == "guard-request-002"
        guard_provider_context = context
        return "native-guard-handle-001"
    end,
    recall = function(handle)
        recalled = handle == "native-guard-handle-001"
        return true
    end,
}).ok)
assert(guard:deploy(rayne, "guard-request-002").ok)
assert(deployed)
assert(guard:status().activeGuardCount == 1)
assert(type(guard_provider_context.onTerminated) == "function")
guard_provider_context.onTerminated({ reason = "guard-downed" })
assert(guard:status().activeGuardCount == 0)
assert(guard:recall(rayne).reason == "no-active-guard")
assert(not recalled)
assert(guard:deploy(rayne, "guard-request-003").ok)
assert(guard:recall(rayne).ok)
assert(recalled)

local leader_row = ui:faction_row(rayne)
assert(leader_row.rankId == "Leader")
assert(leader_row.guard.eligible == true)
assert(leader_row.guard.providerReady == true)

recalled = false
assert(guard:deploy(rayne, "guard-request-004").ok)
local demotion = api:apply_reputation_delta(
    rayne,
    -300,
    {
        source = "consequence",
        operationId = "consequence:guard-demotion:001",
        authority = "pwft.faction-consequence.v1",
        reasonCode = "mission-failure",
    }
)
assert(demotion.ok and demotion.demoted == true)
assert(api:faction_status(rayne).rankId == "CoreMember")
assert(api:faction_status(rayne).guardAccess == false)
local revoked = guard:reconcile_entitlement(
    rayne,
    "reputation-entitlement-revoked"
)
assert(revoked.ok and revoked.revoked == true)
assert(recalled == true)
assert(guard:status().activeGuardCount == 0)
assert(guard:reconcile_entitlement(rayne).reason == "no-active-guard")
local demoted_row = ui:faction_row(rayne)
assert(demoted_row.rankId == "CoreMember")
assert(demoted_row.guard.eligible == false)
assert(demoted_row.lastReputationChange.reasonCode == "mission-failure")

assert(api:award_task(rayne, 300, "task-guard-repromotion-001").ok)
assert(api:faction_status(rayne).rankId == "Leader")
assert(guard:deploy(rayne, "guard-request-005").ok)
assert(guard:recall(rayne, "test-cleanup").ok)

print("PASS faction UI model, hostile-defense truce, guard demotion recall, and re-promotion")
