local HostileCommerceLiveTest = {}
HostileCommerceLiveTest.__index = HostileCommerceLiveTest

local function require_non_empty_string(value, label)
    assert(
        type(value) == "string" and value ~= "",
        label .. " is required"
    )
end

function HostileCommerceLiveTest.create(config, faction_api)
    assert(
        type(config) == "table",
        "hostile commerce live-test config is required"
    )
    assert(
        config.enabled == true,
        "hostile commerce live-test must be explicitly enabled"
    )
    require_non_empty_string(config.key, "hostile commerce live-test key")
    require_non_empty_string(
        config.joinFactionId,
        "hostile commerce join faction ID"
    )
    require_non_empty_string(
        config.targetFactionId,
        "hostile commerce target faction ID"
    )
    require_non_empty_string(
        config.contentId,
        "hostile commerce join content ID"
    )
    assert(type(faction_api) == "table", "faction API is required")
    assert(
        type(faction_api.join_human) == "function"
            and type(faction_api.faction_status) == "function",
        "invalid faction API"
    )
    return setmetatable({
        version = "1.0.0",
        key = config.key,
        joinFactionId = config.joinFactionId,
        targetFactionId = config.targetFactionId,
        contentId = config.contentId,
        factionApi = faction_api,
        activationCount = 0,
    }, HostileCommerceLiveTest)
end

function HostileCommerceLiveTest:activate()
    local before = self.factionApi:faction_status(
        self.targetFactionId
    )
    local joined = self.factionApi:join_human(
        self.joinFactionId,
        self.contentId
    )
    local after = self.factionApi:faction_status(
        self.targetFactionId
    )
    self.activationCount = self.activationCount + 1
    return {
        ok = joined.ok == true
            and after ~= nil
            and after.relation == "Hostile",
        reason = joined.ok == true
                and after ~= nil
                and after.relation == "Hostile"
                and "hostile-commerce-live-test-ready"
            or "hostile-commerce-live-test-precondition-failed",
        joinOutcome = joined,
        joinFactionId = self.joinFactionId,
        targetFactionId = self.targetFactionId,
        beforeRelation = before and before.relation or nil,
        afterRelation = after and after.relation or nil,
        targetReputation = after and after.reputation or nil,
        activationCount = self.activationCount,
        directReputationWrites = false,
        nativeTransactionsRequired = true,
    }
end

function HostileCommerceLiveTest:status()
    local target = self.factionApi:faction_status(
        self.targetFactionId
    )
    return {
        version = self.version,
        key = self.key,
        joinFactionId = self.joinFactionId,
        targetFactionId = self.targetFactionId,
        targetRelation = target and target.relation or nil,
        targetReputation = target and target.reputation or nil,
        activationCount = self.activationCount,
        directReputationWrites = false,
        nativeTransactionsRequired = true,
        persistent = true,
    }
end

return HostileCommerceLiveTest
