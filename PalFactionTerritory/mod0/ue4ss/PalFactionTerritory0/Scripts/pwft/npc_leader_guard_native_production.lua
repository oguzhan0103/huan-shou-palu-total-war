local NpcLeaderGuardNativeProduction = {}

local API_VERSION = "1.0.0"

local TERMINAL_KINDS = {
    ["retire-guards"] = true,
    ["despawn-guards"] = true,
    ["recall-guards"] = true,
}

local function result(ok, reason, extra)
    local value = extra or {}
    value.ok = ok
    value.reason = reason
    return value
end

local function copy(value)
    if type(value) ~= "table" then return value end
    local cloned = {}
    for key, child in pairs(value) do cloned[copy(key)] = copy(child) end
    return cloned
end

local function require_text(value, name)
    assert(type(value) == "string" and value ~= "",
        name .. " must be a non-empty string")
    return value
end

local function count(values)
    local total = 0
    for _ in pairs(values or {}) do total = total + 1 end
    return total
end

local function is_valid(actor)
    if actor == nil then return false end
    local ok, valid = pcall(function() return actor:IsValid() end)
    return not ok or valid ~= false
end

local function safe_full_name(actor)
    if actor == nil then return "<nil>" end
    local ok, value = pcall(function() return actor:GetFullName() end)
    if ok and type(value) == "string" and value ~= "" then return value end
    return tostring(actor)
end

local function class_token(class_key)
    if type(class_key) ~= "string" then return nil end
    local token = string.match(class_key, "%.([%w_]+)$")
        or string.match(class_key, "([%w_]+)$")
    return token
end

local function actor_location(actor)
    local ok, value = pcall(function() return actor:K2_GetActorLocation() end)
    if ok and type(value) == "table"
        and type(value.X) == "number"
        and type(value.Y) == "number"
        and type(value.Z) == "number" then
        return { X = value.X, Y = value.Y, Z = value.Z }
    end
    local fallback = type(actor) == "table" and actor.location or nil
    if type(fallback) == "table"
        and type(fallback.X) == "number"
        and type(fallback.Y) == "number"
        and type(fallback.Z) == "number" then
        return { X = fallback.X, Y = fallback.Y, Z = fallback.Z }
    end
    return nil
end

local function actor_rotation(actor)
    local ok, value = pcall(function() return actor:K2_GetActorRotation() end)
    if ok and type(value) == "table" then
        return {
            Pitch = tonumber(value.Pitch) or 0,
            Yaw = tonumber(value.Yaw) or 0,
            Roll = tonumber(value.Roll) or 0,
        }
    end
    return { Pitch = 0, Yaw = 0, Roll = 0 }
end

local function normalize_archetype(source)
    assert(type(source) == "table", "guard archetype definition is required")
    return {
        archetypeId = require_text(source.archetypeId,
            "guard archetype ID"),
        characterId = require_text(source.characterId,
            "guard archetype character ID"),
        characterClassPath = require_text(source.characterClassPath,
            "guard archetype character class path"),
        controllerClassPath = source.controllerClassPath,
    }
end

local function same_archetype(left, right)
    return left.archetypeId == right.archetypeId
        and left.characterId == right.characterId
        and left.characterClassPath == right.characterClassPath
        and left.controllerClassPath == right.controllerClassPath
end

function NpcLeaderGuardNativeProduction.create(
    orchestrator,
    native_character_adapter,
    config,
    options
)
    assert(type(orchestrator) == "table"
        and type(orchestrator.register_provider) == "function"
        and type(orchestrator.bind_leader) == "function"
        and type(orchestrator.unbind_leader) == "function",
        "NPC leader guard orchestrator is required")
    assert(type(native_character_adapter) == "table"
        and type(native_character_adapter.create_guard_provider) == "function",
        "native character adapter is required")
    config = config or {}
    options = options or {}
    local instance = setmetatable({
        version = API_VERSION,
        orchestrator = orchestrator,
        nativeCharacterAdapter = native_character_adapter,
        enabled = config.enabled ~= false,
        providerId = config.providerId
            or "pwft.native.NPC-leader-guard.production",
        authoritySource = config.authoritySource
            or "pwft.native.NPC-leader-guard.authority",
        spawnRadius = tonumber(config.spawnRadius) or 220,
        spawnVerticalOffset = tonumber(config.spawnVerticalOffset) or 10,
        archetypesById = {},
        bindingsById = {},
        deploymentsById = {},
        spawnPolicyResolver = options.spawnPolicyResolver,
        logger = options.logger,
        active = false,
        activationCount = 0,
        bindCount = 0,
        unbindCount = 0,
        deployCount = 0,
        cleanupCount = 0,
        rollbackCount = 0,
        suppressedCount = 0,
        lastError = nil,
    }, { __index = NpcLeaderGuardNativeProduction })
    assert(instance.spawnRadius >= 0,
        "NPC leader guard spawn radius cannot be negative")
    assert(type(instance.spawnPolicyResolver) == "nil"
        or type(instance.spawnPolicyResolver) == "function",
        "NPC leader guard spawn policy resolver must be a function")
    return instance
end

function NpcLeaderGuardNativeProduction:_log(message)
    if type(self.logger) == "function" then
        self.logger("[PalFactionTerritory0][NpcLeaderGuardNative] "
            .. tostring(message))
    end
end

function NpcLeaderGuardNativeProduction:activate(archetypes)
    if not self.enabled then
        return result(false, "native-NPC-leader-guard-production-disabled")
    end
    assert(type(archetypes) == "table",
        "NPC leader guard native archetypes must be a table")
    for _, definition in ipairs(archetypes) do
        local registered = self:register_archetype(definition)
        if not registered.ok then return registered end
    end
    local registered = self.orchestrator:register_provider({
        providerId = self.providerId,
        authoritySource = self.authoritySource,
        enabled = true,
        executeIntent = function(intent, leader_ref)
            return self:_execute_intent(intent, leader_ref)
        end,
    })
    if not registered.ok then
        self.lastError = registered.reason
        return registered
    end
    self.active = true
    self.activationCount = self.activationCount + 1
    self.lastError = nil
    return result(true, "native-NPC-leader-guard-production-activated", {
        providerId = self.providerId,
        archetypeCount = count(self.archetypesById),
        storyContentIncluded = false,
    })
end

function NpcLeaderGuardNativeProduction:register_archetype(source)
    local ok, definition = pcall(normalize_archetype, source)
    if not ok then
        return result(false, "invalid-native-NPC-leader-guard-archetype", {
            validationError = tostring(definition),
        })
    end
    local existing = self.archetypesById[definition.archetypeId]
    if existing ~= nil then
        if same_archetype(existing, definition) then
            return result(true,
                "native-NPC-leader-guard-archetype-already-registered", {
                    archetypeId = definition.archetypeId,
                })
        end
        return result(false,
            "native-NPC-leader-guard-archetype-id-conflict")
    end
    self.archetypesById[definition.archetypeId] = definition
    return result(true, "native-NPC-leader-guard-archetype-registered", {
        archetypeId = definition.archetypeId,
    })
end

function NpcLeaderGuardNativeProduction:bind_leader(definition)
    if not self.active then
        return result(false, "native-NPC-leader-guard-production-inactive")
    end
    assert(type(definition) == "table",
        "native NPC leader guard binding is required")
    local binding_id = require_text(definition.bindingId,
        "native NPC leader guard binding ID")
    local leader_id = require_text(definition.leaderId,
        "native NPC leader ID")
    local leader = self.orchestrator.leaders[leader_id]
    if leader == nil then
        return result(false, "native-NPC-leader-guard-content-leader-unavailable")
    end
    local actor = definition.actorRef
    if not is_valid(actor) then
        return result(false, "native-NPC-leader-guard-actor-unavailable")
    end
    local actor_key = definition.actorKey or safe_full_name(actor)
    local actor_class_key = definition.actorClassKey
        or leader.actorClassKey
    local expected_token = class_token(leader.actorClassKey)
    if expected_token == nil
        or string.find(safe_full_name(actor), expected_token, 1, true) == nil then
        return result(false, "native-NPC-leader-guard-class-mismatch", {
            expectedActorClassKey = leader.actorClassKey,
            actualActorKey = safe_full_name(actor),
        })
    end
    local existing = self.bindingsById[binding_id]
    if existing ~= nil
        and (existing.actorKey ~= actor_key
            or existing.actorClassKey ~= actor_class_key) then
        local unbound = self:unbind_leader(binding_id)
        if not unbound.ok then return unbound end
    end
    local bound = self.orchestrator:bind_leader({
        bindingId = binding_id,
        providerId = self.providerId,
        leaderId = leader_id,
        actorKey = actor_key,
        actorClassKey = actor_class_key,
        leaderRef = actor,
    })
    if not bound.ok then
        self.lastError = bound.reason
        return bound
    end
    self.bindingsById[binding_id] = {
        bindingId = binding_id,
        leaderId = leader_id,
        factionId = leader.factionId,
        actorKey = actor_key,
        actorClassKey = actor_class_key,
        actorRef = actor,
    }
    self.bindCount = self.bindCount + 1
    self.lastError = nil
    self:_log(string.format(
        "LEADER_BOUND binding=%s leader=%s faction=%s actor=%s",
        binding_id, leader_id, leader.factionId, actor_key
    ))
    return result(true, "native-NPC-leader-guard-leader-bound", {
        bindingId = binding_id,
        leaderId = leader_id,
        factionId = leader.factionId,
        actorKey = actor_key,
    })
end

function NpcLeaderGuardNativeProduction:_expanded_archetypes(intent)
    local expanded = {}
    for _, member in ipairs(intent.members or {}) do
        local archetype = self.archetypesById[member.archetypeId]
        if archetype == nil then
            return nil, "native-NPC-leader-guard-archetype-unavailable:"
                .. tostring(member.archetypeId)
        end
        for _ = 1, member.count do expanded[#expanded + 1] = archetype end
    end
    if #expanded == 0 then
        return nil, "native-NPC-leader-guard-empty-formation"
    end
    return expanded, nil
end

function NpcLeaderGuardNativeProduction:_spawn_location(
    origin,
    index,
    total
)
    local angle = (index - 1) * (math.pi * 2 / math.max(total, 1))
    return {
        X = origin.X + math.cos(angle) * self.spawnRadius,
        Y = origin.Y + math.sin(angle) * self.spawnRadius,
        Z = origin.Z + self.spawnVerticalOffset,
    }
end

function NpcLeaderGuardNativeProduction:_cleanup_deployment(
    deployment_id,
    reason,
    rollback
)
    local deployment = self.deploymentsById[deployment_id]
    if deployment == nil then
        return result(true,
            "native-NPC-leader-guard-deployment-already-clean", {
                deploymentId = deployment_id,
                removedCount = 0,
            })
    end
    deployment.closing = true
    local removed, failed = 0, 0
    for _, member in ipairs(deployment.members) do
        if member.terminated ~= true then
            local ok, recalled = pcall(member.provider.recall,
                member.handle, reason or "NPC-leader-guard-cleanup")
            if ok and recalled ~= false then
                removed = removed + 1
            else
                failed = failed + 1
            end
        end
    end
    self.deploymentsById[deployment_id] = nil
    self.cleanupCount = self.cleanupCount + removed
    if rollback then self.rollbackCount = self.rollbackCount + 1 end
    if failed > 0 then
        self.lastError = "native-NPC-leader-guard-cleanup-partial"
        return result(false, self.lastError, {
            deploymentId = deployment_id,
            removedCount = removed,
            failedCount = failed,
        })
    end
    return result(true, "native-NPC-leader-guard-deployment-cleaned", {
        deploymentId = deployment_id,
        removedCount = removed,
        failedCount = 0,
    })
end

function NpcLeaderGuardNativeProduction:_on_member_terminated(
    deployment_id,
    request_id,
    detail
)
    local deployment = self.deploymentsById[deployment_id]
    if deployment == nil or deployment.closing then return end
    local live = 0
    for _, member in ipairs(deployment.members) do
        if member.requestId == request_id then
            member.terminated = true
            member.terminationDetail = copy(detail)
        end
        if member.terminated ~= true then live = live + 1 end
    end
    if live > 0 or deployment.autoRecallSubmitted then return end
    deployment.autoRecallSubmitted = true
    local binding = self.bindingsById[deployment.bindingId]
    if binding == nil then return end
    local event_id = self.providerId .. ".auto-recall."
        .. deployment.deploymentId
    local outcome = self.orchestrator:ingest({
        schemaVersion = "1.0.0",
        authoritative = true,
        providerId = self.providerId,
        authoritySource = self.authoritySource,
        eventKind = "recall",
        eventId = event_id,
        operationId = event_id,
        bindingId = binding.bindingId,
        actorKey = binding.actorKey,
        actorClassKey = binding.actorClassKey,
        deploymentId = deployment.deploymentId,
    })
    if not outcome.ok then self.lastError = outcome.reason end
end

function NpcLeaderGuardNativeProduction:_deploy(intent, leader_ref)
    if self.deploymentsById[intent.deploymentId] ~= nil then
        return result(true,
            "native-NPC-leader-guard-deployment-already-active", {
                deploymentId = intent.deploymentId,
            })
    end
    if self.spawnPolicyResolver ~= nil then
        local ok, policy = pcall(self.spawnPolicyResolver,
            intent.factionId, "NPC-leader-guard")
        if not ok or type(policy) ~= "table" or policy.ok ~= true then
            self.suppressedCount = self.suppressedCount + 1
            return result(false, "native-NPC-leader-guard-spawn-policy-failed", {
                detail = ok and copy(policy) or tostring(policy),
            })
        end
        if policy.suppressSpawn == true then
            self.suppressedCount = self.suppressedCount + 1
            return result(false,
                "native-NPC-leader-guard-faction-destroyed", {
                    detail = copy(policy),
                })
        end
    end
    local expanded, expansion_error = self:_expanded_archetypes(intent)
    if expanded == nil then return result(false, expansion_error) end
    local origin = actor_location(leader_ref)
    if origin == nil then
        return result(false, "native-NPC-leader-guard-location-unavailable")
    end
    local deployment = {
        deploymentId = intent.deploymentId,
        bindingId = intent.bindingId,
        leaderId = intent.leaderId,
        factionId = intent.factionId,
        phase = "following",
        members = {},
    }
    self.deploymentsById[intent.deploymentId] = deployment
    local rotation = actor_rotation(leader_ref)
    for index, archetype in ipairs(expanded) do
        local provider = self.nativeCharacterAdapter:create_guard_provider(
            archetype.characterId,
            archetype.characterClassPath,
            {
                runtimePrefix = "NPC-leader-guard",
                mode = "NPC-leader-guard",
            }
        )
        local request_id = intent.deploymentId .. ":"
            .. string.format("%02d", index)
        local ok, handle = pcall(provider.deploy,
            intent.factionId, request_id, {
                location = self:_spawn_location(origin, index, #expanded),
                rotation = rotation,
                followTarget = leader_ref,
                controllerClassPath = archetype.controllerClassPath,
                onTerminated = function(detail)
                    self:_on_member_terminated(
                        intent.deploymentId, request_id, detail)
                end,
            })
        if not ok or type(handle) ~= "table" then
            self:_cleanup_deployment(intent.deploymentId,
                "NPC-leader-guard-atomic-rollback", true)
            self.lastError = tostring(handle)
            return result(false,
                "native-NPC-leader-guard-deploy-failed", {
                    failedIndex = index,
                    detail = tostring(handle),
                    rolledBack = true,
                })
        end
        deployment.members[#deployment.members + 1] = {
            index = index,
            requestId = request_id,
            archetypeId = archetype.archetypeId,
            provider = provider,
            handle = handle,
            terminated = false,
        }
    end
    self.deployCount = self.deployCount + 1
    self.lastError = nil
    self:_log(string.format(
        "DEPLOYED deployment=%s leader=%s faction=%s members=%d",
        intent.deploymentId, intent.leaderId, intent.factionId,
        #deployment.members
    ))
    return result(true, "native-NPC-leader-guards-deployed", {
        deploymentId = intent.deploymentId,
        memberCount = #deployment.members,
        nativeHandles = deployment.members,
        PalworldSaveMutation = false,
    })
end

function NpcLeaderGuardNativeProduction:_execute_intent(intent, leader_ref)
    if not self.active then
        return result(false, "native-NPC-leader-guard-production-inactive")
    end
    local binding = self.bindingsById[intent.bindingId]
    if binding == nil or binding.actorRef ~= leader_ref
        or binding.actorKey ~= intent.leaderActorKey
        or binding.actorClassKey ~= intent.leaderActorClassKey then
        return result(false, "native-NPC-leader-guard-binding-mismatch")
    end
    if intent.kind == "deploy-guards" then
        return self:_deploy(intent, leader_ref)
    end
    local deployment = self.deploymentsById[intent.deploymentId]
    if TERMINAL_KINDS[intent.kind] then
        local cleaned = self:_cleanup_deployment(
            intent.deploymentId, intent.kind, false)
        if cleaned.ok and (intent.kind == "retire-guards"
            or intent.kind == "despawn-guards") then
            self.bindingsById[intent.bindingId] = nil
        end
        return cleaned
    end
    if deployment == nil then
        return result(false,
            "native-NPC-leader-guard-deployment-unavailable")
    end
    if intent.kind == "follow-leader" then
        deployment.phase = "following"
    elseif intent.kind == "enter-combat" then
        -- The existing native guard adapter yields movement to Palworld's
        -- hate/combat controller and resumes following after combat.
        deployment.phase = "combat"
    else
        return result(false, "native-NPC-leader-guard-intent-unsupported")
    end
    return result(true, "native-NPC-leader-guard-lifecycle-applied", {
        deploymentId = intent.deploymentId,
        phase = deployment.phase,
        memberCount = #deployment.members,
        PalworldSaveMutation = false,
    })
end

function NpcLeaderGuardNativeProduction:unbind_leader(binding_id)
    require_text(binding_id, "native NPC leader guard binding ID")
    local binding = self.bindingsById[binding_id]
    if binding == nil then
        return result(true,
            "native-NPC-leader-guard-leader-already-unbound")
    end
    local deployment_ids = {}
    for deployment_id, deployment in pairs(self.deploymentsById) do
        if deployment.bindingId == binding_id then
            deployment_ids[#deployment_ids + 1] = deployment_id
        end
    end
    table.sort(deployment_ids)
    for _, deployment_id in ipairs(deployment_ids) do
        local event_id = self.providerId .. ".unbind."
            .. deployment_id
        local recalled = self.orchestrator:ingest({
            schemaVersion = "1.0.0",
            authoritative = true,
            providerId = self.providerId,
            authoritySource = self.authoritySource,
            eventKind = "recall",
            eventId = event_id,
            operationId = event_id,
            bindingId = binding.bindingId,
            actorKey = binding.actorKey,
            actorClassKey = binding.actorClassKey,
            deploymentId = deployment_id,
        })
        if not recalled.ok then return recalled end
    end
    local unbound = self.orchestrator:unbind_leader({
        bindingId = binding_id,
        providerId = self.providerId,
        actorKey = binding.actorKey,
        actorClassKey = binding.actorClassKey,
    })
    if not unbound.ok then return unbound end
    self.bindingsById[binding_id] = nil
    self.unbindCount = self.unbindCount + 1
    return result(true, "native-NPC-leader-guard-leader-unbound", {
        bindingId = binding_id,
    })
end

function NpcLeaderGuardNativeProduction:unbind_world(reason)
    local removed_deployments = 0
    local deployment_ids = {}
    for deployment_id in pairs(self.deploymentsById) do
        deployment_ids[#deployment_ids + 1] = deployment_id
    end
    table.sort(deployment_ids)
    for _, deployment_id in ipairs(deployment_ids) do
        self:_cleanup_deployment(deployment_id,
            reason or "world-unloading", false)
        removed_deployments = removed_deployments + 1
    end
    local removed_bindings = count(self.bindingsById)
    self.bindingsById = {}
    self.deploymentsById = {}
    self.lastError = reason or "world-unloading"
    return result(true, "native-NPC-leader-guard-world-unbound", {
        removedDeploymentCount = removed_deployments,
        removedBindingCount = removed_bindings,
    })
end

function NpcLeaderGuardNativeProduction:status()
    local active_members = 0
    for _, deployment in pairs(self.deploymentsById) do
        for _, member in ipairs(deployment.members) do
            if member.terminated ~= true then active_members = active_members + 1 end
        end
    end
    return {
        apiVersion = self.version,
        enabled = self.enabled,
        active = self.active,
        providerId = self.providerId,
        authoritySource = self.authoritySource,
        archetypeCount = count(self.archetypesById),
        bindingCount = count(self.bindingsById),
        deploymentCount = count(self.deploymentsById),
        activeMemberCount = active_members,
        activationCount = self.activationCount,
        bindCount = self.bindCount,
        unbindCount = self.unbindCount,
        deployCount = self.deployCount,
        cleanupCount = self.cleanupCount,
        rollbackCount = self.rollbackCount,
        suppressedCount = self.suppressedCount,
        exactLeaderBindingsOnly = true,
        broadActorScan = false,
        storyContentIncluded = false,
        PalworldSaveMutation = false,
        lastError = self.lastError,
    }
end

return NpcLeaderGuardNativeProduction
