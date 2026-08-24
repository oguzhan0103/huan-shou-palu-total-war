local StrategicWorldNativeProduction = {}

local API_VERSION = "1.0.0"
local ALL_EVENT_KINDS = {
    "unique-pal-captured",
    "city-captured",
    "boss-damage",
    "boss-death",
    "city-loaded",
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

local function normalize_definitions(definitions)
    assert(type(definitions) == "table",
        "strategic native production definitions are required")
    assert(type(definitions.provider) == "table",
        "strategic native production provider is required")
    assert(type(definitions.cityAnchors) == "table"
            and #definitions.cityAnchors > 0,
        "strategic native city anchors are required")
    assert(type(definitions.uniquePalCities) == "table",
        "strategic native unique-Pal city mapping is required")
    local provider = {
        providerId = require_text(definitions.provider.providerId,
            "strategic native provider ID"),
        authoritySource = require_text(
            definitions.provider.authoritySource,
            "strategic native authority source"
        ),
        allowedEventKinds = copy(ALL_EVENT_KINDS),
        enabled = definitions.provider.enabled ~= false,
    }
    local anchors = {}
    local known_cities = {}
    for _, source in ipairs(definitions.cityAnchors) do
        local city_id = require_text(source.cityId,
            "strategic native anchor city ID")
        assert(known_cities[city_id] == nil,
            "duplicate strategic native city anchor")
        known_cities[city_id] = true
        anchors[#anchors + 1] = {
            bindingId = require_text(source.bindingId,
                "strategic native anchor binding ID"),
            providerId = provider.providerId,
            bindingKind = "city-anchor",
            strategicId = city_id,
            actorKey = require_text(source.actorKey,
                "strategic native anchor actor key"),
            actorClassKey = source.actorClassKey,
        }
    end
    local unique_pal_cities = {}
    for unique_pal_id, source in pairs(definitions.uniquePalCities) do
        require_text(unique_pal_id, "strategic native unique-Pal ID")
        assert(type(source) == "table",
            "strategic native unique-Pal mapping must be a table")
        local city_id = require_text(source.cityId,
            "strategic native unique-Pal city ID")
        assert(known_cities[city_id] == true,
            "strategic native unique-Pal mapping references an unknown anchor")
        unique_pal_cities[unique_pal_id] = {
            cityId = city_id,
            uniquePalBindingId = require_text(
                source.uniquePalBindingId,
                "strategic native unique-Pal binding ID"
            ),
            cityBossBindingId = require_text(
                source.cityBossBindingId,
                "strategic native city Boss binding ID"
            ),
        }
    end
    return {
        provider = provider,
        cityAnchors = anchors,
        uniquePalCities = unique_pal_cities,
    }
end

function StrategicWorldNativeProduction.create(bus, options)
    assert(type(bus) == "table"
            and type(bus.register_provider) == "function"
            and type(bus.bind_actor) == "function"
            and type(bus.unbind_actor) == "function"
            and type(bus.ingest) == "function",
        "strategic native bus is required")
    options = options or {}
    return setmetatable({
        version = API_VERSION,
        bus = bus,
        logger = options.logger,
        active = false,
        provider = nil,
        cityAnchors = {},
        uniquePalCities = {},
        dynamicBindingsByUniquePalId = {},
        activationCount = 0,
        dynamicBindCount = 0,
        dynamicUnbindCount = 0,
        acceptedEventCount = 0,
        rejectedEventCount = 0,
        lastError = nil,
    }, { __index = StrategicWorldNativeProduction })
end

function StrategicWorldNativeProduction:_log(message)
    if type(self.logger) == "function" then
        pcall(self.logger,
            "[StrategicWorldNativeProduction] " .. tostring(message))
    end
end

function StrategicWorldNativeProduction:activate(definitions)
    local normalized = normalize_definitions(definitions)
    local registered = self.bus:register_provider(normalized.provider)
    if not registered.ok then
        self.lastError = registered.reason
        return registered
    end
    self.dynamicBindingsByUniquePalId = {}
    local bound = 0
    for _, binding in ipairs(normalized.cityAnchors) do
        local outcome = self.bus:bind_actor(binding)
        if not outcome.ok then
            self.lastError = outcome.reason
            return result(false,
                "strategic-native-city-anchor-binding-failed", {
                bindingId = binding.bindingId,
                bindingReason = outcome.reason,
            })
        end
        bound = bound + 1
    end
    self.provider = normalized.provider
    self.cityAnchors = normalized.cityAnchors
    self.uniquePalCities = normalized.uniquePalCities
    self.active = true
    self.activationCount = self.activationCount + 1
    self.lastError = nil
    self:_log(string.format(
        "ACTIVATED provider=%s cityAnchors=%d dynamicUniquePals=0 exact=true broadScan=false",
        self.provider.providerId,
        bound
    ))
    return result(true, "strategic-native-production-activated", {
        providerId = self.provider.providerId,
        cityAnchorBindingCount = bound,
        dynamicUniquePalBindingCount = 0,
        storyContentIncluded = false,
    })
end

function StrategicWorldNativeProduction:bind_unique_pal_actor(
    unique_pal_id,
    actor_key,
    actor_class_key
)
    require_text(unique_pal_id, "strategic native unique-Pal ID")
    require_text(actor_key, "strategic native actor key")
    require_text(actor_class_key, "strategic native actor class key")
    if not self.active then
        return result(false, "strategic-native-production-inactive")
    end
    local mapping = self.uniquePalCities[unique_pal_id]
    if mapping == nil then
        return result(false, "strategic-native-unique-pal-unmapped")
    end
    local existing = self.dynamicBindingsByUniquePalId[unique_pal_id]
    if existing ~= nil then
        if existing.actorKey == actor_key
            and existing.actorClassKey == actor_class_key then
            return result(true,
                "strategic-native-unique-pal-actor-already-bound", {
                uniquePalId = unique_pal_id,
                cityId = mapping.cityId,
            })
        end
        local unbound = self:unbind_unique_pal_actor(unique_pal_id)
        if not unbound.ok then return unbound end
    end
    local unique_binding = {
        bindingId = mapping.uniquePalBindingId,
        providerId = self.provider.providerId,
        bindingKind = "unique-pal",
        strategicId = unique_pal_id,
        actorKey = actor_key,
        actorClassKey = actor_class_key,
    }
    local boss_binding = {
        bindingId = mapping.cityBossBindingId,
        providerId = self.provider.providerId,
        bindingKind = "city-boss",
        strategicId = mapping.cityId,
        actorKey = actor_key,
        actorClassKey = actor_class_key,
    }
    local unique_outcome = self.bus:bind_actor(unique_binding)
    if not unique_outcome.ok then return unique_outcome end
    local boss_outcome = self.bus:bind_actor(boss_binding)
    if not boss_outcome.ok then
        self.bus:unbind_actor({
            bindingId = unique_binding.bindingId,
            providerId = unique_binding.providerId,
            actorKey = unique_binding.actorKey,
            actorClassKey = unique_binding.actorClassKey,
        })
        return boss_outcome
    end
    self.dynamicBindingsByUniquePalId[unique_pal_id] = {
        actorKey = actor_key,
        actorClassKey = actor_class_key,
        uniquePal = unique_binding,
        cityBoss = boss_binding,
    }
    self.dynamicBindCount = self.dynamicBindCount + 1
    self.lastError = nil
    self:_log(string.format(
        "DYNAMIC_ACTOR_BOUND uniquePal=%s city=%s actor=%s class=%s",
        unique_pal_id,
        mapping.cityId,
        actor_key,
        actor_class_key
    ))
    return result(true, "strategic-native-unique-pal-actor-bound", {
        uniquePalId = unique_pal_id,
        cityId = mapping.cityId,
        uniquePalBindingId = unique_binding.bindingId,
        cityBossBindingId = boss_binding.bindingId,
    })
end

function StrategicWorldNativeProduction:unbind_unique_pal_actor(
    unique_pal_id
)
    require_text(unique_pal_id, "strategic native unique-Pal ID")
    local record = self.dynamicBindingsByUniquePalId[unique_pal_id]
    if record == nil then
        return result(true,
            "strategic-native-unique-pal-actor-already-unbound")
    end
    for _, binding in ipairs({ record.uniquePal, record.cityBoss }) do
        local outcome = self.bus:unbind_actor({
            bindingId = binding.bindingId,
            providerId = binding.providerId,
            actorKey = binding.actorKey,
            actorClassKey = binding.actorClassKey,
        })
        if not outcome.ok then
            self.lastError = outcome.reason
            return outcome
        end
    end
    self.dynamicBindingsByUniquePalId[unique_pal_id] = nil
    self.dynamicUnbindCount = self.dynamicUnbindCount + 1
    return result(true, "strategic-native-unique-pal-actor-unbound", {
        uniquePalId = unique_pal_id,
    })
end

function StrategicWorldNativeProduction:ingest(event)
    if not self.active or self.provider == nil then
        return result(false, "strategic-native-production-inactive")
    end
    assert(type(event) == "table",
        "strategic native production event is required")
    local request = copy(event)
    request.schemaVersion = "1.0.0"
    request.authoritative = true
    request.providerId = self.provider.providerId
    request.authoritySource = self.provider.authoritySource
    local outcome = self.bus:ingest(request)
    if outcome.ok then
        self.acceptedEventCount = self.acceptedEventCount + 1
        self.lastError = nil
    else
        self.rejectedEventCount = self.rejectedEventCount + 1
        self.lastError = outcome.reason
    end
    return outcome
end

function StrategicWorldNativeProduction:unbind_world(reason)
    self.dynamicBindingsByUniquePalId = {}
    self.active = false
    self.lastError = reason or "world-unloading"
    return result(true, "strategic-native-production-world-unbound")
end

function StrategicWorldNativeProduction:status()
    local dynamic_count = 0
    for _ in pairs(self.dynamicBindingsByUniquePalId) do
        dynamic_count = dynamic_count + 1
    end
    return {
        apiVersion = self.version,
        active = self.active,
        providerId = self.provider and self.provider.providerId or nil,
        cityAnchorBindingCount = #self.cityAnchors,
        dynamicUniquePalBindingCount = dynamic_count,
        activationCount = self.activationCount,
        dynamicBindCount = self.dynamicBindCount,
        dynamicUnbindCount = self.dynamicUnbindCount,
        acceptedEventCount = self.acceptedEventCount,
        rejectedEventCount = self.rejectedEventCount,
        exactIndividualBindingRequired = true,
        broadActorScan = false,
        storyContentIncluded = false,
        PalworldSaveMutation = false,
        lastError = self.lastError,
    }
end

return StrategicWorldNativeProduction
