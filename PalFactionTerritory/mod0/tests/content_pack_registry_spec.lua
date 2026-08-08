package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local ContentPackRegistry = require("pwft.content_pack_registry")

local function manifest(pack_id, namespace, capability, localization_keys)
    return {
        schemaVersion = "1.0.0",
        contentPackId = pack_id,
        contentVersion = "1.0.0",
        namespace = namespace,
        localizationNamespace = namespace .. ".l10n",
        dependencies = {},
        conflicts = {},
        loadAfter = {},
        capabilities = { capability },
        localizationKeys = localization_keys or {
            namespace .. ".l10n.title",
        },
    }
end

local registry = ContentPackRegistry.create({ coreVersion = "1.0.0" })
assert(registry:status().registeredPackCount == 0)
assert(registry:status().atomicBatchRegistration)
assert(registry:status().localizationKeysOnly)
assert(registry:status().manifestMayExecuteCode == false)

-- Unknown fields are rejected so a manifest cannot smuggle authored prose into
-- the mechanism registry. Failed batches do not partially commit valid peers.
local valid_peer = manifest(
    "fan.atomic.good",
    "fan.atomic",
    "pwft.quest.templates"
)
local invalid_peer = manifest(
    "fan.atomic.bad",
    "fan.atomic",
    "pwft.quest.templates"
)
invalid_peer.title = "forbidden inline story prose"
local atomic_failure = registry:register_batch({ valid_peer, invalid_peer })
assert(not atomic_failure.ok)
assert(atomic_failure.reason == "invalid-content-pack-manifest")
assert(registry:status().registeredPackCount == 0)
assert(registry:manifest("fan.atomic.good") == nil)

local foundation = manifest(
    "fan.foundation.core",
    "fan.foundation",
    "pwft.faction.join-sources",
    {
        "fan.foundation.l10n.name",
        "fan.foundation.l10n.summary",
    }
)
foundation.contentVersion = "1.2.0"

local quests = manifest(
    "fan.quests.chapter-one",
    "fan.quests",
    "pwft.quest.templates",
    {
        "fan.quests.l10n.title",
        "fan.quests.l10n.summary",
        "fan.quests.l10n.objective",
    }
)
quests.dependencies = {
    {
        contentPackId = foundation.contentPackId,
        minimumVersion = "1.1.0",
    },
}

-- Input order is intentionally reversed; dependency edges define the stable
-- load order and registration commits only after every manifest passes.
local loaded = registry:register_batch({ quests, foundation })
assert(loaded.ok and loaded.reason == "content-pack-batch-registered")
assert(loaded.registeredCount == 2)
assert(loaded.loadOrder[1] == foundation.contentPackId)
assert(loaded.loadOrder[2] == quests.contentPackId)
assert(registry:status().registeredPackCount == 2)
assert(registry:manifest(quests.contentPackId).loadIndex == 2)
assert(registry:has_capability(quests.contentPackId, "pwft.quest.templates"))
assert(not registry:has_capability(quests.contentPackId, "pwft.pal.discourse"))
assert(registry:owns_localization_key(quests.contentPackId, "fan.quests.l10n.title"))
assert(not registry:owns_localization_key(quests.contentPackId, "fan.other.l10n.title"))
assert(registry:providers("pwft.quest.templates")[1] == quests.contentPackId)

local duplicate = registry:register(quests)
assert(duplicate.ok and duplicate.reason == "content-pack-already-registered")
assert(registry:status().registeredPackCount == 2)

local migrated = manifest(
    "fan.quests.chapter-one",
    "fan.quests",
    "pwft.quest.templates"
)
migrated.contentVersion = "2.0.0"
assert(registry:register(migrated).reason == "content-pack-migration-required")

local missing_dependency = manifest(
    "fan.missing.addon",
    "fan.missing",
    "pwft.quest.templates"
)
missing_dependency.dependencies = {
    {
        contentPackId = "fan.not-installed.core",
        minimumVersion = "1.0.0",
    },
}
local missing = registry:register(missing_dependency)
assert(not missing.ok and missing.reason == "content-pack-dependency-missing")
assert(registry:manifest(missing_dependency.contentPackId) == nil)

local version_dependency = manifest(
    "fan.version.addon",
    "fan.version",
    "pwft.quest.templates"
)
version_dependency.dependencies = {
    {
        contentPackId = foundation.contentPackId,
        minimumVersion = "2.0.0",
    },
}
assert(
    registry:register(version_dependency).reason
        == "content-pack-dependency-version-unsatisfied"
)

local conflicting = manifest(
    "fan.conflict.addon",
    "fan.conflict",
    "pwft.quest.templates"
)
conflicting.conflicts = { quests.contentPackId }
assert(registry:register(conflicting).reason == "content-pack-conflict")
assert(registry:manifest(conflicting.contentPackId) == nil)

local cycle_a = manifest(
    "fan.cycle.alpha",
    "fan.cycle",
    "pwft.quest.templates"
)
local cycle_b = manifest(
    "fan.cycle.beta",
    "fan.cycle",
    "pwft.quest.templates"
)
cycle_a.loadAfter = { cycle_b.contentPackId }
cycle_b.loadAfter = { cycle_a.contentPackId }
local cycle = registry:register_batch({ cycle_a, cycle_b })
assert(not cycle.ok and cycle.reason == "content-pack-load-order-cycle")
assert(registry:manifest(cycle_a.contentPackId) == nil)
assert(registry:manifest(cycle_b.contentPackId) == nil)
assert(registry:status().registeredPackCount == 2)

local bad_localization = manifest(
    "fan.localization.bad",
    "fan.localization",
    "pwft.quest.templates",
    { "someone.else.l10n.title" }
)
assert(registry:register(bad_localization).reason == "invalid-content-pack-manifest")

print("PASS atomic content-pack manifests, namespaces, semver dependencies, conflicts, deterministic load order, capabilities, and localization-key ownership")
