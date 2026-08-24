package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local Readiness = require("pwft.strategic_world_readiness")

local values = {}
local function component(name, value)
    values[name] = value
    return {
        status = function()
            return values[name]
        end,
    }
end

local components = {
    contentModuleLoader = component("contentModuleLoader", {
        configuredModuleCount = 0,
        activatedCount = 0,
        failedCount = 0,
    }),
    strategicWorld = component("strategicWorld", {
        uniquePalCount = 0,
        cityCount = 0,
    }),
    endingRuntime = component("endingRuntime", { routeCount = 0 }),
    strategicWorldNativeBus = component("strategicWorldNativeBus", {
        providerCount = 0,
        fullyCapableProviderCount = 0,
        bindingCount = 0,
        bindingCountByKind = {},
    }),
    uniquePalBossProviderBus = component("uniquePalBossProviderBus", {
        providerCount = 0,
        fullyCapableProviderCount = 0,
        activeProviderHandlerCount = 0,
        activeBindingCount = 0,
        exactVerifiedBindingsOnly = true,
    }),
    uniquePalWorldEffectBus = component("uniquePalWorldEffectBus", {
        providerCount = 0,
        fullyCapableProviderCount = 0,
        activeProviderHandlerCount = 0,
        activeTargetBindingCount = 0,
        fullyOperationalTargetBindingCount = 0,
        exactBoundActorsOnly = true,
        broadActorScan = false,
    }),
    uniquePalNativeDeliveryBridge = component(
        "uniquePalNativeDeliveryBridge",
        {
            currentNativeBindings = 0,
            exactIndividualIdentityRequired = true,
            directContainerMutation = false,
        }
    ),
    uniquePalNativeDeliveryProduction = component(
        "uniquePalNativeDeliveryProduction",
        { enabled = true, activeBindingCount = 0 }
    ),
    factionNpcAttitudeBus = component("factionNpcAttitudeBus", {
        readyProviderCount = 0,
        bindingCount = 0,
    }),
    endingEffectProviderBus = component("endingEffectProviderBus", {
        providerCount = 0,
        fullyCapableProviderCount = 0,
        activeProviderHandlerCount = 0,
        modelCommitAuthority = false,
    }),
}

local readiness = Readiness.create(components)
local empty = readiness:evaluate("empty-base")
assert(not empty.ok)
assert(empty.phase == "content-key-required")
assert(empty.contentBlockedCount == 3)
assert(empty.runtimeBlockedCount == 6)
assert(empty.blockedCount == 9)
assert(empty.liveAccepted == false)
assert(empty.PalworldSaveMutation == false)

values.contentModuleLoader = {
    configuredModuleCount = 1,
    activatedCount = 1,
    failedCount = 0,
}
values.strategicWorld = { uniquePalCount = 1, cityCount = 1 }
values.endingRuntime = { routeCount = 1 }
local content_only = readiness:evaluate("content-installed")
assert(not content_only.ok)
assert(content_only.phase == "native-bindings-required")
assert(content_only.contentBlockedCount == 0)
assert(content_only.runtimeBlockedCount == 6)

values.strategicWorldNativeBus = {
    providerCount = 1,
    fullyCapableProviderCount = 1,
    bindingCount = 3,
    bindingCountByKind = {
        ["unique-pal"] = 1,
        ["city-anchor"] = 1,
        ["city-boss"] = 1,
    },
}
values.uniquePalBossProviderBus = {
    providerCount = 1,
    fullyCapableProviderCount = 1,
    activeProviderHandlerCount = 1,
    activeBindingCount = 1,
    exactVerifiedBindingsOnly = true,
}
values.uniquePalWorldEffectBus = {
    providerCount = 1,
    fullyCapableProviderCount = 1,
    activeProviderHandlerCount = 1,
    activeTargetBindingCount = 1,
    fullyOperationalTargetBindingCount = 1,
    exactBoundActorsOnly = true,
    broadActorScan = false,
}
values.uniquePalNativeDeliveryBridge = {
    currentNativeBindings = 1,
    exactIndividualIdentityRequired = true,
    directContainerMutation = false,
}
values.uniquePalNativeDeliveryProduction = {
    enabled = true,
    activeBindingCount = 1,
}
values.factionNpcAttitudeBus = {
    readyProviderCount = 1,
    bindingCount = 1,
}
values.endingEffectProviderBus = {
    providerCount = 1,
    fullyCapableProviderCount = 1,
    activeProviderHandlerCount = 1,
    modelCommitAuthority = false,
}

local ready = readiness:evaluate("all-bindings-ready")
assert(ready.ok)
assert(ready.reason == "B7-readiness-gate-passed")
assert(ready.phase == "ready-for-b7-live-acceptance")
assert(ready.readyForLiveAcceptance == true)
assert(ready.liveEvidenceRequired == true)
assert(ready.liveAccepted == false)
assert(ready.blockedCount == 0)
assert(ready.passedCount == ready.checkCount)
assert(readiness:status().evaluationReason == "all-bindings-ready")

values.factionNpcAttitudeBus = nil
local status_failed = readiness:evaluate("component-status-failed")
assert(not status_failed.ok)
assert(status_failed.checkCount == 9)
assert(status_failed.runtimeBlockedCount == 1)
assert(status_failed.componentStatusErrors[1]
    == "factionNpcAttitudeBus-status-failed")
values.factionNpcAttitudeBus = {
    readyProviderCount = 1,
    bindingCount = 1,
}

values.uniquePalWorldEffectBus.broadActorScan = true
local unsafe = readiness:evaluate("unsafe-world-provider")
assert(not unsafe.ok)
assert(unsafe.phase == "native-bindings-required")
assert(unsafe.runtimeBlockedCount == 1)
assert(unsafe.blockerIds[1]
    == "unique-pal-world-effect-provider-bound")

print("strategic world B7 readiness tests passed")
