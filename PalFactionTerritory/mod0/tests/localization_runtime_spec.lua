package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local ContentPackRegistry = require("pwft.content_pack_registry")
local LocalizationRuntime = require("pwft.localization_runtime")

local registry = ContentPackRegistry.create()
local manifest = {
    schemaVersion = "1.0.0",
    contentPackId = "sample.localization.foundation",
    contentVersion = "1.0.0",
    namespace = "sample.localization",
    localizationNamespace = "sample.localization.loc",
    dependencies = {},
    conflicts = {},
    loadAfter = {},
    capabilities = { "pwft.pal.discourse" },
    localizationKeys = {
        "sample.localization.loc.opening",
        "sample.localization.loc.choice",
    },
}
assert(registry:register(manifest).ok)

local runtime = LocalizationRuntime.create(registry, {
    fallbackLocale = "zh-CN",
})
local registered = runtime:register_pack(manifest.contentPackId, {
    ["zh-CN"] = {
        ["sample.localization.loc.opening"] = "占位开场",
        ["sample.localization.loc.choice"] = "占位选择",
    },
    ["en-US"] = {
        ["sample.localization.loc.opening"] = "Placeholder opening",
    },
})
assert(registered.ok and registered.messageCount == 3)
assert(runtime:resolve("zh-CN", "sample.localization.loc.choice") == "占位选择")
assert(runtime:resolve("en-US", "sample.localization.loc.opening") == "Placeholder opening")
assert(runtime:resolve("en-US", "sample.localization.loc.choice") == "占位选择")
assert(runtime:resolve("en-US", "sample.localization.loc.unknown") == nil)
assert(runtime:register_pack(manifest.contentPackId, runtime:export_snapshot()[manifest.contentPackId])
    .reason == "localization-pack-already-registered")

local invalid = runtime:register_pack(manifest.contentPackId, {
    ["zh-CN"] = {
        ["sample.localization.loc.not-owned"] = "拒绝",
    },
})
assert(not invalid.ok and invalid.reason == "invalid-localization-pack")

local status = runtime:status()
assert(status.registeredPackCount == 1)
assert(status.localeCount == 2)
assert(status.messageCount == 3)
assert(status.storyContentIncludedByBase == false)

print("PWFT localization runtime specification: PASS")
