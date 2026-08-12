package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local Json = require("pwft.json")
local Bridge = require("pwft.agent_dialogue_file_bridge")

local files = {}
local now_epoch = 1000
local filesystem = {
    exists = function(path) return files[path] ~= nil end,
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
}

local bridge = Bridge.create({
    enabled = true,
    rootPath = "C:/PWFT/State/AgentDialogue",
    requestTtlSeconds = 10,
    nowEpoch = function() return now_epoch end,
}, filesystem)

local request = {
    schemaVersion = "1.0.0",
    requestId = "pwft-agent-00000001",
    createdAt = "2026-08-12T00:00:00Z",
    characterId = "example.minimal.pal.representative.primary",
    sessionId = "pwft-session-00000001",
    worldKey = "world-test.player-test",
    playerKey = "world-test.player-test",
    locale = "zh-CN",
    playerText = "我们能够停止争斗吗？",
    contextKeys = { "example.minimal.loc.pal.node.opening" },
    allowedChoices = {
        {
            choiceId = "example.minimal.pal.choice.complete",
            textKey = "example.minimal.loc.pal.choice.complete",
        },
    },
    allowedResultTags = {},
}

local submitted = bridge:submit_request(request)
assert(submitted.ok and submitted.reason == "request-submitted")
local inbox = "C:/PWFT/State/AgentDialogue/inbox/pwft-agent-00000001.json"
assert(files[inbox] ~= nil)
local encoded = Json.decode(files[inbox])
assert(encoded.playerText == request.playerText)
assert(encoded.affinityDelta == nil)

local authorization = {
    requestId = request.requestId,
    characterId = request.characterId,
    allowedChoiceIds = {
        "example.minimal.pal.choice.complete",
    },
    allowedResultTags = {},
}
local pending = bridge:poll_response(authorization)
assert(not pending.ok and pending.reason == "response-pending")

local outbox = "C:/PWFT/State/AgentDialogue/outbox/pwft-agent-00000001.json"
files[outbox] = Json.encode({
    schemaVersion = "1.0.0",
    requestId = request.requestId,
    createdAt = "2026-08-12T00:00:01Z",
    characterId = request.characterId,
    provider = "ollama",
    dialogue = "争斗不是唯一的道路。",
    proposedChoice = "example.minimal.pal.choice.complete",
    resultTags = {},
})
local ready = bridge:poll_response(authorization)
assert(ready.ok and ready.reason == "response-validated")
assert(ready.dialogue == "争斗不是唯一的道路。")
assert(ready.proposedChoice == "example.minimal.pal.choice.complete")
assert(ready.affinityDelta == nil)

local malicious_request = {}
for key, value in pairs(request) do malicious_request[key] = value end
malicious_request.requestId = "pwft-agent-00000002"
assert(bridge:submit_request(malicious_request).ok)
local malicious_outbox =
    "C:/PWFT/State/AgentDialogue/outbox/pwft-agent-00000002.json"
files[malicious_outbox] = [[{"schemaVersion":"1.0.0","requestId":"pwft-agent-00000002","createdAt":"2026-08-12T00:00:01Z","characterId":"example.minimal.pal.representative.primary","provider":"ollama","dialogue":"越权","proposedChoice":null,"resultTags":[],"affinityDelta":999}]]
local malicious = bridge:poll_response({
    requestId = "pwft-agent-00000002",
    characterId = request.characterId,
    allowedChoiceIds = {},
    allowedResultTags = {},
})
assert(not malicious.ok and malicious.reason == "response-contract-invalid")

local expiring_request = {}
for key, value in pairs(request) do expiring_request[key] = value end
expiring_request.requestId = "pwft-agent-00000003"
assert(bridge:submit_request(expiring_request).ok)
now_epoch = 1011
local expired = bridge:poll_response({
    requestId = "pwft-agent-00000003",
    characterId = request.characterId,
    allowedChoiceIds = {},
    allowedResultTags = {},
})
assert(not expired.ok and expired.reason == "request-expired")

local status = bridge:status()
assert(status.ready == true)
assert(status.submittedCount == 3)
assert(status.validatedCount == 1)
assert(status.rejectedCount == 1)
assert(status.directStateMutation == false)
assert(status.PalworldSaveMutation == false)

print("PASS in-Mod Agent file bridge atomically submits, polls Ollama-only responses, expires stale work, and rejects authority fields")
