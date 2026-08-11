local function fail(message)
    io.stderr:write("PWFT content-pack validation: FAIL\n")
    io.stderr:write(tostring(message) .. "\n")
    os.exit(1)
end

local ok, error_message = pcall(function()
    local core_scripts = assert(arg[1], "Core scripts path argument is required")
    local pack_parent = assert(arg[2], "content-pack parent path argument is required")
    local module_name = assert(arg[3], "content-pack bundle module argument is required")
    package.path = table.concat({
        core_scripts .. "/?.lua",
        pack_parent .. "/?.lua",
        package.path,
    }, ";")

    local Registry = require("pwft.registry")
    local Config = require("pwft.config")
    local Progression = require("pwft.faction_progression")
    local ContentPackRegistry = require("pwft.content_pack_registry")
    local ContentRuntime = require("pwft.content_runtime")
    local EndingRuntime = require("pwft.ending_runtime")
    local LocalizationRuntime = require("pwft.localization_runtime")
    local PalDiscourseRuntime = require("pwft.pal_discourse_runtime")
    local PalReconciliation = require("pwft.pal_reconciliation")
    local QuestRuntime = require("pwft.quest_runtime")
    local StrategicWorld = require("pwft.strategic_world")

    local bundle = require(module_name)
    assert(type(bundle) == "table", "bundle module must return a table")

    local progression = Progression.create(Registry.progression)
    local manifests = ContentPackRegistry.create({ coreVersion = Config.schemaVersion })
    local quests = QuestRuntime.create(progression, manifests)
    local world = StrategicWorld.create(progression, {
        contentPackRegistry = manifests,
    })
    local endings = EndingRuntime.create(progression, world, {
        contentPackRegistry = manifests,
    })
    local reconciliation = PalReconciliation.create(
        Registry.palReconciliation,
        progression
    )
    local discourse = PalDiscourseRuntime.create(
        reconciliation,
        Config.palReconciliation
    )
    local localization = LocalizationRuntime.create(manifests, {
        fallbackLocale = Config.contentModules.fallbackLocale,
    })
    local runtime = ContentRuntime.create(
        progression,
        manifests,
        quests,
        world,
        endings,
        {
            palDiscourseRuntime = discourse,
            localizationRuntime = localization,
        }
    )
    local registered = runtime:register(bundle)
    assert(registered.ok,
        tostring(registered.reason) .. ": "
            .. tostring(registered.validationError or "no detail"))
    local status = runtime:status()
    print("PWFT content-pack validation: PASS")
    print("contentPackId=" .. tostring(registered.contentPackId))
    print("contentVersion=" .. tostring(registered.contentVersion))
    print("questTemplates=" .. tostring(registered.questTemplateCount))
    print("strategicWorld=" .. tostring(registered.strategicWorldRegistered))
    print("endingRoutes=" .. tostring(registered.endingRoutesRegistered))
    print("palDiscourse=" .. tostring(registered.palDiscourseRegistered))
    print("localizedMessages=" .. tostring(registered.localizedMessageCount))
    print("registeredBundles=" .. tostring(status.registeredBundleCount))
end)

if not ok then fail(error_message) end
