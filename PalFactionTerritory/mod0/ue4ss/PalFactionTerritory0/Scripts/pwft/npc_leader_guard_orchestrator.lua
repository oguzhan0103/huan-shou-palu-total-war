local NpcLeaderGuardOrchestrator = {}

local API_VERSION = "1.0.0"
local SNAPSHOT_SCHEMA_VERSION = "1.0.0"

local EVENT_ACTIONS = {
    deploy = "deploy-guards",
    follow = "follow-leader",
    combat = "enter-combat",
    ["leader-death"] = "retire-guards",
    ["actor-unloaded"] = "despawn-guards",
    recall = "recall-guards",
}

local TERMINAL_EVENTS = {
    ["leader-death"] = true,
    ["actor-unloaded"] = true,
    recall = true,
}

local function copy(value)
    if type(value) ~= "table" then return value end
    local cloned = {}
    for key, item in pairs(value) do cloned[copy(key)] = copy(item) end
    return cloned
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

local function require_text(value, name)
    assert(type(value) == "string" and value ~= "", name .. " must be a non-empty string")
    return value
end

local function require_positive_integer(value, name)
    assert(type(value) == "number" and value > 0 and value % 1 == 0,
        name .. " must be a positive integer")
    return value
end

local function count(table_value)
    local total = 0
    for _ in pairs(table_value) do total = total + 1 end
    return total
end

local function operation_owners(results)
    local owners = {}
    for event_id, record in pairs(results or {}) do
        local operation_id = record.input and record.input.operationId
        if type(operation_id) == "string" and operation_id ~= "" then
            assert(owners[operation_id] == nil,
                "duplicate progression-backed leader guard operation ID")
            owners[operation_id] = event_id
        end
    end
    return owners
end

local function ensure_progression_state(faction_api)
    local progression = faction_api.progression
    if type(progression) ~= "table" or type(progression.state) ~= "table" then
        return nil
    end
    local state = progression.state.npcLeaderGuards
    if state == nil then
        state = {
            schemaVersion = SNAPSHOT_SCHEMA_VERSION,
            results = {},
        }
        progression.state.npcLeaderGuards = state
    end
    assert(state.schemaVersion == SNAPSHOT_SCHEMA_VERSION,
        "unsupported progression-backed leader guard state schema")
    state.results = state.results or {}
    return state
end

local function normalize_whitelist(options)
    assert(options.providerWhitelist == nil or type(options.providerWhitelist) == "table",
        "leader guard provider whitelist must be a table")
    local whitelist = {}
    for provider_id, authority_source in pairs(options.providerWhitelist or {}) do
        whitelist[require_text(provider_id, "whitelisted guard provider ID")] = require_text(
            authority_source,
            "whitelisted guard authority source"
        )
    end
    return whitelist
end

local function normalize_limits(source, defaults, prefix)
    source = source or {}
    assert(type(source) == "table", prefix .. " limits must be a table")
    local limits = {}
    for _, field in ipairs({ "perLeader", "perFaction", "perScene" }) do
        local value = source[field] or defaults[field]
        limits[field] = require_positive_integer(value, prefix .. " " .. field .. " limit")
        assert(limits[field] <= defaults[field], prefix .. " cannot exceed orchestrator " .. field .. " limit")
    end
    return limits
end

local function normalize_pack(instance, pack)
    assert(type(pack) == "table", "leader guard content pack is required")
    assert(pack.schemaVersion == "1.0.0", "unsupported leader guard content pack schema")
    local normalized = {
        schemaVersion = "1.0.0",
        contentPackId = require_text(pack.contentPackId, "leader guard content pack ID"),
        contentVersion = require_text(pack.contentVersion, "leader guard content version"),
        leaders = {},
    }
    assert(type(pack.leaders) == "table" and #pack.leaders > 0,
        "leader guard content pack leaders are required")
    local leader_ids = {}
    local formation_ids = {}
    for _, leader in ipairs(pack.leaders) do
        assert(type(leader) == "table", "leader guard leader definition must be a table")
        local leader_id = require_text(leader.leaderId, "leader ID")
        assert(not leader_ids[leader_id], "duplicate leader ID in content pack")
        assert(instance.leaders[leader_id] == nil
            or instance.leaders[leader_id].contentPackId == normalized.contentPackId,
            "leader ID is already owned by another content pack")
        leader_ids[leader_id] = true
        local faction_id = require_text(leader.factionId, "leader faction ID")
        local faction = instance.factionApi:faction_status(faction_id)
        assert(type(faction) == "table" and faction.kind == "Human",
            "NPC leader guards require a known human faction")
        local normalized_leader = {
            leaderId = leader_id,
            factionId = faction_id,
            actorClassKey = require_text(leader.actorClassKey, "leader actor class key"),
            formations = {},
        }
        assert(type(leader.formations) == "table" and #leader.formations > 0,
            "leader guard formations are required")
        for _, formation in ipairs(leader.formations) do
            assert(type(formation) == "table", "guard formation must be a table")
            local formation_id = require_text(formation.formationId, "guard formation ID")
            assert(not formation_ids[formation_id], "duplicate formation ID in content pack")
            assert(instance.formations[formation_id] == nil
                or instance.formations[formation_id].contentPackId == normalized.contentPackId,
                "formation ID is already owned by another content pack")
            formation_ids[formation_id] = true
            assert(type(formation.members) == "table" and #formation.members > 0,
                "guard formation members are required")
            local normalized_members = {}
            local total_members = 0
            local archetypes = {}
            for _, member in ipairs(formation.members) do
                assert(type(member) == "table", "guard formation member must be a table")
                local archetype_id = require_text(member.archetypeId, "guard archetype ID")
                assert(not archetypes[archetype_id], "duplicate guard archetype in formation")
                archetypes[archetype_id] = true
                local member_count = require_positive_integer(member.count, "guard member count")
                total_members = total_members + member_count
                table.insert(normalized_members, { archetypeId = archetype_id, count = member_count })
            end
            assert(total_members <= instance.maximumMembersPerFormation,
                "guard formation exceeds the orchestrator member limit")
            assert(type(formation.allowedSceneKinds) == "table"
                and #formation.allowedSceneKinds > 0,
                "guard formation scene kinds are required")
            local allowed_scenes = {}
            for _, scene_kind in ipairs(formation.allowedSceneKinds) do
                scene_kind = require_text(scene_kind, "guard scene kind")
                assert(not allowed_scenes[scene_kind], "duplicate guard scene kind")
                allowed_scenes[scene_kind] = true
            end
            table.insert(normalized_leader.formations, {
                formationId = formation_id,
                members = normalized_members,
                memberCount = total_members,
                allowedSceneKinds = allowed_scenes,
                limits = normalize_limits(
                    formation.limits,
                    instance.globalLimits,
                    "guard formation"
                ),
            })
        end
        table.insert(normalized.leaders, normalized_leader)
    end
    return normalized
end

local function index_pack(instance, pack)
    for _, leader in ipairs(pack.leaders) do
        local indexed_leader = copy(leader)
        indexed_leader.contentPackId = pack.contentPackId
        instance.leaders[leader.leaderId] = indexed_leader
        for _, formation in ipairs(leader.formations) do
            local indexed_formation = copy(formation)
            indexed_formation.contentPackId = pack.contentPackId
            indexed_formation.leaderId = leader.leaderId
            indexed_formation.factionId = leader.factionId
            instance.formations[formation.formationId] = indexed_formation
        end
    end
end

local function normalize_provider(instance, definition)
    assert(type(definition) == "table", "leader guard provider definition is required")
    local provider_id = require_text(definition.providerId, "leader guard provider ID")
    local authority_source = require_text(definition.authoritySource, "leader guard authority source")
    assert(instance.providerWhitelist[provider_id] == authority_source,
        "leader guard provider is not whitelisted")
    assert(type(definition.executeIntent) == "function",
        "leader guard provider must implement executeIntent")
    return {
        providerId = provider_id,
        authoritySource = authority_source,
        executeIntent = definition.executeIntent,
        enabled = definition.enabled ~= false,
    }
end

local function normalize_binding(instance, definition)
    assert(type(definition) == "table", "leader guard binding is required")
    local provider_id = require_text(definition.providerId, "leader binding provider ID")
    local provider = instance.providers[provider_id]
    assert(provider ~= nil and provider.enabled and type(provider.executeIntent) == "function",
        "leader guard provider is unavailable")
    local leader_id = require_text(definition.leaderId, "leader binding leader ID")
    local leader = instance.leaders[leader_id]
    assert(leader ~= nil, "leader binding references an unknown content leader")
    assert(definition.actorClassKey == leader.actorClassKey,
        "leader actor class does not exactly match the content definition")
    return {
        bindingId = require_text(definition.bindingId, "leader binding ID"),
        providerId = provider_id,
        leaderId = leader_id,
        factionId = leader.factionId,
        actorKey = require_text(definition.actorKey, "leader actor key"),
        actorClassKey = leader.actorClassKey,
        leaderRef = definition.leaderRef,
    }
end

local function same_event(first, second)
    return first.providerId == second.providerId
        and first.authoritySource == second.authoritySource
        and first.eventKind == second.eventKind
        and first.operationId == second.operationId
        and first.bindingId == second.bindingId
        and first.leaderId == second.leaderId
        and first.actorKey == second.actorKey
        and first.actorClassKey == second.actorClassKey
        and first.deploymentId == second.deploymentId
        and first.formationId == second.formationId
        and first.sceneId == second.sceneId
        and first.sceneKind == second.sceneKind
end

local function normalize_event(instance, event)
    assert(type(event) == "table", "leader guard event is required")
    assert(event.schemaVersion == "1.0.0", "unsupported leader guard event schema")
    assert(event.authoritative == true, "leader guard event must be authoritative")
    local provider_id = require_text(event.providerId, "leader guard event provider ID")
    local provider = instance.providers[provider_id]
    assert(provider ~= nil and provider.enabled and type(provider.executeIntent) == "function",
        "leader guard event provider is unavailable")
    assert(event.authoritySource == provider.authoritySource,
        "leader guard event authority source is not trusted")
    local binding_id = require_text(event.bindingId, "leader guard event binding ID")
    local binding = instance.bindings[binding_id]
    assert(binding ~= nil and binding.providerId == provider_id,
        "leader guard event binding is unavailable")
    assert(event.actorKey == binding.actorKey, "leader actor does not exactly match the binding")
    assert(event.actorClassKey == binding.actorClassKey,
        "leader actor class does not exactly match the binding")
    local event_kind = require_text(event.eventKind, "leader guard event kind")
    assert(EVENT_ACTIONS[event_kind] ~= nil, "unsupported leader guard event kind")
    local normalized = {
        schemaVersion = "1.0.0",
        authoritative = true,
        providerId = provider_id,
        authoritySource = event.authoritySource,
        eventKind = event_kind,
        eventId = require_text(event.eventId, "leader guard event ID"),
        operationId = require_text(event.operationId, "leader guard operation ID"),
        bindingId = binding_id,
        leaderId = binding.leaderId,
        factionId = binding.factionId,
        actorKey = binding.actorKey,
        actorClassKey = binding.actorClassKey,
        deploymentId = require_text(event.deploymentId, "guard deployment ID"),
        formationId = event.formationId,
        sceneId = event.sceneId,
        sceneKind = event.sceneKind,
    }
    if event_kind == "deploy" then
        normalized.formationId = require_text(event.formationId, "guard formation ID")
        normalized.sceneId = require_text(event.sceneId, "guard scene ID")
        normalized.sceneKind = require_text(event.sceneKind, "guard scene kind")
        local formation = instance.formations[normalized.formationId]
        assert(formation ~= nil and formation.leaderId == binding.leaderId,
            "guard formation does not belong to the bound leader")
        assert(formation.allowedSceneKinds[normalized.sceneKind],
            "guard formation is not allowed in this scene kind")
    else
        local active = instance.activeDeployments[normalized.deploymentId]
        assert(active ~= nil, "guard deployment is not active")
        assert(active.bindingId == binding_id and active.leaderId == binding.leaderId,
            "guard deployment does not belong to the exact leader binding")
        normalized.formationId = active.formationId
        normalized.sceneId = active.sceneId
        normalized.sceneKind = active.sceneKind
    end
    return normalized, binding, provider
end

local function active_counts(instance, event)
    local counts = { leader = 0, faction = 0, scene = 0 }
    for _, active in pairs(instance.activeDeployments) do
        if active.leaderId == event.leaderId then counts.leader = counts.leader + 1 end
        if active.factionId == event.factionId then counts.faction = counts.faction + 1 end
        if active.sceneId == event.sceneId then counts.scene = counts.scene + 1 end
    end
    return counts
end

local function normalize_snapshot(snapshot)
    assert(type(snapshot) == "table", "leader guard snapshot is required")
    assert(snapshot.schemaVersion == SNAPSHOT_SCHEMA_VERSION,
        "unsupported leader guard snapshot schema")
    assert(type(snapshot.packs) == "table" and type(snapshot.providers) == "table"
        and type(snapshot.results) == "table",
        "leader guard snapshot is incomplete")
    local restored = {
        packs = copy(snapshot.packs),
        providers = {},
        results = copy(snapshot.results),
        -- World-lifetime deployments are intentionally never restored. A
        -- content module must rediscover/bind leaders and deploy again.
        activeDeployments = {},
        operationOwners = {},
    }
    for _, definition in ipairs(snapshot.providers) do
        local provider_id = require_text(definition.providerId, "restored guard provider ID")
        assert(restored.providers[provider_id] == nil, "duplicate restored guard provider")
        restored.providers[provider_id] = {
            providerId = provider_id,
            authoritySource = require_text(definition.authoritySource,
                "restored guard provider authority source"),
            enabled = definition.enabled ~= false,
            executeIntent = nil,
        }
    end
    for event_id, record in pairs(restored.results) do
        require_text(event_id, "restored guard event ID")
        assert(type(record) == "table" and type(record.input) == "table"
            and type(record.outcome) == "table", "restored guard event result is invalid")
        local operation_id = require_text(record.input.operationId, "restored guard operation ID")
        assert(restored.operationOwners[operation_id] == nil,
            "duplicate restored guard operation ID")
        restored.operationOwners[operation_id] = event_id
    end
    return restored
end

function NpcLeaderGuardOrchestrator.create(faction_api, options)
    assert(type(faction_api) == "table" and type(faction_api.faction_status) == "function",
        "faction API is required")
    options = options or {}
    local global_limits = {
        perLeader = require_positive_integer(options.maxPerLeader or 2,
            "orchestrator per-leader limit"),
        perFaction = require_positive_integer(options.maxPerFaction or 6,
            "orchestrator per-faction limit"),
        perScene = require_positive_integer(options.maxPerScene or 12,
            "orchestrator per-scene limit"),
    }
    local progression_state = options.snapshot == nil
        and ensure_progression_state(faction_api) or nil
    local restored = options.snapshot and normalize_snapshot(options.snapshot) or {
        packs = {}, providers = {}, results = {}, activeDeployments = {}, operationOwners = {},
    }
    if progression_state ~= nil then
        restored.results = progression_state.results
        restored.operationOwners = operation_owners(restored.results)
    end
    local instance = setmetatable({
        version = API_VERSION,
        factionApi = faction_api,
        providerWhitelist = normalize_whitelist(options),
        providers = restored.providers,
        bindings = {},
        packs = restored.packs,
        leaders = {},
        formations = {},
        activeDeployments = restored.activeDeployments,
        results = restored.results,
        operationOwners = restored.operationOwners,
        progressionState = progression_state,
        globalLimits = global_limits,
        maximumMembersPerFormation = require_positive_integer(
            options.maximumMembersPerFormation or 16,
            "maximum members per formation"
        ),
        acceptedCount = 0,
        rejectedCount = 0,
        duplicateCount = 0,
        capabilities = {
            contentDefinedLeadersAndFormations = true,
            storyContentIncluded = false,
            exactLeaderBinding = true,
            leaderFactionSceneLimits = true,
            deployFollowCombatDeathUnloadRecallIntents = true,
            providerWhitelist = true,
            providerFailureFailClosed = true,
            serializableRestoreWithoutUObjects = true,
            progressionSidecarIdempotency = progression_state ~= nil,
            nativeMutationDelegatedToProvider = true,
            PalworldSaveMutation = false,
        },
    }, { __index = NpcLeaderGuardOrchestrator })
    for _, pack in pairs(instance.packs) do index_pack(instance, pack) end
    local progression = faction_api.progression
    if type(progression) == "table"
        and type(progression.register_restore_listener) == "function" then
        local registered = progression:register_restore_listener(
            "pwft.npc-leader-guard-orchestrator.v1",
            function() return instance:rebind_progression_state() end
        )
        assert(registered.ok, registered.reason)
    end
    return instance
end

function NpcLeaderGuardOrchestrator:rebind_progression_state()
    local ok, state = pcall(ensure_progression_state, self.factionApi)
    if not ok then
        return result(false, "leader-guard-snapshot-invalid", {
            error = tostring(state),
        })
    end
    self.progressionState = state
    if state ~= nil then
        self.results = state.results
        self.operationOwners = operation_owners(self.results)
    end
    -- These structures can carry UObject references and world-only lifecycle
    -- state. Content packs remain data-only and can be registered idempotently
    -- again, but actors and deployments must be rediscovered.
    self.bindings = {}
    self.activeDeployments = {}
    return result(true, "leader-guard-progression-state-rebound")
end

function NpcLeaderGuardOrchestrator:register_content_pack(pack)
    local ok, normalized = pcall(normalize_pack, self, pack)
    if not ok then
        self.rejectedCount = self.rejectedCount + 1
        return result(false, "invalid-leader-guard-content-pack", {
            validationError = tostring(normalized),
        })
    end
    local existing = self.packs[normalized.contentPackId]
    if existing ~= nil then
        if deep_equal(existing, normalized) then
            return result(true, "leader-guard-content-pack-already-registered", {
                contentPackId = normalized.contentPackId,
            })
        end
        return result(false, "leader-guard-content-pack-id-conflict", {
            contentPackId = normalized.contentPackId,
        })
    end
    self.packs[normalized.contentPackId] = copy(normalized)
    index_pack(self, normalized)
    return result(true, "leader-guard-content-pack-registered", {
        contentPackId = normalized.contentPackId,
        leaderCount = #normalized.leaders,
    })
end

function NpcLeaderGuardOrchestrator:register_provider(definition)
    local ok, provider = pcall(normalize_provider, self, definition)
    if not ok then
        self.rejectedCount = self.rejectedCount + 1
        return result(false, "invalid-leader-guard-provider", { validationError = tostring(provider) })
    end
    local existing = self.providers[provider.providerId]
    if existing ~= nil then
        if existing.authoritySource ~= provider.authoritySource then
            self.rejectedCount = self.rejectedCount + 1
            return result(false, "leader-guard-provider-id-conflict")
        end
        existing.executeIntent = provider.executeIntent
        existing.enabled = provider.enabled
        return result(true, "leader-guard-provider-ready", { providerId = provider.providerId })
    end
    self.providers[provider.providerId] = provider
    return result(true, "leader-guard-provider-registered", { providerId = provider.providerId })
end

function NpcLeaderGuardOrchestrator:bind_leader(definition)
    local ok, binding = pcall(normalize_binding, self, definition)
    if not ok then
        self.rejectedCount = self.rejectedCount + 1
        return result(false, "invalid-leader-guard-binding", { validationError = tostring(binding) })
    end
    local existing = self.bindings[binding.bindingId]
    if existing ~= nil then
        if existing.providerId ~= binding.providerId or existing.leaderId ~= binding.leaderId
            or existing.actorKey ~= binding.actorKey or existing.actorClassKey ~= binding.actorClassKey then
            self.rejectedCount = self.rejectedCount + 1
            return result(false, "leader-guard-binding-id-conflict")
        end
        existing.leaderRef = binding.leaderRef
        return result(true, "leader-guard-leader-rebound", { bindingId = binding.bindingId })
    end
    self.bindings[binding.bindingId] = binding
    return result(true, "leader-guard-leader-bound", {
        bindingId = binding.bindingId,
        leaderId = binding.leaderId,
    })
end

function NpcLeaderGuardOrchestrator:unbind_leader(definition)
    assert(type(definition) == "table", "leader unbinding is required")
    local binding_id = require_text(definition.bindingId,
        "leader unbinding ID")
    local existing = self.bindings[binding_id]
    if existing == nil then
        return result(true, "leader-guard-leader-already-unbound", {
            bindingId = binding_id,
        })
    end
    if definition.providerId ~= nil
        and definition.providerId ~= existing.providerId then
        return result(false, "leader-guard-unbinding-provider-mismatch")
    end
    if definition.actorKey ~= nil
        and definition.actorKey ~= existing.actorKey then
        return result(false, "leader-guard-unbinding-actor-mismatch")
    end
    if definition.actorClassKey ~= nil
        and definition.actorClassKey ~= existing.actorClassKey then
        return result(false, "leader-guard-unbinding-class-mismatch")
    end
    for _, active in pairs(self.activeDeployments) do
        if active.bindingId == binding_id then
            return result(false, "leader-guard-binding-has-active-deployment", {
                bindingId = binding_id,
                deploymentId = active.deploymentId,
            })
        end
    end
    self.bindings[binding_id] = nil
    return result(true, "leader-guard-leader-unbound", {
        bindingId = binding_id,
        leaderId = existing.leaderId,
    })
end

function NpcLeaderGuardOrchestrator:ingest(event)
    local ok, normalized, binding, provider = pcall(normalize_event, self, event)
    if not ok then
        self.rejectedCount = self.rejectedCount + 1
        return result(false, "invalid-leader-guard-event", {
            validationError = tostring(normalized), stateChanged = false,
        })
    end
    local existing = self.results[normalized.eventId]
    if existing ~= nil then
        if not same_event(existing.input, normalized) then
            self.rejectedCount = self.rejectedCount + 1
            return result(false, "leader-guard-event-id-conflict", { stateChanged = false })
        end
        self.duplicateCount = self.duplicateCount + 1
        local duplicate = copy(existing.outcome)
        duplicate.duplicateOfReason = duplicate.reason
        duplicate.reason = "duplicate-leader-guard-event"
        duplicate.stateChanged = false
        duplicate.idempotent = true
        return duplicate
    end
    local operation_owner = self.operationOwners[normalized.operationId]
    if operation_owner ~= nil and operation_owner ~= normalized.eventId then
        self.rejectedCount = self.rejectedCount + 1
        return result(false, "leader-guard-operation-id-conflict", { stateChanged = false })
    end

    local formation = self.formations[normalized.formationId]
    if normalized.eventKind == "deploy" then
        if self.activeDeployments[normalized.deploymentId] ~= nil then
            return result(false, "leader-guard-deployment-id-conflict", { stateChanged = false })
        end
        local active = active_counts(self, normalized)
        if active.leader >= formation.limits.perLeader then
            return result(false, "leader-guard-per-leader-limit", { stateChanged = false })
        elseif active.faction >= formation.limits.perFaction then
            return result(false, "leader-guard-per-faction-limit", { stateChanged = false })
        elseif active.scene >= formation.limits.perScene then
            return result(false, "leader-guard-per-scene-limit", { stateChanged = false })
        end
    end

    local intent = {
        schemaVersion = "1.0.0",
        kind = EVENT_ACTIONS[normalized.eventKind],
        eventKind = normalized.eventKind,
        eventId = normalized.eventId,
        operationId = normalized.operationId,
        deploymentId = normalized.deploymentId,
        bindingId = normalized.bindingId,
        leaderId = normalized.leaderId,
        factionId = normalized.factionId,
        leaderActorKey = normalized.actorKey,
        leaderActorClassKey = normalized.actorClassKey,
        formationId = normalized.formationId,
        members = formation and copy(formation.members) or nil,
        memberCount = formation and formation.memberCount or nil,
        sceneId = normalized.sceneId,
        sceneKind = normalized.sceneKind,
        PalworldSaveMutation = false,
    }
    local invoked, provider_result = pcall(provider.executeIntent, copy(intent), binding.leaderRef)
    if not invoked or type(provider_result) ~= "table" or provider_result.ok ~= true then
        self.rejectedCount = self.rejectedCount + 1
        return result(false, "leader-guard-provider-failed", {
            retryable = true,
            detail = invoked and copy(provider_result) or tostring(provider_result),
            intent = copy(intent),
            stateChanged = false,
        })
    end

    if normalized.eventKind == "deploy" then
        self.activeDeployments[normalized.deploymentId] = {
            deploymentId = normalized.deploymentId,
            bindingId = normalized.bindingId,
            leaderId = normalized.leaderId,
            factionId = normalized.factionId,
            formationId = normalized.formationId,
            sceneId = normalized.sceneId,
            sceneKind = normalized.sceneKind,
            phase = "following",
        }
    elseif TERMINAL_EVENTS[normalized.eventKind] then
        self.activeDeployments[normalized.deploymentId] = nil
        if normalized.eventKind == "leader-death"
            or normalized.eventKind == "actor-unloaded" then
            self.bindings[normalized.bindingId] = nil
        end
    else
        self.activeDeployments[normalized.deploymentId].phase = normalized.eventKind
    end
    local outcome = result(true, "leader-guard-intent-applied", {
        eventId = normalized.eventId,
        operationId = normalized.operationId,
        eventKind = normalized.eventKind,
        deploymentId = normalized.deploymentId,
        providerResult = copy(provider_result),
        intent = copy(intent),
        active = self.activeDeployments[normalized.deploymentId] ~= nil,
        stateChanged = true,
        PalworldSaveMutation = false,
    })
    local persisted_outcome = copy(outcome)
    -- Native adapters may return character handles. Expose them only in the
    -- immediate response and keep the persisted ledger data-only.
    persisted_outcome.providerResult = nil
    self.results[normalized.eventId] = {
        input = copy(normalized),
        outcome = persisted_outcome,
    }
    self.operationOwners[normalized.operationId] = normalized.eventId
    if self.progressionState ~= nil then
        self.progressionState.results = self.results
    end
    self.acceptedCount = self.acceptedCount + 1
    return outcome
end

function NpcLeaderGuardOrchestrator:clear_world()
    local removed_bindings = count(self.bindings)
    local abandoned_deployments = count(self.activeDeployments)
    self.bindings = {}
    self.activeDeployments = {}
    return result(true, "leader-guard-world-cleared", {
        removedBindingCount = removed_bindings,
        abandonedDeploymentCount = abandoned_deployments,
    })
end

function NpcLeaderGuardOrchestrator:status()
    local ready = 0
    for _, provider in pairs(self.providers) do
        if provider.enabled and type(provider.executeIntent) == "function" then ready = ready + 1 end
    end
    return {
        apiVersion = self.version,
        contentPackCount = count(self.packs),
        leaderCount = count(self.leaders),
        formationCount = count(self.formations),
        providerCount = count(self.providers),
        readyProviderCount = ready,
        bindingCount = count(self.bindings),
        activeDeploymentCount = count(self.activeDeployments),
        resultCount = count(self.results),
        acceptedCount = self.acceptedCount,
        rejectedCount = self.rejectedCount,
        duplicateCount = self.duplicateCount,
        bindingsPersisted = false,
        activeDeploymentsPersisted = false,
        progressionSidecarIdempotency = self.progressionState ~= nil,
        serializableStateOnly = true,
        PalworldSaveMutation = false,
    }
end

function NpcLeaderGuardOrchestrator:export_snapshot()
    local providers = {}
    for _, provider in pairs(self.providers) do
        table.insert(providers, {
            providerId = provider.providerId,
            authoritySource = provider.authoritySource,
            enabled = provider.enabled,
        })
    end
    table.sort(providers, function(first, second) return first.providerId < second.providerId end)
    return {
        schemaVersion = SNAPSHOT_SCHEMA_VERSION,
        providers = providers,
        packs = copy(self.packs),
        results = copy(self.results),
    }
end

return NpcLeaderGuardOrchestrator
