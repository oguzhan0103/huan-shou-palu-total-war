local CommerceWindowLiveTest = {}
CommerceWindowLiveTest.__index = CommerceWindowLiveTest

local function require_non_empty_string(value, label)
    assert(type(value) == "string" and value ~= "", label .. " is required")
end

local function require_positive_integer(value, label)
    assert(
        type(value) == "number"
            and value >= 1
            and value == math.floor(value),
        label .. " must be a positive integer"
    )
end

local function default_session_id()
    local epoch = 0
    if os ~= nil and type(os.time) == "function" then
        epoch = os.time()
    end
    return tostring(epoch)
end

function CommerceWindowLiveTest.create(config, options)
    assert(type(config) == "table", "commerce window live-test config is required")
    assert(config.enabled == true, "commerce window live-test must be explicitly enabled")
    require_non_empty_string(config.key, "commerce window live-test key")
    require_non_empty_string(config.windowPrefix, "commerce window live-test prefix")
    require_positive_integer(config.windowCount, "commerce window live-test count")
    options = options or {}
    local session_id = options.sessionId or default_session_id()
    require_non_empty_string(session_id, "commerce window live-test session ID")
    return setmetatable({
        version = "1.0.0",
        enabled = true,
        key = config.key,
        windowPrefix = config.windowPrefix,
        windowCount = config.windowCount,
        sessionId = session_id,
        windowIndex = 1,
        transitionCount = 0,
    }, CommerceWindowLiveTest)
end

function CommerceWindowLiveTest:window_id()
    return string.format(
        "%s:%s:window-%d",
        self.windowPrefix,
        self.sessionId,
        self.windowIndex
    )
end

function CommerceWindowLiveTest:advance()
    if self.windowIndex >= self.windowCount then
        return {
            ok = false,
            reason = "commerce-window-live-test-limit-reached",
            windowId = self:window_id(),
            windowIndex = self.windowIndex,
            windowCount = self.windowCount,
        }
    end
    local previous = self:window_id()
    self.windowIndex = self.windowIndex + 1
    self.transitionCount = self.transitionCount + 1
    return {
        ok = true,
        reason = "commerce-window-live-test-advanced",
        previousWindowId = previous,
        windowId = self:window_id(),
        windowIndex = self.windowIndex,
        windowCount = self.windowCount,
    }
end

function CommerceWindowLiveTest:status()
    return {
        version = self.version,
        enabled = self.enabled,
        key = self.key,
        windowId = self:window_id(),
        windowIndex = self.windowIndex,
        windowCount = self.windowCount,
        transitionCount = self.transitionCount,
        nativeTransactionsOnly = true,
        directReputationWrites = false,
        persistent = false,
    }
end

return CommerceWindowLiveTest
