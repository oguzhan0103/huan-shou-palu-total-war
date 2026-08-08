local Progression = {}

local STATE_SCHEMA_VERSION = "1.0.0"

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

local function sorted_keys(values)
    local keys = {}
    for key, _ in pairs(values or {}) do
        table.insert(keys, key)
    end
    table.sort(keys)
    return keys
end

local function relation_pair_key(faction_a, faction_b)
    if faction_a < faction_b then
        return faction_a .. "|" .. faction_b
    end
    return faction_b .. "|" .. faction_a
end

local function diplomacy_clear_key(target_faction_id, source_faction_id)
    return target_faction_id .. "<-" .. source_faction_id
end

local function contains(values, expected)
    for _, value in ipairs(values or {}) do
        if value == expected then
            return true
        end
    end
    return false
end

local function require_non_empty_string(value, name)
    assert(type(value) == "string" and value ~= "", name .. " must be a non-empty string")
    return value
end

local function require_number(value, name)
    assert(type(value) == "number", name .. " must be a number")
    return value
end

local function validate_contract(contract)
    assert(type(contract) == "table", "faction progression contract is required")
    assert(contract.schemaVersion == "1.0.0", "unsupported faction progression contract schema")
    assert(
        contract.baselineStatus == "user_confirmed_mechanics_baseline_2026-07-28",
        "faction progression baseline is not user-confirmed"
    )
    assert(type(contract.designPolicy) == "table", "progression design policy is required")
    assert(
        contract.designPolicy.multipleHumanMembershipsAllowed == true,
        "multiple human memberships must remain enabled"
    )
    assert(
        contract.designPolicy.reputationDecreaseEnabled == false,
        "reputation decrease is outside the current phase"
    )
    assert(
        contract.designPolicy.palworldSaveMutationAllowed == false,
        "Palworld save mutation must remain disabled"
    )

    local seen = {}
    for _, faction_id in ipairs(contract.humanFactionIds or {}) do
        require_non_empty_string(faction_id, "human faction ID")
        assert(seen[faction_id] == nil, "duplicate progression faction: " .. faction_id)
        seen[faction_id] = "Human"
    end
    for _, faction_id in ipairs(contract.palFactionIds or {}) do
        require_non_empty_string(faction_id, "Pal faction ID")
        assert(seen[faction_id] == nil, "duplicate progression faction: " .. faction_id)
        seen[faction_id] = "Pal"
    end
    assert(#contract.humanFactionIds == 7, "expected seven human factions")
    assert(#contract.palFactionIds == 5, "expected five Pal factions")

    local membership = contract.membershipPolicy
    assert(type(membership) == "table", "membership policy is required")
    assert(
        membership.joinDiplomacyEffectsStatus == "runtime_overlay_and_content_adapter_ready_native_presenter_pending",
        "human faction relation matrix must be ingested before runtime diplomacy work"
    )
    local diplomacy = membership.joinDiplomacyEffects
    assert(type(diplomacy) == "table", "join diplomacy effects contract is required")
    assert(diplomacy.schemaVersion == "1.0.0", "unsupported join diplomacy effects schema")
    assert(diplomacy.defaultUnspecifiedRelation == "Neutral", "unspecified human relations must remain neutral")
    assert(diplomacy.joinedFactionRelation == "Player", "joined human factions must remain Player relation")
    assert(diplomacy.reputationMutationOnJoin == false, "joining a faction must not lower reputation in this phase")

    local valid_pair_relations = {
        Hostile = true,
        Friendly = true,
        Neutral = true,
    }
    local seen_pairs = {}
    for _, pair in ipairs(diplomacy.pairs or {}) do
        local faction_a = require_non_empty_string(pair.factionA, "diplomacy pair faction A")
        local faction_b = require_non_empty_string(pair.factionB, "diplomacy pair faction B")
        assert(faction_a ~= faction_b, "diplomacy pair cannot reference the same faction twice")
        assert(seen[faction_a] == "Human", "diplomacy pair faction A must be human: " .. faction_a)
        assert(seen[faction_b] == "Human", "diplomacy pair faction B must be human: " .. faction_b)
        assert(valid_pair_relations[pair.relation] == true, "invalid diplomacy pair relation")
        local pair_key = faction_a < faction_b and (faction_a .. "|" .. faction_b) or (faction_b .. "|" .. faction_a)
        assert(seen_pairs[pair_key] == nil, "duplicate human diplomacy pair: " .. pair_key)
        seen_pairs[pair_key] = true
    end
    assert(#diplomacy.pairs == 5, "expected five explicit user-confirmed human diplomacy pairs")
    local join_interaction = membership.joinInteraction
    assert(
        type(join_interaction) == "table"
            and join_interaction.enabled == true,
        "join interaction policy is required"
    )
    assert(
        join_interaction.apiVersion == "1.0.0",
        "unsupported join interaction API version"
    )
    assert(
        join_interaction.humanFactionsOnly == true,
        "join interaction must remain human-faction-only"
    )
    assert(
        join_interaction.multipleMembershipsAllowed == true,
        "join interaction must preserve multiple memberships"
    )
    assert(
        join_interaction.requiresRegisteredSource == true
            and join_interaction.requiresExplicitConfirmation == true,
        "join interaction requires a registered source and explicit confirmation"
    )
    assert(
        join_interaction.dialogueContentIncluded == false,
        "join interaction core cannot author dialogue content"
    )

    local previous_threshold = nil
    local rank_ids = {}
    for _, rank in ipairs(contract.rankPolicy.ranks or {}) do
        require_non_empty_string(rank.id, "rank ID")
        require_non_empty_string(rank.displayNameZhHans, "rank display name")
        require_number(rank.minimumReputation, "rank minimum reputation")
        assert(rank_ids[rank.id] == nil, "duplicate rank ID: " .. rank.id)
        assert(
            previous_threshold == nil or rank.minimumReputation > previous_threshold,
            "rank thresholds must be strictly increasing"
        )
        rank_ids[rank.id] = true
        previous_threshold = rank.minimumReputation
    end
    assert(#contract.rankPolicy.ranks == 4, "expected four human membership ranks")
    assert(rank_ids.Member and rank_ids.CoreMember and rank_ids.Leader and rank_ids.Lord, "rank set is incomplete")
    assert(contract.rankPolicy.ranks[3].guardAccess == true, "Leader must unlock player guards")
    assert(contract.rankPolicy.ranks[4].guardAccess == true, "Lord must retain player guards")

    local commerce = contract.reputationSources and contract.reputationSources.commerce or nil
    assert(type(commerce) == "table" and commerce.enabled == true, "commerce reputation source is required")
    require_number(commerce.negativeRecoveryCapPerWindow, "commerce negative recovery cap")
    require_number(commerce.nonNegativeCapPerWindow, "commerce non-negative cap")
    assert(commerce.negativeRecoveryCapPerWindow > commerce.nonNegativeCapPerWindow, "hostile recovery cap must exceed friendly commerce cap")
    local diplomacy_recovery = commerce.diplomacyRecovery
    assert(
        type(diplomacy_recovery) == "table"
            and diplomacy_recovery.enabled == true,
        "commerce diplomacy recovery policy is required"
    )
    require_number(
        diplomacy_recovery.requiredPointsPerHostilitySource,
        "commerce diplomacy recovery threshold"
    )
    require_number(
        diplomacy_recovery.capPerWindow,
        "commerce diplomacy recovery window cap"
    )
    assert(
        diplomacy_recovery.requiredPointsPerHostilitySource > 0,
        "commerce diplomacy recovery threshold must be positive"
    )
    assert(
        diplomacy_recovery.capPerWindow > 0
            and diplomacy_recovery.capPerWindow
                <= commerce.nonNegativeCapPerWindow,
        "commerce diplomacy recovery cap must fit the non-negative commerce cap"
    )
    assert(
        diplomacy_recovery.requiresNonNegativeReputation == true,
        "affiliation hostility cannot clear while numerical reputation is negative"
    )
    assert(
        diplomacy_recovery.carryRemainderAcrossSources == false,
        "one transaction cannot advance multiple hostility sources"
    )

    local pal_reconciliation = contract.reputationSources
        and contract.reputationSources.pal_reconciliation
        or nil
    assert(
        type(pal_reconciliation) == "table"
            and pal_reconciliation.enabled == true,
        "Pal reconciliation reputation source is required"
    )
    assert(
        pal_reconciliation.contentMechanismStatus
            == "finite_token_discourse_contract_ready_content_binding_pending_2026-08-05",
        "Pal reconciliation must use the finite token discourse mechanism"
    )
    assert(
        pal_reconciliation.directReconcileApiEnabled == false,
        "direct Pal reconciliation must stay disabled"
    )
    assert(
        pal_reconciliation.awardAuthority
            == "pal-discourse-service-v1",
        "Pal reconciliation award authority mismatch"
    )
    require_number(
        pal_reconciliation.targetReputation,
        "Pal reconciliation target reputation"
    )

    return seen
end

local function make_initial_state(contract, faction_kinds)
    local state = {
        schemaVersion = STATE_SCHEMA_VERSION,
        revision = 0,
        factions = {},
        unlocks = {
            palReconciliation = false,
            ending3 = false,
        },
        eventCount = 0,
        lastEvent = nil,
        processedEventIds = {},
    }
    for _, faction_id in ipairs(sorted_keys(faction_kinds)) do
        local kind = faction_kinds[faction_id]
        local reputation = contract.initialState.humanReputation
        if kind == "Pal" then
            reputation = contract.initialState.palReputation
        end
        state.factions[faction_id] = {
            factionId = faction_id,
            kind = kind,
            reputation = reputation,
            joined = false,
            rankId = nil,
            relation = nil,
            commerce = {
                windowId = "initial",
                negativeRecoveryAwarded = 0,
                nonNegativeAwarded = 0,
                diplomacyRecoveryAwarded = 0,
                diplomacyRecoveryProgressBySource = {},
                diplomacyRecoveryCompletedCount = 0,
            },
            sourceTotals = {
                task = 0,
                defense = 0,
                commerce = 0,
                pal_reconciliation = 0,
            },
        }
    end
    return state
end

local function validate_snapshot(snapshot, faction_kinds)
    assert(type(snapshot) == "table", "progression snapshot must be a table")
    assert(snapshot.schemaVersion == STATE_SCHEMA_VERSION, "unsupported progression snapshot schema")
    assert(type(snapshot.revision) == "number" and snapshot.revision >= 0, "invalid progression snapshot revision")
    assert(type(snapshot.factions) == "table", "progression snapshot factions are required")
    for faction_id, kind in pairs(faction_kinds) do
        local record = snapshot.factions[faction_id]
        assert(type(record) == "table", "snapshot is missing faction: " .. faction_id)
        assert(record.factionId == faction_id, "snapshot faction key/id mismatch: " .. faction_id)
        assert(record.kind == kind, "snapshot faction kind mismatch: " .. faction_id)
        assert(type(record.reputation) == "number", "snapshot reputation is invalid: " .. faction_id)
        assert(type(record.joined) == "boolean", "snapshot joined flag is invalid: " .. faction_id)
        assert(not (kind == "Pal" and record.joined), "Pal factions cannot be joined")
    end
    for faction_id, _ in pairs(snapshot.factions) do
        assert(faction_kinds[faction_id] ~= nil, "snapshot contains unknown faction: " .. tostring(faction_id))
    end
end

local function add_event(instance, event)
    instance.state.revision = instance.state.revision + 1
    instance.state.eventCount = (instance.state.eventCount or 0) + 1
    event.revision = instance.state.revision
    instance.state.lastEvent = copy(event)
end

local function rank_index(instance, rank_id)
    if rank_id == nil then
        return 0
    end
    return instance.rankIndexes[rank_id] or 0
end

local function faction_pair_relation(instance, faction_a, faction_b)
    if faction_a == faction_b then
        return instance.contract.membershipPolicy.joinDiplomacyEffects.joinedFactionRelation
    end
    return instance.humanRelationMatrix[relation_pair_key(faction_a, faction_b)]
        or instance.contract.membershipPolicy.joinDiplomacyEffects.defaultUnspecifiedRelation
end

local function diplomacy_hostility_sources(instance, target_faction_id)
    local sources = {}
    local cleared = instance.state.diplomacy.clearedHostilityPairs
    for _, source_faction_id in ipairs(instance.contract.humanFactionIds) do
        local source = instance.state.factions[source_faction_id]
        if source_faction_id ~= target_faction_id
            and source.joined == true
            and faction_pair_relation(instance, source_faction_id, target_faction_id) == "Hostile"
            and cleared[diplomacy_clear_key(target_faction_id, source_faction_id)] ~= true then
            table.insert(sources, source_faction_id)
        end
    end
    table.sort(sources)
    return sources
end

local function commerce_diplomacy_recovery_status(instance, record)
    local policy =
        instance.contract.reputationSources.commerce.diplomacyRecovery
    local progress_by_source =
        record.commerce.diplomacyRecoveryProgressBySource or {}
    local unresolved_sources = {}
    if record.kind == "Human" and record.joined ~= true then
        unresolved_sources = diplomacy_hostility_sources(
            instance,
            record.factionId
        )
    end
    local source_progress = {}
    for _, source_faction_id in ipairs(unresolved_sources) do
        local progress = progress_by_source[source_faction_id] or 0
        table.insert(source_progress, {
            sourceFactionId = source_faction_id,
            current = progress,
            required = policy.requiredPointsPerHostilitySource,
            remaining = math.max(
                0,
                policy.requiredPointsPerHostilitySource - progress
            ),
        })
    end
    local active = source_progress[1]
    local window_awarded =
        record.commerce.diplomacyRecoveryAwarded or 0
    return {
        enabled = policy.enabled == true,
        automaticClear = policy.automaticClear == true,
        requiredPerSource =
            policy.requiredPointsPerHostilitySource,
        capPerWindow = policy.capPerWindow,
        windowId = record.commerce.windowId,
        windowAwarded = window_awarded,
        windowRemaining = math.max(
            0,
            policy.capPerWindow - window_awarded
        ),
        requiresNonNegativeReputation =
            policy.requiresNonNegativeReputation == true,
        blockedByNegativeReputation = record.reputation < 0,
        eligible = active ~= nil and record.reputation >= 0,
        activeSourceFactionId =
            active and active.sourceFactionId or nil,
        activeProgress = active and active.current or 0,
        activeRemaining = active and active.remaining or 0,
        unresolvedSourceCount = #source_progress,
        sources = source_progress,
        progressBySource = copy(progress_by_source),
        completedSourceCount =
            record.commerce.diplomacyRecoveryCompletedCount or 0,
        carryRemainderAcrossSources =
            policy.carryRemainderAcrossSources == true,
    }
end

local function rank_for_reputation(instance, reputation)
    local selected_rank =
        instance.contract.rankPolicy.ranks[1]
    for _, rank in ipairs(
        instance.contract.rankPolicy.ranks
    ) do
        if reputation >= rank.minimumReputation then
            selected_rank = rank
        end
    end
    return selected_rank
end

local function refresh_faction(instance, record)
    local hostile_below = instance.contract.relationPolicy.hostileBelowReputation
    if record.kind == "Human" then
        if record.joined then
            record.relation = instance.contract.relationPolicy.joinedHumanRelation
            record.rankId =
                rank_for_reputation(
                    instance,
                    record.reputation
                ).id
        else
            record.rankId = nil
            local diplomacy_sources = diplomacy_hostility_sources(instance, record.factionId)
            record.diplomacyHostilitySources = diplomacy_sources
            if record.reputation < hostile_below or #diplomacy_sources > 0 then
                record.relation = "Hostile"
            else
                record.relation = instance.contract.relationPolicy.nonMemberNonHostileRelation
            end
        end
    else
        record.joined = false
        record.rankId = nil
        record.diplomacyHostilitySources = {}
        if record.reputation < hostile_below then
            record.relation = "Hostile"
        else
            record.relation = instance.contract.relationPolicy.palNonHostileRelation
        end
    end
end

local function refresh_unlocks(instance)
    local required_rank = instance.contract.unlockPolicy.palReconciliation.allHumanFactionsMustReachRank
    local required_rank_index = assert(instance.rankIndexes[required_rank], "unknown Pal reconciliation rank")
    local all_human_lords = true
    for _, faction_id in ipairs(instance.contract.humanFactionIds) do
        local record = instance.state.factions[faction_id]
        if not record.joined or rank_index(instance, record.rankId) < required_rank_index then
            all_human_lords = false
            break
        end
    end
    instance.state.unlocks.palReconciliation = all_human_lords

    local all_pal_friendly = true
    for _, faction_id in ipairs(instance.contract.palFactionIds) do
        if instance.state.factions[faction_id].relation ~= instance.contract.unlockPolicy.ending3.allPalFactionsMustReachRelation then
            all_pal_friendly = false
            break
        end
    end
    instance.state.unlocks.ending3 = all_human_lords and all_pal_friendly
end

local function refresh_all(instance)
    if type(instance.state.processedEventIds) ~= "table" then
        instance.state.processedEventIds = {}
    end
    if type(instance.state.diplomacy) ~= "table" then
        instance.state.diplomacy = {}
    end
    if type(instance.state.diplomacy.clearedHostilityPairs) ~= "table" then
        instance.state.diplomacy.clearedHostilityPairs = {}
    end
    for _, record in pairs(instance.state.factions) do
        if type(record.commerce) ~= "table" then
            record.commerce = {}
        end
        record.commerce.windowId = record.commerce.windowId or "restored"
        record.commerce.negativeRecoveryAwarded = record.commerce.negativeRecoveryAwarded or 0
        record.commerce.nonNegativeAwarded = record.commerce.nonNegativeAwarded or 0
        record.commerce.diplomacyRecoveryAwarded =
            record.commerce.diplomacyRecoveryAwarded or 0
        if type(
            record.commerce.diplomacyRecoveryProgressBySource
        ) ~= "table" then
            record.commerce.diplomacyRecoveryProgressBySource = {}
        end
        record.commerce.diplomacyRecoveryCompletedCount =
            record.commerce.diplomacyRecoveryCompletedCount or 0
        if type(record.sourceTotals) ~= "table" then
            record.sourceTotals = {}
        end
        record.sourceTotals.task = record.sourceTotals.task or 0
        record.sourceTotals.defense = record.sourceTotals.defense or 0
        record.sourceTotals.commerce = record.sourceTotals.commerce or 0
        record.sourceTotals.pal_reconciliation = record.sourceTotals.pal_reconciliation or 0
        record.diplomacyHostilitySources = {}
        refresh_faction(instance, record)
    end
    refresh_unlocks(instance)
end

local function result(ok, reason, extra)
    local value = extra or {}
    value.ok = ok
    value.reason = reason
    return value
end

function Progression.create(contract, snapshot)
    local faction_kinds = validate_contract(contract)
    local instance = {
        contract = copy(contract),
        factionKinds = faction_kinds,
        rankIndexes = {},
        humanRelationMatrix = {},
    }
    for index, rank in ipairs(contract.rankPolicy.ranks) do
        instance.rankIndexes[rank.id] = index
    end
    for _, pair in ipairs(contract.membershipPolicy.joinDiplomacyEffects.pairs) do
        instance.humanRelationMatrix[relation_pair_key(pair.factionA, pair.factionB)] = pair.relation
    end

    if snapshot ~= nil then
        validate_snapshot(snapshot, faction_kinds)
        instance.state = copy(snapshot)
    else
        instance.state = make_initial_state(contract, faction_kinds)
    end
    refresh_all(instance)
    return setmetatable(instance, { __index = Progression })
end

function Progression:status(faction_id)
    if faction_id == nil then
        return {
            schemaVersion = self.state.schemaVersion,
            revision = self.state.revision,
            eventCount = self.state.eventCount,
            palReconciliationUnlocked = self.state.unlocks.palReconciliation,
            ending3Unlocked = self.state.unlocks.ending3,
            persistence = "snapshot-adapter-only",
        }
    end
    local record = self.state.factions[faction_id]
    if record == nil then
        return nil
    end
    local view = copy(record)
    view.guardAccess = self:has_guard_access(faction_id)
    view.joinEligible = self:is_join_eligible(faction_id)
    if record.kind == "Human" then
        view.commerce.diplomacyRecovery =
            commerce_diplomacy_recovery_status(self, record)
    end
    return view
end

function Progression:is_join_eligible(faction_id)
    local record = self.state.factions[faction_id]
    if record == nil or record.kind ~= "Human" or record.joined then
        return false
    end
    return record.reputation >= self.contract.membershipPolicy.joinMinimumReputation
        and record.relation ~= "Hostile"
end

function Progression:join_preview(faction_id)
    local record = self.state.factions[faction_id]
    if record == nil then
        return result(false, "unknown-faction")
    end
    if record.kind ~= "Human" then
        return result(false, "pal-faction-membership-forbidden", {
            factionId = faction_id,
        })
    end
    if record.joined then
        return result(true, "already-joined", {
            factionId = faction_id,
            rankId = record.rankId,
            relation = record.relation,
            joinEligible = false,
            diplomacyChanges = {},
        })
    end
    if record.reputation < self.contract.membershipPolicy.joinMinimumReputation then
        return result(false, "reputation-below-join-threshold", {
            factionId = faction_id,
            reputation = record.reputation,
            requiredReputation =
                self.contract.membershipPolicy.joinMinimumReputation,
            joinEligible = false,
            diplomacyChanges = {},
        })
    end
    if record.relation == "Hostile" then
        return result(false, "diplomacy-hostility-unresolved", {
            factionId = faction_id,
            reputation = record.reputation,
            joinEligible = false,
            diplomacyHostilitySources =
                copy(record.diplomacyHostilitySources),
            diplomacyChanges = {},
        })
    end

    local diplomacy_changes = {}
    local cleared = self.state.diplomacy.clearedHostilityPairs
    for _, target_faction_id in ipairs(
        self.contract.humanFactionIds
    ) do
        if target_faction_id ~= faction_id then
            local target = self.state.factions[target_faction_id]
            local pair_relation = faction_pair_relation(
                self,
                faction_id,
                target_faction_id
            )
            local adds_hostility =
                target.joined ~= true
                and pair_relation == "Hostile"
                and cleared[
                    diplomacy_clear_key(
                        target_faction_id,
                        faction_id
                    )
                ] ~= true
            if adds_hostility then
                table.insert(diplomacy_changes, {
                    factionId = target_faction_id,
                    before = target.relation,
                    after = "Hostile",
                    pairRelation = pair_relation,
                    addsHostilitySource = true,
                    sourceFactionId = faction_id,
                })
            end
        end
    end

    return result(true, "join-available", {
        factionId = faction_id,
        reputation = record.reputation,
        requiredReputation =
            self.contract.membershipPolicy.joinMinimumReputation,
        projectedRankId =
            rank_for_reputation(self, record.reputation).id,
        joinEligible = true,
        multipleMembershipsAllowed = true,
        diplomacyChanges = diplomacy_changes,
    })
end

function Progression:join(faction_id)
    local record = self.state.factions[faction_id]
    if record == nil then
        return result(false, "unknown-faction")
    end
    if record.kind ~= "Human" then
        return result(false, "pal-faction-membership-forbidden")
    end
    if record.joined then
        return result(true, "already-joined", { factionId = faction_id, rankId = record.rankId })
    end
    if not self:is_join_eligible(faction_id) then
        return result(false, "reputation-below-join-threshold")
    end

    local before_relations = {}
    for _, human_faction_id in ipairs(self.contract.humanFactionIds) do
        before_relations[human_faction_id] = self.state.factions[human_faction_id].relation
    end
    record.joined = true
    refresh_all(self)
    local diplomacy_changes = {}
    for _, human_faction_id in ipairs(self.contract.humanFactionIds) do
        local after_relation = self.state.factions[human_faction_id].relation
        if before_relations[human_faction_id] ~= after_relation then
            table.insert(diplomacy_changes, {
                factionId = human_faction_id,
                before = before_relations[human_faction_id],
                after = after_relation,
                hostilitySources = copy(self.state.factions[human_faction_id].diplomacyHostilitySources),
            })
        end
    end
    add_event(self, {
        type = "join",
        factionId = faction_id,
        rankId = record.rankId,
        diplomacyChanges = copy(diplomacy_changes),
    })
    refresh_unlocks(self)
    return result(true, "joined", {
        factionId = faction_id,
        rankId = record.rankId,
        relation = record.relation,
        diplomacyChanges = diplomacy_changes,
    })
end

function Progression:faction_relation(faction_a, faction_b)
    if self.factionKinds[faction_a] ~= "Human" or self.factionKinds[faction_b] ~= "Human" then
        return nil
    end
    return faction_pair_relation(self, faction_a, faction_b)
end

function Progression:clear_diplomacy_hostility(target_faction_id, source_faction_id, context)
    local target = self.state.factions[target_faction_id]
    local source = self.state.factions[source_faction_id]
    if target == nil or source == nil then
        return result(false, "unknown-faction")
    end
    if target.kind ~= "Human" or source.kind ~= "Human" then
        return result(false, "human-factions-required")
    end
    if faction_pair_relation(self, target_faction_id, source_faction_id) ~= "Hostile" then
        return result(false, "factions-not-hostile")
    end
    if source.joined ~= true then
        return result(false, "hostile-affiliation-source-not-joined")
    end

    local clear_key = diplomacy_clear_key(target_faction_id, source_faction_id)
    if self.state.diplomacy.clearedHostilityPairs[clear_key] == true then
        return result(true, "diplomacy-hostility-already-cleared", {
            factionId = target_faction_id,
            sourceFactionId = source_faction_id,
            relation = target.relation,
        })
    end

    local event_id = context and context.eventId or nil
    if event_id ~= nil then
        require_non_empty_string(event_id, "diplomacy recovery event ID")
        if self.state.processedEventIds[event_id] == true then
            return result(true, "duplicate-event", {
                factionId = target_faction_id,
                sourceFactionId = source_faction_id,
                relation = target.relation,
                applied = 0,
            })
        end
    end

    local before = target.relation
    self.state.diplomacy.clearedHostilityPairs[clear_key] = true
    if event_id ~= nil then
        self.state.processedEventIds[event_id] = true
    end
    refresh_all(self)
    add_event(self, {
        type = "diplomacy-recovery",
        factionId = target_faction_id,
        sourceFactionId = source_faction_id,
        before = before,
        after = target.relation,
        contextId = context and context.contextId or nil,
        eventId = event_id,
    })
    return result(true, "diplomacy-hostility-cleared", {
        factionId = target_faction_id,
        sourceFactionId = source_faction_id,
        before = before,
        relation = target.relation,
        applied = 1,
    })
end

function Progression:has_guard_access(faction_id)
    local record = self.state.factions[faction_id]
    if record == nil or not record.joined or record.rankId == nil then
        return false
    end
    for _, rank in ipairs(self.contract.rankPolicy.ranks) do
        if rank.id == record.rankId then
            return rank.guardAccess == true
        end
    end
    return false
end

function Progression:set_commerce_window(faction_id, window_id)
    require_non_empty_string(window_id, "commerce window ID")
    local record = self.state.factions[faction_id]
    if record == nil then
        return result(false, "unknown-faction")
    end
    if record.commerce.windowId ~= window_id then
        record.commerce.windowId = window_id
        record.commerce.negativeRecoveryAwarded = 0
        record.commerce.nonNegativeAwarded = 0
        record.commerce.diplomacyRecoveryAwarded = 0
    end
    return result(true, "commerce-window-ready", {
        factionId = faction_id,
        windowId = window_id,
    })
end

local function grant_commerce(instance, record, requested, context)
    local commerce = instance.contract.reputationSources.commerce
    local window_id = context and context.windowId or record.commerce.windowId or "runtime"
    instance:set_commerce_window(record.factionId, window_id)

    local remaining = requested
    local applied = 0
    local negative_recovery_applied = 0
    local non_negative_applied = 0
    if record.reputation < 0 and remaining > 0 then
        local recovery_room = math.max(
            0,
            commerce.negativeRecoveryCapPerWindow - record.commerce.negativeRecoveryAwarded
        )
        local recovery_needed = -record.reputation
        local recovery_award = math.min(remaining, recovery_room, recovery_needed)
        record.commerce.negativeRecoveryAwarded = record.commerce.negativeRecoveryAwarded + recovery_award
        record.reputation = record.reputation + recovery_award
        remaining = remaining - recovery_award
        applied = applied + recovery_award
        negative_recovery_applied =
            negative_recovery_applied + recovery_award
    end
    if record.reputation >= 0 and remaining > 0 then
        local positive_room = math.max(
            0,
            commerce.nonNegativeCapPerWindow - record.commerce.nonNegativeAwarded
        )
        local positive_award = math.min(remaining, positive_room)
        record.commerce.nonNegativeAwarded = record.commerce.nonNegativeAwarded + positive_award
        record.reputation = record.reputation + positive_award
        applied = applied + positive_award
        non_negative_applied =
            non_negative_applied + positive_award
    end
    return {
        applied = applied,
        negativeRecoveryApplied = negative_recovery_applied,
        nonNegativeApplied = non_negative_applied,
    }
end

local function apply_commerce_diplomacy_recovery(
    instance,
    record,
    eligible_points,
    context
)
    local policy =
        instance.contract.reputationSources.commerce.diplomacyRecovery
    local outcome = {
        enabled = policy.enabled == true,
        eligiblePoints = eligible_points or 0,
        applied = 0,
        cleared = false,
        activeSourceFactionId = nil,
        current = 0,
        required = policy.requiredPointsPerHostilitySource,
        remaining = 0,
        windowRemaining = math.max(
            0,
            policy.capPerWindow
                - (record.commerce.diplomacyRecoveryAwarded or 0)
        ),
        reason = "no-diplomacy-hostility",
    }
    if policy.enabled ~= true or record.kind ~= "Human"
        or record.joined == true then
        outcome.reason = "diplomacy-recovery-not-applicable"
        return outcome
    end
    if context == nil
        or context.diplomacyRecoveryEligible ~= true then
        outcome.reason = "commerce-venue-not-eligible"
        return outcome
    end
    if record.reputation < 0 then
        outcome.reason = "numerical-reputation-still-negative"
        return outcome
    end

    local sources = diplomacy_hostility_sources(
        instance,
        record.factionId
    )
    local source_faction_id = sources[1]
    if source_faction_id == nil then
        return outcome
    end
    outcome.activeSourceFactionId = source_faction_id

    local progress_by_source =
        record.commerce.diplomacyRecoveryProgressBySource
    local before = progress_by_source[source_faction_id] or 0
    local window_room = math.max(
        0,
        policy.capPerWindow
            - record.commerce.diplomacyRecoveryAwarded
    )
    local source_room = math.max(
        0,
        policy.requiredPointsPerHostilitySource - before
    )
    local applied = math.min(
        eligible_points or 0,
        window_room,
        source_room
    )
    if applied <= 0 then
        outcome.current = before
        outcome.remaining = source_room
        outcome.windowRemaining = window_room
        outcome.reason = window_room <= 0
            and "diplomacy-recovery-window-capped"
            or "no-eligible-commerce-points"
        return outcome
    end

    local current = before + applied
    progress_by_source[source_faction_id] = current
    record.commerce.diplomacyRecoveryAwarded =
        record.commerce.diplomacyRecoveryAwarded + applied
    outcome.applied = applied
    outcome.current = current
    outcome.remaining = math.max(
        0,
        policy.requiredPointsPerHostilitySource - current
    )
    outcome.windowRemaining = math.max(
        0,
        policy.capPerWindow
            - record.commerce.diplomacyRecoveryAwarded
    )
    outcome.reason = "diplomacy-recovery-progressed"

    if current >= policy.requiredPointsPerHostilitySource
        and policy.automaticClear == true then
        local clear_event_id = nil
        if context ~= nil and context.eventId ~= nil then
            clear_event_id = "diplomacy-recovery:"
                .. context.eventId
                .. ":"
                .. source_faction_id
        end
        local clear_outcome =
            instance:clear_diplomacy_hostility(
                record.factionId,
                source_faction_id,
                {
                    contextId =
                        context and context.contextId or nil,
                    eventId = clear_event_id,
                }
            )
        outcome.clearOutcome = copy(clear_outcome)
        if clear_outcome.ok == true
            and (
                clear_outcome.reason
                    == "diplomacy-hostility-cleared"
                or clear_outcome.reason
                    == "diplomacy-hostility-already-cleared"
            ) then
            outcome.cleared = true
            outcome.reason =
                "diplomacy-hostility-cleared-by-commerce"
            record.commerce.diplomacyRecoveryCompletedCount =
                record.commerce.diplomacyRecoveryCompletedCount + 1
        else
            outcome.reason = "diplomacy-clear-failed"
        end
    end
    return outcome
end

function Progression:grant_reputation(faction_id, source, amount, context)
    local record = self.state.factions[faction_id]
    if record == nil then
        return result(false, "unknown-faction")
    end
    if type(amount) ~= "number" or amount <= 0 then
        return result(false, "positive-award-required")
    end
    local event_id = context and context.eventId or nil
    if event_id ~= nil then
        require_non_empty_string(event_id, "reputation event ID")
        if self.state.processedEventIds[event_id] == true then
            return result(true, "duplicate-event", {
                factionId = faction_id,
                source = source,
                requested = amount,
                applied = 0,
                after = record.reputation,
                relation = record.relation,
                rankId = record.rankId,
            })
        end
    end
    if source == "pal_reconciliation" then
        return result(false, "use-reconcile-pal-operation")
    end
    local source_policy = self.contract.reputationSources[source]
    if type(source_policy) ~= "table" or source_policy.enabled ~= true then
        return result(false, "unsupported-reputation-source")
    end
    if record.kind == "Pal" then
        return result(false, "pal-reconciliation-mechanism-pending")
    end

    local before = record.reputation
    local applied = 0
    local commerce_award = nil
    if source == "commerce" then
        commerce_award = grant_commerce(
            self,
            record,
            amount,
            context
        )
        applied = commerce_award.applied
    else
        local maximum = source_policy.maximumAwardPerEvent or amount
        applied = math.min(amount, maximum)
        record.reputation = record.reputation + applied
    end

    record.sourceTotals[source] = (record.sourceTotals[source] or 0) + applied
    refresh_faction(self, record)
    if event_id ~= nil
        and (applied > 0 or source == "commerce") then
        self.state.processedEventIds[event_id] = true
    end
    local commerce_diplomacy_recovery = nil
    if applied > 0 then
        add_event(self, {
            type = "reputation",
            factionId = faction_id,
            source = source,
            requested = amount,
            applied = applied,
            before = before,
            after = record.reputation,
            contextId = context and context.contextId or nil,
            eventId = event_id,
            venueMode = context and context.venueMode or nil,
        })
        refresh_unlocks(self)
        if source == "commerce" then
            commerce_diplomacy_recovery =
                apply_commerce_diplomacy_recovery(
                    self,
                    record,
                    commerce_award.nonNegativeApplied,
                    context
                )
        end
    end
    return result(true, applied < amount and "award-capped" or "award-applied", {
        factionId = faction_id,
        source = source,
        requested = amount,
        applied = applied,
        before = before,
        after = record.reputation,
        relation = record.relation,
        rankId = record.rankId,
        commerceBreakdown = commerce_award,
        commerceDiplomacyRecovery =
            commerce_diplomacy_recovery,
    })
end

function Progression:award_pal_reconciliation(
    faction_id,
    amount,
    context
)
    local record = self.state.factions[faction_id]
    if record == nil then
        return result(false, "unknown-faction")
    end
    if record.kind ~= "Pal" then
        return result(false, "human-faction-cannot-use-pal-reconciliation")
    end
    if not self.state.unlocks.palReconciliation then
        return result(false, "pal-reconciliation-locked")
    end
    local policy = self.contract.reputationSources
        .pal_reconciliation
    if context == nil
        or context.authority ~= policy.awardAuthority then
        return result(false, "pal-discourse-authority-required")
    end
    if type(amount) ~= "number" or amount < 0 then
        return result(false, "non-negative-pal-award-required")
    end
    local event_id = context and context.eventId or nil
    if event_id ~= nil then
        require_non_empty_string(event_id, "Pal reconciliation event ID")
        if self.state.processedEventIds[event_id] == true then
            return result(true, "duplicate-event", {
                factionId = faction_id,
                relation = record.relation,
                applied = 0,
            })
        end
    end
    if record.relation == self.contract.relationPolicy.palMaximumRelation then
        return result(true, "already-reconciled", {
            factionId = faction_id,
            relation = record.relation,
        })
    end

    local before = record.reputation
    local target = policy.targetReputation
    local requested = amount
    local applied = math.min(
        requested,
        math.max(0, target - record.reputation)
    )
    record.reputation = record.reputation + applied
    record.sourceTotals.pal_reconciliation = record.sourceTotals.pal_reconciliation + applied
    if event_id ~= nil then
        self.state.processedEventIds[event_id] = true
    end
    refresh_faction(self, record)
    if applied > 0 or event_id ~= nil then
        add_event(self, {
            type = "pal-reconciliation",
            factionId = faction_id,
            requested = requested,
            applied = applied,
            before = before,
            after = record.reputation,
            contextId = context and context.contextId or nil,
            eventId = event_id,
        })
    end
    refresh_unlocks(self)
    local reconciled = record.relation
        == self.contract.relationPolicy.palMaximumRelation
    return result(true, reconciled
        and "pal-reconciled"
        or "pal-reconciliation-progressed", {
        factionId = faction_id,
        requested = requested,
        applied = applied,
        before = before,
        after = record.reputation,
        relation = record.relation,
    })
end

function Progression:reconcile_pal(faction_id, context)
    local record = self.state.factions[faction_id]
    if record == nil then
        return result(false, "unknown-faction")
    end
    if record.kind ~= "Pal" then
        return result(false, "human-faction-cannot-use-pal-reconciliation")
    end
    return result(false, "pal-discourse-service-required", {
        factionId = faction_id,
        relation = record.relation,
        contextId = context and context.contextId or nil,
    })
end

function Progression:relation_events()
    local events = {}
    for revision, faction_id in ipairs(sorted_keys(self.state.factions)) do
        local record = self.state.factions[faction_id]
        table.insert(events, {
            factionId = faction_id,
            state = record.relation,
            revision = revision,
        })
    end
    return events
end

function Progression:export_snapshot()
    return copy(self.state)
end

function Progression:restore_snapshot(snapshot)
    validate_snapshot(snapshot, self.factionKinds)
    self.state = copy(snapshot)
    refresh_all(self)
    return {
        ok = true,
        reason = "snapshot-restored",
        revision = self.state.revision,
    }
end

function Progression:gate_status()
    local missing_human_lords = {}
    local missing_pal_relations = {}
    for _, faction_id in ipairs(self.contract.humanFactionIds) do
        local record = self.state.factions[faction_id]
        if not record.joined or record.rankId ~= self.contract.unlockPolicy.ending3.allHumanFactionsMustReachRank then
            table.insert(missing_human_lords, faction_id)
        end
    end
    for _, faction_id in ipairs(self.contract.palFactionIds) do
        local record = self.state.factions[faction_id]
        if record.relation ~= self.contract.unlockPolicy.ending3.allPalFactionsMustReachRelation then
            table.insert(missing_pal_relations, faction_id)
        end
    end
    return {
        palReconciliationUnlocked = self.state.unlocks.palReconciliation,
        ending3Unlocked = self.state.unlocks.ending3,
        missingHumanLords = missing_human_lords,
        missingPalFriendly = missing_pal_relations,
    }
end

return Progression
