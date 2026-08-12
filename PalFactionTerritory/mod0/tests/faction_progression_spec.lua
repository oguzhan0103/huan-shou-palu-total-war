package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?/init.lua",
    package.path,
}, ";")

local Registry = require("pwft.registry")
local Progression = require("pwft.faction_progression")

local progression = Progression.create(Registry.progression)
local initial = progression:status()
assert(initial.persistence == "snapshot-adapter-only")
assert(initial.palReconciliationUnlocked == false)
assert(initial.ending3Unlocked == false)

local diplomacy = Registry.progression.membershipPolicy.joinDiplomacyEffects
assert(Registry.progression.membershipPolicy.joinDiplomacyEffectsStatus == "runtime_overlay_content_adapter_and_native_presenter_ready")
assert(diplomacy.sourceThreadId == "019f7d91-89f6-7c33-809c-2bb61aedc2a6")
assert(diplomacy.defaultUnspecifiedRelation == "Neutral")
assert(diplomacy.reputationMutationOnJoin == false)
assert(#diplomacy.pairs == 5)
local relation_pairs = {}
for _, pair in ipairs(diplomacy.pairs) do
    local key = pair.factionA < pair.factionB
        and (pair.factionA .. "|" .. pair.factionB)
        or (pair.factionB .. "|" .. pair.factionA)
    relation_pairs[key] = pair.relation
end
assert(relation_pairs["pwft.faction.free_pal_alliance|pwft.faction.rayne_syndicate"] == "Hostile")
assert(relation_pairs["pwft.faction.pal_genetic_research_unit|pwft.faction.rayne_syndicate"] == "Friendly")
assert(relation_pairs["pwft.faction.feybreak_army|pwft.faction.rayne_syndicate"] == "Friendly")
assert(relation_pairs["pwft.faction.eternal_pyre|pwft.faction.pal_genetic_research_unit"] == "Hostile")
assert(relation_pairs["pwft.faction.moonflower|pwft.faction.pal_genetic_research_unit"] == "Neutral")

for _, faction_id in ipairs(Registry.progression.humanFactionIds) do
    local status = progression:status(faction_id)
    assert(status.kind == "Human")
    assert(status.reputation == 0)
    assert(status.joined == false)
    assert(status.relation == "Friendly")
    assert(status.rankId == nil)
    assert(status.joinEligible == true)
end

for _, faction_id in ipairs(Registry.progression.palFactionIds) do
    local status = progression:status(faction_id)
    assert(status.kind == "Pal")
    assert(status.reputation == -100)
    assert(status.joined == false)
    assert(status.relation == "Hostile")
    assert(status.joinEligible == false)
    assert(progression:join(faction_id).reason == "pal-faction-membership-forbidden")
    assert(progression:reconcile_pal(faction_id).reason == "pal-discourse-service-required")
end

-- Hostile human relations can be repaired through commerce, but one commerce
-- window cannot exceed the configured recovery plus friendly-commerce caps.
local hostile_snapshot = progression:export_snapshot()
local rayne_id = "pwft.faction.rayne_syndicate"
hostile_snapshot.factions[rayne_id].reputation = -60
hostile_snapshot.factions[rayne_id].joined = false
local hostile = Progression.create(Registry.progression, hostile_snapshot)
assert(hostile:status(rayne_id).relation == "Hostile")
local commerce = hostile:grant_reputation(
    rayne_id,
    "commerce",
    100,
    { windowId = "test-window-a", contextId = "trade-001" }
)
assert(commerce.ok == true)
assert(commerce.reason == "award-capped")
assert(commerce.applied == 80)
assert(commerce.before == -60)
assert(commerce.after == 20)
assert(hostile:status(rayne_id).relation == "Friendly")
assert(hostile:grant_reputation(rayne_id, "commerce", 10, { windowId = "test-window-a" }).applied == 0)
assert(hostile:grant_reputation(rayne_id, "commerce", 10, { windowId = "test-window-b" }).applied == 10)

-- Affiliation hostility is repaired automatically by successful commerce.
-- Only non-negative commerce awards count; each source needs 60 points, the
-- per-window cap is 20, and a transaction cannot spill into another source.
local free_pal_id = "pwft.faction.free_pal_alliance"
local ineligible_recovery =
    Progression.create(Registry.progression)
assert(ineligible_recovery:join(rayne_id).ok)
local caravan_trade = ineligible_recovery:grant_reputation(
    free_pal_id,
    "commerce",
    20,
    {
        windowId = "caravan-window-1",
        contextId = "caravan-trade-1",
        eventId = "commerce:caravan-trade-1",
        diplomacyRecoveryEligible = false,
        venueMode = "visiting-caravan",
    }
)
assert(caravan_trade.applied == 20)
assert(
    caravan_trade.commerceDiplomacyRecovery.reason
        == "commerce-venue-not-eligible"
)
assert(
    ineligible_recovery:status(free_pal_id)
        .commerce.diplomacyRecovery.activeProgress
        == 0
)
assert(ineligible_recovery:status(free_pal_id).relation
    == "Hostile")

local automatic_recovery = Progression.create(Registry.progression)
assert(automatic_recovery:join(rayne_id).ok)
assert(automatic_recovery:status(free_pal_id).relation == "Hostile")
local recovery_status =
    automatic_recovery:status(free_pal_id)
        .commerce.diplomacyRecovery
assert(recovery_status.activeSourceFactionId == rayne_id)
assert(recovery_status.requiredPerSource == 60)
assert(recovery_status.windowRemaining == 20)
local recovery_1 = automatic_recovery:grant_reputation(
    free_pal_id,
    "commerce",
    20,
    {
        windowId = "recovery-window-1",
        contextId = "recovery-trade-1",
        eventId = "commerce:recovery-trade-1",
        diplomacyRecoveryEligible = true,
        venueMode = "fixed-market",
    }
)
assert(recovery_1.applied == 20)
assert(recovery_1.commerceBreakdown.nonNegativeApplied == 20)
assert(recovery_1.commerceDiplomacyRecovery.applied == 20)
assert(recovery_1.commerceDiplomacyRecovery.current == 20)
assert(recovery_1.commerceDiplomacyRecovery.cleared == false)
assert(automatic_recovery:status(free_pal_id).relation == "Hostile")

-- Progress and duplicate protection survive snapshot restore.
automatic_recovery = Progression.create(
    Registry.progression,
    automatic_recovery:export_snapshot()
)
local duplicate_recovery = automatic_recovery:grant_reputation(
    free_pal_id,
    "commerce",
    20,
    {
        windowId = "recovery-window-1",
        contextId = "recovery-trade-1",
        eventId = "commerce:recovery-trade-1",
        diplomacyRecoveryEligible = true,
        venueMode = "fixed-market",
    }
)
assert(duplicate_recovery.reason == "duplicate-event")
assert(duplicate_recovery.applied == 0)
local capped_recovery = automatic_recovery:grant_reputation(
    free_pal_id,
    "commerce",
    20,
    {
        windowId = "recovery-window-1",
        contextId = "recovery-trade-capped",
        eventId = "commerce:recovery-trade-capped",
        diplomacyRecoveryEligible = true,
        venueMode = "fixed-market",
    }
)
assert(capped_recovery.applied == 0)
assert(
    automatic_recovery:export_snapshot()
        .processedEventIds["commerce:recovery-trade-capped"]
        == true
)
local recovery_2 = automatic_recovery:grant_reputation(
    free_pal_id,
    "commerce",
    20,
    {
        windowId = "recovery-window-2",
        contextId = "recovery-trade-2",
        eventId = "commerce:recovery-trade-2",
        diplomacyRecoveryEligible = true,
        venueMode = "fixed-market",
    }
)
assert(recovery_2.commerceDiplomacyRecovery.current == 40)
local recovery_3 = automatic_recovery:grant_reputation(
    free_pal_id,
    "commerce",
    20,
    {
        windowId = "recovery-window-3",
        contextId = "recovery-trade-3",
        eventId = "commerce:recovery-trade-3",
        diplomacyRecoveryEligible = true,
        venueMode = "fixed-market",
    }
)
assert(recovery_3.commerceDiplomacyRecovery.applied == 20)
assert(recovery_3.commerceDiplomacyRecovery.current == 60)
assert(recovery_3.commerceDiplomacyRecovery.cleared == true)
assert(
    recovery_3.commerceDiplomacyRecovery.reason
        == "diplomacy-hostility-cleared-by-commerce"
)
assert(automatic_recovery:status(free_pal_id).relation == "Friendly")
assert(automatic_recovery:status(free_pal_id).joinEligible == true)
assert(
    automatic_recovery:status(free_pal_id)
        .commerce.diplomacyRecovery.completedSourceCount
        == 1
)
assert(
    automatic_recovery:status(free_pal_id)
        .commerce.diplomacyRecovery
        .progressBySource[rayne_id]
        == 60
)

-- Human memberships are independent. Promotion is reputation-driven and
-- Leader is the first rank that unlocks player guards.  Joining a faction
-- applies the user-confirmed relationship matrix without lowering reputation.
assert(progression:join("pwft.faction.rayne_syndicate").ok == true)
assert(progression:status("pwft.faction.rayne_syndicate").relation == "Player")
assert(progression:status("pwft.faction.free_pal_alliance").relation == "Hostile")
assert(progression:status("pwft.faction.free_pal_alliance").reputation == 0)
assert(progression:status("pwft.faction.free_pal_alliance").joinEligible == false)
assert(progression:status("pwft.faction.free_pal_alliance").diplomacyHostilitySources[1] == rayne_id)
assert(progression:status("pwft.faction.pal_genetic_research_unit").relation == "Friendly")
assert(progression:status("pwft.faction.feybreak_army").relation == "Friendly")
local diplomacy_recovery = progression:clear_diplomacy_hostility(
    free_pal_id,
    rayne_id,
    {
        contextId = "trade-recovery-free-pal",
        eventId = "diplomacy-recovery:trade-recovery-free-pal",
    }
)
assert(diplomacy_recovery.ok == true)
assert(diplomacy_recovery.reason == "diplomacy-hostility-cleared")
assert(progression:status(free_pal_id).relation == "Friendly")
assert(progression:status(free_pal_id).joinEligible == true)
assert(progression:join(free_pal_id).ok == true)
assert(progression:status(free_pal_id).relation == "Player")
assert(progression:status("pwft.faction.rayne_syndicate").rankId == "Member")
assert(progression:has_guard_access("pwft.faction.rayne_syndicate") == false)

assert(progression:grant_reputation(rayne_id, "task", 300, { contextId = "task-001" }).applied == 300)
assert(progression:status(rayne_id).rankId == "CoreMember")
assert(progression:grant_reputation(rayne_id, "defense", 400, { contextId = "defense-001" }).applied == 300)
assert(progression:status(rayne_id).rankId == "CoreMember")
assert(progression:grant_reputation(rayne_id, "defense", 100, { contextId = "defense-002" }).applied == 100)
assert(progression:status(rayne_id).rankId == "Leader")
assert(progression:has_guard_access(rayne_id) == true)
assert(progression:grant_reputation(rayne_id, "task", 500, { contextId = "task-002" }).applied == 300)
assert(progression:grant_reputation(rayne_id, "task", 200, { contextId = "task-003" }).applied == 200)
assert(progression:status(rayne_id).rankId == "Lord")

-- Complete the remaining human faction ranks. This unlocks the Pal
-- reconciliation stage but does not auto-reconcile any Pal faction.
for _, faction_id in ipairs(Registry.progression.humanFactionIds) do
    if not progression:status(faction_id).joined then
        for _, source_faction_id in ipairs(progression:status(faction_id).diplomacyHostilitySources or {}) do
            local cleared = progression:clear_diplomacy_hostility(
                faction_id,
                source_faction_id,
                {
                    contextId = "offline-multi-join-" .. faction_id .. "-" .. source_faction_id,
                    eventId = "diplomacy-recovery:offline-multi-join-" .. faction_id .. "-" .. source_faction_id,
                }
            )
            assert(cleared.ok == true)
        end
        assert(progression:join(faction_id).ok == true)
    end
    while progression:status(faction_id).reputation < 1200 do
        assert(progression:grant_reputation(faction_id, "task", 300, { contextId = "offline-rank-test" }).ok == true)
    end
    assert(progression:status(faction_id).rankId == "Lord")
end
local human_gate = progression:gate_status()
assert(human_gate.palReconciliationUnlocked == true)
assert(human_gate.ending3Unlocked == false)
assert(#human_gate.missingHumanLords == 0)
assert(#human_gate.missingPalFriendly == 5)

for _, faction_id in ipairs(Registry.progression.palFactionIds) do
    local reconciled = progression:award_pal_reconciliation(
        faction_id,
        100,
        {
            authority = "pal-discourse-service-v1",
            contextId = "finite-discourse-core-test",
            eventId = "pal-discourse:test:" .. faction_id,
        }
    )
    assert(reconciled.ok == true)
    assert(reconciled.reason == "pal-reconciled")
    assert(reconciled.relation == "Friendly")
    assert(progression:status(faction_id).joined == false)
    assert(progression:status(faction_id).rankId == nil)
end
local ending_gate = progression:gate_status()
assert(ending_gate.palReconciliationUnlocked == true)
assert(ending_gate.ending3Unlocked == true)
assert(#ending_gate.missingPalFriendly == 0)

local restored = Progression.create(Registry.progression, progression:export_snapshot())
assert(restored:status().ending3Unlocked == true)
assert(restored:status(rayne_id).rankId == "Lord")
assert(restored:status(rayne_id).guardAccess == true)
assert(#restored:relation_events() == Registry.counts.factions)

local in_place = Progression.create(Registry.progression)
local restored_in_place = in_place:restore_snapshot(
    progression:export_snapshot()
)
assert(restored_in_place.ok == true)
assert(in_place:status().ending3Unlocked == true)
assert(in_place:status(rayne_id).rankId == "Lord")

print("PASS Lua faction progression (relation matrix, multi-membership, caps, ranks, guards, gates, snapshot)")
