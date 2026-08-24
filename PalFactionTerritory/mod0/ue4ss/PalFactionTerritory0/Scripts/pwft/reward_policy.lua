local RewardPolicy = {}

local API_VERSION = "1.0.0"
local STATE_SCHEMA_VERSION = "1.0.0"
local PACK_SCHEMA = "pwft.reward-policy.pack.v1"
local SETTLEMENT_SCHEMA = "pwft.reward-settlement.v1"

local SOURCE_KINDS = {
    defense = true,
    raid = true,
    quest = true,
    boss = true,
}

local SETTLEMENT_FIELDS = {
    schemaVersion = true,
    authority = true,
    operationId = true,
    contentPackId = true,
    policyId = true,
    sourceKind = true,
    difficultyScore = true,
    playerParticipated = true,
    playerSideWon = true,
}

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, child in pairs(value) do result[copy(key)] = copy(child) end
    return result
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
    assert(string.match(value, "^[a-z0-9][a-z0-9_.-]+$") ~= nil,
        name .. " must be a stable namespaced ID")
    assert(string.find(value, "..", 1, true) == nil,
        name .. " cannot contain empty namespace segments")
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

local function normalize_rewards(rewards, name)
    assert(type(rewards) == "table" and #rewards > 0,
        name .. " must be a non-empty list")
    local normalized, seen = {}, {}
    for _, reward in ipairs(rewards) do
        assert(type(reward) == "table", name .. " entry must be a table")
        local channel_id = stable_id(reward.channelId,
            name .. " channel ID")
        assert(not seen[channel_id], name .. " contains a duplicate channel")
        seen[channel_id] = true
        local base_units = positive_integer(reward.baseUnits,
            name .. " base units")
        local maximum_units = positive_integer(reward.maximumUnits,
            name .. " maximum units")
        assert(maximum_units >= base_units,
            name .. " maximum units cannot be below base units")
        normalized[#normalized + 1] = {
            channelId = channel_id,
            baseUnits = base_units,
            maximumUnits = maximum_units,
        }
    end
    table.sort(normalized, function(first, second)
        return first.channelId < second.channelId
    end)
    return normalized
end

local function normalize_bands(bands)
    assert(type(bands) == "table" and #bands > 0,
        "reward difficulty bands are required")
    local normalized = {}
    local previous_minimum = -1
    local previous_multiplier = 0
    for index, band in ipairs(bands) do
        assert(type(band) == "table", "reward difficulty band must be a table")
        local minimum = non_negative_integer(band.minimumScore,
            "reward difficulty minimum score")
        assert(minimum <= 100, "reward difficulty score cannot exceed 100")
        assert(index == 1 and minimum == 0 or minimum > previous_minimum,
            "reward difficulty bands must start at zero and increase")
        local multiplier = positive_integer(band.multiplierBps,
            "reward difficulty multiplier")
        assert(multiplier >= previous_multiplier,
            "higher difficulty cannot reduce rewards")
        normalized[#normalized + 1] = {
            minimumScore = minimum,
            multiplierBps = multiplier,
        }
        previous_minimum = minimum
        previous_multiplier = multiplier
    end
    return normalized
end

local function normalize_policy(content_pack_id, policy)
    assert(type(policy) == "table", "reward policy must be a table")
    local source_kind = non_empty(policy.sourceKind, "reward source kind")
    assert(SOURCE_KINDS[source_kind] == true,
        "unsupported reward source kind: " .. source_kind)
    local milestone_every = positive_integer(policy.milestoneEvery or 1,
        "reward milestone interval")
    local milestone_bonus = non_negative_integer(policy.milestoneBonusBps or 0,
        "reward milestone bonus")
    assert(milestone_bonus <= 50000,
        "reward milestone bonus exceeds the safety cap")
    return {
        contentPackId = content_pack_id,
        id = stable_id(policy.id, "reward policy ID"),
        sourceKind = source_kind,
        rewards = normalize_rewards(policy.rewards, "reward policy rewards"),
        difficultyBands = normalize_bands(policy.difficultyBands),
        milestoneEvery = milestone_every,
        milestoneBonusBps = milestone_bonus,
    }
end

local function make_state()
    return {
        schemaVersion = STATE_SCHEMA_VERSION,
        revision = 0,
        policies = {},
        operationSignatures = {},
        eligibleWinsByPolicy = {},
    }
end

local function ensure_state(instance)
    local root = instance.progression.state
    if type(root.rewardPolicy) ~= "table" then
        root.rewardPolicy = make_state()
    end
    local state = root.rewardPolicy
    assert(state.schemaVersion == STATE_SCHEMA_VERSION,
        "unsupported reward policy snapshot schema")
    state.revision = state.revision or 0
    state.policies = state.policies or {}
    state.operationSignatures = state.operationSignatures or {}
    state.eligibleWinsByPolicy = state.eligibleWinsByPolicy or {}
    return state
end

local function policy_signature(policy)
    local parts = {
        policy.contentPackId,
        policy.id,
        policy.sourceKind,
        tostring(policy.milestoneEvery),
        tostring(policy.milestoneBonusBps),
    }
    for _, band in ipairs(policy.difficultyBands) do
        parts[#parts + 1] = tostring(band.minimumScore)
        parts[#parts + 1] = tostring(band.multiplierBps)
    end
    for _, reward in ipairs(policy.rewards) do
        parts[#parts + 1] = reward.channelId
        parts[#parts + 1] = tostring(reward.baseUnits)
        parts[#parts + 1] = tostring(reward.maximumUnits)
    end
    return table.concat(parts, "|")
end

local function settlement_signature(input)
    return table.concat({
        input.contentPackId,
        input.policyId,
        input.sourceKind,
        tostring(input.difficultyScore),
        tostring(input.playerParticipated),
        tostring(input.playerSideWon),
        input.authority,
    }, "|")
end

local function multiplier_for(policy, score)
    local selected = policy.difficultyBands[1].multiplierBps
    for _, band in ipairs(policy.difficultyBands) do
        if score < band.minimumScore then break end
        selected = band.multiplierBps
    end
    return selected
end

local function validate_settlement(instance, input)
    if type(input) ~= "table" then return false, "settlement-table-required" end
    for key in pairs(input) do
        if SETTLEMENT_FIELDS[key] ~= true then
            return false, "settlement-field-not-allowed"
        end
    end
    if input.schemaVersion ~= SETTLEMENT_SCHEMA then
        return false, "unsupported-reward-settlement-schema"
    end
    if input.authority ~= instance.authority then
        return false, "reward-authority-not-trusted"
    end
    if type(input.operationId) ~= "string" or input.operationId == "" then
        return false, "reward-operation-id-required"
    end
    if type(input.contentPackId) ~= "string" or input.contentPackId == ""
        or type(input.policyId) ~= "string" or input.policyId == "" then
        return false, "reward-policy-identity-required"
    end
    if SOURCE_KINDS[input.sourceKind] ~= true then
        return false, "unsupported-reward-source"
    end
    if type(input.difficultyScore) ~= "number"
        or input.difficultyScore < 0 or input.difficultyScore > 100
        or input.difficultyScore ~= math.floor(input.difficultyScore) then
        return false, "invalid-reward-difficulty-score"
    end
    if type(input.playerParticipated) ~= "boolean"
        or type(input.playerSideWon) ~= "boolean" then
        return false, "explicit-reward-outcome-required"
    end
    return true, nil
end

function RewardPolicy.create(progression, options)
    assert(type(progression) == "table" and type(progression.state) == "table",
        "progression state root is required")
    options = options or {}
    assert(options.onChange == nil or type(options.onChange) == "function",
        "reward policy onChange must be a function")
    local instance = setmetatable({
        version = API_VERSION,
        progression = progression,
        authority = options.authority or "pwft.authoritative-reward-outcome.v1",
        nativeAdapterEnabled = options.nativeAdapterEnabled == true,
        onChange = options.onChange,
        lastNotificationError = nil,
        capabilities = {
            defenseRaidQuestBossSources = true,
            highDifficultyNeverReducesRewards = true,
            deterministicMilestoneGuarantee = true,
            perChannelRewardCaps = true,
            operationIdempotency = true,
            persistedOperationReplay = true,
            contentPackExtension = true,
            modelAuthority = false,
            directInventoryMutation = false,
            currencyMutation = false,
            palworldSaveMutation = false,
            nativeAdapterEnabledByDefault = false,
        },
    }, { __index = RewardPolicy })
    instance.state = ensure_state(instance)
    if type(progression.register_restore_listener) == "function" then
        local registered = progression:register_restore_listener(
            "pwft.reward-policy.v1",
            function() return instance:rebind_progression_state() end
        )
        assert(registered.ok, registered.reason)
    end
    return instance
end

function RewardPolicy:rebind_progression_state()
    local ok, rebound = pcall(ensure_state, self)
    if not ok then
        return result(false, "reward-policy-snapshot-invalid", {
            error = tostring(rebound),
        })
    end
    self.state = rebound
    return result(true, "reward-policy-state-rebound")
end

function RewardPolicy:register_pack(pack)
    if type(pack) ~= "table" or pack.schemaVersion ~= PACK_SCHEMA then
        return result(false, "unsupported-reward-policy-pack-schema")
    end
    local ok, normalized_pack = pcall(function()
        local content_pack_id = stable_id(pack.contentPackId,
            "reward policy content pack ID")
        assert(type(pack.policies) == "table" and #pack.policies > 0,
            "reward policies are required")
        local policies, seen = {}, {}
        for _, policy in ipairs(pack.policies) do
            local normalized = normalize_policy(content_pack_id, policy)
            assert(not seen[normalized.id], "duplicate reward policy ID")
            seen[normalized.id] = true
            policies[#policies + 1] = normalized
        end
        return { contentPackId = content_pack_id, policies = policies }
    end)
    if not ok then
        return result(false, "invalid-reward-policy-pack", {
            validationError = tostring(normalized_pack),
        })
    end
    for _, policy in ipairs(normalized_pack.policies) do
        local existing = self.state.policies[policy.id]
        if existing ~= nil
            and policy_signature(existing) ~= policy_signature(policy) then
            return result(false, "reward-policy-id-conflict", {
                policyId = policy.id,
            })
        end
    end
    local registered = 0
    for _, policy in ipairs(normalized_pack.policies) do
        if self.state.policies[policy.id] == nil then
            self.state.policies[policy.id] = copy(policy)
            self.state.eligibleWinsByPolicy[policy.id] = 0
            registered = registered + 1
        end
    end
    if registered > 0 then self.state.revision = self.state.revision + 1 end
    if registered > 0 and self.onChange ~= nil then
        local called, message = pcall(self.onChange, nil, {
            type = "reward-policy-pack-registered",
            contentPackId = normalized_pack.contentPackId,
            registeredPolicyCount = registered,
            revision = self.state.revision,
        })
        if not called then self.lastNotificationError = tostring(message) end
    end
    return result(true, registered > 0
        and "reward-policy-pack-registered"
        or "reward-policy-pack-already-registered", {
        contentPackId = normalized_pack.contentPackId,
        registeredPolicyCount = registered,
    })
end

function RewardPolicy:settle(input)
    local valid, reason = validate_settlement(self, input)
    if not valid then return result(false, reason, { rewardIntents = {} }) end
    local signature = settlement_signature(input)
    local previous = self.state.operationSignatures[input.operationId]
    if previous ~= nil then
        if previous.signature ~= signature then
            return result(false, "reward-operation-id-conflict", {
                rewardIntents = {},
            })
        end
        local duplicate = copy(previous.outcome)
        duplicate.reason = "duplicate-reward-settlement"
        duplicate.duplicateOfReason = previous.outcome.reason
        duplicate.rewardIntents = {}
        duplicate.idempotent = true
        return duplicate
    end
    local policy = self.state.policies[input.policyId]
    if policy == nil or policy.contentPackId ~= input.contentPackId then
        return result(false, "reward-policy-not-registered", {
            rewardIntents = {},
        })
    end
    if policy.sourceKind ~= input.sourceKind then
        return result(false, "reward-source-policy-mismatch", {
            rewardIntents = {},
        })
    end

    local eligible = input.playerParticipated and input.playerSideWon
    local reward_intents = {}
    local multiplier_bps = multiplier_for(policy, input.difficultyScore)
    local milestone = false
    if eligible then
        local wins = (self.state.eligibleWinsByPolicy[policy.id] or 0) + 1
        self.state.eligibleWinsByPolicy[policy.id] = wins
        milestone = wins % policy.milestoneEvery == 0
        for _, reward in ipairs(policy.rewards) do
            local units = math.floor(reward.baseUnits * multiplier_bps / 10000)
            if milestone then
                units = units + math.floor(
                    reward.baseUnits * policy.milestoneBonusBps / 10000
                )
            end
            units = math.min(units, reward.maximumUnits)
            if units > 0 then
                reward_intents[#reward_intents + 1] = {
                    channelId = reward.channelId,
                    units = units,
                }
            end
        end
    end
    local outcome = result(true, eligible
        and "reward-intents-calculated"
        or "reward-not-earned", {
        operationId = input.operationId,
        policyId = policy.id,
        sourceKind = input.sourceKind,
        difficultyScore = input.difficultyScore,
        multiplierBps = multiplier_bps,
        milestoneGuarantee = milestone,
        eligible = eligible,
        rewardIntents = reward_intents,
        nativeApplied = false,
    })
    self.state.operationSignatures[input.operationId] = {
        signature = signature,
        outcome = copy(outcome),
    }
    self.state.revision = self.state.revision + 1
    if self.onChange ~= nil then
        local called, message = pcall(self.onChange, nil, {
            type = "reward-policy-settled",
            operationId = input.operationId,
            contentPackId = input.contentPackId,
            policyId = policy.id,
            sourceKind = input.sourceKind,
            eligible = eligible,
            rewardIntentCount = #reward_intents,
            revision = self.state.revision,
        })
        if not called then self.lastNotificationError = tostring(message) end
    end
    return outcome
end

-- Duplicate settlement calls intentionally return no new intents so callers
-- cannot accidentally grant the same reward twice.  Delivery providers that
-- are recovering after a restart use this read-only operation record instead
-- of recalculating the policy or asking settle() to emit a second intent.
function RewardPolicy:operation_status(operation_id)
    if type(operation_id) ~= "string" or operation_id == "" then
        return nil
    end
    local record = self.state.operationSignatures[operation_id]
    if type(record) ~= "table" or type(record.outcome) ~= "table" then
        return nil
    end
    return copy(record.outcome)
end

function RewardPolicy:status(policy_id)
    local policy = policy_id and self.state.policies[policy_id] or nil
    local policy_count, operation_count = 0, 0
    for _ in pairs(self.state.policies) do policy_count = policy_count + 1 end
    for _ in pairs(self.state.operationSignatures) do
        operation_count = operation_count + 1
    end
    return {
        version = self.version,
        schemaVersion = self.state.schemaVersion,
        revision = self.state.revision,
        policy = copy(policy),
        eligibleWins = policy_id
                and (self.state.eligibleWinsByPolicy[policy_id] or 0)
            or nil,
        policyCount = policy_count,
        operationCount = operation_count,
        nativeAdapterEnabled = self.nativeAdapterEnabled,
        lastNotificationError = self.lastNotificationError,
        capabilities = copy(self.capabilities),
    }
end

function RewardPolicy:export_snapshot()
    return copy(self.state)
end

return RewardPolicy
