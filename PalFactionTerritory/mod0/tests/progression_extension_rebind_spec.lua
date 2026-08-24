package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    "examples/?.lua",
    package.path,
}, ";")

local Registry = require("pwft.registry")
local Progression = require("pwft.faction_progression")
local ContentPackRegistry = require("pwft.content_pack_registry")
local QuestRuntime = require("pwft.quest_runtime")
local StrategicWorld = require("pwft.strategic_world")
local EndingRuntime = require("pwft.ending_runtime")
local PalReconciliation = require("pwft.pal_reconciliation")
local PalDiscourseRuntime = require("pwft.pal_discourse_runtime")
local Example = require("minimal-content-pack.pack")

local progression = Progression.create(Registry.progression)
local reconciliation = PalReconciliation.create(
    Registry.palReconciliation,
    progression,
    { randomIndex = function() return 1 end }
)
local discourse = PalDiscourseRuntime.create(reconciliation, {
    offlineDialogueTreeEnabled = true,
    nativeDialoguePresenterEnabled = true,
})
local pack_registry = ContentPackRegistry.create({ coreVersion = "1.0.0" })
assert(pack_registry:register(Example.manifest).ok)
local quests = QuestRuntime.create(progression, pack_registry)
local world = StrategicWorld.create(progression, {
    contentPackRegistry = pack_registry,
})
local endings = EndingRuntime.create(
    progression,
    world,
    { contentPackRegistry = pack_registry }
)

assert(quests:register_template(Example.questTemplate).ok)
assert(world:register_pack(Example.strategicWorld).ok)
assert(endings:register_pack(Example.endingRoutes).ok)
assert(discourse:register_pack(Example.palDiscourse).ok)
assert(progression:restore_listener_status().count == 5)

local old_root = progression.state
local old_pal = reconciliation.state
local old_quests = quests.state
local old_world = world.state
local old_endings = endings.state
local old_root_revision = old_root.revision
local old_pal_revision = old_pal.revision
local old_quest_sequence = old_quests.sequence
local old_world_revision = old_world.revision
local old_ending_revision = old_endings.revision

local legacy_snapshot = progression:export_snapshot()
legacy_snapshot.schemaVersion = "1.0.0"
legacy_snapshot.processedReputationOperations = nil
legacy_snapshot.extensionMigrationProbe = { preserved = true }
local restored = progression:restore_snapshot(legacy_snapshot)
assert(restored.ok and restored.reason == "snapshot-restored")
assert(restored.reboundListenerCount == 5)
assert(restored.migration.fromSchemaVersion == "1.0.0")
assert(progression.state.schemaVersion == "1.1.0")
assert(progression.state.extensionMigrationProbe.preserved == true)
assert(progression.state ~= old_root)
assert(reconciliation.state == progression.state.palReconciliation)
assert(quests.state == progression.state.contentQuests)
assert(world.state == progression.state.strategicWorld)
assert(endings.state == progression.state.endings)
assert(reconciliation.state ~= old_pal)
assert(quests.state ~= old_quests)
assert(world.state ~= old_world)
assert(endings.state ~= old_endings)

local pal_faction_id = Example.palDiscourse.factions[1].factionId
local raid = reconciliation:record_raid_result(pal_faction_id, {
    raidEventId = "rebind-spec.raid.1",
    playerSideWon = true,
    playerCreditedLeaderKill = true,
})
assert(raid.ok and raid.tokenAwarded == true)

local quest = quests:start(
    Example.questTemplate.templateId,
    "rebind-spec.quest.1",
    "rebind-spec.quest.start.1",
    { sourceId = "rebind-spec" }
)
assert(quest.ok)

local unique_pal_id = Example.strategicWorld.uniquePals[1].id
local transfer = world:transfer_unique_pal(
    unique_pal_id,
    { kind = "wild" },
    { kind = "player", id = "rebind-spec-player" },
    "rebind-spec.world.transfer.1",
    { reason = "rebind-spec" }
)
assert(transfer.ok)

local ending_flag = endings:set_flag(
    "rebind.spec.flag",
    true,
    "rebind-spec.ending.flag.1"
)
assert(ending_flag.ok)

assert(progression.state.revision > old_root_revision)
assert(reconciliation.state.revision > old_pal_revision)
assert(quests.state.sequence > old_quest_sequence)
assert(world.state.revision > old_world_revision)
assert(endings.state.revision > old_ending_revision)
assert(old_root.revision == old_root_revision)
assert(old_pal.revision == old_pal_revision)
assert(old_quests.sequence == old_quest_sequence)
assert(old_world.revision == old_world_revision)
assert(old_endings.revision == old_ending_revision)
assert(old_pal.processedRaidEvents["rebind-spec.raid.1"] == nil)
assert(old_quests.instances["rebind-spec.quest.1"] == nil)
assert(old_endings.flags["rebind.spec.flag"] == nil)

print("PASS delayed progression restore rebinds all extension state and never mutates stale tables")
