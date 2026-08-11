package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local ContentModuleLoader = require("pwft.content_module_loader")

local registrations = {}
local activations = {}
local logs = {}
local runtime = {
    register = function(_, bundle)
        registrations[#registrations + 1] = bundle.manifest.contentPackId
        if bundle.reject then
            return { ok = false, reason = "fixture-rejected" }
        end
        return {
            ok = true,
            reason = "content-bundle-registered",
            contentPackId = bundle.manifest.contentPackId,
        }
    end,
}

package.preload["test_content_modules.valid"] = function()
    return {
        bundle = {
            schemaVersion = "pwft.content-bundle.v1",
            manifest = { contentPackId = "test.module.valid" },
        },
        activate = function(context, registration)
            activations[#activations + 1] = {
                marker = context.marker,
                contentPackId = registration.contentPackId,
            }
            return { ok = true, reason = "fixture-activated" }
        end,
    }
end

package.preload["test_content_modules.data_only"] = function()
    return {
        schemaVersion = "pwft.content-bundle.v1",
        manifest = { contentPackId = "test.module.data-only" },
    }
end

local loader = ContentModuleLoader.create(runtime, {
    enabled = true,
    modules = {
        "test_content_modules.valid",
        "test_content_modules.data_only",
    },
}, {
    marker = "trusted-context",
}, {
    logger = function(message) logs[#logs + 1] = message end,
})

local loaded = loader:load()
assert(loaded.ok and loaded.reason == "content-modules-loaded")
assert(#registrations == 2)
assert(#activations == 1)
assert(activations[1].marker == "trusted-context")
assert(activations[1].contentPackId == "test.module.valid")
assert(#logs == 2)
local status = loader:status()
assert(status.registeredCount == 2)
assert(status.activatedCount == 2)
assert(status.failedCount == 0)
assert(status.internalRequireOnly == true)
assert(status.crossModGlobalsRequired == false)
assert(loader:load().reason == "content-modules-already-loaded")

local failing = ContentModuleLoader.create(runtime, {
    enabled = true,
    modules = {
        "../outside",
        "test_content_modules.missing",
    },
})
local failed = failing:load()
assert(not failed.ok and failed.reason == "content-module-load-failed")
assert(failing:status().failedCount == 2)
assert(failing:status().records[1].reason == "invalid-content-module-name")
assert(failing:status().records[2].reason == "content-module-require-failed")

print("PWFT internal content-module loader specification: PASS")
