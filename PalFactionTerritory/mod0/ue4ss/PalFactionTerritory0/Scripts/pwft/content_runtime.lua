local ContentPackRegistry = require("pwft.content_pack_registry")
local EndingRuntime = require("pwft.ending_runtime")
local FactionProgression = require("pwft.faction_progression")
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

local function assert_bundle_shape(bundle)
    assert(type(bundle) == "table", "content bundle is required")
    local allowed = {
        schemaVersion = true,
        manifest = true,
        questTemplates = true,
        strategicWorld = true,
        endingRoutes = true,
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

    local staged_results = {
        manifest = manifest_result,
        questTemplates = {},
        strategicWorld = nil,
        endingRoutes = nil,
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
    return result(true, "content-bundle-staged", {
        contentPackId = pack_id,
        stagedResults = staged_results,
    })
end

function ContentRuntime.create(progression, content_pack_registry, quest_runtime, strategic_world, ending_runtime)
    assert(type(progression) == "table", "progression service is required")
    assert(type(content_pack_registry) == "table", "content-pack registry is required")
    assert(type(quest_runtime) == "table", "quest runtime is required")
    assert(type(strategic_world) == "table", "strategic-world runtime is required")
    assert(type(ending_runtime) == "table", "ending runtime is required")
    return setmetatable({
        version = API_VERSION,
        progression = progression,
        contentPackRegistry = content_pack_registry,
        questRuntime = quest_runtime,
        strategicWorld = strategic_world,
        endingRuntime = ending_runtime,
        registeredBundles = {},
        capabilities = {
            atomicCrossDomainValidation = true,
            deterministicCommitAfterValidation = true,
            manifestDataOnly = true,
            localizationKeysOnly = true,
            storyContentIncluded = false,
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
    local staged = self:validate(bundle)
    if not staged.ok then return staged end
    local pack_id = staged.contentPackId
    if self.registeredBundles[pack_id] ~= nil then
        return result(true, "content-bundle-already-registered", copy(self.registeredBundles[pack_id]))
    end

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
    local record = {
        contentPackId = pack_id,
        contentVersion = bundle.manifest.contentVersion,
        questTemplateCount = #quest_results,
        strategicWorldRegistered = strategic_result ~= nil,
        endingRoutesRegistered = ending_result ~= nil,
    }
    self.registeredBundles[pack_id] = copy(record)
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
        atomicCrossDomainValidation = true,
        modelMayRegisterContent = false,
        storyContentIncluded = false,
    }
end

return ContentRuntime
