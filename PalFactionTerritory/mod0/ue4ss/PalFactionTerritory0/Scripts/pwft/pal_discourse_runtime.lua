local PalDiscourseRuntime = {}

local API_VERSION = "1.0.0"

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

local function result(ok, reason, extra)
    local value = extra or {}
    value.ok = ok
    value.reason = reason
    return value
end

local function require_non_empty_string(value, name)
    assert(type(value) == "string" and value ~= "", name .. " must be a non-empty string")
    return value
end

local function require_positive_integer(value, name)
    assert(type(value) == "number" and value > 0 and value == math.floor(value), name .. " must be a positive integer")
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

local function validate_policy(contract, config)
    local policy = contract.offlineDialogueTreePolicy
    assert(type(policy) == "table", "offline Pal dialogue-tree policy is required")
    assert(policy.runtimeEnabled == true, "offline Pal dialogue-tree runtime must be enabled")
    assert(policy.nativePresenterEnabled == false, "native Pal dialogue presenter requires live acceptance")
    assert(policy.representativeRegistrationRequired == true, "Pal representative registration must be required")
    assert(policy.explicitIrreversibleConfirmationRequired == true, "irreversible confirmation must be required")
    assert(policy.baseStoryContentIncluded == false, "base Mod cannot include authored Pal story content")
    assert(policy.inlineTextAllowed == false, "Pal dialogue packs must use localization keys")
    assert(policy.deterministicRuleEngineOwnsOutcome == true, "deterministic rules must own Pal dialogue outcomes")
    assert(policy.agentMayMutateState == false, "agents cannot mutate Pal dialogue state")
    assert(policy.graphMustBeAcyclic == true, "Pal dialogue trees must be acyclic")
    assert(policy.allNodesMustBeReachable == true, "unreachable Pal dialogue nodes are forbidden")
    assert(policy.allPathsMustReachTerminal == true, "every Pal dialogue path must terminate")
    assert(type(config) == "table", "Pal discourse runtime configuration is required")
    assert(config.offlineDialogueTreeEnabled == true, "offline Pal dialogue-tree runtime is disabled")
    assert(config.nativeDialoguePresenterEnabled == false, "native Pal dialogue presenter requires live acceptance")
    return policy
end

local function reject_inline_text(value, context)
    assert(value.text == nil, context .. " cannot contain inline text")
    assert(value.label == nil, context .. " cannot contain an inline label")
    assert(value.displayName == nil, context .. " cannot contain an inline display name")
end

local function validate_tree(policy, tree, human_city_ids, maximum_affinity)
    assert(type(tree) == "table", "Pal dialogue tree is required")
    local tree_id = require_non_empty_string(tree.treeId, "Pal dialogue tree ID")
    local city_state_id = require_non_empty_string(tree.cityStateId, "Pal dialogue city-state ID")
    assert(city_state_id == "*" or human_city_ids[city_state_id], "unknown Pal dialogue city-state ID")
    local root_node_id = require_non_empty_string(tree.rootNodeId, "Pal dialogue root node ID")
    assert(type(tree.nodes) == "table", "Pal dialogue nodes are required")
    assert(#tree.nodes > 0 and #tree.nodes <= policy.maximumNodesPerTree, "Pal dialogue node count is invalid")

    local nodes = {}
    for _, node in ipairs(tree.nodes) do
        assert(type(node) == "table", "Pal dialogue node is required")
        reject_inline_text(node, "Pal dialogue node")
        local node_id = require_non_empty_string(node.nodeId, "Pal dialogue node ID")
        assert(nodes[node_id] == nil, "duplicate Pal dialogue node ID: " .. node_id)
        assert(node.speakerRole == "pal-representative" or node.speakerRole == "player", "unsupported Pal dialogue speaker role")
        require_non_empty_string(node.textKey, "Pal dialogue text key")
        local has_terminal = node.terminal ~= nil
        local has_choices = type(node.choices) == "table" and #node.choices > 0
        assert(has_terminal ~= has_choices, "Pal dialogue node must have choices or one terminal")
        local normalized = {
            nodeId = node_id,
            speakerRole = node.speakerRole,
            textKey = node.textKey,
            choices = {},
            choiceById = {},
            terminal = nil,
        }
        if has_terminal then
            assert(type(node.terminal) == "table", "Pal dialogue terminal is invalid")
            local outcome = require_non_empty_string(node.terminal.outcome, "Pal dialogue terminal outcome")
            assert(outcome == "completed" or outcome == "player_abort", "unsupported authored Pal dialogue terminal")
            local affinity = node.terminal.affinityAward or 0
            assert(type(affinity) == "number" and affinity >= 0 and affinity <= maximum_affinity, "Pal dialogue terminal affinity exceeds the registered maximum")
            if outcome == "player_abort" then
                assert(affinity == 0, "player-abort terminal cannot award affinity")
            end
            normalized.terminal = {
                outcome = outcome,
                affinityAward = affinity,
                resultTags = copy(node.terminal.resultTags or {}),
            }
            list_to_set(normalized.terminal.resultTags, "Pal dialogue result tag")
        else
            for _, choice in ipairs(node.choices) do
                assert(type(choice) == "table", "Pal dialogue choice is required")
                reject_inline_text(choice, "Pal dialogue choice")
                local choice_id = require_non_empty_string(choice.choiceId, "Pal dialogue choice ID")
                assert(normalized.choiceById[choice_id] == nil, "duplicate Pal dialogue choice ID")
                local item = {
                    choiceId = choice_id,
                    textKey = require_non_empty_string(choice.textKey, "Pal dialogue choice text key"),
                    nextNodeId = require_non_empty_string(choice.nextNodeId, "Pal dialogue next node ID"),
                }
                normalized.choices[#normalized.choices + 1] = item
                normalized.choiceById[choice_id] = item
            end
        end
        nodes[node_id] = normalized
    end
    assert(nodes[root_node_id] ~= nil, "Pal dialogue root node is missing")
    assert(nodes[root_node_id].terminal == nil, "Pal dialogue root cannot be terminal")

    for _, node in pairs(nodes) do
        for _, choice in ipairs(node.choices) do
            assert(nodes[choice.nextNodeId] ~= nil, "Pal dialogue choice targets an unknown node")
        end
    end
    local colors = {}
    local reached = {}
    local function visit(node_id)
        assert(colors[node_id] ~= 1, "Pal dialogue tree contains a cycle")
        if colors[node_id] == 2 then
            return
        end
        colors[node_id] = 1
        reached[node_id] = true
        local node = nodes[node_id]
        if node.terminal == nil then
            assert(#node.choices > 0, "non-terminal Pal dialogue node has no choices")
            for _, choice in ipairs(node.choices) do
                visit(choice.nextNodeId)
            end
        end
        colors[node_id] = 2
    end
    visit(root_node_id)
    local reached_count = 0
    for _, _ in pairs(reached) do
        reached_count = reached_count + 1
    end
    assert(reached_count == #tree.nodes, "Pal dialogue tree contains unreachable nodes")
    return {
        treeId = tree_id,
        cityStateId = city_state_id,
        rootNodeId = root_node_id,
        nodes = nodes,
        nodeCount = reached_count,
    }
end

local function public_node(node)
    local value = {
        nodeId = node.nodeId,
        speakerRole = node.speakerRole,
        textKey = node.textKey,
        terminal = node.terminal and copy(node.terminal) or nil,
        choices = {},
    }
    for _, choice in ipairs(node.choices) do
        value.choices[#value.choices + 1] = {
            choiceId = choice.choiceId,
            textKey = choice.textKey,
        }
    end
    return value
end

function PalDiscourseRuntime.create(reconciliation, config)
    assert(type(reconciliation) == "table", "Pal reconciliation service is required")
    assert(type(reconciliation.preview_discourse) == "function", "Pal reconciliation preview API is required")
    assert(type(reconciliation.begin_discourse) == "function", "Pal reconciliation begin API is required")
    assert(type(reconciliation.resolve_discourse) == "function", "Pal reconciliation resolution API is required")
    local policy = validate_policy(reconciliation.contract, config)
    return setmetatable({
        version = API_VERSION,
        reconciliation = reconciliation,
        policy = policy,
        factions = {},
        representatives = {},
        offers = {},
        requestIds = {},
        confirmationIds = {},
        sessions = {},
        actionIds = {},
        capabilities = {
            localizationKeysOnly = true,
            deterministicOfflineTrees = true,
            registeredRepresentativesOnly = true,
            explicitIrreversibleConfirmation = true,
            technicalFailureRefund = true,
            authoredStoryContent = false,
            nativePresenter = false,
            agentStateMutation = false,
            PalworldSaveMutation = false,
        },
    }, { __index = PalDiscourseRuntime })
end

function PalDiscourseRuntime:register_pack(pack)
    local ok, normalized_or_error = pcall(function()
        assert(type(pack) == "table", "Pal discourse content pack is required")
        assert(pack.schemaVersion == "1.0.0", "unsupported Pal discourse content-pack schema")
        reject_inline_text(pack, "Pal discourse content pack")
        local pack_id = require_non_empty_string(pack.contentPackId, "Pal discourse content-pack ID")
        local version = require_non_empty_string(pack.contentVersion, "Pal discourse content version")
        assert(type(pack.factions) == "table" and #pack.factions > 0, "Pal discourse faction content is required")
        local normalized = {
            contentPackId = pack_id,
            contentVersion = version,
            factions = {},
        }
        local pack_factions = {}
        local pack_representatives = {}
        for _, item in ipairs(pack.factions) do
            assert(type(item) == "table", "Pal discourse faction entry is required")
            local faction_id = require_non_empty_string(item.factionId, "Pal discourse faction ID")
            assert(self.reconciliation.palFactionIds[faction_id] == true, "Pal discourse content requires a Pal faction")
            assert(pack_factions[faction_id] == nil, "duplicate Pal discourse faction entry")
            local quota = require_positive_integer(item.tokenQuota, "Pal discourse token quota")
            local maximum = item.maximumAffinityPerDiscourse
            assert(type(maximum) == "number" and maximum > 0 and maximum <= 100, "invalid Pal discourse maximum affinity")
            assert(type(item.representative) == "table", "Pal discourse representative is required")
            reject_inline_text(item.representative, "Pal discourse representative")
            local representative_id = require_non_empty_string(item.representative.representativeId, "Pal representative ID")
            assert(self.representatives[representative_id] == nil and pack_representatives[representative_id] == nil, "duplicate Pal representative ID")
            local representative = {
                representativeId = representative_id,
                factionId = faction_id,
                nameKey = require_non_empty_string(item.representative.nameKey, "Pal representative name key"),
                interactionPromptKey = require_non_empty_string(item.representative.interactionPromptKey, "Pal representative interaction prompt key"),
                nativeBinding = nil,
            }
            local trees = {}
            local tree_by_city = {}
            assert(type(item.trees) == "table" and #item.trees > 0, "Pal discourse trees are required")
            for _, tree in ipairs(item.trees) do
                local normalized_tree = validate_tree(self.policy, tree, self.reconciliation.humanCityStateIds, maximum)
                assert(trees[normalized_tree.treeId] == nil, "duplicate Pal dialogue tree ID")
                assert(tree_by_city[normalized_tree.cityStateId] == nil, "duplicate Pal dialogue city-state selector")
                trees[normalized_tree.treeId] = normalized_tree
                tree_by_city[normalized_tree.cityStateId] = normalized_tree
            end
            if tree_by_city["*"] == nil then
                for city_state_id, _ in pairs(self.reconciliation.humanCityStateIds) do
                    assert(tree_by_city[city_state_id] ~= nil, "Pal discourse pack lacks a city-state tree or wildcard")
                end
            end
            local faction = {
                factionId = faction_id,
                contentPackId = pack_id,
                contentVersion = version,
                tokenQuota = quota,
                maximumAffinityPerDiscourse = maximum,
                representative = representative,
                trees = trees,
                treeByCityState = tree_by_city,
            }
            pack_factions[faction_id] = faction
            pack_representatives[representative_id] = representative
            normalized.factions[#normalized.factions + 1] = faction
        end
        return normalized
    end)
    if not ok then
        return result(false, "invalid-pal-discourse-content-pack", {
            validationError = tostring(normalized_or_error),
        })
    end
    local normalized = normalized_or_error
    for _, faction in ipairs(normalized.factions) do
        if self.factions[faction.factionId] ~= nil then
            return result(false, "pal-discourse-content-migration-required", {
                factionId = faction.factionId,
            })
        end
        local current = self.reconciliation:status(faction.factionId)
        if current.configured
            and (
                current.contentPackId ~= faction.contentPackId
                or current.contentVersion ~= faction.contentVersion
                or current.tokenQuota ~= faction.tokenQuota
                or current.maximumAffinityPerDiscourse
                    ~= faction.maximumAffinityPerDiscourse
            ) then
            return result(false, "pal-reconciliation-content-migration-required", {
                factionId = faction.factionId,
            })
        end
    end
    for _, faction in ipairs(normalized.factions) do
        local registration = self.reconciliation:register_content(
            faction.factionId,
            {
                contentPackId = faction.contentPackId,
                contentVersion = faction.contentVersion,
                tokenQuota = faction.tokenQuota,
                maximumAffinityPerDiscourse = faction.maximumAffinityPerDiscourse,
            }
        )
        if not registration.ok then
            return result(false, "pal-reconciliation-content-registration-failed", {
                factionId = faction.factionId,
                registration = copy(registration),
            })
        end
        self.factions[faction.factionId] = faction
        self.representatives[faction.representative.representativeId] = faction.representative
    end
    return result(true, "pal-discourse-content-pack-registered", {
        contentPackId = normalized.contentPackId,
        contentVersion = normalized.contentVersion,
        factionCount = #normalized.factions,
    })
end

function PalDiscourseRuntime:offer(representative_id, token_instance_id, request_id)
    require_non_empty_string(representative_id, "Pal representative ID")
    require_non_empty_string(token_instance_id, "Pal token instance ID")
    require_non_empty_string(request_id, "Pal discourse request ID")
    local existing_offer_id = self.requestIds[request_id]
    if existing_offer_id ~= nil then
        local existing = self.offers[existing_offer_id]
        if existing.representativeId ~= representative_id or existing.tokenInstanceId ~= token_instance_id then
            return result(false, "pal-discourse-request-id-conflict")
        end
        return result(true, "pal-discourse-offer-already-created", copy(existing))
    end
    local representative = self.representatives[representative_id]
    if representative == nil then
        return result(false, "unknown-pal-representative")
    end
    local faction = self.factions[representative.factionId]
    local token = self.reconciliation:token_status(representative.factionId, token_instance_id)
    if token == nil then
        return result(false, "token-does-not-belong-to-representative-faction")
    end
    local tree = faction.treeByCityState[token.cityStateId] or faction.treeByCityState["*"]
    if tree == nil then
        return result(false, "no-pal-discourse-tree-for-token-city")
    end
    local preview = self.reconciliation:preview_discourse(representative.factionId, token_instance_id)
    if not preview.ok then
        return result(false, "pal-discourse-unavailable", {
            eligibilityReason = preview.reason,
            preview = copy(preview),
        })
    end
    local offer_id = "pal-discourse-offer:" .. request_id
    local offer = {
        offerId = offer_id,
        requestId = request_id,
        representativeId = representative_id,
        representativeNameKey = representative.nameKey,
        interactionPromptKey = representative.interactionPromptKey,
        factionId = representative.factionId,
        tokenInstanceId = token_instance_id,
        cityStateId = token.cityStateId,
        treeId = tree.treeId,
        contentPackId = faction.contentPackId,
        contentVersion = faction.contentVersion,
        state = "pending-confirmation",
        explicitConfirmationRequired = true,
        irreversible = true,
        warningCode = preview.warningCode,
        attemptsRemainingAfterConsume = preview.attemptsRemainingAfterConsume,
    }
    self.offers[offer_id] = offer
    self.requestIds[request_id] = offer_id
    return result(true, "pal-discourse-offer-ready", copy(offer))
end

function PalDiscourseRuntime:confirm(offer_id, confirmation_id, accepted)
    require_non_empty_string(offer_id, "Pal discourse offer ID")
    require_non_empty_string(confirmation_id, "Pal discourse confirmation ID")
    assert(type(accepted) == "boolean", "Pal discourse confirmation must be boolean")
    local previous = self.confirmationIds[confirmation_id]
    if previous ~= nil then
        if previous ~= offer_id then
            return result(false, "pal-discourse-confirmation-id-conflict")
        end
        return result(true, "pal-discourse-confirmation-already-processed", copy(self.offers[offer_id].resolution))
    end
    local offer = self.offers[offer_id]
    if offer == nil then
        return result(false, "unknown-pal-discourse-offer")
    end
    if offer.state ~= "pending-confirmation" then
        return result(true, "pal-discourse-offer-already-resolved", copy(offer.resolution))
    end
    self.confirmationIds[confirmation_id] = offer_id
    if not accepted then
        offer.state = "declined"
        offer.resolution = {
            offerId = offer_id,
            confirmationId = confirmation_id,
            tokenConsumed = false,
        }
        return result(true, "pal-discourse-declined-token-preserved", copy(offer.resolution))
    end
    local faction = self.factions[offer.factionId]
    if faction == nil or faction.contentPackId ~= offer.contentPackId or faction.contentVersion ~= offer.contentVersion then
        offer.state = "stale"
        return result(false, "pal-discourse-offer-stale-content")
    end
    local preview = self.reconciliation:preview_discourse(offer.factionId, offer.tokenInstanceId)
    if not preview.ok then
        offer.state = "stale"
        offer.resolution = {
            eligibilityReason = preview.reason,
            tokenConsumed = false,
        }
        return result(false, "pal-discourse-offer-stale", copy(offer.resolution))
    end
    local tree = faction.trees[offer.treeId]
    local session_id = "pal-tree-session:" .. confirmation_id
    local begun = self.reconciliation:begin_discourse(
        offer.factionId,
        offer.tokenInstanceId,
        session_id,
        {
            providerReady = true,
            userConfirmed = true,
            providerKind = "offline-text-tree",
        }
    )
    if not begun.ok then
        offer.state = "failed"
        offer.resolution = copy(begun)
        return result(false, "pal-discourse-session-start-failed", {
            begin = copy(begun),
        })
    end
    local session = {
        sessionId = session_id,
        offerId = offer_id,
        factionId = offer.factionId,
        tokenInstanceId = offer.tokenInstanceId,
        treeId = tree.treeId,
        contentPackId = offer.contentPackId,
        contentVersion = offer.contentVersion,
        state = "active",
        currentNodeId = tree.rootNodeId,
        stepCount = 0,
        resolution = nil,
    }
    self.sessions[session_id] = session
    offer.state = "active"
    offer.resolution = {
        sessionId = session_id,
        tokenConsumed = false,
    }
    return result(true, "pal-discourse-session-started", {
        sessionId = session_id,
        node = public_node(tree.nodes[tree.rootNodeId]),
    })
end

function PalDiscourseRuntime:choose(session_id, choice_id, action_id)
    require_non_empty_string(session_id, "Pal discourse session ID")
    require_non_empty_string(choice_id, "Pal discourse choice ID")
    require_non_empty_string(action_id, "Pal discourse action ID")
    local previous = self.actionIds[action_id]
    if previous ~= nil then
        if previous.sessionId ~= session_id or previous.choiceId ~= choice_id then
            return result(false, "pal-discourse-action-id-conflict")
        end
        return result(true, "pal-discourse-action-already-processed", copy(previous.response))
    end
    local session = self.sessions[session_id]
    if session == nil then
        return result(false, "unknown-pal-discourse-session")
    end
    if session.state ~= "active" then
        return result(false, "pal-discourse-session-not-active", copy(session.resolution))
    end
    local faction = self.factions[session.factionId]
    local tree = faction and faction.trees[session.treeId]
    if tree == nil or faction.contentPackId ~= session.contentPackId or faction.contentVersion ~= session.contentVersion then
        return result(false, "pal-discourse-session-content-unavailable")
    end
    local node = tree.nodes[session.currentNodeId]
    local choice = node.choiceById[choice_id]
    if choice == nil then
        return result(false, "unknown-pal-discourse-choice")
    end
    session.currentNodeId = choice.nextNodeId
    session.stepCount = session.stepCount + 1
    local next_node = tree.nodes[session.currentNodeId]
    local response
    if next_node.terminal == nil then
        response = result(true, "pal-discourse-node-ready", {
            sessionId = session_id,
            stepCount = session.stepCount,
            node = public_node(next_node),
        })
    else
        local terminal = next_node.terminal
        local resolution_id = "pal-tree-resolution:" .. action_id
        local settled = self.reconciliation:resolve_discourse(
            session.factionId,
            session.sessionId,
            terminal.outcome,
            terminal.affinityAward,
            resolution_id,
            { resultTags = terminal.resultTags }
        )
        if not settled.ok then
            session.currentNodeId = node.nodeId
            session.stepCount = session.stepCount - 1
            return result(false, "pal-discourse-terminal-settlement-failed", {
                settlement = copy(settled),
            })
        end
        session.state = "resolved"
        session.resolution = copy(settled)
        response = result(true, "pal-discourse-terminal-resolved", {
            sessionId = session_id,
            terminal = copy(terminal),
            settlement = copy(settled),
        })
    end
    self.actionIds[action_id] = {
        sessionId = session_id,
        choiceId = choice_id,
        response = copy(response),
    }
    return response
end

function PalDiscourseRuntime:player_abort(session_id, abort_id)
    require_non_empty_string(session_id, "Pal discourse session ID")
    require_non_empty_string(abort_id, "Pal discourse abort ID")
    local session = self.sessions[session_id]
    if session == nil then
        return result(false, "unknown-pal-discourse-session")
    end
    if session.state ~= "active" then
        return result(true, "pal-discourse-session-already-resolved", copy(session.resolution))
    end
    local settled = self.reconciliation:resolve_discourse(
        session.factionId,
        session_id,
        "player_abort",
        0,
        "pal-tree-abort:" .. abort_id
    )
    if settled.ok then
        session.state = "resolved"
        session.resolution = copy(settled)
    end
    return result(settled.ok == true,
        settled.ok and "pal-discourse-player-abort-consumed" or "pal-discourse-player-abort-failed",
        { settlement = copy(settled) }
    )
end

function PalDiscourseRuntime:technical_failure(session_id, failure_id, technical_reason)
    require_non_empty_string(session_id, "Pal discourse session ID")
    require_non_empty_string(failure_id, "Pal discourse failure ID")
    require_non_empty_string(technical_reason, "Pal discourse technical reason")
    local session = self.sessions[session_id]
    if session == nil then
        return result(false, "unknown-pal-discourse-session")
    end
    if session.state ~= "active" then
        return result(true, "pal-discourse-session-already-resolved", copy(session.resolution))
    end
    local settled = self.reconciliation:resolve_discourse(
        session.factionId,
        session_id,
        "technical_failure",
        0,
        "pal-tree-technical:" .. failure_id,
        { technicalReason = technical_reason }
    )
    if settled.ok then
        session.state = "technical-refund"
        session.resolution = copy(settled)
    end
    return result(settled.ok == true,
        settled.ok and "pal-discourse-technical-failure-refunded" or "pal-discourse-technical-failure-settlement-failed",
        { settlement = copy(settled) }
    )
end

function PalDiscourseRuntime:session_status(session_id)
    local session = self.sessions[session_id]
    if session == nil then
        return nil
    end
    local value = copy(session)
    if session.state == "active" then
        local faction = self.factions[session.factionId]
        local tree = faction and faction.trees[session.treeId]
        if tree ~= nil then
            value.node = public_node(tree.nodes[session.currentNodeId])
        end
    end
    return value
end

function PalDiscourseRuntime:status()
    local faction_count = 0
    local representative_count = 0
    local active_sessions = 0
    local resolved_sessions = 0
    for _, _ in pairs(self.factions) do faction_count = faction_count + 1 end
    for _, _ in pairs(self.representatives) do representative_count = representative_count + 1 end
    for _, session in pairs(self.sessions) do
        if session.state == "active" then active_sessions = active_sessions + 1 else resolved_sessions = resolved_sessions + 1 end
    end
    return {
        apiVersion = self.version,
        registeredFactionCount = faction_count,
        registeredRepresentativeCount = representative_count,
        activeSessionCount = active_sessions,
        resolvedSessionCount = resolved_sessions,
        offlineDialogueTreeEnabled = true,
        nativeDialoguePresenterEnabled = false,
        baseStoryContentIncluded = false,
        localizationKeysOnly = true,
    }
end

return PalDiscourseRuntime
