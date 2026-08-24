local EndingEffectNativeProduction = {}

local API_VERSION = "1.0.0"
local EFFECT_KINDS = {
    "set_title",
    "set_world_disposition",
    "set_faction_disposition",
    "city_transition",
}

local function copy(value)
    if type(value) ~= "table" then return value end
    local output = {}
    for key, child in pairs(value) do output[copy(key)] = copy(child) end
    return output
end

local function result(ok, reason, extra)
    local output = extra or {}
    output.ok = ok
    output.reason = reason
    return output
end

local function require_text(value, name)
    assert(type(value) == "string" and value ~= "",
        name .. " must be a non-empty string")
    return value
end

local function is_valid(object)
    if object == nil then return false end
    local ok, valid = pcall(function()
        if object.IsValid ~= nil then return object:IsValid() end
        return true
    end)
    return ok and valid ~= false
end

local function default_present_title(title_key)
    if type(_G.StaticFindObject) ~= "function"
        or type(_G.FindAllOf) ~= "function" then
        return false, "native-title-surface-unavailable"
    end
    local ok, library = pcall(
        _G.StaticFindObject,
        "/Script/Engine.Default__KismetTextLibrary"
    )
    if not ok or not is_valid(library) then
        return false, "native-title-text-library-unavailable"
    end
    local text_ok, text = pcall(function()
        return library:Conv_StringToText(
            "结局称号已解锁：" .. title_key
        )
    end)
    if not text_ok or text == nil then
        return false, "native-title-text-conversion-failed"
    end
    local found, surfaces = pcall(_G.FindAllOf, "PalHUDService")
    if not found or type(surfaces) ~= "table" then
        return false, "native-title-HUD-surface-unavailable"
    end
    for _, surface in pairs(surfaces) do
        if is_valid(surface) then
            local shown = pcall(function()
                surface:ShowCommonWarning({
                    Message = text,
                    DisplayType = 0,
                })
            end)
            if shown then return true, "PalHUDService.ShowCommonWarning" end
        end
    end
    return false, "native-title-HUD-presentation-failed"
end

function EndingEffectNativeProduction.create(
    bus,
    ending_runtime,
    strategic_world,
    faction_npc_attitude_bus,
    options
)
    assert(type(bus) == "table"
            and type(bus.register_provider) == "function",
        "ending effect provider bus is required")
    assert(type(ending_runtime) == "table"
            and type(ending_runtime.post_ending_policy) == "function",
        "ending runtime is required")
    assert(type(strategic_world) == "table"
            and type(strategic_world.city_status) == "function",
        "strategic world is required")
    assert(type(faction_npc_attitude_bus) == "table"
            and type(faction_npc_attitude_bus.refresh_faction)
                == "function",
        "faction NPC attitude bus is required")
    options = options or {}
    return setmetatable({
        version = API_VERSION,
        bus = bus,
        endingRuntime = ending_runtime,
        strategicWorld = strategic_world,
        factionNpcAttitudeBus = faction_npc_attitude_bus,
        adapters = options.adapters or {},
        logger = options.logger,
        providerId = nil,
        factionCityById = {},
        cityFactionById = {},
        merchantRuntime = nil,
        economyMerchantRuntime = nil,
        currentTitleKey = nil,
        active = false,
        activationCount = 0,
        deliveryCount = 0,
        duplicateDeliveryCount = 0,
        titleApplyCount = 0,
        attitudeRefreshCount = 0,
        cityTransitionCount = 0,
        merchantDeactivateCount = 0,
        lastDeliveryById = {},
        lastError = nil,
    }, { __index = EndingEffectNativeProduction })
end

function EndingEffectNativeProduction:_log(message)
    if type(self.logger) == "function" then
        pcall(self.logger,
            "[EndingEffectNativeProduction] " .. tostring(message))
    end
end

function EndingEffectNativeProduction:set_merchant_runtimes(
    merchant_runtime,
    economy_merchant_runtime
)
    assert(merchant_runtime == nil or type(merchant_runtime) == "table",
        "ending merchant runtime must be a table")
    assert(economy_merchant_runtime == nil
            or type(economy_merchant_runtime) == "table",
        "ending economy merchant runtime must be a table")
    self.merchantRuntime = merchant_runtime
    self.economyMerchantRuntime = economy_merchant_runtime
    return result(true, "ending-native-merchant-runtimes-bound")
end

function EndingEffectNativeProduction:_present_title(output)
    local shown, detail
    if type(self.adapters.presentTitle) == "function" then
        local ok, accepted, route = pcall(
            self.adapters.presentTitle,
            output.titleKey,
            copy(output)
        )
        shown = ok and accepted == true
        detail = ok and route or tostring(accepted)
    else
        shown, detail = default_present_title(output.titleKey)
    end
    if not shown then
        return result(false, "ending-native-title-presentation-failed", {
            detail = tostring(detail),
        })
    end
    self.currentTitleKey = output.titleKey
    self.titleApplyCount = self.titleApplyCount + 1
    return result(true, "ending-native-title-presented", {
        presentationRoute = detail,
    })
end

function EndingEffectNativeProduction:_refresh_attitudes(output)
    local faction_id = output.kind == "set_faction_disposition"
        and output.factionId or nil
    local refreshed = self.factionNpcAttitudeBus:refresh_faction(
        faction_id,
        {
            trigger = "ending-changed",
            force = true,
        }
    )
    if not refreshed.ok then
        return result(false, "ending-native-attitude-refresh-failed", {
            detail = copy(refreshed),
        })
    end
    self.attitudeRefreshCount = self.attitudeRefreshCount + 1
    return result(true, "ending-native-attitudes-refreshed", {
        factionId = faction_id,
        bindingCount = refreshed.bindingCount or 0,
        appliedCount = refreshed.appliedCount or 0,
    })
end

function EndingEffectNativeProduction:_deactivate_faction(
    faction_id,
    reason
)
    local calls = 0
    local failures = {}
    if self.merchantRuntime ~= nil
        and type(self.merchantRuntime.deactivate_faction) == "function" then
        local ok, outcome = pcall(
            self.merchantRuntime.deactivate_faction,
            self.merchantRuntime,
            faction_id,
            reason
        )
        calls = calls + 1
        if not ok or type(outcome) ~= "table"
            or outcome.ok ~= true then
            failures[#failures + 1] = ok
                    and tostring(outcome and outcome.reason)
                or tostring(outcome)
        end
    end
    if self.economyMerchantRuntime ~= nil
        and type(self.economyMerchantRuntime.deactivate_faction)
            == "function" then
        local ok, outcome = pcall(
            self.economyMerchantRuntime.deactivate_faction,
            self.economyMerchantRuntime,
            faction_id,
            reason
        )
        calls = calls + 1
        if not ok or type(outcome) ~= "table"
            or outcome.ok ~= true then
            failures[#failures + 1] = ok
                    and tostring(outcome and outcome.reason)
                or tostring(outcome)
        end
    end
    if #failures > 0 then
        return result(false,
            "ending-native-merchant-deactivation-failed", {
            failures = failures,
        })
    end
    self.merchantDeactivateCount =
        self.merchantDeactivateCount + calls
    return result(true, "ending-native-faction-deactivated", {
        runtimeCallCount = calls,
    })
end

function EndingEffectNativeProduction:_apply_city_transition(output)
    local city = self.strategicWorld:city_status(output.cityId)
    if type(city) ~= "table" then
        return result(false, "ending-native-city-unavailable")
    end
    if city.status ~= output.status then
        return result(false, "ending-native-city-status-not-committed", {
            expectedStatus = output.status,
            actualStatus = city.status,
        })
    end
    if output.ownerFactionId ~= nil
        and city.ownerFactionId ~= output.ownerFactionId then
        return result(false, "ending-native-city-owner-not-committed", {
            expectedOwnerFactionId = output.ownerFactionId,
            actualOwnerFactionId = city.ownerFactionId,
        })
    end
    local faction_id = self.cityFactionById[output.cityId]
        or city.factionId or city.ownerFactionId
    local deactivated = nil
    if output.status == "destroyed" and faction_id ~= nil then
        deactivated = self:_deactivate_faction(
            faction_id,
            "ending-city-transition-destroyed"
        )
        if not deactivated.ok then return deactivated end
    end
    self.cityTransitionCount = self.cityTransitionCount + 1
    return result(true, "ending-native-city-transition-applied", {
        cityId = output.cityId,
        factionId = faction_id,
        status = output.status,
        spawnPolicyReconciled = true,
        deactivated = deactivated,
    })
end

function EndingEffectNativeProduction:_handle(output, context)
    if self.active ~= true then
        return result(false, "ending-native-production-inactive", {
            applied = false,
            deliveryId = output.deliveryId,
        })
    end
    local previous = self.lastDeliveryById[output.deliveryId]
    if previous ~= nil then
        self.duplicateDeliveryCount = self.duplicateDeliveryCount + 1
        return result(true, "duplicate-ending-native-delivery", {
            applied = true,
            deliveryId = output.deliveryId,
            idempotent = true,
        })
    end
    local outcome
    if output.kind == "set_title" then
        outcome = self:_present_title(output)
    elseif output.kind == "set_world_disposition"
        or output.kind == "set_faction_disposition" then
        outcome = self:_refresh_attitudes(output)
    elseif output.kind == "city_transition" then
        outcome = self:_apply_city_transition(output)
    else
        outcome = result(false,
            "ending-native-effect-kind-unsupported")
    end
    if outcome.ok ~= true then
        self.lastError = outcome.reason
        outcome.applied = false
        outcome.deliveryId = output.deliveryId
        return outcome
    end
    self.lastDeliveryById[output.deliveryId] = {
        kind = output.kind,
        scopeId = context and context.scopeId or nil,
    }
    self.deliveryCount = self.deliveryCount + 1
    self.lastError = nil
    outcome.applied = true
    outcome.deliveryId = output.deliveryId
    self:_log(string.format(
        "DELIVERY_APPLIED id=%s kind=%s scope=%s",
        output.deliveryId,
        output.kind,
        tostring(context and context.scopeId or "none")
    ))
    return outcome
end

function EndingEffectNativeProduction:activate(definitions)
    assert(type(definitions) == "table",
        "ending native definitions are required")
    local provider_id = require_text(definitions.providerId,
        "ending native provider ID")
    assert(type(definitions.factionCityById) == "table",
        "ending native faction-city mapping is required")
    self.factionCityById = copy(definitions.factionCityById)
    self.cityFactionById = {}
    local mapping_count = 0
    for faction_id, city_id in pairs(self.factionCityById) do
        require_text(faction_id, "ending native faction ID")
        require_text(city_id, "ending native city ID")
        assert(self.cityFactionById[city_id] == nil,
            "ending native city is mapped more than once")
        self.cityFactionById[city_id] = faction_id
        mapping_count = mapping_count + 1
    end
    self.providerId = provider_id
    self.active = true
    local registered = self.bus:register_provider({
        providerId = provider_id,
        effectKinds = copy(EFFECT_KINDS),
        idempotentDeliveryIds = true,
        readOnlyInput = true,
        enabled = true,
    }, function(output, context)
        return self:_handle(output, context)
    end)
    if not registered.ok then
        self.active = false
        self.lastError = registered.reason
        return registered
    end
    self.activationCount = self.activationCount + 1
    self.lastError = nil
    return result(true, "ending-native-production-activated", {
        providerId = provider_id,
        factionCityMappingCount = mapping_count,
        storyContentIncluded = false,
    })
end

function EndingEffectNativeProduction:faction_spawn_policy(
    faction_id,
    spawn_kind
)
    local city_id = self.factionCityById[faction_id]
    if city_id == nil then
        return result(true, "ending-city-spawn-policy-unmapped", {
            suppressSpawn = false,
        })
    end
    local city = self.strategicWorld:city_status(city_id)
    if type(city) ~= "table" then
        return result(false, "ending-city-spawn-policy-unavailable", {
            suppressSpawn = true,
        })
    end
    local suppress = city.status == "destroyed"
    return result(true, suppress
            and "ending-destroyed-city-spawn-suppressed"
            or "ending-city-spawn-allowed", {
        suppressSpawn = suppress,
        factionId = faction_id,
        cityId = city_id,
        cityStatus = city.status,
        spawnKind = spawn_kind,
    })
end

function EndingEffectNativeProduction:unbind_world(reason)
    self.lastDeliveryById = {}
    self.lastError = reason or "world-unloading"
    return result(true, "ending-native-production-world-unbound")
end

function EndingEffectNativeProduction:status()
    local mapping_count = 0
    for _ in pairs(self.factionCityById) do mapping_count = mapping_count + 1 end
    return {
        apiVersion = self.version,
        active = self.active,
        providerId = self.providerId,
        factionCityMappingCount = mapping_count,
        merchantRuntimesBound = self.merchantRuntime ~= nil
            and self.economyMerchantRuntime ~= nil,
        currentTitleKey = self.currentTitleKey,
        activationCount = self.activationCount,
        deliveryCount = self.deliveryCount,
        duplicateDeliveryCount = self.duplicateDeliveryCount,
        titleApplyCount = self.titleApplyCount,
        attitudeRefreshCount = self.attitudeRefreshCount,
        cityTransitionCount = self.cityTransitionCount,
        merchantDeactivateCount = self.merchantDeactivateCount,
        playerConfirmationAuthorityRequired = true,
        modelCommitAuthority = false,
        storyContentIncluded = false,
        PalworldSaveMutation = false,
        lastError = self.lastError,
    }
end

return EndingEffectNativeProduction
