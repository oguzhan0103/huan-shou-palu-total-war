package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    "examples/?.lua",
    package.path,
}, ";")

local Registry = require("pwft.registry")
local Progression = require("pwft.faction_progression")
local ContentPackRegistry = require("pwft.content_pack_registry")
local ContentActionRuntime = require("pwft.content_action_runtime")
local ContentRuntime = require("pwft.content_runtime")
local FactionApi = require("pwft.faction_api")
local QuestRuntime = require("pwft.quest_runtime")
local RewardPolicy = require("pwft.reward_policy")
local StrategicWorld = require("pwft.strategic_world")
local EndingRuntime = require("pwft.ending_runtime")
local PalReconciliation = require("pwft.pal_reconciliation")
local PalDiscourseRuntime = require("pwft.pal_discourse_runtime")
local LocalizationRuntime = require("pwft.localization_runtime")
local NpcLeaderGuardOrchestrator =
    require("pwft.npc_leader_guard_orchestrator")
local RewardPolicy = require("pwft.reward_policy")
local Example = require("minimal-content-pack.pack")

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[copy(key)] = copy(item) end
    return result
end

local function assert_all_key_fields_declared(pack_registry, content_pack_id, value)
    if type(value) ~= "table" then return end
    for key, item in pairs(value) do
        if type(key) == "string" and string.match(key, "Key$") ~= nil then
            assert(type(item) == "string", key .. " must contain one localization key")
            assert(
                pack_registry:owns_localization_key(content_pack_id, item),
                "undeclared example localization key: " .. item
            )
        else
            assert_all_key_fields_declared(pack_registry, content_pack_id, item)
        end
    end
end

local pack_registry = ContentPackRegistry.create({ coreVersion = "1.0.0" })

-- One invalid peer rejects the whole batch. The otherwise-valid example must
-- not leak into the registry before the author fixes the bad manifest.
local invalid_manifest = copy(Example.manifest)
invalid_manifest.contentPackId = "example.invalid.atomic"
invalid_manifest.namespace = "example.invalid"
invalid_manifest.localizationNamespace = "example.invalid.loc"
invalid_manifest.title = "forbidden-inline-field"
local atomic = pack_registry:register_batch({ Example.manifest, invalid_manifest })
assert(not atomic.ok and atomic.reason == "invalid-content-pack-manifest")
assert(pack_registry:status().registeredPackCount == 0)
assert(pack_registry:manifest(Example.manifest.contentPackId) == nil)

local manifest_result = pack_registry:register(Example.manifest)
assert(manifest_result.ok and manifest_result.reason == "content-pack-registered")
assert(pack_registry:has_capability(Example.manifest.contentPackId, "pwft.quest.templates"))
assert(pack_registry:has_capability(Example.manifest.contentPackId, "pwft.pal.discourse"))
assert(pack_registry:has_capability(Example.manifest.contentPackId, "pwft.world.unique-pals"))
assert(pack_registry:has_capability(Example.manifest.contentPackId, "pwft.world.city-states"))
assert(pack_registry:has_capability(Example.manifest.contentPackId, "pwft.world.endings"))

assert_all_key_fields_declared(pack_registry, Example.manifest.contentPackId, Example.questTemplate)
assert_all_key_fields_declared(pack_registry, Example.manifest.contentPackId, Example.strategicWorld)
assert_all_key_fields_declared(pack_registry, Example.manifest.contentPackId, Example.endingRoutes)
assert_all_key_fields_declared(pack_registry, Example.manifest.contentPackId, Example.palDiscourse)

local progression = Progression.create(Registry.progression)
local quests = QuestRuntime.create(progression, pack_registry)
local template_result = quests:register_template(Example.questTemplate)
assert(template_result.ok and template_result.reason == "quest-template-registered")

local world = StrategicWorld.create(progression, { contentPackRegistry = pack_registry })
local world_result = world:register_pack(Example.strategicWorld)
assert(world_result.ok and world_result.reason == "content-pack-registered")
assert(world_result.uniquePalCount == 1 and world_result.cityCount == 1)

local endings = EndingRuntime.create(
    progression,
    world,
    { contentPackRegistry = pack_registry }
)
local ending_result = endings:register_pack(Example.endingRoutes)
assert(ending_result.ok and ending_result.reason == "ending-pack-registered")
assert(ending_result.routeCount == 3)

-- Validate the supplied Pal-discourse tree against the same real mechanism
-- contracts. It remains data only; native presentation is deliberately off.
local reconciliation = PalReconciliation.create(
    Registry.palReconciliation,
    progression,
    { randomIndex = function() return 1 end }
)
local discourse = PalDiscourseRuntime.create(reconciliation, {
    offlineDialogueTreeEnabled = true,
    nativeDialoguePresenterEnabled = true,
})
local discourse_result = discourse:register_pack(Example.palDiscourse)
assert(discourse_result.ok and discourse_result.reason == "pal-discourse-content-pack-registered")
assert(discourse_result.factionCount == 1)

-- The public author entrypoint must also validate as one atomic bundle. This
-- mirrors the in-game internal module loader rather than the legacy sequence
-- of separate cross-Mod global registrations.
local bundle_progression = Progression.create(Registry.progression)
local bundle_registry = ContentPackRegistry.create({ coreVersion = "1.0.0" })
local bundle_quests = QuestRuntime.create(bundle_progression, bundle_registry)
local bundle_world = StrategicWorld.create(bundle_progression, {
    contentPackRegistry = bundle_registry,
})
local bundle_endings = EndingRuntime.create(
    bundle_progression,
    bundle_world,
    { contentPackRegistry = bundle_registry }
)
local bundle_reconciliation = PalReconciliation.create(
    Registry.palReconciliation,
    bundle_progression
)
local bundle_discourse = PalDiscourseRuntime.create(
    bundle_reconciliation,
    { offlineDialogueTreeEnabled = true, nativeDialoguePresenterEnabled = true }
)
local bundle_localization = LocalizationRuntime.create(bundle_registry, {
    fallbackLocale = "zh-CN",
})
local bundle_faction_api = FactionApi.create(bundle_progression)
local bundle_leader_guards = NpcLeaderGuardOrchestrator.create(
    bundle_faction_api,
    { providerWhitelist = {} }
)
local bundle_rewards = RewardPolicy.create(bundle_progression)
local bundle_runtime = ContentRuntime.create(
    bundle_progression,
    bundle_registry,
    bundle_quests,
    bundle_world,
    bundle_endings,
    {
        palDiscourseRuntime = bundle_discourse,
        localizationRuntime = bundle_localization,
        contentActionRuntime = ContentActionRuntime.create(
            bundle_faction_api,
            bundle_world,
            bundle_endings,
            bundle_registry
        ),
        npcLeaderGuardOrchestrator = bundle_leader_guards,
        rewardPolicy = bundle_rewards,
    }
)
local invalid_leader_bundle = copy(Example.bundle)
invalid_leader_bundle.leaderGuards.leaders[1].factionId =
    "example.minimal.unknown-faction"
local invalid_leader_result = bundle_runtime:register(
    invalid_leader_bundle
)
assert(not invalid_leader_result.ok)
assert(bundle_registry:status().registeredPackCount == 0)
assert(bundle_quests:status().templateCount == 0)
assert(bundle_world:status().contentPackCount == 0)
assert(bundle_endings:status().contentPackCount == 0)
assert(bundle_leader_guards:status().contentPackCount == 0)
local atomic_bundle = bundle_runtime:register(Example.bundle)
assert(
    atomic_bundle.ok and atomic_bundle.reason == "content-bundle-registered",
    tostring(atomic_bundle.reason) .. ":"
        .. tostring(atomic_bundle.validationError or "no-detail")
)
assert(atomic_bundle.questTemplateCount == 1)
assert(atomic_bundle.palDiscourseRegistered)
assert(atomic_bundle.localizationRegistered)
assert(atomic_bundle.localizedMessageCount > 0)
assert(atomic_bundle.contentActionsRegistered)
assert(atomic_bundle.contentActionCount == 4)
assert(atomic_bundle.leaderGuardsRegistered)
assert(atomic_bundle.leaderGuardLeaderCount == 1)
assert(atomic_bundle.rewardPoliciesRegistered)
assert(atomic_bundle.rewardPolicyCount == 1)
assert(bundle_rewards:status().policyCount == 1)
assert(atomic_bundle.rewardPoliciesRegistered)
assert(atomic_bundle.rewardPolicyCount == 1)
assert(bundle_leader_guards:status().contentPackCount == 1)
assert(bundle_leader_guards:status().leaderCount == 1)
assert(type(bundle_progression:export_snapshot().npcLeaderGuards)
    == "table")
assert(bundle_localization:resolve(
    "zh-CN",
    Example.localization.byName.palRepresentativePrompt
) == "与代表论道")

-- Minimal loop: content registration -> quest choice -> structured result ->
-- trusted Core operations -> deterministic ending evaluation and commit.
local quest_id = "example.minimal.quest.instance.e2e"
assert(quests:start(
    Example.questTemplate.templateId,
    quest_id,
    "example.minimal.event.quest.start",
    { sourceId = "example.minimal.source.e2e" }
).ok)
assert(quests:advance(
    quest_id,
    "example.minimal.quest.stage.choose",
    "example.minimal.event.quest.advance",
    { triggerId = "example.minimal.trigger.ready" }
).ok)
assert(quests:branch(
    quest_id,
    "example.minimal.quest.branch.preserve",
    "example.minimal.event.quest.branch",
    { decisionId = "example.minimal.decision.preserve" }
).ok)
local completed = quests:complete(
    quest_id,
    "example.minimal.event.quest.complete",
    {
        decisionId = "example.minimal.decision.preserve",
        uniquePalActionId = "example.minimal.action.claim",
        endingFlagId = "example.minimal.flag.route.preserve",
    }
)
assert(completed.ok and completed.reason == "quest-completed")

local settled = completed.resolution.structuredResult
assert(settled.decisionId == "example.minimal.decision.preserve")
assert(settled.uniquePalActionId == "example.minimal.action.claim")
assert(settled.endingFlagId == "example.minimal.flag.route.preserve")

local player = { kind = "player", id = "example-minimal-e2e-player" }
local transfer = world:transfer_unique_pal(
    "example.minimal.unique.keystone",
    { kind = "wild" },
    player,
    "example.minimal.operation.claim",
    { reason = settled.uniquePalActionId }
)
assert(transfer.ok and transfer.reason == "unique-pal-transferred")
local flag = endings:set_flag(
    settled.endingFlagId,
    true,
    "example.minimal.operation.ending-flag"
)
assert(flag.ok and flag.reason == "ending-flag-set")

local evaluation = endings:evaluate("example.minimal.ending.route.preserve")
assert(evaluation.ok and evaluation.ready and evaluation.reason == "ending-route-ready")
local committed = endings:commit(
    "example.minimal.ending.route.preserve",
    "example.minimal.operation.ending-commit"
)
assert(committed.ok and committed.reason == "ending-committed")
assert(endings:post_ending_policy().worldDisposition == "pacified")
assert(world:city_status("example.minimal.city.primary").status == "active")
assert(world:unique_pal_status("example.minimal.unique.keystone").owner.kind == "player")
assert(quests:quest_status(quest_id).state == "completed")

local snapshot = progression:export_snapshot()
assert(type(snapshot.contentQuests) == "table")
assert(type(snapshot.strategicWorld) == "table")
assert(type(snapshot.endings) == "table")

print("PASS minimal author SDK atomic registration and deterministic quest-to-world-to-ending loop")
