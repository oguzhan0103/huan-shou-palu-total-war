local UniquePalCampaign = {}

local API_VERSION = "1.0.0"
local STATE_SCHEMA_VERSION = "1.0.0"
local PACK_SCHEMA = "pwft.unique-pal-campaign.pack.v1"
local CAPTURE_AUTHORITY = "pwft.native-unique-pal-capture.v1"
local BOSS_SPAWN_AUTHORITY = "pwft.native-unique-pal-boss-spawn.v1"
local WAR_RESULT_AUTHORITY = "pwft.unique-pal-war-result.v1"
local RANSOM_AUTHORITY = "pwft.native-ransom-payment.v1"

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, child in pairs(value) do result[copy(key)] = copy(child) end
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
    local response = extra or {}
    response.ok = ok
    response.reason = reason
    return response
end

local function non_empty(value, name)
    assert(type(value) == "string" and value ~= "", name .. " is required")
    return value
end

local function stable_id(value, name)
    non_empty(value, name)
    assert(string.match(value, "^[a-z0-9][a-z0-9_.-]+$") ~= nil,
        name .. " must be a stable namespaced ID")
    assert(string.find(value, "..", 1, true) == nil,
        name .. " cannot contain an empty namespace segment")
    return value
end

local function semver(value, name)
    non_empty(value, name)
    assert(string.match(value, "^%d+%.%d+%.%d+[%w.+-]*$") ~= nil,
        name .. " must use semantic version syntax")
    return value
end

local function positive_integer(value, name)
    assert(type(value) == "number" and value > 0
            and value == math.floor(value),
        name .. " must be a positive integer")
    return value
end

local function non_negative_integer(value, name)
    assert(type(value) == "number" and value >= 0
            and value == math.floor(value),
        name .. " must be a non-negative integer")
    return value
end

local function sorted_keys(values)
    local keys = {}
    for key in pairs(values or {}) do keys[#keys + 1] = key end
    table.sort(keys)
    return keys
end

local function owner_key(owner)
    return tostring(owner and owner.kind) .. ":"
        .. tostring(owner and owner.id or "")
end

local function target_key(target)
    return target.kind .. ":" .. target.id
end

local function stable_hash(value)
    local hash = 5381
    for index = 1, #value do
        hash = (hash * 33 + string.byte(value, index)) % 2147483647
    end
    return hash
end

local function assert_only_fields(value, allowed, name)
    for key in pairs(value) do
        assert(allowed[key] == true,
            name .. " contains unsupported field: " .. tostring(key))
    end
end

local function normalize_human_faction_ids(instance, values, name, allow_empty)
    assert(type(values) == "table", name .. " must be an array")
    local normalized = {}
    local seen = {}
    for index, faction_id in ipairs(values) do
        stable_id(faction_id, name .. " entry " .. tostring(index))
        assert(instance.progression.factionKinds[faction_id] == "Human",
            name .. " must reference human factions")
        assert(seen[faction_id] == nil,
            name .. " contains duplicate faction: " .. faction_id)
        seen[faction_id] = true
        normalized[#normalized + 1] = faction_id
    end
    assert(allow_empty or #normalized > 0, name .. " cannot be empty")
    table.sort(normalized)
    return normalized
end

local function normalize_definition(instance, definition)
    assert(type(definition) == "table",
        "unique-Pal campaign definition must be a table")
    assert_only_fields(definition, {
        id = true,
        target = true,
        boss = true,
        schedule = true,
        ransomPrice = true,
        candidateFactionIds = true,
        tags = true,
    }, "unique-Pal campaign definition")
    local id = stable_id(definition.id, "unique Pal ID")
    local strategic = instance.strategicWorld:unique_pal_status(id)
    assert(strategic ~= nil,
        "campaign unique Pal must already exist in StrategicWorld: " .. id)

    assert(type(definition.target) == "table",
        "unique-Pal destruction target is required")
    assert_only_fields(definition.target, {
        kind = true,
        id = true,
        affectedFactionIds = true,
    }, "unique-Pal destruction target")
    local target_kind = non_empty(definition.target.kind,
        "unique-Pal destruction target kind")
    assert(target_kind == "faction" or target_kind == "strategic-target",
        "unique-Pal destruction target kind is unsupported")
    local target_id = stable_id(definition.target.id,
        "unique-Pal destruction target ID")
    local affected = normalize_human_faction_ids(
        instance,
        definition.target.affectedFactionIds or {},
        "affected faction IDs",
        target_kind == "strategic-target"
    )
    if target_kind == "faction" then
        assert(instance.progression.factionKinds[target_id] == "Human",
            "faction destruction target must be a known human faction")
        local includes_target = false
        for _, faction_id in ipairs(affected) do
            if faction_id == target_id then includes_target = true end
        end
        assert(includes_target,
            "faction destruction target must be included in affected factions")
    end

    assert(type(definition.boss) == "table",
        "unique-Pal Boss definition is required")
    assert_only_fields(definition.boss, {
        speciesId = true,
        nativeBossAvailable = true,
        nativeBossSlotId = true,
        bindingStatus = true,
        strengthProfile = true,
    }, "unique-Pal Boss definition")
    local species_id = non_empty(definition.boss.speciesId,
        "unique-Pal Boss species ID")
    assert(species_id == strategic.definition.speciesId,
        "campaign Boss species must match StrategicWorld")
    assert(type(definition.boss.nativeBossAvailable) == "boolean",
        "native Boss availability flag is required")
    local slot_id = definition.boss.nativeBossSlotId
    if slot_id ~= nil then
        non_empty(slot_id, "native Boss slot ID")
    end
    local binding_status = definition.boss.bindingStatus or "pending"
    assert(binding_status == "pending" or binding_status == "bound",
        "unsupported native Boss binding status")
    if binding_status == "bound" and not definition.boss.nativeBossAvailable then
        assert(slot_id ~= nil,
            "a replacement Boss slot is required before binding can be active")
    end
    assert(definition.boss.strengthProfile == "raid-slab",
        "unique-Pal Boss strength profile must be raid-slab")

    assert(type(definition.schedule) == "table",
        "unique-Pal opening schedule is required")
    assert_only_fields(definition.schedule, {
        minimumIntervalTicks = true,
        maximumIntervalTicks = true,
        noticeTicks = true,
        openTicks = true,
    }, "unique-Pal opening schedule")
    local minimum = positive_integer(
        definition.schedule.minimumIntervalTicks,
        "minimum opening interval")
    local maximum = positive_integer(
        definition.schedule.maximumIntervalTicks,
        "maximum opening interval")
    assert(maximum >= minimum,
        "maximum opening interval cannot be below minimum")
    local candidates = normalize_human_faction_ids(
        instance,
        definition.candidateFactionIds,
        "unique-Pal assignment candidates",
        false
    )

    return {
        id = id,
        target = {
            kind = target_kind,
            id = target_id,
            affectedFactionIds = affected,
        },
        boss = {
            speciesId = species_id,
            nativeBossAvailable = definition.boss.nativeBossAvailable,
            nativeBossSlotId = slot_id,
            bindingStatus = binding_status,
            strengthProfile = "raid-slab",
        },
        schedule = {
            minimumIntervalTicks = minimum,
            maximumIntervalTicks = maximum,
            noticeTicks = positive_integer(
                definition.schedule.noticeTicks,
                "opening notice duration"),
            openTicks = positive_integer(
                definition.schedule.openTicks,
                "Boss opening duration"),
        },
        ransomPrice = positive_integer(definition.ransomPrice,
            "unique-Pal ransom price"),
        candidateFactionIds = candidates,
        tags = copy(definition.tags or {}),
    }
end

local function normalize_pack(instance, pack)
    assert(type(pack) == "table", "unique-Pal campaign pack is required")
    assert_only_fields(pack, {
        schemaVersion = true,
        contentPackId = true,
        contentVersion = true,
        uniquePals = true,
    }, "unique-Pal campaign pack")
    assert(pack.schemaVersion == PACK_SCHEMA,
        "unsupported unique-Pal campaign pack schema")
    assert(type(pack.uniquePals) == "table",
        "unique-Pal campaign definitions are required")
    local normalized = {
        schemaVersion = PACK_SCHEMA,
        contentPackId = stable_id(pack.contentPackId,
            "campaign content pack ID"),
        contentVersion = semver(pack.contentVersion,
            "campaign content version"),
        uniquePals = {},
    }
    local ids = {}
    local species = {}
    local targets = {}
    for _, definition in ipairs(pack.uniquePals) do
        local value = normalize_definition(instance, definition)
        assert(ids[value.id] == nil,
            "duplicate campaign unique Pal ID: " .. value.id)
        assert(species[value.boss.speciesId] == nil,
            "one species cannot define multiple unique Bosses: "
                .. value.boss.speciesId)
        local key = target_key(value.target)
        assert(targets[key] == nil,
            "one destruction target cannot use multiple unique Pals: " .. key)
        ids[value.id] = true
        species[value.boss.speciesId] = true
        targets[key] = true
        normalized.uniquePals[#normalized.uniquePals + 1] = value
    end
    assert(#normalized.uniquePals > 0,
        "unique-Pal campaign pack cannot be empty")
    table.sort(normalized.uniquePals, function(first, second)
        return first.id < second.id
    end)
    return normalized
end

local function make_state(max_history)
    return {
        schemaVersion = STATE_SCHEMA_VERSION,
        revision = 0,
        eventCount = 0,
        logicalTick = 0,
        maxHistory = max_history,
        historyDropped = 0,
        history = {},
        operationSignatures = {},
        packs = {},
        campaigns = {},
        targets = {},
        wars = {},
    }
end

local function ensure_state(instance)
    local root = instance.progression.state
    if type(root.uniquePalCampaign) ~= "table" then
        root.uniquePalCampaign = make_state(instance.maxHistory)
    end
    local state = root.uniquePalCampaign
    assert(state.schemaVersion == STATE_SCHEMA_VERSION,
        "unsupported unique-Pal campaign snapshot schema")
    state.revision = state.revision or 0
    state.eventCount = state.eventCount or 0
    state.logicalTick = state.logicalTick or 0
    state.maxHistory = state.maxHistory or instance.maxHistory
    state.historyDropped = state.historyDropped or 0
    state.history = state.history or {}
    state.operationSignatures = state.operationSignatures or {}
    state.packs = state.packs or {}
    state.campaigns = state.campaigns or {}
    state.targets = state.targets or {}
    state.wars = state.wars or {}
    return state
end

local function append_history(instance, event)
    local state = instance.state
    state.revision = state.revision + 1
    state.eventCount = state.eventCount + 1
    event.revision = state.revision
    state.history[#state.history + 1] = copy(event)
    if #state.history > state.maxHistory then
        table.remove(state.history, 1)
        state.historyDropped = state.historyDropped + 1
    end
    if instance.onChange ~= nil then
        local called, message = pcall(instance.onChange, copy(event))
        if not called then instance.lastNotificationError = tostring(message) end
    end
end

local function duplicate_operation(instance, operation_id, signature)
    local previous = instance.state.operationSignatures[operation_id]
    if previous == nil then return nil end
    if previous.signature ~= signature then
        return result(false, "operation-id-conflict", {
            operationId = operation_id,
        })
    end
    local response = copy(previous.response)
    response.ok = true
    response.duplicateOfReason = response.reason
    response.reason = "duplicate-operation"
    response.idempotent = true
    return response
end

local function commit_operation(instance, operation_id, signature, response, events)
    for _, event in ipairs(events or {}) do append_history(instance, event) end
    instance.state.operationSignatures[operation_id] = {
        signature = signature,
        response = copy(response),
    }
    return response
end

local function current_owner(instance, unique_pal_id)
    local value = instance.strategicWorld:unique_pal_status(unique_pal_id)
    return value and value.owner or nil
end

local function owner_is_wild(owner)
    return owner ~= nil
        and (owner.kind == "wild" or owner.kind == "unclaimed")
end

local function faction_destroyed(instance, faction_id)
    for _, target in pairs(instance.state.targets) do
        if target.status == "destroyed" then
            for _, affected in ipairs(target.affectedFactionIds or {}) do
                if affected == faction_id then return true end
            end
        end
    end
    return false
end

local function player_joined_target(instance, target)
    for _, faction_id in ipairs(target.affectedFactionIds or {}) do
        local status = instance.progression:status(faction_id)
        if status ~= nil and status.joined == true then return true end
    end
    return false
end

local function select_assignment_faction(instance, definition, event_id)
    local eligible = {}
    for _, faction_id in ipairs(definition.candidateFactionIds) do
        if not faction_destroyed(instance, faction_id) then
            eligible[#eligible + 1] = faction_id
        end
    end
    if #eligible == 0 then return nil end
    table.sort(eligible)
    local index = (stable_hash(event_id .. "|" .. definition.id)
        % #eligible) + 1
    return eligible[index]
end

local function active_war_for_pal(instance, unique_pal_id)
    local campaign = instance.state.campaigns[unique_pal_id]
    if campaign == nil or campaign.activeWarId == nil then return nil end
    local war = instance.state.wars[campaign.activeWarId]
    if war == nil or war.status ~= "pending" then return nil end
    return war
end

local function sync_campaign_from_owner(instance, unique_pal_id)
    local campaign = instance.state.campaigns[unique_pal_id]
    local owner = current_owner(instance, unique_pal_id)
    if campaign == nil or owner == nil then return nil end
    if owner_is_wild(owner) then
        if campaign.phase == "owned" then campaign.phase = "closed" end
    else
        campaign.phase = "owned"
        campaign.eventId = nil
        campaign.noticeTick = nil
        campaign.openTick = nil
        campaign.closeTick = nil
        campaign.nativeSpawnId = nil
        campaign.actorBindingId = nil
    end
    campaign.owner = copy(owner)
    return owner
end

local function preflight_target_destruction(instance, definition)
    local affected = {}
    for _, faction_id in ipairs(definition.target.affectedFactionIds) do
        affected[faction_id] = true
    end
    local city_ids = {}
    for city_id, city_definition in pairs(
        instance.strategicWorld.cityDefinitions or {}) do
        local city = instance.strategicWorld:city_status(city_id)
        if affected[city_definition.factionId]
            and city ~= nil and city.status ~= "destroyed" then
            if city_definition.requiredUniquePalId ~= definition.id then
                return nil, result(false,
                    "city-unique-pal-mapping-conflict", {
                        cityId = city_id,
                        expectedUniquePalId = definition.id,
                        actualUniquePalId =
                            city_definition.requiredUniquePalId,
                    })
            end
            city_ids[#city_ids + 1] = city_id
        end
    end
    table.sort(city_ids)
    return city_ids, nil
end

local function destroy_target(instance, definition, war, resolution_id)
    local target = instance.state.targets[target_key(definition.target)]
    if target == nil then return result(false, "unknown-destruction-target") end
    if target.status == "destroyed" then
        return result(true, "destruction-target-already-destroyed", {
            target = copy(target),
            idempotent = true,
        })
    end
    local city_ids, failure = preflight_target_destruction(
        instance,
        definition
    )
    if failure ~= nil then return failure end
    local actor = { kind = "faction", id = war.attackerFactionId }
    local destroyed_city_ids = {}
    for _, city_id in ipairs(city_ids) do
        local destroyed = instance.strategicWorld:destroy_city(
            city_id,
            actor,
            resolution_id .. ":city:" .. city_id,
            {
                sourceId = "pwft.unique-pal-destruction-war.v1",
                warId = war.id,
            }
        )
        if not destroyed.ok then
            return result(false, "strategic-city-destruction-failed", {
                cityId = city_id,
                strategicReason = destroyed.reason,
            })
        end
        destroyed_city_ids[#destroyed_city_ids + 1] = city_id
    end
    target.status = "destroyed"
    target.destroyedByFactionId = war.attackerFactionId
    target.destroyedByUniquePalId = definition.id
    target.destroyedByWarId = war.id
    target.destroyedResolutionId = resolution_id
    target.destroyedAtTick = instance.state.logicalTick
    return result(true, "destruction-target-destroyed", {
        target = copy(target),
        destroyedCityIds = destroyed_city_ids,
    })
end

function UniquePalCampaign.create(progression, strategic_world, options)
    assert(type(progression) == "table"
            and type(progression.state) == "table",
        "faction progression is required")
    assert(type(strategic_world) == "table"
            and type(strategic_world.unique_pal_status) == "function"
            and type(strategic_world.transfer_unique_pal) == "function"
            and type(strategic_world.destroy_city) == "function",
        "StrategicWorld is required")
    options = options or {}
    local max_history = options.maxHistory or 256
    positive_integer(max_history, "unique-Pal campaign history limit")
    assert(options.onChange == nil or type(options.onChange) == "function",
        "unique-Pal campaign onChange must be a function")
    local instance = setmetatable({
        version = API_VERSION,
        progression = progression,
        strategicWorld = strategic_world,
        maxHistory = max_history,
        playerId = options.playerId or "local-player",
        onChange = options.onChange,
        definitions = {},
        packDefinitions = {},
        speciesIndex = {},
        targetIndex = {},
        lastNotificationError = nil,
        capabilities = {
            uniquePalBossWhitelist = true,
            raidSlabBalanceProfileRequired = true,
            deterministicOpeningWindows = true,
            preOpeningNotifications = true,
            nativeBossSpawnConfirmationRequired = true,
            authoritativeCaptureOnly = true,
            deterministicTimeoutFactionAssignment = true,
            singleOwnerDelegatedToStrategicWorld = true,
            backgroundDestructionWar = true,
            playerMembershipDefenseRoute = true,
            persistentFactionExtinction = true,
            factionSpawnSuppressionPolicy = true,
            merchantSpawnSuppressionPolicy = true,
            authoritativeRansomSettlement = true,
            nativeBossMutation = false,
            nativeCurrencyMutation = false,
            nativeSpawnSuppressionMutation = false,
            storyContentIncluded = false,
            PalworldSaveMutation = false,
        },
    }, { __index = UniquePalCampaign })
    non_empty(instance.playerId, "unique-Pal campaign player ID")
    instance.state = ensure_state(instance)
    if type(progression.register_restore_listener) == "function" then
        local registered = progression:register_restore_listener(
            "pwft.unique-pal-campaign.v1",
            function()
                return instance:rebind_progression_state()
            end
        )
        assert(registered.ok, registered.reason)
    end
    return instance
end

function UniquePalCampaign:rebind_progression_state()
    local called, rebound = pcall(ensure_state, self)
    if not called then
        return result(false, "unique-pal-campaign-snapshot-invalid", {
            error = tostring(rebound),
        })
    end
    self.state = rebound
    for unique_pal_id in pairs(self.definitions) do
        if self.state.campaigns[unique_pal_id] == nil then
            return result(false,
                "restored-state-missing-unique-pal-campaign", {
                    uniquePalId = unique_pal_id,
                })
        end
    end
    return result(true, "unique-pal-campaign-state-rebound")
end

function UniquePalCampaign:register_pack(pack)
    local called, normalized = pcall(normalize_pack, self, pack)
    if not called then
        return result(false, "invalid-unique-pal-campaign-pack", {
            error = tostring(normalized),
        })
    end
    local existing = self.state.packs[normalized.contentPackId]
    if existing ~= nil then
        if existing.contentVersion ~= normalized.contentVersion then
            return result(false, "campaign-content-pack-migration-required", {
                contentPackId = normalized.contentPackId,
                currentVersion = existing.contentVersion,
                requestedVersion = normalized.contentVersion,
            })
        end
        if not deep_equal(existing.definition, normalized) then
            return result(false,
                "campaign-content-version-content-mismatch", {
                    contentPackId = normalized.contentPackId,
                })
        end
        self.packDefinitions[normalized.contentPackId] = copy(normalized)
        for _, definition in ipairs(normalized.uniquePals) do
            if self.state.campaigns[definition.id] == nil then
                return result(false,
                    "restored-state-missing-unique-pal-campaign", {
                        uniquePalId = definition.id,
                    })
            end
            self.definitions[definition.id] = copy(definition)
            self.speciesIndex[definition.boss.speciesId] = definition.id
            self.targetIndex[target_key(definition.target)] = definition.id
        end
        return result(true, "unique-pal-campaign-pack-already-registered", {
            contentPackId = normalized.contentPackId,
            uniquePalCount = #normalized.uniquePals,
        })
    end

    for _, definition in ipairs(normalized.uniquePals) do
        if self.definitions[definition.id] ~= nil
            or self.state.campaigns[definition.id] ~= nil then
            return result(false, "unique-pal-campaign-definition-conflict", {
                uniquePalId = definition.id,
            })
        end
        if self.speciesIndex[definition.boss.speciesId] ~= nil then
            return result(false, "unique-pal-boss-species-conflict", {
                speciesId = definition.boss.speciesId,
            })
        end
        local key = target_key(definition.target)
        if self.targetIndex[key] ~= nil or self.state.targets[key] ~= nil then
            return result(false, "unique-pal-destruction-target-conflict", {
                targetKey = key,
            })
        end
    end

    self.state.packs[normalized.contentPackId] = {
        contentPackId = normalized.contentPackId,
        contentVersion = normalized.contentVersion,
        definition = copy(normalized),
    }
    self.packDefinitions[normalized.contentPackId] = copy(normalized)
    for _, definition in ipairs(normalized.uniquePals) do
        self.definitions[definition.id] = copy(definition)
        self.speciesIndex[definition.boss.speciesId] = definition.id
        local key = target_key(definition.target)
        self.targetIndex[key] = definition.id
        local owner = current_owner(self, definition.id)
        self.state.campaigns[definition.id] = {
            uniquePalId = definition.id,
            phase = owner_is_wild(owner) and "closed" or "owned",
            owner = copy(owner),
            scheduleSequence = 0,
            eventId = nil,
            noticeTick = nil,
            openTick = nil,
            closeTick = nil,
            activeWarId = nil,
            captureCount = 0,
            timeoutAssignmentCount = 0,
            ransomCount = 0,
        }
        self.state.targets[key] = {
            key = key,
            kind = definition.target.kind,
            id = definition.target.id,
            affectedFactionIds = copy(
                definition.target.affectedFactionIds),
            status = "active",
        }
    end
    append_history(self, {
        type = "unique-pal-campaign-pack-registered",
        contentPackId = normalized.contentPackId,
        contentVersion = normalized.contentVersion,
        uniquePalCount = #normalized.uniquePals,
    })
    return result(true, "unique-pal-campaign-pack-registered", {
        contentPackId = normalized.contentPackId,
        uniquePalCount = #normalized.uniquePals,
    })
end

function UniquePalCampaign:schedule_next(
    unique_pal_id,
    logical_tick,
    operation_id
)
    non_empty(operation_id, "opening schedule operation ID")
    non_negative_integer(logical_tick, "opening schedule logical tick")
    local signature = table.concat({
        "schedule", unique_pal_id, tostring(logical_tick),
    }, "|")
    local duplicate = duplicate_operation(self, operation_id, signature)
    if duplicate ~= nil then return duplicate end
    local definition = self.definitions[unique_pal_id]
    local campaign = self.state.campaigns[unique_pal_id]
    if definition == nil or campaign == nil then
        return result(false, "unknown-unique-pal-campaign")
    end
    if logical_tick < self.state.logicalTick then
        return result(false, "logical-tick-regression")
    end
    local owner = sync_campaign_from_owner(self, unique_pal_id)
    if not owner_is_wild(owner) then
        return result(false, "unique-pal-already-owned", {
            owner = copy(owner),
        })
    end
    if campaign.phase ~= "closed" then
        return result(false, "unique-pal-opening-already-scheduled", {
            phase = campaign.phase,
            eventId = campaign.eventId,
        })
    end
    campaign.scheduleSequence = campaign.scheduleSequence + 1
    local event_id = string.format(
        "unique-pal-opening.%s.%d",
        unique_pal_id,
        campaign.scheduleSequence
    )
    local span = definition.schedule.maximumIntervalTicks
        - definition.schedule.minimumIntervalTicks + 1
    local interval = definition.schedule.minimumIntervalTicks
        + (stable_hash(event_id .. "|" .. operation_id) % span)
    campaign.phase = "scheduled"
    campaign.eventId = event_id
    campaign.noticeTick = logical_tick + interval
    campaign.openTick = campaign.noticeTick
        + definition.schedule.noticeTicks
    campaign.closeTick = campaign.openTick
        + definition.schedule.openTicks
    self.state.logicalTick = logical_tick
    local response = result(true, "unique-pal-opening-scheduled", {
        uniquePalId = unique_pal_id,
        eventId = event_id,
        noticeTick = campaign.noticeTick,
        openTick = campaign.openTick,
        closeTick = campaign.closeTick,
        intervalTicks = interval,
    })
    return commit_operation(self, operation_id, signature, response, {{
        type = "unique-pal-opening-scheduled",
        uniquePalId = unique_pal_id,
        eventId = event_id,
        noticeTick = campaign.noticeTick,
        openTick = campaign.openTick,
        closeTick = campaign.closeTick,
    }})
end

function UniquePalCampaign:advance(logical_tick, operation_id)
    non_empty(operation_id, "campaign advance operation ID")
    non_negative_integer(logical_tick, "campaign logical tick")
    local signature = "advance|" .. tostring(logical_tick)
    local duplicate = duplicate_operation(self, operation_id, signature)
    if duplicate ~= nil then return duplicate end
    if logical_tick < self.state.logicalTick then
        return result(false, "logical-tick-regression", {
            currentTick = self.state.logicalTick,
        })
    end
    self.state.logicalTick = logical_tick
    local events = {}
    local transitions = {}
    for _, unique_pal_id in ipairs(sorted_keys(self.definitions)) do
        local definition = self.definitions[unique_pal_id]
        local campaign = self.state.campaigns[unique_pal_id]
        local owner = current_owner(self, unique_pal_id)
        if not owner_is_wild(owner) then
            if campaign.phase ~= "owned"
                or owner_key(campaign.owner) ~= owner_key(owner) then
                campaign.phase = "owned"
                campaign.owner = copy(owner)
                campaign.eventId = nil
                campaign.noticeTick = nil
                campaign.openTick = nil
                campaign.closeTick = nil
                events[#events + 1] = {
                    type = "unique-pal-owner-synchronized",
                    uniquePalId = unique_pal_id,
                    owner = copy(owner),
                }
                transitions[#transitions + 1] = {
                    uniquePalId = unique_pal_id,
                    phase = "owned",
                }
            end
        else
            if campaign.phase == "scheduled"
                and logical_tick >= campaign.noticeTick then
                campaign.phase = "announced"
                events[#events + 1] = {
                    type = "unique-pal-opening-announced",
                    uniquePalId = unique_pal_id,
                    eventId = campaign.eventId,
                    openTick = campaign.openTick,
                    closeTick = campaign.closeTick,
                    notificationRequired = true,
                }
                transitions[#transitions + 1] = {
                    uniquePalId = unique_pal_id,
                    phase = "announced",
                }
            end
            if campaign.phase == "announced"
                and logical_tick >= campaign.openTick then
                campaign.phase = "activation-pending"
                events[#events + 1] = {
                    type = "unique-pal-boss-spawn-requested",
                    uniquePalId = unique_pal_id,
                    eventId = campaign.eventId,
                    bossSpeciesId = definition.boss.speciesId,
                    nativeBossSlotId = definition.boss.nativeBossSlotId,
                    strengthProfile = definition.boss.strengthProfile,
                    closeTick = campaign.closeTick,
                    nativeSpawnRequired = true,
                }
                transitions[#transitions + 1] = {
                    uniquePalId = unique_pal_id,
                    phase = "activation-pending",
                }
            end
            if campaign.phase == "open"
                and logical_tick >= campaign.closeTick then
                local assigned = select_assignment_faction(
                    self,
                    definition,
                    campaign.eventId
                )
                if assigned == nil then
                    local expired_event_id = campaign.eventId
                    campaign.phase = "closed"
                    campaign.eventId = nil
                    campaign.noticeTick = nil
                    campaign.openTick = nil
                    campaign.closeTick = nil
                    campaign.nativeSpawnId = nil
                    campaign.actorBindingId = nil
                    events[#events + 1] = {
                        type = "unique-pal-opening-expired-unassigned",
                        uniquePalId = unique_pal_id,
                        eventId = expired_event_id,
                        reason = "no-surviving-assignment-faction",
                        nativeDespawnRequired = true,
                    }
                    transitions[#transitions + 1] = {
                        uniquePalId = unique_pal_id,
                        phase = "closed",
                    }
                else
                    local expected = copy(owner)
                    local transferred = self.strategicWorld
                        :transfer_unique_pal(
                            unique_pal_id,
                            expected,
                            { kind = "faction", id = assigned },
                            campaign.eventId .. ":timeout-assignment",
                            {
                                reason = "unique-pal-opening-timeout",
                            }
                        )
                    if not transferred.ok then
                        return result(false,
                            "timeout-unique-pal-transfer-failed", {
                                uniquePalId = unique_pal_id,
                                strategicReason = transferred.reason,
                            })
                    end
                    local expired_event_id = campaign.eventId
                    campaign.phase = "owned"
                    campaign.owner = {
                        kind = "faction",
                        id = assigned,
                    }
                    campaign.eventId = nil
                    campaign.noticeTick = nil
                    campaign.openTick = nil
                    campaign.closeTick = nil
                    campaign.nativeSpawnId = nil
                    campaign.actorBindingId = nil
                    campaign.timeoutAssignmentCount =
                        campaign.timeoutAssignmentCount + 1
                    events[#events + 1] = {
                        type = "unique-pal-opening-expired-assigned",
                        uniquePalId = unique_pal_id,
                        eventId = expired_event_id,
                        factionId = assigned,
                        nativeDespawnRequired = true,
                        textNotificationRequired = true,
                    }
                    transitions[#transitions + 1] = {
                        uniquePalId = unique_pal_id,
                        phase = "owned",
                        owner = copy(campaign.owner),
                    }
                end
            end
        end
    end
    local response = result(true,
        #transitions > 0 and "unique-pal-campaign-advanced"
            or "unique-pal-campaign-no-transition", {
            logicalTick = logical_tick,
            transitions = copy(transitions),
            transitionCount = #transitions,
        })
    return commit_operation(self, operation_id, signature,
        response, events)
end

function UniquePalCampaign:confirm_boss_spawn(input)
    assert(type(input) == "table",
        "unique-Pal Boss spawn confirmation is required")
    local spawn_id = non_empty(input.spawnId,
        "unique-Pal Boss spawn ID")
    local unique_pal_id = stable_id(input.uniquePalId,
        "spawned unique Pal ID")
    local logical_tick = non_negative_integer(input.logicalTick,
        "Boss spawn logical tick")
    local signature = table.concat({
        "confirm-spawn",
        unique_pal_id,
        tostring(input.eventId),
        tostring(input.authoritySource),
        tostring(input.actorBindingId),
        tostring(logical_tick),
    }, "|")
    local duplicate = duplicate_operation(self, spawn_id, signature)
    if duplicate ~= nil then return duplicate end
    if input.authoritySource ~= BOSS_SPAWN_AUTHORITY then
        return result(false, "unique-pal-boss-spawn-authority-rejected")
    end
    non_empty(input.actorBindingId,
        "unique-Pal Boss actor binding ID")
    local definition = self.definitions[unique_pal_id]
    local campaign = self.state.campaigns[unique_pal_id]
    if definition == nil or campaign == nil then
        return result(false, "unknown-unique-pal-campaign")
    end
    if campaign.phase ~= "activation-pending" then
        return result(false, "unique-pal-boss-spawn-not-pending", {
            phase = campaign.phase,
        })
    end
    if input.eventId ~= campaign.eventId then
        return result(false, "unique-pal-boss-spawn-event-mismatch")
    end
    if logical_tick < self.state.logicalTick then
        return result(false, "logical-tick-regression")
    end
    local owner = current_owner(self, unique_pal_id)
    if not owner_is_wild(owner) then
        return result(false, "unique-pal-boss-spawn-owner-conflict", {
            owner = copy(owner),
        })
    end
    self.state.logicalTick = logical_tick
    campaign.phase = "open"
    campaign.nativeSpawnId = spawn_id
    campaign.actorBindingId = input.actorBindingId
    campaign.openTick = logical_tick
    campaign.closeTick = logical_tick + definition.schedule.openTicks
    local response = result(true, "unique-pal-opening-started", {
        uniquePalId = unique_pal_id,
        eventId = campaign.eventId,
        spawnId = spawn_id,
        actorBindingId = input.actorBindingId,
        openTick = campaign.openTick,
        closeTick = campaign.closeTick,
        strengthProfile = definition.boss.strengthProfile,
    })
    return commit_operation(self, spawn_id, signature, response, {{
        type = "unique-pal-opening-started",
        uniquePalId = unique_pal_id,
        eventId = campaign.eventId,
        spawnId = spawn_id,
        actorBindingId = input.actorBindingId,
        openTick = campaign.openTick,
        closeTick = campaign.closeTick,
        strengthProfile = definition.boss.strengthProfile,
    }})
end

function UniquePalCampaign:capture(input)
    assert(type(input) == "table", "unique-Pal capture input is required")
    local capture_id = non_empty(input.captureId,
        "unique-Pal capture ID")
    local unique_pal_id = stable_id(input.uniquePalId,
        "captured unique Pal ID")
    local signature = table.concat({
        "capture",
        unique_pal_id,
        tostring(input.eventId),
        tostring(input.playerId),
        tostring(input.authoritySource),
    }, "|")
    local duplicate = duplicate_operation(self, capture_id, signature)
    if duplicate ~= nil then return duplicate end
    if input.authoritySource ~= CAPTURE_AUTHORITY then
        return result(false, "unique-pal-capture-authority-rejected")
    end
    if input.playerId ~= self.playerId then
        return result(false, "unique-pal-capture-player-mismatch")
    end
    local campaign = self.state.campaigns[unique_pal_id]
    if campaign == nil then return result(false, "unknown-unique-pal-campaign") end
    if campaign.phase ~= "open" then
        return result(false, "unique-pal-capture-window-not-open", {
            phase = campaign.phase,
        })
    end
    if input.eventId ~= campaign.eventId then
        return result(false, "unique-pal-capture-event-mismatch")
    end
    local owner = current_owner(self, unique_pal_id)
    if not owner_is_wild(owner) then
        return result(false, "unique-pal-capture-owner-conflict", {
            owner = copy(owner),
        })
    end
    local transferred = self.strategicWorld:transfer_unique_pal(
        unique_pal_id,
        owner,
        { kind = "player", id = self.playerId },
        capture_id .. ":owner-transfer",
        { reason = "authoritative-native-capture" }
    )
    if not transferred.ok then
        return result(false, "unique-pal-capture-transfer-failed", {
            strategicReason = transferred.reason,
        })
    end
    local event_id = campaign.eventId
    campaign.phase = "owned"
    campaign.owner = { kind = "player", id = self.playerId }
    campaign.eventId = nil
    campaign.noticeTick = nil
    campaign.openTick = nil
    campaign.closeTick = nil
    campaign.nativeSpawnId = nil
    campaign.actorBindingId = nil
    campaign.captureCount = campaign.captureCount + 1
    local response = result(true, "unique-pal-captured-by-player", {
        uniquePalId = unique_pal_id,
        eventId = event_id,
        owner = copy(campaign.owner),
        nativeDespawnDuplicateRequired = true,
    })
    return commit_operation(self, capture_id, signature, response, {{
        type = "unique-pal-captured-by-player",
        uniquePalId = unique_pal_id,
        eventId = event_id,
        playerId = self.playerId,
        captureId = capture_id,
    }})
end

function UniquePalCampaign:sync_owner(unique_pal_id, operation_id, reason)
    stable_id(unique_pal_id, "unique Pal ID")
    non_empty(operation_id, "owner synchronization operation ID")
    local owner = current_owner(self, unique_pal_id)
    if owner == nil or self.state.campaigns[unique_pal_id] == nil then
        return result(false, "unknown-unique-pal-campaign")
    end
    local signature = "sync-owner|" .. unique_pal_id .. "|"
        .. owner_key(owner)
    local duplicate = duplicate_operation(self, operation_id, signature)
    if duplicate ~= nil then return duplicate end
    local campaign = self.state.campaigns[unique_pal_id]
    local previous = copy(campaign.owner)
    local changed = owner_key(previous) ~= owner_key(owner)
        or (owner_is_wild(owner) and campaign.phase == "owned")
        or (not owner_is_wild(owner) and campaign.phase ~= "owned")
    sync_campaign_from_owner(self, unique_pal_id)
    local events = {}
    if changed then
        events[1] = {
            type = "unique-pal-owner-synchronized",
            uniquePalId = unique_pal_id,
            previousOwner = previous,
            owner = copy(owner),
            sourceReason = reason,
        }
    end
    local response = result(true,
        changed and "unique-pal-owner-synchronized"
            or "unique-pal-owner-already-synchronized", {
            uniquePalId = unique_pal_id,
            owner = copy(owner),
            changed = changed,
        })
    return commit_operation(self, operation_id, signature,
        response, events)
end

function UniquePalCampaign:declare_destruction_war(
    unique_pal_id,
    war_id,
    logical_tick,
    operation_id
)
    stable_id(unique_pal_id, "unique Pal ID")
    non_empty(war_id, "destruction war ID")
    non_empty(operation_id, "destruction war operation ID")
    non_negative_integer(logical_tick, "destruction war logical tick")
    local signature = table.concat({
        "declare-war", unique_pal_id, war_id, tostring(logical_tick),
    }, "|")
    local duplicate = duplicate_operation(self, operation_id, signature)
    if duplicate ~= nil then return duplicate end
    local definition = self.definitions[unique_pal_id]
    local campaign = self.state.campaigns[unique_pal_id]
    if definition == nil or campaign == nil then
        return result(false, "unknown-unique-pal-campaign")
    end
    if self.state.wars[war_id] ~= nil then
        return result(false, "destruction-war-id-conflict")
    end
    if active_war_for_pal(self, unique_pal_id) ~= nil then
        return result(false, "unique-pal-destruction-war-already-active")
    end
    if logical_tick < self.state.logicalTick then
        return result(false, "logical-tick-regression")
    end
    local owner = current_owner(self, unique_pal_id)
    if owner == nil or owner.kind ~= "faction" then
        return result(false, "npc-faction-must-own-unique-pal", {
            owner = copy(owner),
        })
    end
    if faction_destroyed(self, owner.id) then
        return result(false, "destroyed-faction-cannot-declare-war")
    end
    for _, target_faction_id in ipairs(
        definition.target.affectedFactionIds) do
        if target_faction_id == owner.id then
            return result(false, "faction-cannot-destroy-itself")
        end
    end
    local target = self.state.targets[target_key(definition.target)]
    if target.status == "destroyed" then
        return result(false, "destruction-target-already-destroyed")
    end
    self.state.logicalTick = logical_tick
    local route = player_joined_target(self, definition.target)
        and "player-defense" or "background"
    local war = {
        id = war_id,
        uniquePalId = unique_pal_id,
        attackerFactionId = owner.id,
        targetKey = target.key,
        targetKind = target.kind,
        targetId = target.id,
        affectedFactionIds = copy(target.affectedFactionIds),
        route = route,
        status = "pending",
        declaredAtTick = logical_tick,
        resolutionId = nil,
        outcome = nil,
    }
    self.state.wars[war_id] = war
    campaign.activeWarId = war_id
    local response = result(true, "unique-pal-destruction-war-declared", {
        war = copy(war),
        playerDefenseRequired = route == "player-defense",
        textNotificationRequired = true,
        nativeRaidRequired = route == "player-defense",
        backgroundPresentationOnly = route == "background",
    })
    return commit_operation(self, operation_id, signature, response, {{
        type = "unique-pal-destruction-war-declared",
        warId = war_id,
        uniquePalId = unique_pal_id,
        attackerFactionId = owner.id,
        targetKey = target.key,
        route = route,
        textNotificationRequired = true,
    }})
end

function UniquePalCampaign:settle_destruction_war(input)
    assert(type(input) == "table",
        "destruction war result input is required")
    local war_id = non_empty(input.warId, "destruction war ID")
    local resolution_id = non_empty(input.resolutionId,
        "destruction war resolution ID")
    local signature = table.concat({
        "settle-war",
        war_id,
        tostring(input.authoritySource),
        tostring(input.attackerWon),
        tostring(input.playerParticipated),
        tostring(input.playerSideWon),
    }, "|")
    local duplicate = duplicate_operation(self, resolution_id, signature)
    if duplicate ~= nil then return duplicate end
    if input.authoritySource ~= WAR_RESULT_AUTHORITY then
        return result(false, "destruction-war-result-authority-rejected")
    end
    local war = self.state.wars[war_id]
    if war == nil then return result(false, "unknown-destruction-war") end
    if war.status ~= "pending" then
        return result(false, "destruction-war-already-settled", {
            war = copy(war),
        })
    end
    local owner = current_owner(self, war.uniquePalId)
    if owner == nil or owner.kind ~= "faction"
        or owner.id ~= war.attackerFactionId then
        return result(false, "destruction-war-unique-pal-owner-changed", {
            owner = copy(owner),
        })
    end
    local attacker_won = nil
    local player_victory = nil
    if war.route == "background" then
        if type(input.attackerWon) ~= "boolean" then
            return result(false,
                "background-war-attacker-result-required")
        end
        if input.playerParticipated ~= nil
            or input.playerSideWon ~= nil then
            return result(false,
                "background-war-cannot-contain-player-result")
        end
        attacker_won = input.attackerWon
    else
        if type(input.playerParticipated) ~= "boolean"
            or type(input.playerSideWon) ~= "boolean" then
            return result(false,
                "player-defense-result-required")
        end
        player_victory = input.playerParticipated
            and input.playerSideWon
        attacker_won = not player_victory
        if input.attackerWon ~= nil
            and input.attackerWon ~= attacker_won then
            return result(false,
                "player-defense-attacker-result-conflict")
        end
    end

    local destruction = nil
    if attacker_won then
        destruction = destroy_target(
            self,
            self.definitions[war.uniquePalId],
            war,
            resolution_id
        )
        if not destruction.ok then return destruction end
    end
    war.status = "resolved"
    war.resolutionId = resolution_id
    war.outcome = attacker_won and "target-destroyed"
        or "target-survived"
    war.playerParticipated = input.playerParticipated
    war.playerSideWon = input.playerSideWon
    local campaign = self.state.campaigns[war.uniquePalId]
    if campaign.activeWarId == war_id then campaign.activeWarId = nil end
    local response = result(true,
        attacker_won and "unique-pal-destruction-war-won"
            or "unique-pal-destruction-war-defended", {
            war = copy(war),
            targetDestroyed = attacker_won,
            playerVictory = player_victory,
            destruction = copy(destruction),
            textNotificationRequired = true,
        })
    return commit_operation(self, resolution_id, signature, response, {{
        type = attacker_won
            and "unique-pal-destruction-target-destroyed"
            or "unique-pal-destruction-target-survived",
        warId = war_id,
        uniquePalId = war.uniquePalId,
        attackerFactionId = war.attackerFactionId,
        targetKey = war.targetKey,
        route = war.route,
        playerParticipated = input.playerParticipated,
        playerSideWon = input.playerSideWon,
        resolutionId = resolution_id,
        textNotificationRequired = true,
    }})
end

function UniquePalCampaign:ransom_quote(unique_pal_id, player_id)
    stable_id(unique_pal_id, "unique Pal ID")
    if player_id ~= self.playerId then
        return result(false, "ransom-player-mismatch")
    end
    local definition = self.definitions[unique_pal_id]
    if definition == nil then return result(false, "unknown-unique-pal-campaign") end
    local owner = current_owner(self, unique_pal_id)
    if owner == nil or owner.kind ~= "faction" then
        return result(false, "unique-pal-not-held-by-ransom-faction", {
            owner = copy(owner),
        })
    end
    local target = self.state.targets[target_key(definition.target)]
    if target.status == "destroyed" then
        return result(false, "ransom-too-late-target-destroyed")
    end
    if not player_joined_target(self, definition.target) then
        return result(false, "ransom-requires-target-faction-membership")
    end
    return result(true, "unique-pal-ransom-available", {
        uniquePalId = unique_pal_id,
        holderFactionId = owner.id,
        playerId = self.playerId,
        currency = "Gold",
        amount = definition.ransomPrice,
        activeWarId = self.state.campaigns[unique_pal_id]
            .activeWarId,
        nativePaymentConfirmationRequired = true,
    })
end

function UniquePalCampaign:settle_ransom(input)
    assert(type(input) == "table", "ransom settlement input is required")
    local transaction_id = non_empty(input.transactionId,
        "ransom transaction ID")
    local unique_pal_id = stable_id(input.uniquePalId,
        "ransom unique Pal ID")
    local signature = table.concat({
        "ransom",
        unique_pal_id,
        tostring(input.playerId),
        tostring(input.authoritySource),
        tostring(input.currency),
        tostring(input.amount),
        tostring(input.paid),
    }, "|")
    local duplicate = duplicate_operation(self, transaction_id, signature)
    if duplicate ~= nil then return duplicate end
    if input.authoritySource ~= RANSOM_AUTHORITY then
        return result(false, "ransom-payment-authority-rejected")
    end
    if input.paid ~= true then
        return result(false, "ransom-payment-not-confirmed")
    end
    local quote = self:ransom_quote(unique_pal_id, input.playerId)
    if not quote.ok then return quote end
    if input.currency ~= quote.currency or input.amount ~= quote.amount then
        return result(false, "ransom-payment-amount-mismatch", {
            expectedCurrency = quote.currency,
            expectedAmount = quote.amount,
        })
    end
    local owner = { kind = "faction", id = quote.holderFactionId }
    local transferred = self.strategicWorld:transfer_unique_pal(
        unique_pal_id,
        owner,
        { kind = "player", id = self.playerId },
        transaction_id .. ":owner-transfer",
        { reason = "merchant-guild-ransom-payment-confirmed" }
    )
    if not transferred.ok then
        return result(false, "ransom-unique-pal-transfer-failed", {
            strategicReason = transferred.reason,
        })
    end
    local campaign = self.state.campaigns[unique_pal_id]
    local cancelled_war_id = campaign.activeWarId
    if cancelled_war_id ~= nil then
        local war = self.state.wars[cancelled_war_id]
        if war ~= nil and war.status == "pending" then
            war.status = "cancelled"
            war.resolutionId = transaction_id
            war.outcome = "cancelled-by-ransom"
        end
    end
    campaign.activeWarId = nil
    campaign.phase = "owned"
    campaign.owner = { kind = "player", id = self.playerId }
    campaign.ransomCount = campaign.ransomCount + 1
    local response = result(true, "unique-pal-ransom-settled", {
        uniquePalId = unique_pal_id,
        previousHolderFactionId = quote.holderFactionId,
        owner = copy(campaign.owner),
        currency = quote.currency,
        amount = quote.amount,
        cancelledWarId = cancelled_war_id,
        nativeDeliveryRequired = true,
        commerceReputationAward = 0,
    })
    return commit_operation(self, transaction_id, signature, response, {{
        type = "unique-pal-ransom-settled",
        uniquePalId = unique_pal_id,
        transactionId = transaction_id,
        previousHolderFactionId = quote.holderFactionId,
        playerId = self.playerId,
        amount = quote.amount,
        cancelledWarId = cancelled_war_id,
        commerceReputationAward = 0,
    }})
end

function UniquePalCampaign:boss_spawn_policy(species_id)
    non_empty(species_id, "Pal Boss species ID")
    local unique_pal_id = self.speciesIndex[species_id]
    if unique_pal_id == nil then
        return result(false, "non-unique-pal-boss-suppressed", {
            speciesId = species_id,
            suppressNativeBossSpawn = true,
        })
    end
    local definition = self.definitions[unique_pal_id]
    local campaign = self.state.campaigns[unique_pal_id]
    local authorized = campaign.phase == "activation-pending"
        or campaign.phase == "open"
    return result(authorized,
        campaign.phase == "activation-pending"
                and "unique-pal-boss-spawn-request-authorized"
            or campaign.phase == "open"
                and "unique-pal-boss-instance-authorized"
            or "unique-pal-boss-window-closed", {
            uniquePalId = unique_pal_id,
            speciesId = species_id,
            phase = campaign.phase,
            eventId = campaign.eventId,
            boss = copy(definition.boss),
            suppressNativeBossSpawn = not authorized,
        })
end

function UniquePalCampaign:faction_spawn_policy(faction_id, spawn_kind)
    stable_id(faction_id, "spawn faction ID")
    non_empty(spawn_kind, "faction spawn kind")
    if self.progression.factionKinds[faction_id] ~= "Human" then
        return result(false, "human-faction-required")
    end
    local destroyed = faction_destroyed(self, faction_id)
    return result(not destroyed,
        destroyed and "destroyed-faction-spawn-suppressed"
            or "faction-spawn-authorized", {
            factionId = faction_id,
            spawnKind = spawn_kind,
            destroyed = destroyed,
            suppressSpawn = destroyed,
        })
end

function UniquePalCampaign:merchant_spawn_policy(faction_id)
    local policy = self:faction_spawn_policy(
        faction_id,
        "merchant-guild-counter"
    )
    policy.merchantGuildCounter = true
    return policy
end

function UniquePalCampaign:campaign_status(unique_pal_id)
    local definition = self.definitions[unique_pal_id]
    local campaign = self.state.campaigns[unique_pal_id]
    if definition == nil or campaign == nil then return nil end
    local value = copy(campaign)
    value.definition = copy(definition)
    value.owner = copy(current_owner(self, unique_pal_id))
    if campaign.activeWarId ~= nil then
        value.activeWar = copy(self.state.wars[campaign.activeWarId])
    end
    return value
end

function UniquePalCampaign:target_status(kind, id)
    local key = non_empty(kind, "destruction target kind") .. ":"
        .. stable_id(id, "destruction target ID")
    local value = self.state.targets[key]
    return value and copy(value) or nil
end

function UniquePalCampaign:war_status(war_id)
    local value = self.state.wars[war_id]
    return value and copy(value) or nil
end

function UniquePalCampaign:status()
    local pack_count = 0
    local campaign_count = 0
    local open_count = 0
    local activation_pending_count = 0
    local pending_war_count = 0
    local destroyed_target_count = 0
    for _ in pairs(self.state.packs) do pack_count = pack_count + 1 end
    for _, campaign in pairs(self.state.campaigns) do
        campaign_count = campaign_count + 1
        if campaign.phase == "open" then open_count = open_count + 1 end
        if campaign.phase == "activation-pending" then
            activation_pending_count = activation_pending_count + 1
        end
    end
    for _, war in pairs(self.state.wars) do
        if war.status == "pending" then
            pending_war_count = pending_war_count + 1
        end
    end
    for _, target in pairs(self.state.targets) do
        if target.status == "destroyed" then
            destroyed_target_count = destroyed_target_count + 1
        end
    end
    return {
        apiVersion = self.version,
        schemaVersion = self.state.schemaVersion,
        packCount = pack_count,
        uniquePalCount = campaign_count,
        openCount = open_count,
        activationPendingCount = activation_pending_count,
        pendingWarCount = pending_war_count,
        destroyedTargetCount = destroyed_target_count,
        logicalTick = self.state.logicalTick,
        revision = self.state.revision,
        eventCount = self.state.eventCount,
        historyDropped = self.state.historyDropped,
        captureAuthority = CAPTURE_AUTHORITY,
        bossSpawnAuthority = BOSS_SPAWN_AUTHORITY,
        warResultAuthority = WAR_RESULT_AUTHORITY,
        ransomAuthority = RANSOM_AUTHORITY,
        lastNotificationError = self.lastNotificationError,
        capabilities = copy(self.capabilities),
    }
end

function UniquePalCampaign:export_snapshot()
    return copy(self.state)
end

return UniquePalCampaign
