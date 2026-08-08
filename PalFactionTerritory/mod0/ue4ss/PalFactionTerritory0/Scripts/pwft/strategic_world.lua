local StrategicWorld = {}

local API_VERSION = "1.0.0"
local STATE_SCHEMA_VERSION = "1.0.0"
local PACK_SCHEMA = "pwft.strategic-world.pack.v1"

local function copy(value)
    if type(value) ~= "table" then
        return value
    end
    local result = {}
    for key, child in pairs(value) do
        result[copy(key)] = copy(child)
    end
    return result
end

local function deep_equal(first, second)
    if type(first) ~= type(second) then return false end
    if type(first) ~= "table" then return first == second end
    for key, value in pairs(first) do
        if not deep_equal(value, second[key]) then return false end
    end
    for key in pairs(second) do
        if first[key] == nil then return false end
    end
    return true
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

local function stable_id(value, name)
    non_empty(value, name)
    assert(string.match(value, "^[a-z0-9][a-z0-9_.-]+$") ~= nil, name .. " must be a stable namespaced ID")
    assert(string.find(value, "..", 1, true) == nil, name .. " cannot contain an empty namespace segment")
    return value
end

local function semver(value, name)
    non_empty(value, name)
    assert(string.match(value, "^%d+%.%d+%.%d+[%w.+-]*$") ~= nil, name .. " must use semantic version syntax")
    return value
end

local function localization_key(value, name)
    stable_id(value, name)
    assert(string.find(value, ".text.", 1, true) ~= nil or string.find(value, ".loc.", 1, true) ~= nil,
        name .. " must be a localization key, not inline story text")
    return value
end

local function owner_key(owner)
    return tostring(owner.kind) .. ":" .. tostring(owner.id or "")
end

local function normalize_owner(owner, progression, context)
    assert(type(owner) == "table", context .. " owner is required")
    local kind = non_empty(owner.kind, context .. " owner kind")
    assert(kind == "unclaimed" or kind == "wild" or kind == "player" or kind == "faction",
        context .. " owner kind is unsupported")
    local id = owner.id
    if kind == "faction" then
        stable_id(id, context .. " owner faction ID")
        assert(progression.factionKinds[id] ~= nil, context .. " owner references an unknown faction")
    elseif kind == "player" then
        non_empty(id, context .. " owner player ID")
    else
        assert(id == nil, context .. " owner ID is not allowed for " .. kind)
    end
    return { kind = kind, id = id }
end

local function normalize_pack(pack, progression)
    assert(type(pack) == "table", "strategic-world pack is required")
    assert(pack.schemaVersion == PACK_SCHEMA, "unsupported strategic-world pack schema")
    local normalized = {
        schemaVersion = PACK_SCHEMA,
        contentPackId = stable_id(pack.contentPackId, "content pack ID"),
        contentVersion = semver(pack.contentVersion, "content version"),
        uniquePals = {},
        cities = {},
    }
    assert(type(pack.uniquePals) == "table", "unique Pal definitions are required")
    assert(type(pack.cities) == "table", "city definitions are required")

    local pal_ids = {}
    for _, definition in ipairs(pack.uniquePals) do
        assert(type(definition) == "table", "unique Pal definition must be a table")
        local id = stable_id(definition.id, "unique Pal ID")
        assert(pal_ids[id] == nil, "duplicate unique Pal ID: " .. id)
        pal_ids[id] = true
        table.insert(normalized.uniquePals, {
            id = id,
            speciesId = non_empty(definition.speciesId, "unique Pal species ID"),
            displayNameKey = localization_key(definition.displayNameKey, "unique Pal display name key"),
            initialOwner = normalize_owner(definition.initialOwner or { kind = "wild" }, progression, id),
            tags = copy(definition.tags or {}),
        })
    end

    local city_ids = {}
    for _, definition in ipairs(pack.cities) do
        assert(type(definition) == "table", "city definition must be a table")
        local id = stable_id(definition.id, "city ID")
        assert(city_ids[id] == nil, "duplicate city ID: " .. id)
        city_ids[id] = true
        stable_id(definition.factionId, "city faction ID")
        assert(progression.factionKinds[definition.factionId] == "Human", "city faction must be a known human faction")
        stable_id(definition.requiredUniquePalId, "city required unique Pal ID")
        assert(pal_ids[definition.requiredUniquePalId] == true,
            "city required unique Pal must be declared in the same pack: " .. definition.requiredUniquePalId)
        local owner_faction_id = definition.initialOwnerFactionId or definition.factionId
        stable_id(owner_faction_id, "city initial owner faction ID")
        assert(progression.factionKinds[owner_faction_id] == "Human", "city initial owner must be a known human faction")
        table.insert(normalized.cities, {
            id = id,
            factionId = definition.factionId,
            displayNameKey = localization_key(definition.displayNameKey, "city display name key"),
            requiredUniquePalId = definition.requiredUniquePalId,
            initialOwnerFactionId = owner_faction_id,
            restorable = definition.restorable == true,
            tags = copy(definition.tags or {}),
        })
    end
    return normalized
end

local function make_state()
    return {
        schemaVersion = STATE_SCHEMA_VERSION,
        revision = 0,
        eventCount = 0,
        lastEvent = nil,
        processedOperationIds = {},
        packs = {},
        uniquePals = {},
        cities = {},
        ultimatums = {},
    }
end

local function ensure_state(progression)
    assert(type(progression) == "table" and type(progression.state) == "table", "progression state root is required")
    if type(progression.state.strategicWorld) ~= "table" then
        progression.state.strategicWorld = make_state()
    end
    local state = progression.state.strategicWorld
    assert(state.schemaVersion == STATE_SCHEMA_VERSION, "unsupported strategic-world state schema")
    state.revision = state.revision or 0
    state.eventCount = state.eventCount or 0
    state.processedOperationIds = state.processedOperationIds or {}
    state.packs = state.packs or {}
    state.uniquePals = state.uniquePals or {}
    state.cities = state.cities or {}
    state.ultimatums = state.ultimatums or {}
    return state
end

local function notify(instance, event)
    instance.state.revision = instance.state.revision + 1
    instance.state.eventCount = instance.state.eventCount + 1
    event.revision = instance.state.revision
    instance.state.lastEvent = copy(event)
    if instance.onChange ~= nil then
        local ok, error_message = pcall(instance.onChange, event.factionId, copy(event))
        if not ok then
            instance.lastNotificationError = tostring(error_message)
        end
    end
end

local function duplicate_operation(instance, operation_id)
    local previous = instance.state.processedOperationIds[operation_id]
    if previous == nil then
        return nil
    end
    local response = copy(previous)
    response.ok = true
    response.reason = "duplicate-operation"
    response.duplicateOfReason = previous.reason
    return response
end

local function commit_operation(instance, operation_id, response, event)
    instance.state.processedOperationIds[operation_id] = copy(response)
    notify(instance, event)
    return response
end

local function city_faction_status(instance, faction_id)
    local active = 0
    local occupied = 0
    local destroyed = 0
    for city_id, definition in pairs(instance.cityDefinitions) do
        if definition.factionId == faction_id then
            local record = instance.state.cities[city_id]
            if record.status == "destroyed" then
                destroyed = destroyed + 1
            elseif record.ownerFactionId ~= definition.factionId then
                occupied = occupied + 1
            else
                active = active + 1
            end
        end
    end
    return { active = active, occupied = occupied, destroyed = destroyed, survives = active + occupied > 0 }
end

function StrategicWorld.create(progression, options)
    options = options or {}
    assert(options.onChange == nil or type(options.onChange) == "function", "strategic-world onChange must be a function")
    local instance = setmetatable({
        version = API_VERSION,
        progression = progression,
        state = ensure_state(progression),
        onChange = options.onChange,
        contentPackRegistry = options.contentPackRegistry,
        packDefinitions = {},
        uniquePalDefinitions = {},
        cityDefinitions = {},
        lastNotificationError = nil,
        capabilities = {
            contentOwnedDefinitions = true,
            singleOwnerUniquePals = true,
            optimisticOwnerTransfer = true,
            bossOneHpProtection = true,
            gatedPermanentCityDestruction = true,
            occupationAndRestoration = true,
            ultimatumStateMachine = true,
            modOwnedSnapshot = true,
            storyContentIncluded = false,
        },
    }, { __index = StrategicWorld })
    return instance
end

function StrategicWorld:register_pack(pack)
    local ok, normalized_or_error = pcall(normalize_pack, pack, self.progression)
    if not ok then
        return result(false, "invalid-content-pack", { error = tostring(normalized_or_error) })
    end
    local normalized = normalized_or_error
    if self.contentPackRegistry ~= nil then
        local manifest = self.contentPackRegistry:manifest(normalized.contentPackId)
        if manifest == nil then
            return result(false, "content-pack-manifest-not-registered", {
                contentPackId = normalized.contentPackId,
            })
        end
        if not self.contentPackRegistry:has_capability(normalized.contentPackId, "pwft.world.unique-pals")
            or not self.contentPackRegistry:has_capability(normalized.contentPackId, "pwft.world.city-states") then
            return result(false, "content-pack-capability-missing", {
                contentPackId = normalized.contentPackId,
            })
        end
    end
    local existing = self.state.packs[normalized.contentPackId]
    if existing ~= nil then
        if existing.contentVersion == normalized.contentVersion then
            if existing.definition ~= nil and not deep_equal(existing.definition, normalized) then
                return result(false, "content-pack-version-content-mismatch", {
                    contentPackId = normalized.contentPackId,
                    contentVersion = normalized.contentVersion,
                })
            end
            self.packDefinitions[normalized.contentPackId] = copy(normalized)
            for _, definition in ipairs(normalized.uniquePals) do
                local record = self.state.uniquePals[definition.id]
                if record == nil then
                    return result(false, "restored-state-missing-unique-pal", { uniquePalId = definition.id })
                end
                self.uniquePalDefinitions[definition.id] = copy(definition)
            end
            for _, definition in ipairs(normalized.cities) do
                local record = self.state.cities[definition.id]
                if record == nil then
                    return result(false, "restored-state-missing-city", { cityId = definition.id })
                end
                self.cityDefinitions[definition.id] = copy(definition)
            end
            return result(true, "content-pack-already-registered", { contentPackId = normalized.contentPackId })
        end
        return result(false, "content-pack-migration-required", {
            contentPackId = normalized.contentPackId,
            currentVersion = existing.contentVersion,
            requestedVersion = normalized.contentVersion,
        })
    end

    for _, definition in ipairs(normalized.uniquePals) do
        if self.uniquePalDefinitions[definition.id] ~= nil or self.state.uniquePals[definition.id] ~= nil then
            return result(false, "unique-pal-definition-conflict", { uniquePalId = definition.id })
        end
    end
    for _, definition in ipairs(normalized.cities) do
        if self.cityDefinitions[definition.id] ~= nil or self.state.cities[definition.id] ~= nil then
            return result(false, "city-definition-conflict", { cityId = definition.id })
        end
    end

    self.packDefinitions[normalized.contentPackId] = copy(normalized)
    self.state.packs[normalized.contentPackId] = {
        contentPackId = normalized.contentPackId,
        contentVersion = normalized.contentVersion,
        definition = copy(normalized),
    }
    for _, definition in ipairs(normalized.uniquePals) do
        self.uniquePalDefinitions[definition.id] = copy(definition)
        self.state.uniquePals[definition.id] = {
            id = definition.id,
            owner = copy(definition.initialOwner),
            transferCount = 0,
            lastTransferReason = "content-pack-initial-state",
        }
    end
    for _, definition in ipairs(normalized.cities) do
        self.cityDefinitions[definition.id] = copy(definition)
        self.state.cities[definition.id] = {
            id = definition.id,
            status = "active",
            ownerFactionId = definition.initialOwnerFactionId,
            preservationCount = 0,
            occupationCount = 0,
            destroyedBy = nil,
        }
    end
    notify(self, {
        type = "strategic-content-pack-registered",
        contentPackId = normalized.contentPackId,
        contentVersion = normalized.contentVersion,
    })
    return result(true, "content-pack-registered", {
        contentPackId = normalized.contentPackId,
        uniquePalCount = #normalized.uniquePals,
        cityCount = #normalized.cities,
    })
end

function StrategicWorld:unique_pal_status(unique_pal_id)
    local definition = self.uniquePalDefinitions[unique_pal_id]
    local record = self.state.uniquePals[unique_pal_id]
    if definition == nil or record == nil then
        return nil
    end
    local value = copy(record)
    value.definition = copy(definition)
    return value
end

function StrategicWorld:city_status(city_id)
    local definition = self.cityDefinitions[city_id]
    local record = self.state.cities[city_id]
    if definition == nil or record == nil then
        return nil
    end
    local value = copy(record)
    value.definition = copy(definition)
    return value
end

function StrategicWorld:faction_status(faction_id)
    if self.progression.factionKinds[faction_id] == nil then
        return nil
    end
    local value = city_faction_status(self, faction_id)
    value.factionId = faction_id
    return value
end

function StrategicWorld:transfer_unique_pal(unique_pal_id, expected_owner, new_owner, operation_id, context)
    stable_id(unique_pal_id, "unique Pal ID")
    non_empty(operation_id, "operation ID")
    local duplicate = duplicate_operation(self, operation_id)
    if duplicate ~= nil then
        return duplicate
    end
    local record = self.state.uniquePals[unique_pal_id]
    if record == nil or self.uniquePalDefinitions[unique_pal_id] == nil then
        return result(false, "unknown-unique-pal")
    end
    local expected = normalize_owner(expected_owner, self.progression, "expected")
    local requested = normalize_owner(new_owner, self.progression, "new")
    if owner_key(record.owner) ~= owner_key(expected) then
        return result(false, "unique-pal-owner-conflict", { currentOwner = copy(record.owner) })
    end
    if owner_key(expected) == owner_key(requested) then
        return result(false, "unique-pal-owner-unchanged")
    end
    local previous = copy(record.owner)
    record.owner = copy(requested)
    record.transferCount = record.transferCount + 1
    record.lastTransferReason = context and context.reason or "content-operation"
    local response = result(true, "unique-pal-transferred", {
        uniquePalId = unique_pal_id,
        previousOwner = previous,
        owner = copy(requested),
    })
    return commit_operation(self, operation_id, response, {
        type = "unique-pal-transferred",
        uniquePalId = unique_pal_id,
        previousOwner = previous,
        owner = copy(requested),
        operationId = operation_id,
    })
end

function StrategicWorld:destruction_gate(city_id, actor)
    local city = self.state.cities[city_id]
    local definition = self.cityDefinitions[city_id]
    if city == nil or definition == nil then
        return result(false, "unknown-city")
    end
    if city.status == "destroyed" then
        return result(false, "city-already-destroyed")
    end
    local normalized_actor = normalize_owner(actor, self.progression, "actor")
    assert(normalized_actor.kind == "player" or normalized_actor.kind == "faction",
        "city destruction actor must be a player or faction")
    local pal = self.state.uniquePals[definition.requiredUniquePalId]
    local authorized = pal ~= nil and owner_key(pal.owner) == owner_key(normalized_actor)
    return result(authorized, authorized and "destruction-authorized" or "required-unique-pal-not-controlled", {
        cityId = city_id,
        requiredUniquePalId = definition.requiredUniquePalId,
        actor = copy(normalized_actor),
        uniquePalOwner = pal and copy(pal.owner) or nil,
        minimumBossHealth = authorized and 0 or 1,
    })
end

function StrategicWorld:boss_health_gate(city_id, actor, proposed_health)
    assert(type(proposed_health) == "number", "proposed boss health must be numeric")
    local gate = self:destruction_gate(city_id, actor)
    if proposed_health > 0 or gate.ok then
        return result(true, "boss-health-accepted", {
            cityId = city_id,
            requestedHealth = proposed_health,
            appliedHealth = proposed_health,
            destructionAuthorized = gate.ok,
        })
    end
    return result(true, "boss-one-hp-protection-applied", {
        cityId = city_id,
        requestedHealth = proposed_health,
        appliedHealth = 1,
        destructionAuthorized = false,
        requiredUniquePalId = gate.requiredUniquePalId,
    })
end

function StrategicWorld:preserve_city(city_id, operation_id, context)
    non_empty(operation_id, "operation ID")
    local duplicate = duplicate_operation(self, operation_id)
    if duplicate ~= nil then
        return duplicate
    end
    local record = self.state.cities[city_id]
    if record == nil then
        return result(false, "unknown-city")
    end
    if record.status == "destroyed" then
        return result(false, "city-already-destroyed")
    end
    record.preservationCount = record.preservationCount + 1
    local response = result(true, "city-preserved", { city = self:city_status(city_id) })
    return commit_operation(self, operation_id, response, {
        type = "city-preserved",
        cityId = city_id,
        factionId = self.cityDefinitions[city_id].factionId,
        operationId = operation_id,
        sourceId = context and context.sourceId or nil,
    })
end

function StrategicWorld:occupy_city(city_id, new_owner_faction_id, operation_id, context)
    stable_id(new_owner_faction_id, "new owner faction ID")
    assert(self.progression.factionKinds[new_owner_faction_id] == "Human", "city owner must be a known human faction")
    non_empty(operation_id, "operation ID")
    local duplicate = duplicate_operation(self, operation_id)
    if duplicate ~= nil then
        return duplicate
    end
    local record = self.state.cities[city_id]
    if record == nil then
        return result(false, "unknown-city")
    end
    if record.status == "destroyed" then
        return result(false, "city-already-destroyed")
    end
    local previous_owner = record.ownerFactionId
    if previous_owner == new_owner_faction_id then
        return result(false, "city-owner-unchanged")
    end
    record.ownerFactionId = new_owner_faction_id
    record.status = "occupied"
    record.occupationCount = record.occupationCount + 1
    local response = result(true, "city-occupied", { city = self:city_status(city_id) })
    return commit_operation(self, operation_id, response, {
        type = "city-occupied",
        cityId = city_id,
        factionId = self.cityDefinitions[city_id].factionId,
        previousOwnerFactionId = previous_owner,
        ownerFactionId = new_owner_faction_id,
        operationId = operation_id,
        sourceId = context and context.sourceId or nil,
    })
end

function StrategicWorld:destroy_city(city_id, actor, operation_id, context)
    non_empty(operation_id, "operation ID")
    local duplicate = duplicate_operation(self, operation_id)
    if duplicate ~= nil then
        return duplicate
    end
    local gate = self:destruction_gate(city_id, actor)
    if not gate.ok then
        return gate
    end
    local record = self.state.cities[city_id]
    record.status = "destroyed"
    record.destroyedBy = copy(gate.actor)
    local response = result(true, "city-destroyed", { city = self:city_status(city_id) })
    return commit_operation(self, operation_id, response, {
        type = "city-destroyed",
        cityId = city_id,
        factionId = self.cityDefinitions[city_id].factionId,
        actor = copy(gate.actor),
        requiredUniquePalId = gate.requiredUniquePalId,
        operationId = operation_id,
        sourceId = context and context.sourceId or nil,
    })
end

function StrategicWorld:restore_city(city_id, owner_faction_id, operation_id, context)
    non_empty(operation_id, "operation ID")
    local duplicate = duplicate_operation(self, operation_id)
    if duplicate ~= nil then
        return duplicate
    end
    local definition = self.cityDefinitions[city_id]
    local record = self.state.cities[city_id]
    if definition == nil or record == nil then
        return result(false, "unknown-city")
    end
    if not definition.restorable then
        return result(false, "city-restoration-not-allowed-by-content")
    end
    if record.status ~= "destroyed" then
        return result(false, "city-is-not-destroyed")
    end
    stable_id(owner_faction_id, "restored city owner faction ID")
    assert(self.progression.factionKinds[owner_faction_id] == "Human", "restored city owner must be human")
    record.status = owner_faction_id == definition.factionId and "active" or "occupied"
    record.ownerFactionId = owner_faction_id
    record.destroyedBy = nil
    local response = result(true, "city-restored", { city = self:city_status(city_id) })
    return commit_operation(self, operation_id, response, {
        type = "city-restored",
        cityId = city_id,
        factionId = definition.factionId,
        ownerFactionId = owner_faction_id,
        operationId = operation_id,
        sourceId = context and context.sourceId or nil,
    })
end

-- Ending routes are trusted deterministic content, but they still cross a
-- narrow authority boundary. This method is intentionally not a general
-- force-set API: only the versioned ending runtime may use it, every change
-- is idempotent, and the transition remains in the Mod-owned event history.
function StrategicWorld:apply_ending_transition(city_id, transition, operation_id, context)
    assert(type(context) == "table" and context.authority == "pwft.ending-runtime.v1",
        "ending transition requires the ending-runtime authority")
    assert(type(transition) == "table", "ending city transition is required")
    non_empty(operation_id, "operation ID")
    local duplicate = duplicate_operation(self, operation_id)
    if duplicate ~= nil then
        return duplicate
    end
    local definition = self.cityDefinitions[city_id]
    local record = self.state.cities[city_id]
    if definition == nil or record == nil then
        return result(false, "unknown-city")
    end
    local status = non_empty(transition.status, "ending city status")
    assert(status == "active" or status == "occupied" or status == "destroyed",
        "unsupported ending city status")
    local owner_faction_id = transition.ownerFactionId
    if status == "active" then
        owner_faction_id = owner_faction_id or definition.factionId
        assert(owner_faction_id == definition.factionId,
            "active ending city must be owned by its defining faction")
    elseif status == "occupied" then
        stable_id(owner_faction_id, "ending city owner faction ID")
        assert(self.progression.factionKinds[owner_faction_id] == "Human",
            "occupied ending city owner must be human")
        assert(owner_faction_id ~= definition.factionId,
            "occupied ending city requires a different faction owner")
    else
        owner_faction_id = nil
    end
    local previous = copy(record)
    record.status = status
    record.ownerFactionId = owner_faction_id
    record.destroyedBy = status == "destroyed" and {
        kind = "ending-route",
        id = context.routeId,
    } or nil
    local response = result(true, "ending-city-transition-applied", {
        city = self:city_status(city_id),
        previousCity = previous,
    })
    return commit_operation(self, operation_id, response, {
        type = "ending-city-transition-applied",
        cityId = city_id,
        factionId = definition.factionId,
        status = status,
        ownerFactionId = owner_faction_id,
        routeId = context.routeId,
        operationId = operation_id,
    })
end

function StrategicWorld:issue_ultimatum(ultimatum_id, issuer_faction_id, target_id, demand, operation_id)
    stable_id(ultimatum_id, "ultimatum ID")
    stable_id(issuer_faction_id, "issuer faction ID")
    non_empty(target_id, "ultimatum target ID")
    non_empty(operation_id, "operation ID")
    assert(self.progression.factionKinds[issuer_faction_id] == "Human", "ultimatum issuer must be human")
    assert(type(demand) == "table", "ultimatum demand is required")
    local demand_kind = non_empty(demand.kind, "ultimatum demand kind")
    assert(demand_kind == "tribute" or demand_kind == "submission" or demand_kind == "resource"
        or demand_kind == "ceasefire" or demand_kind == "custom", "unsupported ultimatum demand kind")
    local duplicate = duplicate_operation(self, operation_id)
    if duplicate ~= nil then
        return duplicate
    end
    if self.state.ultimatums[ultimatum_id] ~= nil then
        return result(false, "ultimatum-id-conflict")
    end
    self.state.ultimatums[ultimatum_id] = {
        id = ultimatum_id,
        issuerFactionId = issuer_faction_id,
        targetId = target_id,
        demand = copy(demand),
        status = "pending",
        resolutionId = nil,
    }
    local response = result(true, "ultimatum-issued", { ultimatum = copy(self.state.ultimatums[ultimatum_id]) })
    return commit_operation(self, operation_id, response, {
        type = "ultimatum-issued",
        ultimatumId = ultimatum_id,
        factionId = issuer_faction_id,
        operationId = operation_id,
    })
end

function StrategicWorld:resolve_ultimatum(ultimatum_id, accepted, operation_id, context)
    assert(type(accepted) == "boolean", "ultimatum acceptance must be boolean")
    non_empty(operation_id, "operation ID")
    local duplicate = duplicate_operation(self, operation_id)
    if duplicate ~= nil then
        return duplicate
    end
    local record = self.state.ultimatums[ultimatum_id]
    if record == nil then
        return result(false, "unknown-ultimatum")
    end
    if record.status ~= "pending" then
        return result(false, "ultimatum-already-resolved", { ultimatum = copy(record) })
    end
    record.status = accepted and "accepted" or "rejected"
    record.resolutionId = operation_id
    record.result = copy(context or {})
    local response = result(true, accepted and "ultimatum-accepted" or "ultimatum-rejected", {
        ultimatum = copy(record),
    })
    return commit_operation(self, operation_id, response, {
        type = accepted and "ultimatum-accepted" or "ultimatum-rejected",
        ultimatumId = ultimatum_id,
        factionId = record.issuerFactionId,
        operationId = operation_id,
    })
end

function StrategicWorld:status()
    local pack_count = 0
    local pal_count = 0
    local city_count = 0
    local ultimatum_count = 0
    for _ in pairs(self.state.packs) do pack_count = pack_count + 1 end
    for _ in pairs(self.state.uniquePals) do pal_count = pal_count + 1 end
    for _ in pairs(self.state.cities) do city_count = city_count + 1 end
    for _ in pairs(self.state.ultimatums) do ultimatum_count = ultimatum_count + 1 end
    return {
        apiVersion = self.version,
        schemaVersion = self.state.schemaVersion,
        revision = self.state.revision,
        eventCount = self.state.eventCount,
        contentPackCount = pack_count,
        uniquePalCount = pal_count,
        cityCount = city_count,
        ultimatumCount = ultimatum_count,
        storyContentIncluded = false,
        lastNotificationError = self.lastNotificationError,
    }
end

function StrategicWorld:export_snapshot()
    return copy(self.state)
end

return StrategicWorld
