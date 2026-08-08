local FactionUiModel = {}

local RELATION_LABELS = {
    Hostile = "敌对",
    Friendly = "中立友好",
    Player = "已加入",
}

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

local function next_rank(contract, rank_id)
    if rank_id == nil then
        return contract.rankPolicy.ranks[1]
    end
    for index, rank in ipairs(contract.rankPolicy.ranks) do
        if rank.id == rank_id then
            return contract.rankPolicy.ranks[index + 1]
        end
    end
    return nil
end

local function rank_minimum(contract, rank_id)
    if rank_id == nil then
        return contract.membershipPolicy.joinMinimumReputation
    end
    for _, rank in ipairs(contract.rankPolicy.ranks) do
        if rank.id == rank_id then
            return rank.minimumReputation
        end
    end
    return 0
end

local function rank_progress(contract, status)
    if status.kind ~= "Human" then
        return nil
    end
    if not status.joined then
        return {
            currentRankId = nil,
            nextRankId = "Member",
            current = status.reputation,
            target = contract.membershipPolicy.joinMinimumReputation,
            fraction = status.joinEligible and 1 or 0,
            complete = status.joinEligible,
        }
    end
    local following = next_rank(contract, status.rankId)
    if following == nil then
        return {
            currentRankId = status.rankId,
            nextRankId = nil,
            current = status.reputation,
            target = status.reputation,
            fraction = 1,
            complete = true,
        }
    end
    local floor = rank_minimum(contract, status.rankId)
    local span = following.minimumReputation - floor
    return {
        currentRankId = status.rankId,
        nextRankId = following.id,
        current = status.reputation,
        target = following.minimumReputation,
        fraction = math.max(
            0,
            math.min(1, (status.reputation - floor) / span)
        ),
        complete = false,
    }
end

function FactionUiModel.create(
    registry,
    progression,
    commerce,
    guard,
    pal_reconciliation
)
    assert(type(registry) == "table", "registry is required")
    assert(type(progression) == "table", "progression is required")
    assert(type(commerce) == "table", "commerce is required")
    assert(type(guard) == "table", "guard service is required")
    return setmetatable({
        version = "1.1.0",
        registry = registry,
        progression = progression,
        commerce = commerce,
        guard = guard,
        palReconciliation = pal_reconciliation,
    }, { __index = FactionUiModel })
end

function FactionUiModel:faction_row(faction_id)
    local faction = self.registry.factions[faction_id]
    local status = self.progression:status(faction_id)
    if faction == nil or status == nil then
        return nil
    end
    local row = {
        factionId = faction_id,
        displayNameZhHans = faction.displayNameZhHans,
        displayNameEn = faction.displayNameEn,
        kind = status.kind,
        reputation = status.reputation,
        relation = status.relation,
        relationLabelZhHans = RELATION_LABELS[status.relation]
            or status.relation,
        relationColour = self.registry.palette[status.relation],
        joined = status.joined,
        rankId = status.rankId,
        guardAccess = status.guardAccess,
        joinEligible = status.joinEligible,
        diplomacyBlocked = #(status.diplomacyHostilitySources or {}) > 0,
        diplomacyHostilitySources = copy(status.diplomacyHostilitySources or {}),
        rankProgress = rank_progress(
            self.registry.progression,
            status
        ),
        sourceTotals = copy(status.sourceTotals),
    }
    if status.kind == "Human" then
        local commerce = self.commerce:merchant_status(faction_id)
        local entitlement = self.guard:entitlement(faction_id)
        local policy = self.registry.progression.reputationSources.commerce
        row.commerce = {
            merchantId = commerce.merchantId,
            clothingColour = commerce.clothingColour,
            salesChannel = commerce.salesChannel,
            requestedItemIds = copy(commerce.requestedItemIds),
            windowId = status.commerce.windowId,
            negativeRecoveryRemaining = math.max(
                0,
                policy.negativeRecoveryCapPerWindow
                    - status.commerce.negativeRecoveryAwarded
            ),
            nonNegativeRemaining = math.max(
                0,
                policy.nonNegativeCapPerWindow
                    - status.commerce.nonNegativeAwarded
            ),
            diplomacyRecovery = copy(
                status.commerce.diplomacyRecovery
            ),
        }
        row.guard = {
            eligible = entitlement.ok,
            slotCount = entitlement.slotCount,
            providerReady = entitlement.providerReady,
            active = entitlement.active,
            reason = entitlement.reason,
        }
    else
        row.reconciliation = {
            unlocked = self.progression:gate_status()
                .palReconciliationUnlocked,
            maximumRelation = "Friendly",
            membershipAllowed = false,
            serviceReady = self.palReconciliation ~= nil,
        }
        if self.palReconciliation ~= nil then
            local reconciliation_status =
                self.palReconciliation:status(faction_id)
            for key, value in pairs(reconciliation_status or {}) do
                row.reconciliation[key] = copy(value)
            end
        end
    end
    return row
end

function FactionUiModel:build()
    local rows = {}
    for _, faction_id in ipairs(
        self.registry.progression.humanFactionIds
    ) do
        table.insert(rows, self:faction_row(faction_id))
    end
    for _, faction_id in ipairs(
        self.registry.progression.palFactionIds
    ) do
        table.insert(rows, self:faction_row(faction_id))
    end
    return {
        schemaVersion = "1.0.0",
        modelVersion = self.version,
        palette = copy(self.registry.palette),
        humanFactionCount =
            #self.registry.progression.humanFactionIds,
        palFactionCount = #self.registry.progression.palFactionIds,
        rows = rows,
        gates = self.progression:gate_status(),
        renderingStatus =
            "dedicated-faction-panel-ready-live-acceptance-pending",
    }
end

return FactionUiModel
