package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local Registry = require("pwft.registry")
local Config = require("pwft.config")
local Progression = require("pwft.faction_progression")
local ContentPackRegistry = require("pwft.content_pack_registry")
local ContentActionRuntime = require("pwft.content_action_runtime")
local ContentRuntime = require("pwft.content_runtime")
local FactionApi = require("pwft.faction_api")
local QuestRuntime = require("pwft.quest_runtime")
local StrategicWorld = require("pwft.strategic_world")
local EndingRuntime = require("pwft.ending_runtime")
local LocalizationRuntime = require("pwft.localization_runtime")
local PalDiscourseRuntime = require("pwft.pal_discourse_runtime")
local PalReconciliation = require("pwft.pal_reconciliation")
local RewardPolicy = require("pwft.reward_policy")
local UniquePalCampaign = require("pwft.unique_pal_campaign")

local progression = Progression.create(Registry.progression)
local manifests = ContentPackRegistry.create()
local quests = QuestRuntime.create(progression, manifests)
local world = StrategicWorld.create(progression, { contentPackRegistry = manifests })
local endings = EndingRuntime.create(progression, world, { contentPackRegistry = manifests })
local reconciliation = PalReconciliation.create(Registry.palReconciliation, progression)
local discourse = PalDiscourseRuntime.create(reconciliation, Config.palReconciliation)
local localization = LocalizationRuntime.create(manifests, { fallbackLocale = "zh-CN" })
local content_actions = ContentActionRuntime.create(
    FactionApi.create(progression), world, endings, manifests
)
local rewards = RewardPolicy.create(progression)
local unique_pal_campaign = UniquePalCampaign.create(progression, world)
local runtime = ContentRuntime.create(progression, manifests, quests, world, endings, {
    palDiscourseRuntime = discourse,
    localizationRuntime = localization,
    contentActionRuntime = content_actions,
    rewardPolicy = rewards,
    uniquePalCampaign = unique_pal_campaign,
})

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
        "pwft.pal.discourse",
        "pwft.world.city-states",
        "pwft.world.endings",
        "pwft.world.unique-pals",
        "pwft.world.unique-pal-campaign",
    },
    localizationKeys = {
        "sample.bundle.l10n.quest.objective",
        "sample.bundle.l10n.quest.summary",
        "sample.bundle.l10n.quest.title",
    },
}

local pal_discourse = {
    schemaVersion = "1.0.0",
    contentPackId = manifest.contentPackId,
    contentVersion = manifest.contentVersion,
    factions = {
        {
            factionId = "pwft.faction.desert_pal_tribe",
            tokenQuota = 1,
            maximumAffinityPerDiscourse = 10,
            representative = {
                representativeId = "sample.bundle.pal.representative",
                nameKey = "sample.bundle.l10n.quest.title",
                interactionPromptKey = "sample.bundle.l10n.quest.summary",
            },
            trees = {
                {
                    treeId = "sample.bundle.pal.tree",
                    cityStateId = "*",
                    rootNodeId = "sample.bundle.pal.node.opening",
                    nodes = {
                        {
                            nodeId = "sample.bundle.pal.node.opening",
                            speakerRole = "pal-representative",
                            textKey = "sample.bundle.l10n.quest.objective",
                            choices = {
                                {
                                    choiceId = "sample.bundle.pal.choice.finish",
                                    textKey = "sample.bundle.l10n.quest.summary",
                                    nextNodeId = "sample.bundle.pal.node.finish",
                                },
                            },
                        },
                        {
                            nodeId = "sample.bundle.pal.node.finish",
                            speakerRole = "pal-representative",
                            textKey = "sample.bundle.l10n.quest.objective",
                            terminal = {
                                outcome = "completed",
                                affinityAward = 10,
                                resultTags = { "sample.bundle.pal.complete" },
                            },
                        },
                    },
                },
            },
        },
    },
}

local localization_bundle = {
    schemaVersion = "1.0.0",
    contentPackId = manifest.contentPackId,
    contentVersion = manifest.contentVersion,
    catalogs = {
        ["zh-CN"] = {
            ["sample.bundle.l10n.quest.objective"] = "占位目标",
            ["sample.bundle.l10n.quest.summary"] = "占位摘要",
            ["sample.bundle.l10n.quest.title"] = "占位标题",
        },
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

local unique_pal_campaign_pack = {
    schemaVersion = "pwft.unique-pal-campaign.pack.v1",
    contentPackId = manifest.contentPackId,
    contentVersion = manifest.contentVersion,
    uniquePals = {{
        id = "sample.bundle.unique.smoke",
        target = {
            kind = "faction",
            id = "pwft.faction.rayne_syndicate",
            affectedFactionIds = {
                "pwft.faction.rayne_syndicate",
            },
        },
        boss = {
            speciesId = "SampleSmokePal",
            nativeBossAvailable = false,
            bindingStatus = "pending",
            strengthProfile = "raid-slab",
        },
        schedule = {
            minimumIntervalTicks = 10,
            maximumIntervalTicks = 20,
            noticeTicks = 5,
            openTicks = 10,
        },
        ransomPrice = 99999999,
        candidateFactionIds = {
            "pwft.faction.pidf",
        },
    }},
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
    palDiscourse = pal_discourse,
    localization = localization_bundle,
    uniquePalCampaign = unique_pal_campaign_pack,
}
local invalid = runtime:register(invalid_bundle)
assert(not invalid.ok)
assert(manifests:status().registeredPackCount == 0)
assert(quests:status().templateCount == 0)
assert(world:status().contentPackCount == 0)
assert(endings:status().contentPackCount == 0)
assert(discourse:status().registeredFactionCount == 0)
assert(localization:status().registeredPackCount == 0)

local bundle = {
    schemaVersion = "pwft.content-bundle.v1",
    manifest = manifest,
    questTemplates = { quest_template },
    strategicWorld = strategic_pack,
    endingRoutes = ending_pack,
    palDiscourse = pal_discourse,
    localization = localization_bundle,
    uniquePalCampaign = unique_pal_campaign_pack,
    rewardPolicies = {
        schemaVersion = "pwft.reward-policy.pack.v1",
        contentPackId = manifest.contentPackId,
        policies = {{
            id = "sample.bundle.reward.quest",
            sourceKind = "quest",
            difficultyBands = {
                { minimumScore = 0, multiplierBps = 10000 },
            },
            rewards = {{
                channelId = "sample.bundle.reward.channel.quest",
                baseUnits = 1,
                maximumUnits = 1,
            }},
        }},
    },
}
assert(runtime:validate(bundle).reason == "content-bundle-staged")
assert(manifests:status().registeredPackCount == 0)
local registered = runtime:register(bundle)
assert(registered.ok and registered.reason == "content-bundle-registered")
assert(registered.questTemplateCount == 1)
assert(registered.strategicWorldRegistered and registered.endingRoutesRegistered)
assert(registered.palDiscourseRegistered and registered.localizationRegistered)
assert(registered.rewardPoliciesRegistered)
assert(registered.uniquePalCampaignRegistered)
assert(registered.uniquePalCampaignCount == 1)
assert(registered.rewardPolicyCount == 1)
assert(registered.localizedMessageCount == 3)
assert(runtime:register(bundle).reason == "content-bundle-already-registered")
assert(runtime:status().registeredBundleCount == 1)
assert(runtime:status().modelMayRegisterContent == false)
assert(runtime:status().palDiscourseFactionCount == 1)
assert(runtime:status().localizationPackCount == 1)
assert(runtime:status().rewardPolicyCount == 1)
assert(runtime:status().uniquePalCampaignCount == 1)
assert(runtime:status().uniquePalCampaignPackCount == 1)
assert(localization:resolve("zh-CN", "sample.bundle.l10n.quest.title") == "占位标题")

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
