local StrategicWorldReadiness = {}

local API_VERSION = "1.0.0"

local COMPONENTS = {
    "contentModuleLoader",
    "strategicWorld",
    "endingRuntime",
    "strategicWorldNativeBus",
    "uniquePalBossProviderBus",
    "uniquePalWorldEffectBus",
    "uniquePalNativeDeliveryBridge",
    "uniquePalNativeDeliveryProduction",
    "factionNpcAttitudeBus",
    "endingEffectProviderBus",
}

local function copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] ~= nil then return seen[value] end
    local output = {}
    seen[value] = output
    for key, child in pairs(value) do
        output[copy(key, seen)] = copy(child, seen)
    end
    return output
end

local function result(ok, reason, extra)
    local value = extra or {}
    value.ok = ok
    value.reason = reason
    return value
end

local function count_by_status(checks, wanted)
    local count = 0
    for _, check in ipairs(checks) do
        if check.status == wanted then count = count + 1 end
    end
    return count
end

local function read_component_status(component_name, component)
    if type(component) ~= "table" or type(component.status) ~= "function" then
        return nil, component_name .. "-status-unavailable"
    end
    local ok, status = pcall(component.status, component)
    if not ok or type(status) ~= "table" then
        return nil, component_name .. "-status-failed"
    end
    return copy(status), nil
end

local function add_check(checks, id, owner, passed, actual, required)
    checks[#checks + 1] = {
        id = id,
        owner = owner,
        status = passed and "pass" or "blocked",
        actual = actual,
        required = required,
    }
end

function StrategicWorldReadiness.create(components, options)
    assert(type(components) == "table", "B7 readiness components are required")
    options = options or {}
    local minimums = options.minimums or {}
    assert(type(minimums) == "table", "B7 readiness minimums must be a table")
    local normalized = {}
    for _, name in ipairs(COMPONENTS) do
        assert(type(components[name]) == "table",
            "B7 readiness component is required: " .. name)
        normalized[name] = components[name]
    end
    return setmetatable({
        version = API_VERSION,
        components = normalized,
        minimums = {
            contentModules = minimums.contentModules or 1,
            uniquePals = minimums.uniquePals or 1,
            cities = minimums.cities or 1,
            endingRoutes = minimums.endingRoutes or 1,
        },
        evaluationCount = 0,
        lastEvaluation = nil,
        capabilities = {
            mechanicsOnly = true,
            storyContentIncluded = false,
            exactBindingGate = true,
            liveEvidenceRequired = true,
            userAcceptanceClaimed = false,
            PalworldSaveMutation = false,
        },
    }, { __index = StrategicWorldReadiness })
end

function StrategicWorldReadiness:evaluate(reason)
    self.evaluationCount = self.evaluationCount + 1
    local statuses = {}
    local status_errors = {}
    for _, name in ipairs(COMPONENTS) do
        local status, status_error = read_component_status(
            name,
            self.components[name]
        )
        statuses[name] = status
        if status_error ~= nil then
            status_errors[#status_errors + 1] = status_error
        end
    end

    local checks = {}
    local loader = statuses.contentModuleLoader or {}
    add_check(
        checks,
        "content-modules-activated",
        "content-author",
        (loader.configuredModuleCount or 0) >= self.minimums.contentModules
            and (loader.activatedCount or 0) >= self.minimums.contentModules
            and (loader.failedCount or 0) == 0,
        {
            configured = loader.configuredModuleCount or 0,
            activated = loader.activatedCount or 0,
            failed = loader.failedCount or 0,
        },
        { configured = self.minimums.contentModules, failed = 0 }
    )

    local strategic = statuses.strategicWorld or {}
    add_check(
        checks,
        "strategic-content-defined",
        "content-author",
        (strategic.uniquePalCount or 0) >= self.minimums.uniquePals
            and (strategic.cityCount or 0) >= self.minimums.cities,
        {
            uniquePals = strategic.uniquePalCount or 0,
            cities = strategic.cityCount or 0,
        },
        {
            uniquePals = self.minimums.uniquePals,
            cities = self.minimums.cities,
        }
    )

    local ending = statuses.endingRuntime or {}
    add_check(
        checks,
        "ending-content-defined",
        "content-author",
        (ending.routeCount or 0) >= self.minimums.endingRoutes,
        ending.routeCount or 0,
        self.minimums.endingRoutes
    )

    local native = statuses.strategicWorldNativeBus or {}
    add_check(
        checks,
        "strategic-native-provider-bound",
        "runtime-integration",
        (native.fullyCapableProviderCount or 0) > 0
            and type(native.bindingCountByKind) == "table"
            and (native.bindingCountByKind["unique-pal"] or 0) > 0
            and (native.bindingCountByKind["city-anchor"] or 0) > 0
            and (native.bindingCountByKind["city-boss"] or 0) > 0,
        {
            providers = native.providerCount or 0,
            fullyCapableProviders =
                native.fullyCapableProviderCount or 0,
            bindings = native.bindingCount or 0,
            bindingKinds = copy(native.bindingCountByKind or {}),
        },
        {
            fullyCapableProviders = 1,
            bindingKinds = {
                ["unique-pal"] = 1,
                ["city-anchor"] = 1,
                ["city-boss"] = 1,
            },
        }
    )

    local boss = statuses.uniquePalBossProviderBus or {}
    add_check(
        checks,
        "unique-pal-boss-provider-bound",
        "runtime-integration",
        (boss.fullyCapableProviderCount or 0) > 0
            and (boss.activeBindingCount or 0) > 0
            and boss.exactVerifiedBindingsOnly == true,
        {
            providers = boss.providerCount or 0,
            fullyCapableProviders =
                boss.fullyCapableProviderCount or 0,
            handlers = boss.activeProviderHandlerCount or 0,
            bindings = boss.activeBindingCount or 0,
            exact = boss.exactVerifiedBindingsOnly == true,
        },
        {
            fullyCapableProviders = 1,
            handlers = 1,
            bindings = 1,
            exact = true,
        }
    )

    local world_effect = statuses.uniquePalWorldEffectBus or {}
    add_check(
        checks,
        "unique-pal-world-effect-provider-bound",
        "runtime-integration",
        (world_effect.fullyCapableProviderCount or 0) > 0
            and (world_effect.fullyOperationalTargetBindingCount or 0) > 0
            and world_effect.exactBoundActorsOnly == true
            and world_effect.broadActorScan == false,
        {
            providers = world_effect.providerCount or 0,
            fullyCapableProviders =
                world_effect.fullyCapableProviderCount or 0,
            handlers = world_effect.activeProviderHandlerCount or 0,
            bindings = world_effect.activeTargetBindingCount or 0,
            fullyOperationalBindings =
                world_effect.fullyOperationalTargetBindingCount or 0,
            exact = world_effect.exactBoundActorsOnly == true,
            broadActorScan = world_effect.broadActorScan,
        },
        {
            fullyCapableProviders = 1,
            handlers = 1,
            fullyOperationalBindings = 1,
            exact = true,
            broadActorScan = false,
        }
    )

    local delivery = statuses.uniquePalNativeDeliveryBridge or {}
    local production = statuses.uniquePalNativeDeliveryProduction or {}
    add_check(
        checks,
        "unique-pal-native-delivery-bound",
        "runtime-integration",
        production.enabled == true
            and (production.activeBindingCount or 0) > 0
            and (delivery.currentNativeBindings or 0) > 0
            and delivery.exactIndividualIdentityRequired == true
            and delivery.directContainerMutation == false,
        {
            productionEnabled = production.enabled == true,
            productionBindings = production.activeBindingCount or 0,
            nativeBindings = delivery.currentNativeBindings or 0,
            exactIndividual = delivery.exactIndividualIdentityRequired == true,
            directContainerMutation = delivery.directContainerMutation,
        },
        {
            productionEnabled = true,
            productionBindings = 1,
            nativeBindings = 1,
            exactIndividual = true,
            directContainerMutation = false,
        }
    )

    local attitude = statuses.factionNpcAttitudeBus or {}
    add_check(
        checks,
        "faction-npc-attitude-provider-bound",
        "runtime-integration",
        (attitude.readyProviderCount or 0) > 0
            and (attitude.bindingCount or 0) > 0,
        {
            readyProviders = attitude.readyProviderCount or 0,
            bindings = attitude.bindingCount or 0,
        },
        { readyProviders = 1, bindings = 1 }
    )

    local ending_effect = statuses.endingEffectProviderBus or {}
    add_check(
        checks,
        "ending-effect-provider-bound",
        "runtime-integration",
        (ending_effect.fullyCapableProviderCount or 0) > 0
            and ending_effect.modelCommitAuthority == false,
        {
            providers = ending_effect.providerCount or 0,
            fullyCapableProviders =
                ending_effect.fullyCapableProviderCount or 0,
            handlers = ending_effect.activeProviderHandlerCount or 0,
            modelCommitAuthority = ending_effect.modelCommitAuthority,
        },
        {
            fullyCapableProviders = 1,
            handlers = 1,
            modelCommitAuthority = false,
        }
    )

    local blocked = count_by_status(checks, "blocked")
    local content_blocked = 0
    local runtime_blocked = 0
    local blocker_ids = {}
    for _, check in ipairs(checks) do
        if check.status == "blocked" then
            blocker_ids[#blocker_ids + 1] = check.id
            if check.owner == "content-author" then
                content_blocked = content_blocked + 1
            else
                runtime_blocked = runtime_blocked + 1
            end
        end
    end

    local phase = "ready-for-b7-live-acceptance"
    if content_blocked > 0 then
        phase = "content-key-required"
    elseif runtime_blocked > 0 then
        phase = "native-bindings-required"
    end
    local evaluation = result(blocked == 0,
        blocked == 0 and "B7-readiness-gate-passed"
            or "B7-readiness-gate-blocked", {
            apiVersion = self.version,
            evaluationReason = reason or "manual",
            evaluationSequence = self.evaluationCount,
            phase = phase,
            readyForLiveAcceptance = blocked == 0,
            liveEvidenceRequired = true,
            liveAccepted = false,
            userAcceptanceClaimed = false,
            checkCount = #checks,
            passedCount = count_by_status(checks, "pass"),
            blockedCount = blocked,
            contentBlockedCount = content_blocked,
            runtimeBlockedCount = runtime_blocked,
            blockerIds = blocker_ids,
            checks = checks,
            componentStatusErrors = status_errors,
            storyContentIncluded = false,
            PalworldSaveMutation = false,
        })
    self.lastEvaluation = copy(evaluation)
    return copy(evaluation)
end

function StrategicWorldReadiness:status()
    if self.lastEvaluation == nil then
        return self:evaluate("status-first-read")
    end
    return copy(self.lastEvaluation)
end

return StrategicWorldReadiness
