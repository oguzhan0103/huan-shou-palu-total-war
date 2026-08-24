local FactionGuard = {}

local function require_non_empty_string(value, name)
    assert(type(value) == "string" and value ~= "", name .. " must be a non-empty string")
    return value
end

local function result(ok, reason, extra)
    local value = extra or {}
    value.ok = ok
    value.reason = reason
    return value
end

function FactionGuard.create(faction_api)
    assert(type(faction_api) == "table", "faction API is required")
    assert(type(faction_api.has_guard_access) == "function", "faction API lacks guard eligibility")
    return setmetatable({
        version = "1.1.0",
        factionApi = faction_api,
        providers = {},
        active = {},
        capabilities = {
            leaderUnlock = true,
            lordAccess = true,
            oneActiveGuardPerFaction = true,
            entitlementReconciliation = true,
            automaticDemotionRecall = true,
            nativeProviderRequired = true,
            PalworldSaveMutation = false,
        },
    }, { __index = FactionGuard })
end

function FactionGuard:entitlement(faction_id)
    require_non_empty_string(faction_id, "guard faction ID")
    local faction = self.factionApi:faction_status(faction_id)
    if faction == nil then
        return result(false, "unknown-faction", {
            factionId = faction_id,
            slotCount = 0,
        })
    end
    if faction.kind ~= "Human" then
        return result(false, "human-guards-only", {
            factionId = faction_id,
            slotCount = 0,
        })
    end
    local eligible = self.factionApi:has_guard_access(faction_id)
    return result(eligible, eligible and "guard-access" or "leader-rank-required", {
        factionId = faction_id,
        rankId = faction.rankId,
        slotCount = eligible and 1 or 0,
        providerReady = self.providers[faction_id] ~= nil,
        active = self.active[faction_id] ~= nil,
    })
end

function FactionGuard:register_provider(faction_id, provider)
    require_non_empty_string(faction_id, "guard faction ID")
    assert(type(provider) == "table", "guard provider must be a table")
    assert(type(provider.deploy) == "function", "guard provider must implement deploy")
    assert(type(provider.recall) == "function", "guard provider must implement recall")
    local faction = self.factionApi:faction_status(faction_id)
    if faction == nil or faction.kind ~= "Human" then
        return result(false, "unknown-human-faction")
    end
    self.providers[faction_id] = provider
    return result(true, "provider-registered", { factionId = faction_id })
end

function FactionGuard:deploy(faction_id, request_id, context)
    require_non_empty_string(faction_id, "guard faction ID")
    require_non_empty_string(request_id, "guard request ID")
    local entitlement = self:entitlement(faction_id)
    if not entitlement.ok then
        return entitlement
    end
    if self.active[faction_id] ~= nil then
        return result(true, "already-deployed", {
            factionId = faction_id,
            requestId = self.active[faction_id].requestId,
        })
    end
    local provider = self.providers[faction_id]
    if provider == nil then
        return result(false, "native-guard-provider-pending", {
            factionId = faction_id,
            slotCount = entitlement.slotCount,
        })
    end
    local provider_context = {}
    for key, value in pairs(context or {}) do
        provider_context[key] = value
    end
    local consumer_on_terminated = provider_context.onTerminated
    provider_context.onTerminated = function(detail)
        local active = self.active[faction_id]
        if active ~= nil and active.requestId == request_id then
            self.active[faction_id] = nil
        end
        if type(consumer_on_terminated) == "function" then
            pcall(consumer_on_terminated, detail)
        end
    end
    local provider_ok, handle_or_error = pcall(
        provider.deploy,
        faction_id,
        request_id,
        provider_context
    )
    if not provider_ok or handle_or_error == nil then
        return result(false, "guard-deploy-failed", {
            factionId = faction_id,
            detail = tostring(handle_or_error),
        })
    end
    self.active[faction_id] = {
        factionId = faction_id,
        requestId = request_id,
        handle = handle_or_error,
    }
    return result(true, "guard-deployed", {
        factionId = faction_id,
        requestId = request_id,
        handle = handle_or_error,
    })
end

function FactionGuard:recall(faction_id, reason)
    require_non_empty_string(faction_id, "guard faction ID")
    local active = self.active[faction_id]
    if active == nil then
        return result(true, "no-active-guard", { factionId = faction_id })
    end
    local provider = self.providers[faction_id]
    if provider == nil then
        return result(false, "guard-provider-missing-during-recall", {
            factionId = faction_id,
        })
    end
    local provider_ok, provider_result = pcall(
        provider.recall,
        active.handle,
        reason or "content-request"
    )
    if not provider_ok or provider_result == false then
        return result(false, "guard-recall-failed", {
            factionId = faction_id,
            detail = tostring(provider_result),
        })
    end
    self.active[faction_id] = nil
    return result(true, "guard-recalled", { factionId = faction_id })
end

function FactionGuard:reconcile_entitlement(faction_id, reason)
    require_non_empty_string(faction_id, "guard faction ID")
    local active = self.active[faction_id]
    if active == nil then
        return result(true, "no-active-guard", {
            factionId = faction_id,
            revoked = false,
        })
    end
    local entitlement = self:entitlement(faction_id)
    if entitlement.ok then
        return result(true, "guard-entitlement-retained", {
            factionId = faction_id,
            revoked = false,
            rankId = entitlement.rankId,
        })
    end
    local recalled = self:recall(
        faction_id,
        reason or "reputation-entitlement-revoked"
    )
    recalled.revoked = recalled.ok == true
    recalled.entitlementReason = entitlement.reason
    recalled.rankId = entitlement.rankId
    return recalled
end

function FactionGuard:reconcile_all_entitlements(reason)
    local outcomes = {}
    local faction_ids = {}
    for faction_id, _ in pairs(self.active) do
        faction_ids[#faction_ids + 1] = faction_id
    end
    table.sort(faction_ids)
    local revoked_count = 0
    local failed_count = 0
    for _, faction_id in ipairs(faction_ids) do
        local outcome = self:reconcile_entitlement(faction_id, reason)
        outcomes[#outcomes + 1] = outcome
        if outcome.revoked then
            revoked_count = revoked_count + 1
        elseif not outcome.ok then
            failed_count = failed_count + 1
        end
    end
    return result(failed_count == 0, failed_count == 0
        and "guard-entitlements-reconciled"
        or "guard-entitlement-reconciliation-partial", {
        checkedCount = #faction_ids,
        revokedCount = revoked_count,
        failedCount = failed_count,
        outcomes = outcomes,
    })
end

function FactionGuard:status()
    local provider_count = 0
    for _, _ in pairs(self.providers) do
        provider_count = provider_count + 1
    end
    local active_count = 0
    for _, _ in pairs(self.active) do
        active_count = active_count + 1
    end
    return {
        version = self.version,
        providerCount = provider_count,
        activeGuardCount = active_count,
    }
end

return FactionGuard
