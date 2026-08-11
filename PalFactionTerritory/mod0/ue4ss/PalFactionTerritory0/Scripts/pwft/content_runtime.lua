local ContentPackRegistry = require("pwft.content_pack_registry")
local EndingRuntime = require("pwft.ending_runtime")
local FactionProgression = require("pwft.faction_progression")
local LocalizationRuntime = require("pwft.localization_runtime")
local PalDiscourseRuntime = require("pwft.pal_discourse_runtime")
local PalReconciliation = require("pwft.pal_reconciliation")
local QuestRuntime = require("pwft.quest_runtime")
local StrategicWorld = require("pwft.strategic_world")

local ContentRuntime = {}

local API_VERSION = "1.0.0"
local BUNDLE_SCHEMA = "pwft.content-bundle.v1"

local function copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] ~= nil then return seen[value] end
    local result = {}
    seen[value] = result
    for key, child in pairs(value) do result[copy(key, seen)] = copy(child, seen) end
    return result
end

local function result(ok, reason, extra)
    local value = extra or {}
    value.ok = ok
    value.reason = reason
    return value
end

local function non_empty(value, name)
    assert(type(value) == "string" and value ~= "", name .. " is required")
    return value
end

local function sorted_keys(values)
    local keys = {}
    for key in pairs(values or {}) do keys[#keys + 1] = key end
    table.sort(keys)
    return keys
end

local function stable_encode(value)
    if type(value) ~= "table" then
        return type(value) .. ":" .. tostring(value)
    end
    local parts = { "{" }
    for _, key in ipairs(sorted_keys(value)) do
        parts[#parts + 1] = stable_encode(key)
        parts[#parts + 1] = stable_encode(value[key])
    end
    parts[#parts + 1] = "}"
    return table.concat(parts, "|")
end

local function assert_bundle_shape(bundle)
    assert(type(bundle) == "table", "content bundle is required")
    local allowed = {
        schemaVersion = true,
        manifest = true,
        questTemplates = true,
        strategicWorld = true,
        endingRoutes = true,
        palDiscourse = true,
        localization = true,
    }
    for key in pairs(bundle) do
        assert(allowed[key] == true, "content bundle contains unsupported field: " .. tostring(key))
    end
    assert(bundle.schemaVersion == BUNDLE_SCHEMA, "unsupported content bundle schema")
    assert(type(bundle.manifest) == "table", "content bundle manifest is required")
    assert(type(bundle.questTemplates or {}) == "table", "content bundle quest templates must be an array")
    assert(bundle.strategicWorld == nil or type(bundle.strategicWorld) == "table",
        "content bundle strategic world must be a table")
    assert(bundle.endingRoutes == nil or type(bundle.endingRoutes) == "table",
        "content bundle ending routes must be a table")
    assert(bundle.palDiscourse == nil or type(bundle.palDiscourse) == "table",
        "content bundle Pal discourse must be a table")
    assert(bundle.localization == nil or type(bundle.localization) == "table",
        "content bundle localization must be a table")
    return non_empty(bundle.manifest.contentPackId, "content bundle pack ID")
end

local function manifest_without_runtime_fields(manifest)
    local value = copy(manifest)
    value.loadIndex = nil
    return value
end

local function clone_registry(source)
    local clone = ContentPackRegistry.create({ coreVersion = source.coreVersion })
    local manifests = {}
    for _, pack_id in ipairs(source:status().loadOrder) do
        table.insert(manifests, manifest_without_runtime_fields(source:manifest(pack_id)))
    end
    if #manifests > 0 then
        local registered = clone:register_batch(manifests)
        assert(registered.ok, "installed content manifests could not be cloned")
    end
    return clone
end

local function stage_bundle(instance, bundle)
    local pack_id = assert_bundle_shape(bundle)
    assert(bundle.manifest.contentPackId == pack_id, "content bundle manifest ID mismatch")
    for _, template in ipairs(bundle.questTemplates or {}) do
        assert(template.contentPackId == pack_id, "quest template pack ID mismatch")
    end
    if bundle.strategicWorld ~= nil then
        assert(bundle.strategicWorld.contentPackId == pack_id, "strategic-world pack ID mismatch")
    end
    if bundle.endingRoutes ~= nil then
        assert(bundle.endingRoutes.contentPackId == pack_id, "ending-routes pack ID mismatch")
    end
    if bundle.palDiscourse ~= nil then
        assert(bundle.palDiscourse.contentPackId == pack_id, "Pal-discourse pack ID mismatch")
        assert(bundle.palDiscourse.contentVersion == bundle.manifest.contentVersion,
            "Pal-discourse content version mismatch")
    end
    if bundle.localization ~= nil then
        assert(bundle.localization.schemaVersion == "1.0.0", "unsupported localization bundle schema")
        assert(bundle.localization.contentPackId == pack_id, "localization pack ID mismatch")
        assert(bundle.localization.contentVersion == bundle.manifest.contentVersion,
            "localization content version mismatch")
        assert(type(bundle.localization.catalogs) == "table", "localization catalogs are required")
    end

    local staged_registry = clone_registry(instance.contentPackRegistry)
    local manifest_result = staged_registry:register(bundle.manifest)
    if not manifest_result.ok then return manifest_result end

    local staged_progression = FactionProgression.create(
        instance.progression.contract,
        instance.progression:export_snapshot()
    )
    local staged_quests = QuestRuntime.create(staged_progression, staged_registry)
    staged_quests.templates = copy(instance.questRuntime.templates)

    local staged_world = StrategicWorld.create(staged_progression, {
        contentPackRegistry = staged_registry,
    })
    staged_world.packDefinitions = copy(instance.strategicWorld.packDefinitions)
    staged_world.uniquePalDefinitions = copy(instance.strategicWorld.uniquePalDefinitions)
    staged_world.cityDefinitions = copy(instance.strategicWorld.cityDefinitions)

    local staged_endings = EndingRuntime.create(staged_progression, staged_world, {
        contentPackRegistry = staged_registry,
    })
    staged_endings.packDefinitions = copy(instance.endingRuntime.packDefinitions)
    staged_endings.routeDefinitions = copy(instance.endingRuntime.routeDefinitions)

    local staged_discourse = nil
    if instance.palDiscourseRuntime ~= nil then
        local staged_reconciliation = PalReconciliation.create(
            instance.palDiscourseRuntime.reconciliation.contract,
            staged_progression
        )
        staged_discourse = PalDiscourseRuntime.create(
            staged_reconciliation,
            instance.palDiscourseRuntime.config
        )
        local existing_packs = instance.palDiscourseRuntime
            :export_registered_packs()
        for _, existing_pack_id in ipairs(sorted_keys(existing_packs)) do
            local existing_pack = existing_packs[existing_pack_id]
            local replayed = staged_discourse:register_pack(existing_pack)
            assert(replayed.ok, "installed Pal discourse packs could not be cloned")
        end
    end

    local staged_localization = nil
    if instance.localizationRuntime ~= nil then
        staged_localization = LocalizationRuntime.create(staged_registry, {
            fallbackLocale = instance.localizationRuntime.fallbackLocale,
        })
        local snapshot = instance.localizationRuntime:export_snapshot()
        for _, existing_pack_id in ipairs(sorted_keys(snapshot)) do
            local replayed = staged_localization:register_pack(
                existing_pack_id,
                snapshot[existing_pack_id]
            )
            assert(replayed.ok, "installed localization packs could not be cloned")
        end
    end

    local staged_results = {
        manifest = manifest_result,
        questTemplates = {},
        strategicWorld = nil,
        endingRoutes = nil,
        palDiscourse = nil,
        localization = nil,
    }
    for _, template in ipairs(bundle.questTemplates or {}) do
        local registered = staged_quests:register_template(template)
        if not registered.ok then return registered end
        table.insert(staged_results.questTemplates, registered)
    end
    if bundle.strategicWorld ~= nil then
        staged_results.strategicWorld = staged_world:register_pack(bundle.strategicWorld)
        if not staged_results.strategicWorld.ok then return staged_results.strategicWorld end
    end
    if bundle.endingRoutes ~= nil then
        staged_results.endingRoutes = staged_endings:register_pack(bundle.endingRoutes)
        if not staged_results.endingRoutes.ok then return staged_results.endingRoutes end
    end
    if bundle.palDiscourse ~= nil then
        assert(staged_discourse ~= nil, "Pal discourse runtime is not configured")
        staged_results.palDiscourse = staged_discourse:register_pack(bundle.palDiscourse)
        if not staged_results.palDiscourse.ok then return staged_results.palDiscourse end
    end
    if bundle.localization ~= nil then
        assert(staged_localization ~= nil, "localization runtime is not configured")
        staged_results.localization = staged_localization:register_pack(
            pack_id,
            bundle.localization.catalogs
        )
        if not staged_results.localization.ok then return staged_results.localization end
    end
    return result(true, "content-bundle-staged", {
        contentPackId = pack_id,
        stagedResults = staged_results,
    })
end

function ContentRuntime.create(
    progression,
    content_pack_registry,
    quest_runtime,
    strategic_world,
    ending_runtime,
    options
)
    assert(type(progression) == "table", "progression service is required")
    assert(type(content_pack_registry) == "table", "content-pack registry is required")
    assert(type(quest_runtime) == "table", "quest runtime is required")
    assert(type(strategic_world) == "table", "strategic-world runtime is required")
    assert(type(ending_runtime) == "table", "ending runtime is required")
    options = options or {}
    assert(options.palDiscourseRuntime == nil
        or type(options.palDiscourseRuntime) == "table",
        "Pal discourse runtime must be a table")
    assert(options.localizationRuntime == nil
        or type(options.localizationRuntime) == "table",
        "localization runtime must be a table")
    return setmetatable({
        version = API_VERSION,
        progression = progression,
        contentPackRegistry = content_pack_registry,
        questRuntime = quest_runtime,
        strategicWorld = strategic_world,
        endingRuntime = ending_runtime,
        palDiscourseRuntime = options.palDiscourseRuntime,
        localizationRuntime = options.localizationRuntime,
        registeredBundles = {},
        bundleFingerprints = {},
        capabilities = {
            atomicCrossDomainValidation = true,
            deterministicCommitAfterValidation = true,
            manifestDataOnly = true,
            localizationKeysOnly = true,
            storyContentIncluded = false,
            palDiscourseAtomicRegistration = options.palDiscourseRuntime ~= nil,
            localizationAtomicRegistration = options.localizationRuntime ~= nil,
        },
    }, { __index = ContentRuntime })
end

function ContentRuntime:validate(bundle)
    local ok, staged_or_error = pcall(stage_bundle, self, bundle)
    if not ok then
        return result(false, "invalid-content-bundle", { validationError = tostring(staged_or_error) })
    end
    return staged_or_error
end

function ContentRuntime:register(bundle)
    local shape_ok, pack_id_or_error = pcall(assert_bundle_shape, bundle)
    if not shape_ok then
        return result(false, "invalid-content-bundle", {
            validationError = tostring(pack_id_or_error),
        })
    end
    local existing = self.registeredBundles[pack_id_or_error]
    if existing ~= nil then
        if self.bundleFingerprints[pack_id_or_error]
            ~= stable_encode(bundle) then
            return result(false, "content-bundle-migration-required", {
                contentPackId = pack_id_or_error,
            })
        end
        return result(true, "content-bundle-already-registered", copy(existing))
    end
    local staged = self:validate(bundle)
    if not staged.ok then return staged end
    local pack_id = staged.contentPackId

    local manifest = self.contentPackRegistry:register(bundle.manifest)
    assert(manifest.ok, "staged content manifest failed during deterministic commit")
    local quest_results = {}
    for _, template in ipairs(bundle.questTemplates or {}) do
        local registered = self.questRuntime:register_template(template)
        assert(registered.ok, "staged quest template failed during deterministic commit")
        table.insert(quest_results, registered)
    end
    local strategic_result = nil
    if bundle.strategicWorld ~= nil then
        strategic_result = self.strategicWorld:register_pack(bundle.strategicWorld)
        assert(strategic_result.ok, "staged strategic-world pack failed during deterministic commit")
    end
    local ending_result = nil
    if bundle.endingRoutes ~= nil then
        ending_result = self.endingRuntime:register_pack(bundle.endingRoutes)
        assert(ending_result.ok, "staged ending pack failed during deterministic commit")
    end
    local pal_discourse_result = nil
    if bundle.palDiscourse ~= nil then
        pal_discourse_result = self.palDiscourseRuntime:register_pack(bundle.palDiscourse)
        assert(pal_discourse_result.ok,
            "staged Pal discourse pack failed during deterministic commit")
    end
    local localization_result = nil
    if bundle.localization ~= nil then
        localization_result = self.localizationRuntime:register_pack(
            pack_id,
            bundle.localization.catalogs
        )
        assert(localization_result.ok,
            "staged localization pack failed during deterministic commit")
    end
    local record = {
        contentPackId = pack_id,
        contentVersion = bundle.manifest.contentVersion,
        questTemplateCount = #quest_results,
        strategicWorldRegistered = strategic_result ~= nil,
        endingRoutesRegistered = ending_result ~= nil,
        palDiscourseRegistered = pal_discourse_result ~= nil,
        localizationRegistered = localization_result ~= nil,
        localizedMessageCount = localization_result
            and localization_result.messageCount or 0,
    }
    self.registeredBundles[pack_id] = copy(record)
    self.bundleFingerprints[pack_id] = stable_encode(bundle)
    return result(true, "content-bundle-registered", record)
end

function ContentRuntime:status()
    local count = 0
    for _ in pairs(self.registeredBundles) do count = count + 1 end
    return {
        apiVersion = self.version,
        registeredBundleCount = count,
        registeredPackCount = self.contentPackRegistry:status().registeredPackCount,
        questTemplateCount = self.questRuntime:status().templateCount,
        strategicWorldPackCount = self.strategicWorld:status().contentPackCount,
        endingPackCount = self.endingRuntime:status().contentPackCount,
        palDiscourseFactionCount = self.palDiscourseRuntime
            and self.palDiscourseRuntime:status().registeredFactionCount or 0,
        localizationPackCount = self.localizationRuntime
            and self.localizationRuntime:status().registeredPackCount or 0,
        localizedMessageCount = self.localizationRuntime
            and self.localizationRuntime:status().messageCount or 0,
        atomicCrossDomainValidation = true,
        modelMayRegisterContent = false,
        storyContentIncluded = false,
    }
end

return ContentRuntime
