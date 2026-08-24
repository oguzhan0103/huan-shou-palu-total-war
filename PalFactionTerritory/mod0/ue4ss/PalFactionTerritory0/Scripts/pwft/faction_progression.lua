local Progression = {}

local STATE_SCHEMA_VERSION = "1.1.0"
local LEGACY_STATE_SCHEMA_VERSION = "1.0.0"

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

local function stable_sorted_keys(values)
    local keys = {}
    for key, _ in pairs(values or {}) do
        keys[#keys + 1] = key
    end
    table.sort(keys, function(left, right)
        if type(left) == type(right) then
            return left < right
        end
        return type(left) < type(right)
    end)
    return keys
end

local function stable_encode(value)
    local value_type = type(value)
    if value_type == "nil" then
        return "n"
    elseif value_type == "boolean" then
        return value and "b1" or "b0"
    elseif value_type == "number" then
        return "d" .. tostring(value)
    elseif value_type == "string" then
        return "s" .. #value .. ":" .. value
    end
    assert(value_type == "table", "unsupported reputation operation value")
    local parts = { "t{" }
    for _, key in ipairs(stable_sorted_keys(value)) do
        parts[#parts + 1] = stable_encode(key)
        parts[#parts + 1] = stable_encode(value[key])
    end
    parts[#parts + 1] = "}"
    return table.concat(parts)
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
    assert(contract.schemaVersion == "1.1.0", "unsupported faction progression contract schema")
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
        contract.designPolicy.reputationDecreaseEnabled == true,
        "reputation decrease must be enabled for the P0 progression contract"
    )
    assert(
        contract.designPolicy.palworldSaveMutationAllowed == false,
        "Palworld save mutation must remain disabled"
    )

    local mutation = contract.reputationMutationPolicy
    assert(type(mutation) == "table", "reputation mutation policy is required")
    assert(mutation.schemaVersion == "1.0.0", "unsupported reputation mutation policy schema")
    assert(mutation.humanFactionsOnly == true, "reputation deltas must remain human-faction-only")
    assert(mutation.palFactionDecreaseAllowed == false, "Pal-faction affinity decrease must remain disabled")
    assert(mutation.zeroDeltaAllowed == false, "zero-value reputation operations must remain disabled")
    require_number(mutation.minimumReputation, "minimum human reputation")
    require_number(mutation.maximumReputation, "maximum human reputation")
    assert(mutation.minimumReputation < 0, "minimum human reputation must be negative")
    assert(mutation.maximumReputation >= 1200, "maximum human reputation must preserve Lord rank")
    assert(mutation.minimumReputation < mutation.maximumReputation, "invalid reputation bounds")
    assert(mutation.operationIdRequired == true, "reputation operation IDs are required")
    assert(mutation.operationSignatureRequired == true, "reputation operation signatures are required")
    assert(mutation.idempotencyConflictPolicy == "reject", "reputation event conflicts must be rejected")
    assert(mutation.arbitraryClientMutationAllowed == false, "arbitrary client reputation mutation is forbidden")
    assert(mutation.ollamaMutationAllowed == false, "Ollama cannot mutate reputation")
    local authority_ids = {}
    for _, authority in ipairs(mutation.authorities or {}) do
        require_non_empty_string(authority.id, "reputation authority ID")
        assert(authority_ids[authority.id] == nil, "duplicate reputation authority: " .. authority.id)
        authority_ids[authority.id] = true
        assert(type(authority.directions) == "table" and #authority.directions > 0, "reputation authority directions are required")
        assert(type(authority.sources) == "table" and #authority.sources > 0, "reputation authority sources are required")
        assert(type(authority.reasonCodes) == "table" and #authority.reasonCodes > 0, "reputation authority reason codes are required")
        for _, direction in ipairs(authority.directions) do
            assert(direction == "positive" or direction == "negative", "invalid reputation authority direction")
        end
        for _, source in ipairs(authority.sources) do
            require_non_empty_string(source, "reputation authority source")
        end
        for _, reason_code in ipairs(authority.reasonCodes) do
            require_non_empty_string(reason_code, "reputation reason code")
        end
    end
    assert(#mutation.authorities == 4, "expected four authoritative reputation producers")

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
        membership.joinDiplomacyEffectsStatus == "runtime_overlay_content_adapter_and_native_presenter_ready",
        "human faction relation matrix must be ingested before runtime diplomacy work"
    )
    local diplomacy = membership.joinDiplomacyEffects
    assert(type(diplomacy) == "table", "join diplomacy effects contract is required")
    assert(diplomacy.schemaVersion == "1.0.0", "unsupported join diplomacy effects schema")
    assert(diplomacy.defaultUnspecifiedRelation == "Neutral", "unspecified human relations must remain neutral")
    assert(diplomacy.joinedFactionRelation == "Player", "joined human factions must remain Player relation")
    assert(diplomacy.reputationMutationOnJoin == false, "joining a faction must not mutate reputation")
    assert(
        membership.retainJoinedMembershipAtZero == true
            and membership.retainJoinedMembershipBelowZero == true,
        "reputation demotion must retain joined membership"
    )
    assert(
        contract.relationPolicy.joinedHumanHostileRelation == "Hostile",
        "negative joined reputation must become hostile"
    )

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
    assert(contract.rankPolicy.automaticDemotion == true, "automatic rank demotion is required")
    assert(contract.rankPolicy.minimumJoinedRank == "Member", "joined members must demote to Member")
    assert(contract.rankPolicy.ranks[3].guardAccess == true, "Leader must unlock player guards")
    assert(contract.rankPolicy.ranks[4].guardAccess == true, "Lord must retain player guards")

    local commerce = contract.reputationSources and contract.reputationSources.commerce or nil
    assert(type(commerce) == "table" and commerce.enabled == true, "commerce reputation source is required")
    require_number(commerce.totalCapPerWindow, "commerce total window cap")
    require_number(commerce.negativeRecoveryCapPerWindow, "commerce negative recovery cap")
    require_number(commerce.nonNegativeCapPerWindow, "commerce non-negative cap")
    assert(commerce.totalCapPerWindow == 20, "accepted commerce total window cap must remain 20")
    assert(commerce.negativeRecoveryCapPerWindow <= commerce.totalCapPerWindow, "hostile recovery must fit the commerce total cap")
    assert(commerce.nonNegativeCapPerWindow <= commerce.totalCapPerWindow, "friendly commerce must fit the commerce total cap")
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

    local consequence = contract.reputationSources.consequence
    assert(type(consequence) == "table" and consequence.enabled == true, "negative consequence source is required")
    assert(consequence.direction == "negative-only", "consequence reputation must remain negative-only")
    assert(consequence.humanOnly == true, "consequence reputation must remain human-faction-only")
    require_number(consequence.maximumPenaltyPerEvent, "maximum reputation penalty per event")
    assert(consequence.maximumPenaltyPerEvent > 0, "maximum reputation penalty must be positive")
    assert(consequence.authority == "pwft.faction-consequence.v1", "consequence authority mismatch")
    local routing = consequence.routingPolicy
    assert(type(routing) == "table", "consequence routing policy is required")
    assert(routing.schemaVersion == "1.0.0", "unsupported consequence routing policy")
    assert(routing.eventSchemaVersion == "1.0.0", "unsupported consequence event schema")
    assert(routing.exactActorAndClassRequired == true, "actor consequences require exact bindings")
    assert(routing.nativeConfirmationRequired == true, "actor consequences require native confirmation")
    assert(routing.worldGenerationRequiredForActorEvents == true, "actor consequences require world generation fencing")
    assert(routing.modelDispatchAllowed == false, "models cannot dispatch faction consequences")
    assert(routing.arbitraryClientDispatchAllowed == false, "arbitrary clients cannot dispatch faction consequences")
    local native_damage = routing.nativeDamageBinding
    assert(type(native_damage) == "table", "native damage consequence binding is required")
    assert(native_damage.schemaVersion == "1.0.0", "unsupported native damage consequence binding")
    require_non_empty_string(native_damage.sourceBuildId, "native damage source build ID")
    require_non_empty_string(native_damage.currentHostBuildId, "native damage current host build ID")
    require_non_empty_string(native_damage.sourceObjectDumpSha256, "native damage ObjectDump hash")
    assert(string.len(native_damage.sourceObjectDumpSha256) == 64, "native damage ObjectDump hash must be SHA-256")
    require_non_empty_string(native_damage.hookPath, "native damage hook path")
    require_non_empty_string(native_damage.damageResultStruct, "native damage result struct")
    require_non_empty_string(native_damage.attackerField, "native damage attacker field")
    require_non_empty_string(native_damage.defenderField, "native damage defender field")
    require_non_empty_string(native_damage.actualDamageField, "native damage actual-damage field")
    assert(native_damage.exactRegisteredDefenderOnly == true, "native damage requires an exact registered defender")
    assert(native_damage.directLocalPlayerOnly == true, "native damage requires the direct local player")
    assert(native_damage.positiveActualDamageOnly == true, "native damage requires positive actual damage")
    require_number(native_damage.minimumIntervalSecondsPerTarget, "native damage target interval")
    assert(native_damage.minimumIntervalSecondsPerTarget > 0, "native damage target interval must be positive")
    assert(type(native_damage.penaltyByActorRole) == "table", "native damage role penalties are required")
    require_number(native_damage.penaltyByActorRole["faction-member"], "faction-member damage penalty")
    require_number(native_damage.penaltyByActorRole.civilian, "civilian damage penalty")
    assert(native_damage.penaltyByActorRole["faction-member"] > 0, "faction-member damage penalty must be positive")
    assert(native_damage.penaltyByActorRole.civilian > 0, "civilian damage penalty must be positive")
    assert(native_damage.probeEnabled == true, "native damage probe must be enabled")
    assert(native_damage.settlementEnabled == false, "unverified current-build native damage settlement must fail closed")
    require_non_empty_string(native_damage.settlementGate, "native damage settlement gate")
    assert(native_damage.storyContentIncluded == false, "native damage binding cannot include story content")
    local consequence_providers = {}
    local consequence_reason_codes = {}
    for _, provider in ipairs(routing.providers or {}) do
        require_non_empty_string(provider.id, "consequence provider ID")
        require_non_empty_string(provider.authoritySource, "consequence provider authority source")
        assert(consequence_providers[provider.id] == nil, "duplicate consequence provider")
        assert(type(provider.reasonCodes) == "table" and #provider.reasonCodes > 0, "consequence provider reason codes are required")
        consequence_providers[provider.id] = provider.authoritySource
        for _, reason_code in ipairs(provider.reasonCodes) do
            require_non_empty_string(reason_code, "consequence provider reason code")
            assert(consequence_reason_codes[reason_code] == nil, "duplicate consequence reason route")
            consequence_reason_codes[reason_code] = provider.id
        end
    end
    assert(#routing.providers == 3, "expected three consequence provider routes")
    for _, reason_code in ipairs({
        "friendly-fire",
        "civilian-harm",
        "contract-breach",
        "mission-failure",
        "war-consequence",
    }) do
        assert(consequence_reason_codes[reason_code] ~= nil, "missing consequence reason route: " .. reason_code)
    end

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
        legacyOperationSequence = 0,
        processedEventIds = {},
        processedReputationOperations = {},
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
                consequence = 0,
                pal_reconciliation = 0,
            },
        }
    end
    return state
end

local function values_to_set(values)
    local result = {}
    for _, value in ipairs(values or {}) do
        result[value] = true
    end
    return result
end

local function migrate_snapshot(snapshot)
    assert(type(snapshot) == "table", "progression snapshot must be a table")
    if snapshot.schemaVersion == STATE_SCHEMA_VERSION then
        return copy(snapshot), nil
    end
    assert(
        snapshot.schemaVersion == LEGACY_STATE_SCHEMA_VERSION,
        "unsupported progression snapshot schema"
    )
    local migrated = copy(snapshot)
    migrated.schemaVersion = STATE_SCHEMA_VERSION
    migrated.processedReputationOperations =
        migrated.processedReputationOperations or {}
    migrated.legacyOperationSequence = migrated.legacyOperationSequence or 0
    for _, record in pairs(migrated.factions or {}) do
        record.sourceTotals = record.sourceTotals or {}
        record.sourceTotals.consequence =
            record.sourceTotals.consequence or 0
    end
    return migrated, {
        fromSchemaVersion = LEGACY_STATE_SCHEMA_VERSION,
        toSchemaVersion = STATE_SCHEMA_VERSION,
        strategy = "preserve-extensions-add-reputation-operation-ledger",
    }
end

local function validate_snapshot(snapshot, faction_kinds)
    assert(type(snapshot) == "table", "progression snapshot must be a table")
    assert(snapshot.schemaVersion == STATE_SCHEMA_VERSION, "unsupported progression snapshot schema")
    assert(type(snapshot.revision) == "number" and snapshot.revision >= 0, "invalid progression snapshot revision")
    assert(type(snapshot.factions) == "table", "progression snapshot factions are required")
    assert(type(snapshot.processedEventIds) == "table", "progression processed events are required")
    assert(type(snapshot.processedReputationOperations) == "table", "reputation operation ledger is required")
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
            if record.reputation < hostile_below then
                record.relation = instance.contract.relationPolicy.joinedHumanHostileRelation
            else
                record.relation = instance.contract.relationPolicy.joinedHumanRelation
            end
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
    if type(instance.state.processedReputationOperations) ~= "table" then
        instance.state.processedReputationOperations = {}
    end
    instance.state.legacyOperationSequence =
        instance.state.legacyOperationSequence or 0
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
        record.sourceTotals.consequence = record.sourceTotals.consequence or 0
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
        mutationAuthorities = {},
        restoreListeners = {},
        restoreListenerOrder = {},
    }
    for index, rank in ipairs(contract.rankPolicy.ranks) do
        instance.rankIndexes[rank.id] = index
    end
    for _, pair in ipairs(contract.membershipPolicy.joinDiplomacyEffects.pairs) do
        instance.humanRelationMatrix[relation_pair_key(pair.factionA, pair.factionB)] = pair.relation
    end
    for _, authority in ipairs(contract.reputationMutationPolicy.authorities) do
        instance.mutationAuthorities[authority.id] = {
            directions = values_to_set(authority.directions),
            sources = values_to_set(authority.sources),
            reasonCodes = values_to_set(authority.reasonCodes),
        }
    end

    if snapshot ~= nil then
        local migrated, migration = migrate_snapshot(snapshot)
        validate_snapshot(migrated, faction_kinds)
        instance.state = migrated
        instance.lastMigration = migration
    else
        instance.state = make_initial_state(contract, faction_kinds)
        instance.lastMigration = nil
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
            lastMigration = copy(self.lastMigration),
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

    local window_awarded =
        (record.commerce.negativeRecoveryAwarded or 0)
        + (record.commerce.nonNegativeAwarded or 0)
    local remaining = math.min(
        requested,
        math.max(0, commerce.totalCapPerWindow - window_awarded)
    )
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
        local source_event_id = context
            and (context.operationId or context.eventId)
            or nil
        if source_event_id ~= nil then
            clear_event_id = "diplomacy-recovery:"
                .. source_event_id
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

local function mutation_direction(delta)
    return delta < 0 and "negative" or "positive"
end

local function reputation_operation_signature(
    faction_id,
    source,
    delta,
    operation
)
    return stable_encode({
        factionId = faction_id,
        source = source,
        delta = delta,
        authority = operation.authority,
        reasonCode = operation.reasonCode,
        contextId = operation.contextId,
        windowId = operation.windowId,
        diplomacyRecoveryEligible =
            operation.diplomacyRecoveryEligible == true,
        venueMode = operation.venueMode,
    })
end

local function duplicate_reputation_operation(
    instance,
    record,
    operation_id,
    signature
)
    local previous =
        instance.state.processedReputationOperations[operation_id]
    if previous ~= nil then
        if previous.signature ~= signature then
            return result(false, "reputation-operation-id-conflict", {
                factionId = record.factionId,
                operationId = operation_id,
                previousAuthority = previous.authority,
                previousReasonCode = previous.reasonCode,
            })
        end
        return result(true, "duplicate-event", {
            factionId = record.factionId,
            operationId = operation_id,
            source = previous.source,
            requested = previous.requested,
            delta = previous.requested,
            applied = 0,
            originalApplied = previous.applied,
            after = record.reputation,
            relation = record.relation,
            rankId = record.rankId,
            replayed = true,
        })
    end
    if instance.state.processedEventIds[operation_id] == true then
        return result(true, "duplicate-legacy-event", {
            factionId = record.factionId,
            operationId = operation_id,
            applied = 0,
            after = record.reputation,
            relation = record.relation,
            rankId = record.rankId,
            replayed = true,
            signatureUnavailable = true,
        })
    end
    return nil
end

function Progression:apply_reputation_delta(
    faction_id,
    source,
    delta,
    operation
)
    local record = self.state.factions[faction_id]
    if record == nil then
        return result(false, "unknown-faction")
    end
    if record.kind ~= "Human" then
        return result(false, "human-reputation-delta-only")
    end
    if type(delta) ~= "number" or delta == 0 then
        return result(false, "non-zero-reputation-delta-required")
    end
    if type(operation) ~= "table" then
        return result(false, "reputation-operation-required")
    end
    local operation_id = operation.operationId
    local authority_id = operation.authority
    local reason_code = operation.reasonCode
    if type(operation_id) ~= "string" or operation_id == "" then
        return result(false, "reputation-operation-id-required")
    end
    if type(authority_id) ~= "string" or authority_id == "" then
        return result(false, "reputation-authority-required")
    end
    if type(reason_code) ~= "string" or reason_code == "" then
        return result(false, "reputation-reason-code-required")
    end

    local source_policy = self.contract.reputationSources[source]
    if type(source_policy) ~= "table" or source_policy.enabled ~= true then
        return result(false, "unsupported-reputation-source")
    end
    local authority = self.mutationAuthorities[authority_id]
    local direction = mutation_direction(delta)
    if authority == nil
        or authority.directions[direction] ~= true
        or authority.sources[source] ~= true
        or authority.reasonCodes[reason_code] ~= true then
        return result(false, "reputation-authority-policy-rejected", {
            factionId = faction_id,
            source = source,
            direction = direction,
            authority = authority_id,
            reasonCode = reason_code,
        })
    end
    if direction == "negative" and source ~= "consequence" then
        return result(false, "negative-consequence-source-required")
    end
    if direction == "positive" and source == "consequence" then
        return result(false, "consequence-source-is-negative-only")
    end

    local signature = reputation_operation_signature(
        faction_id,
        source,
        delta,
        operation
    )
    local replay = duplicate_reputation_operation(
        self,
        record,
        operation_id,
        signature
    )
    if replay ~= nil then
        return replay
    end

    local mutation_policy = self.contract.reputationMutationPolicy
    local before = record.reputation
    local before_rank_id = record.rankId
    local before_relation = record.relation
    local before_joined = record.joined
    local applied = 0
    local commerce_award = nil
    if direction == "positive" then
        local bounded_request = math.min(
            delta,
            math.max(0, mutation_policy.maximumReputation - before)
        )
        if source == "commerce" then
            commerce_award = grant_commerce(
                self,
                record,
                bounded_request,
                operation
            )
            applied = commerce_award.applied
        else
            local maximum = source_policy.maximumAwardPerEvent or bounded_request
            applied = math.min(bounded_request, maximum)
            record.reputation = record.reputation + applied
        end
    else
        local maximum = source_policy.maximumPenaltyPerEvent
        local requested_magnitude = math.min(-delta, maximum)
        local target = math.max(
            mutation_policy.minimumReputation,
            before - requested_magnitude
        )
        applied = target - before
        record.reputation = target
    end

    record.sourceTotals[source] =
        (record.sourceTotals[source] or 0) + applied
    refresh_faction(self, record)
    refresh_unlocks(self)

    local commerce_diplomacy_recovery = nil
    if source == "commerce" and applied > 0 then
        commerce_diplomacy_recovery =
            apply_commerce_diplomacy_recovery(
                self,
                record,
                commerce_award.nonNegativeApplied,
                operation
            )
    end

    local capped = math.abs(applied) < math.abs(delta)
    local outcome_reason = nil
    if direction == "positive" then
        outcome_reason = capped and "award-capped" or "award-applied"
    else
        outcome_reason = capped and "penalty-capped" or "penalty-applied"
    end
    local after_rank_id = record.rankId
    local rank_changed = before_rank_id ~= after_rank_id
    record.lastReputationChange = {
        operationId = operation_id,
        authority = authority_id,
        reasonCode = reason_code,
        source = source,
        requested = delta,
        applied = applied,
        before = before,
        after = record.reputation,
        beforeRankId = before_rank_id,
        afterRankId = after_rank_id,
        beforeRelation = before_relation,
        afterRelation = record.relation,
    }
    local outcome = result(true, outcome_reason, {
        factionId = faction_id,
        source = source,
        requested = delta,
        delta = delta,
        applied = applied,
        before = before,
        after = record.reputation,
        beforeRelation = before_relation,
        relation = record.relation,
        beforeRankId = before_rank_id,
        rankId = after_rank_id,
        rankChanged = rank_changed,
        promoted = rank_changed
            and rank_index(self, after_rank_id)
                > rank_index(self, before_rank_id),
        demoted = rank_changed
            and rank_index(self, after_rank_id)
                < rank_index(self, before_rank_id),
        membershipRetained = before_joined and record.joined,
        operationId = operation_id,
        authority = authority_id,
        reasonCode = reason_code,
        operationRecorded = true,
        commerceBreakdown = commerce_award,
        commerceDiplomacyRecovery =
            commerce_diplomacy_recovery,
    })

    self.state.processedEventIds[operation_id] = true
    self.state.processedReputationOperations[operation_id] = {
        signature = signature,
        authority = authority_id,
        reasonCode = reason_code,
        source = source,
        requested = delta,
        applied = applied,
    }
    add_event(self, {
        type = "reputation-delta",
        factionId = faction_id,
        source = source,
        requested = delta,
        applied = applied,
        before = before,
        after = record.reputation,
        beforeRankId = before_rank_id,
        afterRankId = after_rank_id,
        beforeRelation = before_relation,
        afterRelation = record.relation,
        authority = authority_id,
        reasonCode = reason_code,
        contextId = operation.contextId,
        eventId = operation_id,
        venueMode = operation.venueMode,
    })
    return outcome
end

function Progression:grant_reputation(faction_id, source, amount, context)
    if type(amount) ~= "number" or amount <= 0 then
        return result(false, "positive-award-required")
    end
    if source == "pal_reconciliation" then
        return result(false, "use-reconcile-pal-operation")
    end
    local legacy_authorities = {
        task = {
            authority = "pwft.task-award.v1",
            reasonCode = "task-completed",
        },
        defense = {
            authority = "pwft.defense-award.v1",
            reasonCode = "defense-resolved",
        },
        commerce = {
            authority = "pwft.commerce-award.v1",
            reasonCode = "commerce-confirmed",
        },
    }
    local producer = legacy_authorities[source]
    if producer == nil then
        return result(false, "unsupported-reputation-source")
    end
    context = context or {}
    local operation_id = context.eventId
    if operation_id == nil then
        self.state.legacyOperationSequence =
            self.state.legacyOperationSequence + 1
        operation_id = string.format(
            "legacy:%s:%d",
            source,
            self.state.legacyOperationSequence
        )
    end
    return self:apply_reputation_delta(
        faction_id,
        source,
        amount,
        {
            operationId = operation_id,
            authority = producer.authority,
            reasonCode = producer.reasonCode,
            contextId = context.contextId,
            windowId = context.windowId,
            diplomacyRecoveryEligible =
                context.diplomacyRecoveryEligible == true,
            venueMode = context.venueMode,
        }
    )
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

function Progression.migrate_snapshot(snapshot)
    local migrated, migration = migrate_snapshot(snapshot)
    return migrated, copy(migration)
end

function Progression:register_restore_listener(listener_id, listener)
    require_non_empty_string(listener_id, "restore listener ID")
    assert(type(listener) == "function", "restore listener must be a function")
    if self.restoreListeners[listener_id] ~= nil then
        return result(false, "restore-listener-id-conflict", {
            listenerId = listener_id,
        })
    end
    self.restoreListeners[listener_id] = listener
    self.restoreListenerOrder[#self.restoreListenerOrder + 1] = listener_id
    return result(true, "restore-listener-registered", {
        listenerId = listener_id,
    })
end

function Progression:restore_listener_status()
    return {
        count = #self.restoreListenerOrder,
        listenerIds = copy(self.restoreListenerOrder),
    }
end

function Progression:restore_snapshot(snapshot)
    local migrated, migration = migrate_snapshot(snapshot)
    validate_snapshot(migrated, self.factionKinds)
    local previous_state = self.state
    local previous_migration = self.lastMigration
    self.state = migrated
    self.lastMigration = migration
    local refresh_ok, refresh_error = pcall(refresh_all, self)
    if not refresh_ok then
        self.state = previous_state
        self.lastMigration = previous_migration
        refresh_all(self)
        error("snapshot refresh failed: " .. tostring(refresh_error))
    end

    local listener_failure = nil
    for _, listener_id in ipairs(self.restoreListenerOrder) do
        local listener = self.restoreListeners[listener_id]
        local called, response, response_reason = pcall(
            listener,
            {
                phase = "apply",
                listenerId = listener_id,
            }
        )
        if not called then
            listener_failure = listener_id .. ":" .. tostring(response)
            break
        end
        if response == false
            or (type(response) == "table" and response.ok == false) then
            local reason = response_reason
            if type(response) == "table" then
                reason = response.reason
            end
            listener_failure = listener_id .. ":"
                .. tostring(reason or "listener-rejected-restore")
            break
        end
    end
    if listener_failure ~= nil then
        local rejected_state = self.state
        self.state = previous_state
        self.lastMigration = previous_migration
        refresh_all(self)
        for _, listener_id in ipairs(self.restoreListenerOrder) do
            pcall(
                self.restoreListeners[listener_id],
                {
                    phase = "rollback",
                    listenerId = listener_id,
                    rejectedState = rejected_state,
                }
            )
        end
        error("snapshot restore listener failed: " .. listener_failure)
    end
    return {
        ok = true,
        reason = "snapshot-restored",
        revision = self.state.revision,
        reboundListenerCount = #self.restoreListenerOrder,
        migration = copy(migration),
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
