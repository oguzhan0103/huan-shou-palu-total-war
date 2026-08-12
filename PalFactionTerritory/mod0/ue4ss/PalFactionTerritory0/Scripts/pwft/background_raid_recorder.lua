local BackgroundRaidRecorder = {}

local EVENT_TYPE = "settlement-raid-background-resolved"

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

local function finite_number(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function non_empty_text(value)
    return type(value) == "string" and value ~= ""
end

local function normalize(record)
    if type(record) ~= "table" then
        return nil, "background-raid-record-not-table"
    end
    if not non_empty_text(record.settlementId) then
        return nil, "background-raid-settlement-id-invalid"
    end
    if not non_empty_text(record.source) then
        return nil, "background-raid-source-invalid"
    end
    if not finite_number(record.generation) then
        return nil, "background-raid-generation-invalid"
    end
    if not finite_number(record.resolvedAt) then
        return nil, "background-raid-resolved-at-invalid"
    end
    if record.playerPresent ~= false
        or record.actorSpawns ~= 0
        or record.worldCombat ~= false
        or record.saveWrites ~= false then
        return nil, "background-raid-safety-contract-violated"
    end
    if record.outcome ~= "raid-occurred-offscreen" then
        return nil, "background-raid-outcome-invalid"
    end
    if record.playerDistance ~= nil
        and not finite_number(record.playerDistance) then
        return nil, "background-raid-player-distance-invalid"
    end
    return {
        type = EVENT_TYPE,
        settlementId = record.settlementId,
        source = record.source,
        generation = record.generation,
        resolvedAt = record.resolvedAt,
        playerPresent = false,
        playerDistance = record.playerDistance,
        outcome = record.outcome,
        actorSpawns = 0,
        worldCombat = false,
        saveWrites = false,
    }, nil
end

local function ledger_is_active(instance)
    local ok, status = pcall(function()
        return instance.ledger:status()
    end)
    if not ok then
        return false, "ledger-status-error:" .. tostring(status)
    end
    if type(status) ~= "table" or status.active ~= true then
        return false, "companion-profile-not-active"
    end
    return true, nil
end

local function persist(instance, event)
    local active, active_reason = ledger_is_active(instance)
    if not active then
        return false, active_reason
    end
    local called, recorded, result = pcall(function()
        return instance.ledger:record(copy(event))
    end)
    if not called then
        return false, "ledger-record-error:" .. tostring(recorded)
    end
    if recorded ~= true then
        return false, tostring(result or "ledger-record-rejected")
    end
    instance.persistedCount = instance.persistedCount + 1
    instance.lastError = nil
    return true, result
end

local function enqueue(instance, event)
    if #instance.pending >= instance.maxPending then
        table.remove(instance.pending, 1)
        instance.droppedCount = instance.droppedCount + 1
    end
    table.insert(instance.pending, copy(event))
end

function BackgroundRaidRecorder.create(ledger, config)
    assert(type(ledger) == "table", "companion ledger is required")
    assert(type(ledger.status) == "function", "companion ledger status is required")
    assert(type(ledger.record) == "function", "companion ledger record is required")
    config = config or {}
    local max_pending = config.maxPending or 32
    assert(
        type(max_pending) == "number"
            and max_pending >= 1
            and max_pending == math.floor(max_pending),
        "background raid max pending must be a positive integer"
    )
    return setmetatable({
        ledger = ledger,
        maxPending = max_pending,
        pending = {},
        receivedCount = 0,
        persistedCount = 0,
        rejectedCount = 0,
        droppedCount = 0,
        flushCount = 0,
        lastError = nil,
    }, { __index = BackgroundRaidRecorder })
end

function BackgroundRaidRecorder:flush()
    local active, active_reason = ledger_is_active(self)
    if not active then
        self.lastError = active_reason
        return false, active_reason
    end
    local flushed = 0
    while #self.pending > 0 do
        local persisted, persist_reason = persist(self, self.pending[1])
        if not persisted then
            self.lastError = persist_reason
            return false, persist_reason
        end
        table.remove(self.pending, 1)
        flushed = flushed + 1
    end
    self.flushCount = self.flushCount + 1
    self.lastError = nil
    return true, flushed
end

function BackgroundRaidRecorder:record(record)
    local event, normalize_error = normalize(record)
    if event == nil then
        self.rejectedCount = self.rejectedCount + 1
        self.lastError = normalize_error
        return false, normalize_error
    end
    self.receivedCount = self.receivedCount + 1

    if #self.pending > 0 then
        local flushed, flush_reason = self:flush()
        if not flushed then
            enqueue(self, event)
            self.lastError = flush_reason
            return false, "queued:" .. tostring(flush_reason)
        end
    end

    local persisted, persist_reason = persist(self, event)
    if persisted then
        return true, "persisted"
    end
    enqueue(self, event)
    self.lastError = persist_reason
    return false, "queued:" .. tostring(persist_reason)
end

function BackgroundRaidRecorder:status()
    return {
        eventType = EVENT_TYPE,
        maxPending = self.maxPending,
        pendingCount = #self.pending,
        receivedCount = self.receivedCount,
        persistedCount = self.persistedCount,
        rejectedCount = self.rejectedCount,
        droppedCount = self.droppedCount,
        flushCount = self.flushCount,
        lastError = self.lastError,
    }
end

return BackgroundRaidRecorder
