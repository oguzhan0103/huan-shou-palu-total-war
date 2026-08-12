package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local Json = require("pwft.json")
local Operator = require("pwft.agent_dialogue_operator")

local files = {}
local now_epoch = 2000
local filesystem = {
    read_limited = function(path, maximum)
        local value = files[path]
        if value == nil then return nil, "not-found" end
        if #value > maximum then return nil, "too-large" end
        return value, nil
    end,
    write_atomic = function(path, value)
        files[path] = value
        return true, nil
    end,
    remove = function(path)
        files[path] = nil
        return true
    end,
}

local presenter = {
    record = {
        state = "active",
        sessionId = "session-1",
        lastView = { choices = {} },
    },
    submissions = {},
    polls = 0,
}
function presenter:presentation_status(id)
    return id == "presentation-1" and self.record or nil
end
function presenter:submit_agent_turn(id, text, context)
    self.submissions[#self.submissions + 1] = {
        presentationId = id,
        text = text,
        context = context,
    }
    return {
        ok = true,
        reason = "agent-request-submitted",
        requestId = "pwft-agent-00000001",
    }
end
function presenter:poll_agent_turn(id, request_id)
    self.polls = self.polls + 1
    assert(id == "presentation-1")
    assert(request_id == "pwft-agent-00000001")
    if self.polls == 1 then
        return { ok = false, reason = "agent-response-pending" }
    end
    self.record.lastView.agent = {
        requestId = request_id,
        state = "ready",
        dialogue = "本地模型已经回应。",
        proposedChoice = "continue",
        requiresPlayerConfirmation = true,
    }
    return {
        ok = true,
        reason = "agent-response-ready",
        requiresPlayerConfirmation = true,
        stateMutationApplied = false,
    }
end

local router = { activePresentationId = "presentation-1" }
function router:status()
    return { activePresentationId = self.activePresentationId }
end

local operator = Operator.create(
    presenter,
    router,
    {
        enabled = true,
        operatorInputPath = "C:/PWFT/State/pwft-agent-operator-input-v1.json",
        operatorStatusPath = "C:/PWFT/State/pwft-agent-operator-status-v1.json",
        operatorCommandTtlSeconds = 300,
    },
    {
        filesystem = filesystem,
        nowEpoch = function() return now_epoch end,
        identityResolver = function()
            return {
                profileKey = "world-abc.player-def",
                worldDirectory = "world-abc",
                playerUid = "player-def",
            }
        end,
    }
)

operator:on_world_loaded()
local status_path = "C:/PWFT/State/pwft-agent-operator-status-v1.json"
assert(files[status_path] ~= nil)

local input_path = "C:/PWFT/State/pwft-agent-operator-input-v1.json"
files[input_path] = Json.encode({
    schemaVersion = "1.0.0",
    commandId = "operator-command-1",
    createdAtEpoch = now_epoch,
    action = "submit-agent-text",
    presentationId = "presentation-1",
    playerText = "你怎样看待人类？",
})

local pending = operator:tick()
assert(not pending.ok and pending.reason == "agent-response-pending")
assert(files[input_path] == nil)
assert(#presenter.submissions == 1)
assert(presenter.submissions[1].text == "你怎样看待人类？")
assert(presenter.submissions[1].context.worldKey == "world-abc")
assert(presenter.submissions[1].context.playerKey == "player-def")

local ready = operator:tick()
assert(ready.ok and ready.reason == "agent-response-ready")
assert(ready.requiresPlayerConfirmation == true)
assert(ready.stateMutationApplied == false)
assert(#presenter.submissions == 1)

local status = Json.decode(files[status_path])
assert(status.reason == "agent-response-ready")
assert(status.requestState == "idle")
assert(status.directStateMutation == false)
assert(status.proposalRequiresPlayerConfirmation == true)

-- Re-reading the same command is idempotent and cannot submit twice.
local idle = operator:tick()
assert(idle.ok and idle.reason == "operator-idle")
assert(#presenter.submissions == 1)

operator:on_world_unloading()
assert(operator:status().requestState == "idle")
assert(operator:status().worldReady == false)
assert(operator:tick().reason == "operator-world-not-ready")

print("PASS Agent operator accepts one external text command, auto-polls, refreshes the presenter, and keeps choice authority behind player confirmation")
