local PalReconciliation = {}

local API_VERSION = "1.0.0"
local STATE_SCHEMA_VERSION = "1.0.0"
local AWARD_AUTHORITY = "pal-discourse-service-v1"

local function copy(value)
    if type(value) ~= "table" then
        return value
    end
    local result = {}
    for key, item in pairs(value) do
        result[copy(key)] = copy(item)
    end
    return result
end

local function require_non_empty_string(value, name)
    assert(
        type(value) == "string" and value ~= "",
        name .. " must be a non-empty string"
    )
    return value
end

local function require_positive_integer(value, name)
    assert(
        type(value) == "number"
            and value > 0
            and value == math.floor(value),
        name .. " must be a positive integer"
    )
    return value
end

local function require_non_negative_number(value, name)
    assert(
        type(value) == "number" and value >= 0,
        name .. " must be a non-negative number"
    )
    return value
end

local function result(ok, reason, extra)
    local value = extra or {}
    value.ok = ok
    value.reason = reason
    return value
end

local function list_to_set(values, name)
    local seen = {}
    for _, value in ipairs(values or {}) do
        require_non_empty_string(value, name)
        assert(seen[value] == nil, "duplicate " .. name .. ": " .. value)
        seen[value] = true
    end
    return seen
end

local function validate_contract(contract, progression)
    assert(type(contract) == "table", "Pal reconciliation contract is required")
    assert(contract.schemaVersion == "1.0.0", "unsupported Pal reconciliation contract schema")
    assert(
        contract.baselineStatus
            == "user_confirmed_token_discourse_mechanics_2026-08-05",
        "Pal reconciliation baseline is not user-confirmed"
    )
    assert(
        contract.contentStatus
            == "mechanics_only_content_author_registration_required",
        "Pal reconciliation base must not include authored story content"
    )
    assert(type(progression) == "table", "faction progression instance is required")
    assert(type(progression.status) == "function", "invalid faction progression instance")
    assert(type(progression.gate_status) == "function", "faction progression gate API is required")
    assert(
        type(progression.award_pal_reconciliation) == "function",
        "finite Pal affinity award API is required"
    )

    local design = contract.designPolicy or {}
    assert(design.storyContentIncluded == false, "base cannot author Pal reconciliation stories")
    assert(design.taskTextIncluded == false, "base cannot author Pal reconciliation tasks")
    assert(design.dialogueContentIncluded == false, "base cannot author Pal discourse dialogue")
    assert(design.palMembershipAllowed == false, "Pal membership must remain forbidden")
    assert(design.reputationDecreaseEnabled == false, "Pal affinity decrease is outside the current phase")
    assert(design.palworldSaveMutationAllowed == false, "Palworld save mutation must remain disabled")

    local human_ids = list_to_set(contract.humanCityStateIds, "human city-state ID")
    local pal_ids = list_to_set(contract.palFactionIds, "Pal faction ID")
    assert(#contract.humanCityStateIds == 7, "expected seven human city-states")
    assert(#contract.palFactionIds == 5, "expected five Pal factions")

    local raid = contract.raidEligibility or {}
    assert(raid.playerSideMustWin == true, "player victory must be required")
    assert(
        raid.participationRule == "authoritative_raid_leader_kill_credit",
        "raid leader kill credit must define participation"
    )
    assert(raid.oneTokenPerRaidEvent == true, "one raid may award at most one token")
    assert(raid.randomAcrossAllHumanCityStates == true, "token draw must use all city-states")
    assert(raid.duplicateCityStateResultsAllowed == true, "duplicate city-state results must remain allowed")

    local token = contract.tokenPolicy or {}
    assert(token.quotaSource == "content_pack_per_pal_faction", "content packs must own token quota")
    assert(token.oneTokenPerDiscourseAttempt == true, "one token must equal one discourse attempt")
    assert(token.eachDropCreatesIndependentInstance == true, "each drop must create an independent token")
    assert(token.virtualLedgerIsAuthoritative == true, "virtual token ledger must remain authoritative")

    local discourse = contract.discoursePolicy or {}
    assert(discourse.requiresAllHumanLords == true, "all human Lords must gate Pal discourse")
    assert(discourse.explicitIrreversibleConfirmationRequired == true, "irreversible confirmation is required")
    assert(discourse.preConfirmationCancelConsumesToken == false, "pre-confirmation cancel cannot consume a token")
    assert(discourse.playerAbortAfterConfirmationConsumesToken == true, "confirmed player abort must consume a token")
    assert(discourse.technicalFailureConsumesToken == false, "technical failures cannot consume a token")
    assert(discourse.interruptedActiveSessionRecovery == "technical_refund", "interrupted sessions must refund")
    assert(discourse.modelMayMutateAffinityDirectly == false, "models cannot mutate Pal affinity")
    assert(discourse.deterministicRuleEngineOwnsAffinity == true, "deterministic rules must own affinity")
    assert(discourse.targetReputation == 0, "Pal reconciliation target must remain zero")
    assert(discourse.maximumRelation == "Friendly", "Pal relation cannot exceed Friendly")
    assert(discourse.exhaustedBeforeTargetPermanentlyLocksFaction == true, "attempt exhaustion must permanently lock reconciliation")

    return human_ids, pal_ids
end

local function make_faction_state(faction_id)
    return {
        factionId = faction_id,
        configured = false,
        contentPackId = nil,
        contentVersion = nil,
        tokenQuota = 0,
        maximumAffinityPerDiscourse = 0,
        tokensAwarded = 0,
        tokensConsumed = 0,
        technicalRefunds = 0,
        activeSessionId = nil,
        locked = false,
        reconciled = false,
        tokens = {},
        sessions = {},
        migrations = {},
    }
end

local function make_state(contract)
    local state = {
        schemaVersion = STATE_SCHEMA_VERSION,
        revision = 0,
        eventCount = 0,
        nextTokenSerial = 1,
        nextSessionSerial = 1,
        lastEvent = nil,
        processedRaidEvents = {},
        factions = {},
    }
    for _, faction_id in ipairs(contract.palFactionIds) do
        state.factions[faction_id] = make_faction_state(faction_id)
    end
    return state
end

local function normalize_faction_state(record, faction_id)
    assert(type(record) == "table", "missing Pal reconciliation faction state: " .. faction_id)
    assert(record.factionId == faction_id, "Pal reconciliation faction state mismatch")
    record.configured = record.configured == true
    record.tokenQuota = record.tokenQuota or 0
    record.maximumAffinityPerDiscourse = record.maximumAffinityPerDiscourse or 0
    record.tokensAwarded = record.tokensAwarded or 0
    record.tokensConsumed = record.tokensConsumed or 0
    record.technicalRefunds = record.technicalRefunds or 0
    record.locked = record.locked == true
    record.reconciled = record.reconciled == true
    record.tokens = record.tokens or {}
    record.sessions = record.sessions or {}
    record.migrations = record.migrations or {}
    assert(record.tokensConsumed <= record.tokensAwarded, "consumed token count exceeds awarded count")
    if record.configured then
        require_non_empty_string(record.contentPackId, "content pack ID")
        require_non_empty_string(record.contentVersion, "content version")
        require_positive_integer(record.tokenQuota, "token quota")
        require_non_negative_number(record.maximumAffinityPerDiscourse, "maximum affinity per discourse")
        assert(record.maximumAffinityPerDiscourse > 0, "maximum affinity per discourse must be positive")
        assert(record.tokensAwarded <= record.tokenQuota, "awarded token count exceeds configured quota")
    end
end

local function ensure_state(instance)
    local root = instance.progression.state
    assert(type(root) == "table", "progression state root is required")
    if type(root.palReconciliation) ~= "table" then
        root.palReconciliation = make_state(instance.contract)
    end
    local state = root.palReconciliation
    assert(state.schemaVersion == STATE_SCHEMA_VERSION, "unsupported Pal reconciliation state schema")
    state.revision = state.revision or 0
    state.eventCount = state.eventCount or 0
    state.nextTokenSerial = state.nextTokenSerial or 1
    state.nextSessionSerial = state.nextSessionSerial or 1
    state.processedRaidEvents = state.processedRaidEvents or {}
    state.factions = state.factions or {}
    for _, faction_id in ipairs(instance.contract.palFactionIds) do
        if type(state.factions[faction_id]) ~= "table" then
            state.factions[faction_id] = make_faction_state(faction_id)
        end
        normalize_faction_state(state.factions[faction_id], faction_id)
    end
    for faction_id, _ in pairs(state.factions) do
        assert(instance.palFactionIds[faction_id] == true, "unknown faction in Pal reconciliation state: " .. tostring(faction_id))
    end
    instance.state = state
end

local function notify(instance, faction_id, event)
    if instance.onChange == nil then
        return
    end
    local ok, error_message = pcall(
        instance.onChange,
        faction_id,
        copy(event),
        instance:status(faction_id)
    )
    if not ok then
        instance.lastNotificationError = tostring(error_message)
    end
end

local function touch(instance, faction_id, event)
    instance.state.revision = instance.state.revision + 1
    instance.state.eventCount = instance.state.eventCount + 1
    event.revision = instance.state.revision
    instance.state.lastEvent = copy(event)
    notify(instance, faction_id, event)
end

local function faction_state(instance, faction_id)
    local record = instance.state.factions[faction_id]
    if record == nil then
        return nil, result(false, "unknown-pal-faction")
    end
    return record, nil
end

local function progression_reconciled(instance, faction_id)
    local status = instance.progression:status(faction_id)
    return status ~= nil
        and status.relation == instance.contract.discoursePolicy.maximumRelation
end

local function update_terminal_state(instance, record)
    if progression_reconciled(instance, record.factionId) then
        record.reconciled = true
        record.locked = false
        return "reconciled"
    end
    record.reconciled = false
    if record.configured
        and record.tokensAwarded >= record.tokenQuota
        and record.tokensConsumed >= record.tokenQuota then
        record.locked = true
        return "reconciliation-locked-attempts-exhausted"
    end
    return "attempts-remaining"
end

local function token_counts(record)
    local counts = {
        questPending = 0,
        questComplete = 0,
        reserved = 0,
        consumed = 0,
    }
    for _, token in pairs(record.tokens) do
        if token.state == "quest-pending" then
            counts.questPending = counts.questPending + 1
        elseif token.state == "quest-complete" then
            counts.questComplete = counts.questComplete + 1
        elseif token.state == "reserved" then
            counts.reserved = counts.reserved + 1
        elseif token.state == "consumed" then
            counts.consumed = counts.consumed + 1
        else
            error("unknown token state: " .. tostring(token.state))
        end
    end
    return counts
end

local function default_random_index(maximum)
    return math.random(maximum)
end

local function make_token_id(state, faction_id)
    local suffix = string.gsub(faction_id, "^pwft%.faction%.", "")
    local token_id = string.format(
        "pwft.pal-token.%s.%06d",
        suffix,
        state.nextTokenSerial
    )
    state.nextTokenSerial = state.nextTokenSerial + 1
    return token_id
end

local function make_session_id(state, faction_id)
    local suffix = string.gsub(faction_id, "^pwft%.faction%.", "")
    local session_id = string.format(
        "pwft.pal-discourse.%s.%06d",
        suffix,
        state.nextSessionSerial
    )
    state.nextSessionSerial = state.nextSessionSerial + 1
    return session_id
end

local function find_token(record, token_instance_id)
    return record.tokens[token_instance_id]
end

local function recover_interrupted_sessions(instance)
    local recovered = 0
    for _, faction_id in ipairs(instance.contract.palFactionIds) do
        local record = instance.state.factions[faction_id]
        for session_id, session in pairs(record.sessions) do
            if session.state == "active" then
                local token = find_token(record, session.tokenInstanceId)
                assert(token ~= nil, "active discourse session token is missing")
                assert(token.state == "reserved", "active discourse session token is not reserved")
                token.state = "quest-complete"
                token.reservedBySessionId = nil
                session.state = "resolved"
                session.outcome = "technical-recovery"
                session.tokenConsumed = false
                session.affinityApplied = 0
                record.technicalRefunds = record.technicalRefunds + 1
                if record.activeSessionId == session_id then
                    record.activeSessionId = nil
                end
                recovered = recovered + 1
                touch(instance, faction_id, {
                    type = "discourse-technical-recovery",
                    factionId = faction_id,
                    sessionId = session_id,
                    tokenInstanceId = token.tokenInstanceId,
                })
            end
        end
    end
    return recovered
end

function PalReconciliation.create(contract, progression, options)
    local human_ids, pal_ids = validate_contract(contract, progression)
    options = options or {}
    assert(options.onChange == nil or type(options.onChange) == "function", "Pal reconciliation onChange must be a function")
    assert(options.randomIndex == nil or type(options.randomIndex) == "function", "Pal reconciliation randomIndex must be a function")
    local instance = setmetatable({
        version = API_VERSION,
        contract = copy(contract),
        progression = progression,
        humanCityStateIds = human_ids,
        palFactionIds = pal_ids,
        onChange = options.onChange,
        randomIndex = options.randomIndex or default_random_index,
        lastNotificationError = nil,
        capabilities = {
            contentConfiguredTokenQuota = true,
            duplicateCityStateTokens = true,
            authoritativeLeaderKillCredit = true,
            playerVictoryRequired = true,
            questContentAdapter = true,
            explicitIrreversibleConfirmation = true,
            technicalFailureRefund = true,
            confirmedPlayerAbortConsumes = true,
            deterministicAffinitySettlement = true,
            permanentExhaustionLock = true,
            directModelMutation = false,
            storyContentIncluded = false,
        },
    }, { __index = PalReconciliation })
    ensure_state(instance)
    instance.recoveredInterruptedSessionCount = recover_interrupted_sessions(instance)
    return instance
end

function PalReconciliation:register_content(faction_id, content)
    local record, failure = faction_state(self, faction_id)
    if failure ~= nil then
        return failure
    end
    assert(type(content) == "table", "Pal reconciliation content registration is required")
    local content_pack_id = require_non_empty_string(content.contentPackId, "content pack ID")
    local content_version = require_non_empty_string(content.contentVersion, "content version")
    local token_quota = require_positive_integer(content.tokenQuota, "token quota")
    local maximum = require_non_negative_number(content.maximumAffinityPerDiscourse, "maximum affinity per discourse")
    assert(maximum > 0, "maximum affinity per discourse must be positive")
    assert(maximum <= 100, "maximum affinity per discourse cannot exceed the full Pal reputation span")

    if record.configured then
        if record.contentPackId == content_pack_id
            and record.contentVersion == content_version
            and record.tokenQuota == token_quota
            and record.maximumAffinityPerDiscourse == maximum then
            return result(true, "content-already-registered", self:status(faction_id))
        end
        return result(false, "content-migration-required", {
            factionId = faction_id,
            currentContentPackId = record.contentPackId,
            currentContentVersion = record.contentVersion,
            currentTokenQuota = record.tokenQuota,
        })
    end

    record.configured = true
    record.contentPackId = content_pack_id
    record.contentVersion = content_version
    record.tokenQuota = token_quota
    record.maximumAffinityPerDiscourse = maximum
    update_terminal_state(self, record)
    touch(self, faction_id, {
        type = "pal-content-registered",
        factionId = faction_id,
        contentPackId = content_pack_id,
        contentVersion = content_version,
        tokenQuota = token_quota,
        maximumAffinityPerDiscourse = maximum,
    })
    return result(true, "content-registered", self:status(faction_id))
end

function PalReconciliation:migrate_content(faction_id, content, migration_id)
    local record, failure = faction_state(self, faction_id)
    if failure ~= nil then
        return failure
    end
    require_non_empty_string(migration_id, "content migration ID")
    if record.migrations[migration_id] == true then
        return result(true, "duplicate-content-migration", self:status(faction_id))
    end
    if not record.configured then
        return result(false, "content-not-configured")
    end
    if record.activeSessionId ~= nil then
        return result(false, "active-discourse-session")
    end
    assert(type(content) == "table", "Pal reconciliation content migration is required")
    local token_quota = require_positive_integer(content.tokenQuota, "token quota")
    local maximum = require_non_negative_number(content.maximumAffinityPerDiscourse, "maximum affinity per discourse")
    assert(maximum > 0 and maximum <= 100, "invalid maximum affinity per discourse")
    if token_quota < record.tokensAwarded then
        return result(false, "quota-below-awarded-token-count", {
            tokensAwarded = record.tokensAwarded,
            requestedTokenQuota = token_quota,
        })
    end
    record.contentPackId = require_non_empty_string(content.contentPackId, "content pack ID")
    record.contentVersion = require_non_empty_string(content.contentVersion, "content version")
    record.tokenQuota = token_quota
    record.maximumAffinityPerDiscourse = maximum
    record.migrations[migration_id] = true
    local terminal = update_terminal_state(self, record)
    touch(self, faction_id, {
        type = "pal-content-migrated",
        factionId = faction_id,
        migrationId = migration_id,
        tokenQuota = token_quota,
        maximumAffinityPerDiscourse = maximum,
        terminal = terminal,
    })
    return result(true, "content-migrated", self:status(faction_id))
end

function PalReconciliation:record_raid_result(faction_id, raid)
    local record, failure = faction_state(self, faction_id)
    if failure ~= nil then
        return failure
    end
    assert(type(raid) == "table", "raid result is required")
    local raid_event_id = require_non_empty_string(raid.raidEventId, "raid event ID")
    local existing = self.state.processedRaidEvents[raid_event_id]
    if existing ~= nil then
        return result(true, "duplicate-raid-event", copy(existing))
    end
    if not record.configured then
        return result(false, "content-not-configured", { factionId = faction_id })
    end
    if record.reconciled or progression_reconciled(self, faction_id) then
        record.reconciled = true
        return result(false, "pal-faction-already-reconciled", { factionId = faction_id })
    end
    if record.locked then
        return result(false, "pal-reconciliation-permanently-locked", { factionId = faction_id })
    end

    local outcome = {
        factionId = faction_id,
        raidEventId = raid_event_id,
        playerSideWon = raid.playerSideWon == true,
        playerCreditedLeaderKill = raid.playerCreditedLeaderKill == true,
        tokenAwarded = false,
        tokenInstanceId = nil,
        cityStateId = nil,
    }
    if not outcome.playerSideWon then
        outcome.reason = "player-side-did-not-win"
    elseif not outcome.playerCreditedLeaderKill then
        outcome.reason = "raid-leader-kill-credit-required"
    elseif record.tokensAwarded >= record.tokenQuota then
        outcome.reason = "token-quota-exhausted"
    else
        local maximum = #self.contract.humanCityStateIds
        local index = self.randomIndex(maximum, {
            factionId = faction_id,
            raidEventId = raid_event_id,
            nextTokenOrdinal = record.tokensAwarded + 1,
        })
        assert(
            type(index) == "number"
                and index == math.floor(index)
                and index >= 1
                and index <= maximum,
            "random city-state index is out of range"
        )
        local city_state_id = self.contract.humanCityStateIds[index]
        local token_instance_id = make_token_id(self.state, faction_id)
        record.tokens[token_instance_id] = {
            tokenInstanceId = token_instance_id,
            palFactionId = faction_id,
            cityStateId = city_state_id,
            cityOccurrence = record.tokensAwarded + 1,
            raidEventId = raid_event_id,
            state = "quest-pending",
            questCompletionId = nil,
            questId = nil,
            topicKeys = {},
            reservedBySessionId = nil,
            consumedBySessionId = nil,
        }
        record.tokensAwarded = record.tokensAwarded + 1
        outcome.reason = "token-awarded"
        outcome.tokenAwarded = true
        outcome.tokenInstanceId = token_instance_id
        outcome.cityStateId = city_state_id
    end
    self.state.processedRaidEvents[raid_event_id] = copy(outcome)
    touch(self, faction_id, {
        type = "pal-raid-token-result",
        factionId = faction_id,
        raidEventId = raid_event_id,
        reason = outcome.reason,
        tokenInstanceId = outcome.tokenInstanceId,
        cityStateId = outcome.cityStateId,
    })
    return result(true, outcome.reason, outcome)
end

function PalReconciliation:complete_token_quest(
    faction_id,
    token_instance_id,
    completion_id,
    quest_context
)
    local record, failure = faction_state(self, faction_id)
    if failure ~= nil then
        return failure
    end
    require_non_empty_string(token_instance_id, "token instance ID")
    require_non_empty_string(completion_id, "quest completion ID")
    quest_context = quest_context or {}
    local token = find_token(record, token_instance_id)
    if token == nil then
        return result(false, "unknown-token-instance")
    end
    if token.state == "quest-complete"
        and token.questCompletionId == completion_id then
        return result(true, "duplicate-quest-completion", {
            token = copy(token),
        })
    end
    if token.state ~= "quest-pending" then
        return result(false, "token-not-awaiting-quest", {
            tokenState = token.state,
        })
    end
    token.state = "quest-complete"
    token.questCompletionId = completion_id
    token.questId = quest_context.questId
    token.topicKeys = copy(quest_context.topicKeys or {})
    token.contentRevision = quest_context.contentRevision
    touch(self, faction_id, {
        type = "pal-token-quest-completed",
        factionId = faction_id,
        tokenInstanceId = token_instance_id,
        completionId = completion_id,
        questId = token.questId,
    })
    return result(true, "token-quest-completed", {
        token = copy(token),
    })
end

function PalReconciliation:preview_discourse(faction_id, token_instance_id)
    local record, failure = faction_state(self, faction_id)
    if failure ~= nil then
        return failure
    end
    local token = find_token(record, token_instance_id)
    if token == nil then
        return result(false, "unknown-token-instance")
    end
    if not record.configured then
        return result(false, "content-not-configured")
    end
    if record.reconciled or progression_reconciled(self, faction_id) then
        return result(false, "pal-faction-already-reconciled")
    end
    if record.locked then
        return result(false, "pal-reconciliation-permanently-locked")
    end
    if not self.progression:gate_status().palReconciliationUnlocked then
        return result(false, "all-human-lords-required")
    end
    if record.activeSessionId ~= nil then
        return result(false, "active-discourse-session")
    end
    if token.state ~= "quest-complete" then
        return result(false, "token-quest-not-complete", {
            tokenState = token.state,
        })
    end
    return result(true, "discourse-confirmation-required", {
        factionId = faction_id,
        tokenInstanceId = token_instance_id,
        cityStateId = token.cityStateId,
        irreversible = true,
        tokenConsumesOnCompletedSession = true,
        tokenConsumesOnConfirmedPlayerAbort = true,
        tokenRefundsOnTechnicalFailure = true,
        totalAttemptsRemaining = math.max(0, record.tokenQuota - record.tokensConsumed),
        attemptsRemainingAfterConsume = math.max(0, record.tokenQuota - record.tokensConsumed - 1),
        warningCode = "PWFT_PAL_DISCOURSE_IRREVERSIBLE_ATTEMPT",
    })
end

function PalReconciliation:begin_discourse(
    faction_id,
    token_instance_id,
    session_id,
    context
)
    context = context or {}
    local preview = self:preview_discourse(faction_id, token_instance_id)
    if not preview.ok then
        return preview
    end
    if context.providerReady ~= true then
        return result(false, "discourse-provider-not-ready-token-preserved", {
            tokenInstanceId = token_instance_id,
            technicalFailure = true,
        })
    end
    if context.userConfirmed ~= true then
        return result(false, "irreversible-confirmation-required", preview)
    end
    local record = self.state.factions[faction_id]
    local token = assert(find_token(record, token_instance_id))
    if session_id == nil then
        session_id = make_session_id(self.state, faction_id)
    else
        require_non_empty_string(session_id, "discourse session ID")
    end
    if record.sessions[session_id] ~= nil then
        return result(false, "duplicate-discourse-session-id")
    end
    token.state = "reserved"
    token.reservedBySessionId = session_id
    record.activeSessionId = session_id
    record.sessions[session_id] = {
        sessionId = session_id,
        factionId = faction_id,
        tokenInstanceId = token_instance_id,
        cityStateId = token.cityStateId,
        state = "active",
        outcome = nil,
        tokenConsumed = false,
        affinityRequested = 0,
        affinityApplied = 0,
        providerKind = context.providerKind or "offline-text-tree",
        resolutionId = nil,
    }
    touch(self, faction_id, {
        type = "pal-discourse-started",
        factionId = faction_id,
        sessionId = session_id,
        tokenInstanceId = token_instance_id,
        cityStateId = token.cityStateId,
        providerKind = record.sessions[session_id].providerKind,
        irreversible = true,
    })
    return result(true, "discourse-started", {
        session = copy(record.sessions[session_id]),
        token = copy(token),
    })
end

local function consume_session_token(record, session, token)
    token.state = "consumed"
    token.reservedBySessionId = nil
    token.consumedBySessionId = session.sessionId
    record.tokensConsumed = record.tokensConsumed + 1
    record.activeSessionId = nil
    session.state = "resolved"
    session.tokenConsumed = true
end

function PalReconciliation:resolve_discourse(
    faction_id,
    session_id,
    outcome,
    affinity_award,
    resolution_id,
    context
)
    local record, failure = faction_state(self, faction_id)
    if failure ~= nil then
        return failure
    end
    require_non_empty_string(session_id, "discourse session ID")
    require_non_empty_string(resolution_id, "discourse resolution ID")
    context = context or {}
    local session = record.sessions[session_id]
    if session == nil then
        return result(false, "unknown-discourse-session")
    end
    if session.state == "resolved" then
        if session.resolutionId == resolution_id then
            return result(true, "duplicate-discourse-resolution", {
                session = copy(session),
                status = self:status(faction_id),
            })
        end
        return result(false, "discourse-session-already-resolved")
    end
    if record.activeSessionId ~= session_id then
        return result(false, "discourse-session-not-active")
    end
    local token = assert(find_token(record, session.tokenInstanceId), "active discourse token is missing")
    assert(token.state == "reserved", "active discourse token must be reserved")
    assert(token.reservedBySessionId == session_id, "reserved token/session mismatch")

    if outcome == "technical_failure" then
        token.state = "quest-complete"
        token.reservedBySessionId = nil
        record.activeSessionId = nil
        record.technicalRefunds = record.technicalRefunds + 1
        session.state = "resolved"
        session.outcome = "technical-failure-refunded"
        session.tokenConsumed = false
        session.affinityRequested = 0
        session.affinityApplied = 0
        session.resolutionId = resolution_id
        session.technicalReason = context.technicalReason
        touch(self, faction_id, {
            type = "pal-discourse-technical-refund",
            factionId = faction_id,
            sessionId = session_id,
            tokenInstanceId = token.tokenInstanceId,
            resolutionId = resolution_id,
            technicalReason = context.technicalReason,
        })
        return result(true, "technical-failure-token-refunded", {
            session = copy(session),
            status = self:status(faction_id),
        })
    end

    if outcome ~= "player_abort" and outcome ~= "completed" then
        return result(false, "unsupported-discourse-outcome")
    end

    local requested = 0
    local award_outcome = nil
    if outcome == "completed" then
        requested = require_non_negative_number(affinity_award or 0, "Pal discourse affinity award")
        requested = math.min(requested, record.maximumAffinityPerDiscourse)
        if requested > 0 then
            award_outcome = self.progression:award_pal_reconciliation(
                faction_id,
                requested,
                {
                    authority = AWARD_AUTHORITY,
                    contextId = session_id,
                    eventId = "pal-discourse:" .. resolution_id,
                }
            )
            if not award_outcome.ok then
                return result(false, "affinity-settlement-failed-token-preserved", {
                    settlement = copy(award_outcome),
                })
            end
        end
    end

    consume_session_token(record, session, token)
    session.outcome = outcome == "player_abort"
        and "player-abort-consumed"
        or "completed-consumed"
    session.affinityRequested = requested
    session.affinityApplied = award_outcome and award_outcome.applied or 0
    session.resolutionId = resolution_id
    session.resultTags = copy(context.resultTags or {})
    local terminal = update_terminal_state(self, record)
    touch(self, faction_id, {
        type = "pal-discourse-resolved",
        factionId = faction_id,
        sessionId = session_id,
        tokenInstanceId = token.tokenInstanceId,
        outcome = session.outcome,
        affinityRequested = requested,
        affinityApplied = session.affinityApplied,
        resolutionId = resolution_id,
        terminal = terminal,
    })
    local reason = "discourse-completed-token-consumed"
    if outcome == "player_abort" then
        reason = "player-abort-token-consumed"
    elseif terminal == "reconciled" then
        reason = "pal-reconciled"
    elseif terminal == "reconciliation-locked-attempts-exhausted" then
        reason = terminal
    end
    return result(true, reason, {
        session = copy(session),
        settlement = copy(award_outcome),
        status = self:status(faction_id),
    })
end

function PalReconciliation:status(faction_id)
    if faction_id == nil then
        local configured = 0
        local reconciled = 0
        local locked = 0
        local active = 0
        for _, pal_faction_id in ipairs(self.contract.palFactionIds) do
            local record = self.state.factions[pal_faction_id]
            if record.configured then
                configured = configured + 1
            end
            if progression_reconciled(self, pal_faction_id) then
                reconciled = reconciled + 1
            elseif record.locked then
                locked = locked + 1
            end
            if record.activeSessionId ~= nil then
                active = active + 1
            end
        end
        return {
            schemaVersion = self.state.schemaVersion,
            apiVersion = self.version,
            revision = self.state.revision,
            eventCount = self.state.eventCount,
            configuredFactionCount = configured,
            palFactionCount = #self.contract.palFactionIds,
            reconciledFactionCount = reconciled,
            permanentlyLockedFactionCount = locked,
            activeSessionCount = active,
            recoveredInterruptedSessionCount = self.recoveredInterruptedSessionCount or 0,
            nativeRaidResultBindingEnabled = self.contract.runtimeActivation.nativeRaidResultBindingEnabled,
            nativeDialoguePresenterEnabled = self.contract.runtimeActivation.nativeDialoguePresenterEnabled,
            agentAdapterEnabled = self.contract.runtimeActivation.agentAdapterEnabled,
            storyContentIncluded = false,
        }
    end
    local record = self.state.factions[faction_id]
    if record == nil then
        return nil
    end
    local counts = token_counts(record)
    local reconciled = progression_reconciled(self, faction_id)
    return {
        factionId = faction_id,
        configured = record.configured,
        contentPackId = record.contentPackId,
        contentVersion = record.contentVersion,
        tokenQuota = record.tokenQuota,
        tokensAwarded = record.tokensAwarded,
        tokensConsumed = record.tokensConsumed,
        futureDropsRemaining = math.max(0, record.tokenQuota - record.tokensAwarded),
        ownedUnconsumedTokens = math.max(0, record.tokensAwarded - record.tokensConsumed),
        totalAttemptsRemaining = math.max(0, record.tokenQuota - record.tokensConsumed),
        questPendingCount = counts.questPending,
        discourseReadyCount = counts.questComplete,
        reservedCount = counts.reserved,
        technicalRefunds = record.technicalRefunds,
        activeSessionId = record.activeSessionId,
        reconciled = reconciled,
        permanentlyLocked = record.locked and not reconciled,
        maximumAffinityPerDiscourse = record.maximumAffinityPerDiscourse,
        targetReputation = self.contract.discoursePolicy.targetReputation,
        currentReputation = self.progression:status(faction_id).reputation,
        unlockGateOpen = self.progression:gate_status().palReconciliationUnlocked,
    }
end

function PalReconciliation:token_status(faction_id, token_instance_id)
    local record = self.state.factions[faction_id]
    if record == nil then
        return nil
    end
    return copy(record.tokens[token_instance_id])
end

-- Return only tokens that can start a discourse session right now.  The
-- virtual ledger remains authoritative; callers cannot mutate the copied
-- entries, and the normal preview gate (all Human Lords, no active session,
-- quest complete, faction not reconciled/locked) is applied to every token.
function PalReconciliation:discourse_ready_tokens(faction_id)
    local record = self.state.factions[faction_id]
    if record == nil then
        return {}
    end
    local token_ids = {}
    for token_instance_id, token in pairs(record.tokens) do
        if token.state == "quest-complete" then
            token_ids[#token_ids + 1] = token_instance_id
        end
    end
    table.sort(token_ids)
    local ready = {}
    for _, token_instance_id in ipairs(token_ids) do
        local preview = self:preview_discourse(
            faction_id,
            token_instance_id
        )
        if preview.ok then
            local token = copy(record.tokens[token_instance_id])
            token.preview = copy(preview)
            ready[#ready + 1] = token
        end
    end
    return ready
end

function PalReconciliation:export_snapshot()
    return copy(self.state)
end

return PalReconciliation
