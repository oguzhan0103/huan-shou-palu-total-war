package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local Registry = require("pwft.registry")
local Progression = require("pwft.faction_progression")
local ContentPackRegistry = require("pwft.content_pack_registry")
local ContentRuntime = require("pwft.content_runtime")
local QuestRuntime = require("pwft.quest_runtime")
local StrategicWorld = require("pwft.strategic_world")
local EndingRuntime = require("pwft.ending_runtime")

local progression = Progression.create(Registry.progression)
local manifests = ContentPackRegistry.create()
local quests = QuestRuntime.create(progression, manifests)
local world = StrategicWorld.create(progression, { contentPackRegistry = manifests })
local endings = EndingRuntime.create(progression, world, { contentPackRegistry = manifests })
local runtime = ContentRuntime.create(progression, manifests, quests, world, endings)

local manifest = {
    schemaVersion = "1.0.0",
    contentPackId = "sample.bundle.foundation",
    contentVersion = "1.0.0",
    namespace = "sample.bundle",
    localizationNamespace = "sample.bundle.l10n",
    dependencies = {},
    conflicts = {},
    loadAfter = {},
    capabilities = {
        "pwft.quest.templates",
        "pwft.world.city-states",
        "pwft.world.endings",
        "pwft.world.unique-pals",
    },
    localizationKeys = {
        "sample.bundle.l10n.quest.objective",
        "sample.bundle.l10n.quest.summary",
        "sample.bundle.l10n.quest.title",
    },
}

local quest_template = {
    schemaVersion = "1.0.0",
    contentPackId = manifest.contentPackId,
    contentVersion = manifest.contentVersion,
    templateId = "sample.bundle.quest.smoke",
    titleKey = "sample.bundle.l10n.quest.title",
    summaryKey = "sample.bundle.l10n.quest.summary",
    startStageId = "ready",
    stages = {
        {
            stageId = "ready",
            objectiveKey = "sample.bundle.l10n.quest.objective",
            nextStageIds = {},
            branches = {},
            completionAllowed = true,
            abortAllowed = true,
        },
    },
}

local strategic_pack = {
    schemaVersion = "pwft.strategic-world.pack.v1",
    contentPackId = manifest.contentPackId,
    contentVersion = manifest.contentVersion,
    uniquePals = {
        {
            id = "sample.bundle.unique.smoke",
            speciesId = "SampleSmokePal",
            displayNameKey = "sample.bundle.loc.unique.smoke.name",
            initialOwner = { kind = "wild" },
        },
    },
    cities = {
        {
            id = "sample.bundle.city.smoke",
            factionId = "pwft.faction.rayne_syndicate",
            displayNameKey = "sample.bundle.loc.city.smoke.name",
            requiredUniquePalId = "sample.bundle.unique.smoke",
        },
    },
}

local ending_pack = {
    schemaVersion = "pwft.ending-routes.pack.v1",
    contentPackId = manifest.contentPackId,
    contentVersion = manifest.contentVersion,
    routes = {
        {
            id = "sample.bundle.ending.smoke",
            displayNameKey = "sample.bundle.loc.ending.smoke.name",
            priority = 1,
            conditions = {
                { kind = "flag_equals", key = "sample.bundle.flag.ready", value = true },
            },
            effects = {
                { kind = "set_title", titleKey = "sample.bundle.loc.ending.smoke.title" },
                { kind = "set_world_disposition", value = "conditional" },
            },
        },
    },
}

local invalid_strategic = {}
for key, value in pairs(strategic_pack) do invalid_strategic[key] = value end
invalid_strategic.cities = {
    {
        id = "sample.bundle.city.invalid",
        factionId = "pwft.faction.rayne_syndicate",
        displayNameKey = "sample.bundle.loc.city.invalid.name",
        requiredUniquePalId = "sample.bundle.unique.not-declared",
    },
}
local invalid_bundle = {
    schemaVersion = "pwft.content-bundle.v1",
    manifest = manifest,
    questTemplates = { quest_template },
    strategicWorld = invalid_strategic,
    endingRoutes = ending_pack,
}
local invalid = runtime:register(invalid_bundle)
assert(not invalid.ok)
assert(manifests:status().registeredPackCount == 0)
assert(quests:status().templateCount == 0)
assert(world:status().contentPackCount == 0)
assert(endings:status().contentPackCount == 0)

local bundle = {
    schemaVersion = "pwft.content-bundle.v1",
    manifest = manifest,
    questTemplates = { quest_template },
    strategicWorld = strategic_pack,
    endingRoutes = ending_pack,
}
assert(runtime:validate(bundle).reason == "content-bundle-staged")
assert(manifests:status().registeredPackCount == 0)
local registered = runtime:register(bundle)
assert(registered.ok and registered.reason == "content-bundle-registered")
assert(registered.questTemplateCount == 1)
assert(registered.strategicWorldRegistered and registered.endingRoutesRegistered)
assert(runtime:register(bundle).reason == "content-bundle-already-registered")
assert(runtime:status().registeredBundleCount == 1)
assert(runtime:status().modelMayRegisterContent == false)

assert(quests:start(
    "sample.bundle.quest.smoke",
    "sample.bundle.quest.instance.smoke",
    "sample.bundle.event.start",
    { source = "automated-smoke" }
).ok)
assert(quests:complete(
    "sample.bundle.quest.instance.smoke",
    "sample.bundle.event.complete",
    { resultTags = { "sample-smoke-complete" } }
).ok)
assert(world:city_status("sample.bundle.city.smoke").status == "active")
assert(endings:set_flag("sample.bundle.flag.ready", true, "sample.bundle.event.flag").ok)
assert(endings:evaluate("sample.bundle.ending.smoke").ready)

print("PWFT atomic cross-domain content runtime specification: PASS")
