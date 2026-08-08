local FactionApi = {}

local API_VERSION = "1.0.0"

local function require_non_empty_string(value, name)
    assert(type(value) == "string" and value ~= "", name .. " must be a non-empty string")
    return value
end

local function require_positive_number(value, name)
    assert(type(value) == "number" and value > 0, name .. " must be positive")
    return value
end

local function changed(outcome)
    if type(outcome) ~= "table" or outcome.ok ~= true then
        return false
    end
    if outcome.reason == "joined"
        or outcome.reason == "pal-reconciled"
        or outcome.reason == "pal-reconciliation-progressed"
        or outcome.reason == "diplomacy-hostility-cleared" then
        return true
    end
    return type(outcome.applied) == "number" and outcome.applied > 0
end

local function notify(instance, faction_id, outcome)
    if not changed(outcome) or instance.onChange == nil then
        return
    end
    local ok, error_message = pcall(
        instance.onChange,
        faction_id,
        outcome,
        instance.progression:status(faction_id)
    )
    outcome.notificationOk = ok
    if not ok then
        outcome.notificationError = tostring(error_message)
    end
end

function FactionApi.create(progression, on_change)
    assert(type(progression) == "table", "faction progression instance is required")
    assert(type(progression.status) == "function", "invalid faction progression instance")
    assert(on_change == nil or type(on_change) == "function", "faction change callback must be a function")
    return setmetatable({
        version = API_VERSION,
        progression = progression,
        onChange = on_change,
        capabilities = {
            multipleHumanMemberships = true,
            humanFactionRelationMatrix = true,
            affiliationDiplomacyRecovery = true,
            automaticCommerceDiplomacyRecovery = true,
            joinPreview = true,
            registeredJoinInteraction = true,
            reputationDecrease = false,
            taskAwards = true,
            defenseAwards = true,
            commerceAwards = true,
            hostileDefenseRecovery = true,
            playerGuardsByRank = true,
            PalMembership = false,
            PalReconciliationGate = true,
            finitePalDiscourse = true,
            directPalReconciliation = false,
            ending3Gate = true,
            snapshotExport = true,
            PalworldSaveMutation = false,
        },
    }, { __index = FactionApi })
end

function FactionApi:faction_status(faction_id)
    return self.progression:status(require_non_empty_string(faction_id, "faction ID"))
end

function FactionApi:gate_status()
    return self.progression:gate_status()
end

function FactionApi:can_join(faction_id)
    return self.progression:is_join_eligible(
        require_non_empty_string(faction_id, "faction ID")
    )
end

function FactionApi:join_preview(faction_id)
    return self.progression:join_preview(
        require_non_empty_string(faction_id, "faction ID")
    )
end

function FactionApi:faction_relation(faction_a, faction_b)
    return self.progression:faction_relation(
        require_non_empty_string(faction_a, "faction A ID"),
        require_non_empty_string(faction_b, "faction B ID")
    )
end

function FactionApi:join_human(faction_id, content_id)
    require_non_empty_string(faction_id, "faction ID")
    require_non_empty_string(content_id, "join content ID")
    local outcome = self.progression:join(faction_id)
    outcome.contentId = content_id
    notify(self, faction_id, outcome)
    return outcome
end

function FactionApi:clear_affiliation_hostility(
    target_faction_id,
    source_faction_id,
    resolution_id
)
    require_non_empty_string(target_faction_id, "target faction ID")
    require_non_empty_string(source_faction_id, "source faction ID")
    require_non_empty_string(resolution_id, "diplomacy recovery resolution ID")
    local outcome = self.progression:clear_diplomacy_hostility(
        target_faction_id,
        source_faction_id,
        {
            contextId = resolution_id,
            eventId = "diplomacy-recovery:" .. resolution_id,
        }
    )
    notify(self, target_faction_id, outcome)
    return outcome
end

function FactionApi:award_task(faction_id, amount, completion_id)
    require_non_empty_string(faction_id, "faction ID")
    require_positive_number(amount, "task reputation award")
    require_non_empty_string(completion_id, "task completion ID")
    local outcome = self.progression:grant_reputation(
        faction_id,
        "task",
        amount,
        {
            contextId = completion_id,
            eventId = "task:" .. completion_id,
        }
    )
    notify(self, faction_id, outcome)
    return outcome
end

function FactionApi:award_defense(faction_id, amount, resolution_id)
    require_non_empty_string(faction_id, "faction ID")
    require_positive_number(amount, "defense reputation award")
    require_non_empty_string(resolution_id, "defense resolution ID")
    local outcome = self.progression:grant_reputation(
        faction_id,
        "defense",
        amount,
        {
            contextId = resolution_id,
            eventId = "defense:" .. resolution_id,
        }
    )
    notify(self, faction_id, outcome)
    return outcome
end

function FactionApi:award_commerce(
    faction_id,
    amount,
    transaction_id,
    commerce_window_id,
    commerce_context
)
    require_non_empty_string(faction_id, "faction ID")
    require_positive_number(amount, "commerce reputation award")
    require_non_empty_string(transaction_id, "commerce transaction ID")
    require_non_empty_string(commerce_window_id, "commerce window ID")
    assert(
        commerce_context == nil
            or type(commerce_context) == "table",
        "commerce context must be a table"
    )
    local outcome = self.progression:grant_reputation(
        faction_id,
        "commerce",
        amount,
        {
            contextId = transaction_id,
            eventId = "commerce:" .. transaction_id,
            windowId = commerce_window_id,
            diplomacyRecoveryEligible =
                commerce_context ~= nil
                    and commerce_context
                        .diplomacyRecoveryEligible
                    == true,
            venueMode =
                commerce_context
                    and commerce_context.venueMode
                or nil,
        }
    )
    notify(self, faction_id, outcome)
    return outcome
end

function FactionApi:reconcile_pal(faction_id, resolution_id)
    require_non_empty_string(faction_id, "faction ID")
    require_non_empty_string(resolution_id, "Pal reconciliation resolution ID")
    local outcome = self.progression:reconcile_pal(
        faction_id,
        {
            contextId = resolution_id,
            eventId = "pal-reconciliation:" .. resolution_id,
        }
    )
    notify(self, faction_id, outcome)
    return outcome
end

function FactionApi:has_guard_access(faction_id)
    return self.progression:has_guard_access(
        require_non_empty_string(faction_id, "faction ID")
    )
end

function FactionApi:export_snapshot()
    return self.progression:export_snapshot()
end

return FactionApi
