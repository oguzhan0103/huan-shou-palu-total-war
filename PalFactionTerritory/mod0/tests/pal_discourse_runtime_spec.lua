package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local Registry = require("pwft.registry")
local Progression = require("pwft.faction_progression")
local PalReconciliation = require("pwft.pal_reconciliation")
local PalDiscourseRuntime = require("pwft.pal_discourse_runtime")

local function unlock_all_human_lords(progression)
    for _, faction_id in ipairs(Registry.progression.humanFactionIds) do
        local status = progression:status(faction_id)
        for _, source_faction_id in ipairs(status.diplomacyHostilitySources or {}) do
            local id = "discourse-test-clear:" .. faction_id .. ":" .. source_faction_id
            assert(progression:clear_diplomacy_hostility(
                faction_id,
                source_faction_id,
                { contextId = id, eventId = id }
            ).ok)
        end
        if not progression:status(faction_id).joined then
            assert(progression:join(faction_id).ok)
        end
        local ordinal = 0
        while progression:status(faction_id).reputation < 1200 do
            ordinal = ordinal + 1
            assert(progression:grant_reputation(
                faction_id,
                "task",
                300,
                {
                    contextId = "discourse-test-rank:" .. faction_id .. ":" .. ordinal,
                    eventId = "discourse-test-rank:" .. faction_id .. ":" .. ordinal,
                }
            ).ok)
        end
        assert(progression:status(faction_id).rankId == "Lord")
    end
end

local progression = Progression.create(Registry.progression)
local reconciliation = PalReconciliation.create(
    Registry.palReconciliation,
    progression,
    { randomIndex = function() return 1 end }
)
local runtime = PalDiscourseRuntime.create(
    reconciliation,
    {
        offlineDialogueTreeEnabled = true,
        nativeDialoguePresenterEnabled = true,
    }
)
local faction_id = "pwft.faction.desert_pal_tribe"
local representative_id = "fan.pal-representative.desert.v1"

local pack = {
    schemaVersion = "1.0.0",
    contentPackId = "fan.pal-discourse.desert.v1",
    contentVersion = "1.0.0",
    factions = {
        {
            factionId = faction_id,
            tokenQuota = 3,
            maximumAffinityPerDiscourse = 50,
            representative = {
                representativeId = representative_id,
                nameKey = "fan.desert.representative.name",
                interactionPromptKey = "fan.desert.representative.prompt",
            },
            trees = {
                {
                    treeId = "fan.desert.tree.default.v1",
                    cityStateId = "*",
                    rootNodeId = "pal-opening",
                    nodes = {
                        {
                            nodeId = "pal-opening",
                            speakerRole = "pal-representative",
                            textKey = "fan.desert.node.opening",
                            choices = {
                                {
                                    choiceId = "continue",
                                    textKey = "fan.desert.choice.continue",
                                    nextNodeId = "player-position",
                                },
                                {
                                    choiceId = "withdraw",
                                    textKey = "fan.desert.choice.withdraw",
                                    nextNodeId = "abort-terminal",
                                },
                            },
                        },
                        {
                            nodeId = "player-position",
                            speakerRole = "player",
                            textKey = "fan.desert.node.player-position",
                            choices = {
                                {
                                    choiceId = "agree",
                                    textKey = "fan.desert.choice.agree",
                                    nextNodeId = "success-terminal",
                                },
                            },
                        },
                        {
                            nodeId = "success-terminal",
                            speakerRole = "pal-representative",
                            textKey = "fan.desert.node.success",
                            terminal = {
                                outcome = "completed",
                                affinityAward = 50,
                                resultTags = { "mutual-understanding" },
                            },
                        },
                        {
                            nodeId = "abort-terminal",
                            speakerRole = "player",
                            textKey = "fan.desert.node.withdrawn",
                            terminal = {
                                outcome = "player_abort",
                                affinityAward = 0,
                            },
                        },
                    },
                },
            },
        },
    },
}

-- Inline authored prose is rejected; the mechanism contract accepts only
-- localization keys supplied by a fan content pack.
local invalid_pack = {
    schemaVersion = "1.0.0",
    contentPackId = "fan.invalid.inline-text",
    contentVersion = "1.0.0",
    factions = {
        {
            factionId = faction_id,
            tokenQuota = 1,
            maximumAffinityPerDiscourse = 50,
            representative = {
                representativeId = "fan.invalid.representative",
                nameKey = "fan.invalid.name",
                interactionPromptKey = "fan.invalid.prompt",
                displayName = "forbidden inline story text",
            },
            trees = pack.factions[1].trees,
        },
    },
}
local invalid = runtime:register_pack(invalid_pack)
assert(not invalid.ok and invalid.reason == "invalid-pal-discourse-content-pack")
assert(runtime:status().registeredFactionCount == 0)

local registered = runtime:register_pack(pack)
assert(registered.ok and registered.reason == "pal-discourse-content-pack-registered")
assert(registered.factionCount == 1)
assert(runtime:status().registeredRepresentativeCount == 1)
assert(runtime.capabilities.authoredStoryContent == false)
assert(runtime.capabilities.nativePresenter == true)

local tokens = {}
for index = 1, 3 do
    local awarded = reconciliation:record_raid_result(faction_id, {
        raidEventId = "discourse-runtime-raid:" .. index,
        playerSideWon = true,
        playerCreditedLeaderKill = true,
    })
    assert(awarded.ok and awarded.tokenAwarded)
    tokens[index] = awarded.tokenInstanceId
    assert(reconciliation:complete_token_quest(
        faction_id,
        tokens[index],
        "discourse-runtime-quest:" .. index,
        { questId = "fan.desert.quest." .. index }
    ).ok)
end

assert(runtime:offer(
    "unknown-representative",
    tokens[1],
    "offer-unknown"
).reason == "unknown-pal-representative")
local locked_offer = runtime:offer(
    representative_id,
    tokens[1],
    "offer-before-human-lords"
)
assert(not locked_offer.ok)
assert(locked_offer.eligibilityReason == "all-human-lords-required")
local locked_ready = runtime:ready_tokens_for_representative(
    representative_id
)
assert(locked_ready.ok and #locked_ready.tokens == 0)
unlock_all_human_lords(progression)
local ready = runtime:ready_tokens_for_representative(
    representative_id
)
assert(ready.ok and ready.reason == "pal-discourse-ready-tokens-listed")
assert(#ready.tokens == 3)
assert(ready.tokens[1].tokenInstanceId == tokens[1])
assert(ready.tokens[1].state == "quest-complete")
assert(ready.tokens[1].preview.ok == true)

-- Declining before the irreversible confirmation preserves the token.
local declined_offer = runtime:offer(
    representative_id,
    tokens[1],
    "offer-decline"
)
assert(declined_offer.ok and declined_offer.irreversible)
assert(declined_offer.representativeNameKey == "fan.desert.representative.name")
local declined = runtime:confirm(
    declined_offer.offerId,
    "confirmation-decline",
    false
)
assert(declined.ok and declined.reason == "pal-discourse-declined-token-preserved")
assert(reconciliation:token_status(faction_id, tokens[1]).state == "quest-complete")
assert(runtime:confirm(
    declined_offer.offerId,
    "confirmation-decline",
    false
).reason == "pal-discourse-confirmation-already-processed")

-- An accepted offer reserves the token, then the deterministic tree resolves
-- a content-authored affinity value through the reconciliation service.
local success_offer = runtime:offer(
    representative_id,
    tokens[1],
    "offer-success"
)
local started = runtime:confirm(
    success_offer.offerId,
    "confirmation-success",
    true
)
assert(started.ok and started.reason == "pal-discourse-session-started")
assert(started.node.textKey == "fan.desert.node.opening")
assert(reconciliation:token_status(faction_id, tokens[1]).state == "reserved")
assert(runtime:choose(
    started.sessionId,
    "unknown-choice",
    "action-unknown"
).reason == "unknown-pal-discourse-choice")
local middle = runtime:choose(
    started.sessionId,
    "continue",
    "action-continue"
)
assert(middle.ok and middle.reason == "pal-discourse-node-ready")
assert(middle.node.speakerRole == "player")
local completed = runtime:choose(
    started.sessionId,
    "agree",
    "action-agree"
)
assert(completed.ok and completed.reason == "pal-discourse-terminal-resolved")
assert(completed.terminal.affinityAward == 50)
assert(completed.settlement.session.affinityApplied == 50)
assert(progression:status(faction_id).reputation == -50)
assert(reconciliation:token_status(faction_id, tokens[1]).state == "consumed")
local repeated = runtime:choose(
    started.sessionId,
    "agree",
    "action-agree"
)
assert(repeated.ok and repeated.reason == "pal-discourse-action-already-processed")
assert(progression:status(faction_id).reputation == -50)

-- A provider/runtime failure after confirmation refunds the reserved token.
local technical_offer = runtime:offer(
    representative_id,
    tokens[2],
    "offer-technical"
)
local technical_started = runtime:confirm(
    technical_offer.offerId,
    "confirmation-technical",
    true
)
local refunded = runtime:technical_failure(
    technical_started.sessionId,
    "failure-renderer",
    "localization-provider-unavailable"
)
assert(refunded.ok and refunded.reason == "pal-discourse-technical-failure-refunded")
assert(reconciliation:token_status(faction_id, tokens[2]).state == "quest-complete")

-- Closing an already confirmed session is a player abort and consumes its
-- chance without affinity.
local abort_offer = runtime:offer(
    representative_id,
    tokens[2],
    "offer-api-abort"
)
local abort_started = runtime:confirm(
    abort_offer.offerId,
    "confirmation-api-abort",
    true
)
local aborted = runtime:player_abort(
    abort_started.sessionId,
    "close-dialogue-window"
)
assert(aborted.ok and aborted.reason == "pal-discourse-player-abort-consumed")
assert(reconciliation:token_status(faction_id, tokens[2]).state == "consumed")
assert(progression:status(faction_id).reputation == -50)

-- An authored withdraw branch is governed by the same confirmed-abort rule.
local branch_offer = runtime:offer(
    representative_id,
    tokens[3],
    "offer-branch-abort"
)
local branch_started = runtime:confirm(
    branch_offer.offerId,
    "confirmation-branch-abort",
    true
)
local branch_aborted = runtime:choose(
    branch_started.sessionId,
    "withdraw",
    "action-withdraw"
)
assert(branch_aborted.ok and branch_aborted.reason == "pal-discourse-terminal-resolved")
assert(branch_aborted.terminal.outcome == "player_abort")
assert(reconciliation:token_status(faction_id, tokens[3]).state == "consumed")
assert(progression:status(faction_id).reputation == -50)
assert(reconciliation:status(faction_id).permanentlyLocked == true)

local status = runtime:status()
assert(status.activeSessionCount == 0)
assert(status.resolvedSessionCount == 4)
assert(status.localizationKeysOnly == true)
assert(status.baseStoryContentIncluded == false)

print("PASS registered Pal representatives, localization-key-only trees, irreversible confirmation, deterministic branches, abort consumption, and technical refunds")
