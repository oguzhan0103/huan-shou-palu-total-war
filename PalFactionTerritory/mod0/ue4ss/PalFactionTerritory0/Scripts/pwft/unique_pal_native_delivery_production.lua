local UniquePalNativeDeliveryProduction = {}

local API_VERSION = "1.0.0"

local function copy(value)
    if type(value) ~= "table" then return value end
    local output = {}
    for key, child in pairs(value) do output[copy(key)] = copy(child) end
    return output
end

local function result(ok, reason, extra)
    local value = extra or {}
    value.ok = ok
    value.reason = reason
    return value
end

local function stable_id(value, name)
    assert(type(value) == "string" and value ~= "",
        name .. " must be a non-empty string")
    assert(string.match(value, "^[a-z0-9][a-z0-9_.-]+$") ~= nil,
        name .. " must be a stable namespaced ID")
    assert(string.find(value, "..", 1, true) == nil,
        name .. " cannot contain an empty namespace segment")
    return value
end

local function require_text(value, name)
    assert(type(value) == "string" and value ~= "",
        name .. " must be a non-empty string")
    return value
end

local function normalize_species_map(values, approved)
    assert(type(values) == "table",
        "production native Pal species map is required")
    local output, count = {}, 0
    for unique_pal_id, species_id in pairs(values) do
        unique_pal_id = stable_id(unique_pal_id, "unique Pal ID")
        species_id = require_text(species_id, "native Pal species ID")
        assert(approved[unique_pal_id] == species_id,
            "native Pal species is not approved for the current Build")
        output[unique_pal_id] = species_id
        count = count + 1
    end
    assert(count > 0, "production native Pal species map cannot be empty")
    return output, count
end

function UniquePalNativeDeliveryProduction.create(
    bridge,
    adapter,
    world_effect_bus,
    configuration
)
    assert(type(bridge) == "table"
            and type(bridge.register_binding) == "function"
            and type(bridge.handle_delivery) == "function",
        "native Pal delivery bridge is required")
    assert(type(adapter) == "table"
            and type(adapter.bind_world) == "function"
            and type(adapter.status) == "function",
        "native Pal delivery adapter is required")
    assert(type(world_effect_bus) == "table"
            and type(world_effect_bus.status) == "function",
        "unique-Pal world-effect bus is required")
    configuration = configuration or {}
    assert(type(configuration.enabled) == "boolean",
        "production native Pal delivery flag is required")
    local build_id = require_text(configuration.buildId,
        "production native Pal delivery Build ID")
    local object_dump_sha256 = require_text(
        configuration.objectDumpSha256,
        "production native Pal delivery ObjectDump SHA-256"
    )
    assert(#object_dump_sha256 == 64
            and string.match(object_dump_sha256, "^[%x]+$") ~= nil,
        "production native Pal delivery ObjectDump SHA-256 is invalid")
    assert(type(configuration.deliveryLevel) == "number"
            and configuration.deliveryLevel >= 1
            and configuration.deliveryLevel == math.floor(
                configuration.deliveryLevel),
        "production native Pal delivery level must be a positive integer")
    local approved, approved_count = normalize_species_map(
        configuration.approvedSpeciesByUniquePalId,
        configuration.approvedSpeciesByUniquePalId
    )
    assert(approved["pwft.unique.feybreak"] == nil,
        "tentative Feybreak unique Pal must remain fail-closed")
    return setmetatable({
        version = API_VERSION,
        bridge = bridge,
        adapter = adapter,
        worldEffectBus = world_effect_bus,
        enabled = configuration.enabled == true,
        buildId = build_id,
        objectDumpSha256 = string.lower(object_dump_sha256),
        deliveryLevel = configuration.deliveryLevel,
        approvedSpeciesByUniquePalId = approved,
        approvedSpeciesCount = approved_count,
        registrationsByTargetBindingId = {},
        registrationCount = 0,
        worldRebindCount = 0,
        bridgeWorldGeneration = nil,
        rejectionCount = 0,
        deliveryRequestCount = 0,
        lastError = nil,
    }, { __index = UniquePalNativeDeliveryProduction })
end

function UniquePalNativeDeliveryProduction:register(definition)
    if not self.enabled then
        self.rejectionCount = self.rejectionCount + 1
        return result(false, "production-native-pal-delivery-disabled")
    end
    local called, normalized = pcall(function()
        assert(type(definition) == "table",
            "production native Pal delivery registration is required")
        local bus_status = self.worldEffectBus:status()
        assert(definition.worldGeneration == bus_status.worldGeneration,
            "production native Pal delivery generation is stale")
        local species, species_count = normalize_species_map(
            definition.speciesByUniquePalId,
            self.approvedSpeciesByUniquePalId
        )
        local adapter_status = self.adapter:status()
        assert(adapter_status.buildId == self.buildId,
            "production native Pal adapter Build ID drifted")
        assert(string.lower(adapter_status.objectDumpSha256)
                == self.objectDumpSha256,
            "production native Pal adapter ObjectDump hash drifted")
        assert(adapter_status.allowMutatingDelivery == true,
            "production native Pal adapter mutation gate is disabled")
        local capabilities = adapter_status.capabilities or {}
        for _, capability in ipairs({
            "currentBuildSignatureBound", "capacityPreflight",
            "serverAuthoritativeSpawn", "stableIndividualIdentity",
            "serverAuthoritativeCapture", "exactStorageReadback",
        }) do
            assert(capabilities[capability] == true,
                "production native Pal adapter capability missing: "
                    .. capability)
        end
        assert(capabilities.directContainerMutation == false
                and capabilities.PalworldSaveMutation == false,
            "production native Pal adapter crosses the save/container boundary")
        return {
            bindingId = stable_id(definition.bindingId,
                "production native Pal delivery binding ID"),
            targetBindingId = stable_id(definition.targetBindingId,
                "world-effect target binding ID"),
            providerId = stable_id(definition.providerId,
                "world-effect provider ID"),
            palDeliveryKey = require_text(definition.palDeliveryKey,
                "production native Pal delivery route key"),
            worldGeneration = bus_status.worldGeneration,
            speciesByUniquePalId = species,
            speciesCount = species_count,
        }
    end)
    if not called then
        self.rejectionCount = self.rejectionCount + 1
        self.lastError = tostring(normalized)
        return result(false, "invalid-production-native-pal-delivery-binding", {
            validationError = self.lastError,
        })
    end

    local existing = self.registrationsByTargetBindingId[
        normalized.targetBindingId]
    if existing ~= nil then
        local same = existing.bindingId == normalized.bindingId
            and existing.providerId == normalized.providerId
            and existing.palDeliveryKey == normalized.palDeliveryKey
        if same then
            for unique_pal_id, species_id in pairs(
                existing.speciesByUniquePalId) do
                if normalized.speciesByUniquePalId[unique_pal_id]
                        ~= species_id then
                    same = false
                end
            end
            for unique_pal_id, species_id in pairs(
                normalized.speciesByUniquePalId) do
                if existing.speciesByUniquePalId[unique_pal_id]
                        ~= species_id then
                    same = false
                end
            end
        end
        if not same then
            self.rejectionCount = self.rejectionCount + 1
            self.lastError = "production-native-pal-delivery-binding-conflict"
            return result(false,
                "production-native-pal-delivery-binding-conflict")
        end
    end

    -- Progression restore deliberately advances the world-effect generation
    -- after its persistent snapshot is rebound.  The native bridge owns
    -- world-scoped adapter references, so clear the complete previous
    -- generation exactly once before rebuilding the five content bindings.
    -- Without this fence the first post-restore registration conflicts with
    -- the otherwise identical old signature solely because its generation
    -- changed.
    if self.bridgeWorldGeneration ~= normalized.worldGeneration then
        if self.bridgeWorldGeneration ~= nil
            and type(self.bridge.unbind_world) == "function" then
            local unbound = self.bridge:unbind_world(
                "production-native-pal-delivery-generation-rebind"
            )
            if type(unbound) ~= "table" or unbound.ok ~= true then
                self.rejectionCount = self.rejectionCount + 1
                self.lastError = type(unbound) == "table"
                        and unbound.reason
                    or "production-native-pal-bridge-world-unbind-failed"
                return result(false, self.lastError)
            end
        end
        self.bridgeWorldGeneration = normalized.worldGeneration
    end

    local bound = self.adapter:bind_world(normalized.worldGeneration)
    if type(bound) ~= "table" or bound.ok ~= true then
        self.rejectionCount = self.rejectionCount + 1
        self.lastError = type(bound) == "table" and bound.reason
            or "production-native-pal-adapter-world-bind-failed"
        return result(false, self.lastError)
    end
    local registered = self.bridge:register_binding({
        bindingId = normalized.bindingId,
        targetBindingId = normalized.targetBindingId,
        providerId = normalized.providerId,
        palDeliveryKey = normalized.palDeliveryKey,
        speciesByUniquePalId = normalized.speciesByUniquePalId,
        worldGeneration = normalized.worldGeneration,
        buildId = self.buildId,
        verifiedBuildId = self.buildId,
        currentBuildVerified = true,
        serverAuthoritativeSpawn = true,
        serverAuthoritativeCapture = true,
        capacityPreflight = true,
        storageVerification = true,
        stableIndividualIdentity = true,
    }, self.adapter)
    if registered.ok ~= true then
        self.rejectionCount = self.rejectionCount + 1
        self.lastError = registered.reason
        return registered
    end
    self.registrationsByTargetBindingId[normalized.targetBindingId] =
        copy(normalized)
    if existing == nil then
        self.registrationCount = self.registrationCount + 1
    elseif existing.worldGeneration ~= normalized.worldGeneration then
        self.worldRebindCount = self.worldRebindCount + 1
    end
    self.lastError = nil
    registered.productionReady = true
    registered.approvedSpeciesCount = normalized.speciesCount
    return registered
end

function UniquePalNativeDeliveryProduction:handle_delivery(payload, context)
    self.deliveryRequestCount = self.deliveryRequestCount + 1
    if not self.enabled then
        return result(false, "production-native-pal-delivery-disabled")
    end
    return self.bridge:handle_delivery(payload, context)
end

function UniquePalNativeDeliveryProduction:status()
    local active = 0
    local generation = self.worldEffectBus:status().worldGeneration
    for _, registration in pairs(self.registrationsByTargetBindingId) do
        if registration.worldGeneration == generation then
            active = active + 1
        end
    end
    return {
        apiVersion = self.version,
        enabled = self.enabled,
        buildId = self.buildId,
        objectDumpSha256 = self.objectDumpSha256,
        deliveryLevel = self.deliveryLevel,
        worldGeneration = generation,
        approvedSpeciesCount = self.approvedSpeciesCount,
        activeBindingCount = active,
        registrationCount = self.registrationCount,
        worldRebindCount = self.worldRebindCount,
        bridgeWorldGeneration = self.bridgeWorldGeneration,
        rejectionCount = self.rejectionCount,
        deliveryRequestCount = self.deliveryRequestCount,
        lastError = self.lastError,
        contentBindingRequired = true,
        feybreakTentativeEnabled = false,
        storyContentIncluded = false,
        directContainerMutation = false,
        PalworldSaveMutation = false,
    }
end

return UniquePalNativeDeliveryProduction
