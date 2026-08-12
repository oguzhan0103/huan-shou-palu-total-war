local project_root = assert(
    rawget(_G, "PAL_AGENT_TEST_PROJECT_ROOT") or os.getenv("PAL_AGENT_TEST_PROJECT_ROOT"),
    "test project root is required"
)
local bridge_root = assert(
    rawget(_G, "PAL_AGENT_TEST_BRIDGE_ROOT") or os.getenv("PAL_AGENT_TEST_BRIDGE_ROOT"),
    "test bridge root is required"
)
local missing_bridge_root = assert(
    rawget(_G, "PAL_AGENT_TEST_MISSING_BRIDGE_ROOT")
        or os.getenv("PAL_AGENT_TEST_MISSING_BRIDGE_ROOT"),
    "test missing-directory bridge root is required"
)

package.path = table.concat({
    project_root .. "/ue4ss/PalAgentDialogueBridge0/Scripts/?.lua",
    project_root .. "/ue4ss/PalAgentDialogueBridge0/Scripts/?/init.lua",
    package.path,
}, ";")

local json = require("pad.json")
local bridge_module = require("pad.bridge")
local core_controller_module = require("pwft.pal_dialogue_controller")
local now_epoch = 1000
local bridge = bridge_module.create({
    root = bridge_root,
    allowMockProvider = true,
    requestTtlSeconds = 5,
    nowEpoch = function() return now_epoch end,
})

local function write_file(path, content)
    local handle = assert(io.open(path, "wb"))
    assert(handle:write(content))
    handle:close()
end

local function read_file(path)
    local handle = assert(io.open(path, "rb"))
    local content = handle:read("*a")
    handle:close()
    return content
end

local function request_with(request_id, player_text)
    return {
        schemaVersion = "1.0.0",
        requestId = request_id,
        createdAt = "2026-08-07T12:00:00Z",
        characterId = "example_guide",
        sessionId = "meeting-1",
        worldKey = "world-local",
        playerKey = "player-local",
        locale = "zh-CN",
        playerText = player_text or "我们继续谈吧。",
        contextKeys = { "example.guide.met_player" },
        allowedChoices = {
            { choiceId = "continue", textKey = "example.choice.continue" },
        },
        allowedResultTags = { "heard_player" },
    }
end

local base_request = request_with("lua-e2e-1")

-- A configured root is data, never a path fragment controlled by a request.
-- It must be absolute and cannot contain traversal components.
assert(not pcall(bridge_module.create, { root = "relative/bridge-data" }))
local traversal_root = bridge_root:match("^%a:/")
    and "C:/safe/../bridge-data"
    or "/safe/../bridge-data"
assert(not pcall(bridge_module.create, { root = traversal_root }))

local forbidden_request = {}
for key, value in pairs(base_request) do forbidden_request[key] = value end
forbidden_request.requestId = "lua-forbidden"
forbidden_request.affinityDelta = 999
local forbidden = bridge:submit_request(forbidden_request)
assert(not forbidden.ok and forbidden.reason == "request-fields-not-allowed")

local submitted = bridge:submit_request(base_request)
assert(submitted.ok and submitted.reason == "request-submitted")
assert(submitted.requestState == "pending")

local inbox_path = bridge_root .. "/inbox/lua-e2e-1.json"
local encoded_request = json.decode(read_file(inbox_path))
assert(encoded_request.requestId == "lua-e2e-1")
assert(encoded_request.playerText == "我们继续谈吧。")
assert(encoded_request.affinityDelta == nil)
assert(#encoded_request.allowedChoices == 1)

-- Load the current Mod Core controller, not a hand-copied fixture, and prove
-- its generated submit payload crosses this production adapter unchanged.
local core_discourse = {
    session = {
        sessionId = "pal-tree-session:bridge-e2e",
        representativeId = "example_guide",
        factionId = "pwft.faction.desert_pal_tribe",
        state = "active",
        node = {
            nodeId = "opening",
            textKey = "example.guide.opening",
            choices = {
                {
                    choiceId = "continue",
                    textKey = "example.choice.continue",
                },
            },
        },
    },
}
function core_discourse:session_status(session_id)
    if session_id == self.session.sessionId then
        return self.session
    end
    return nil
end
function core_discourse:choose()
    error("bridge transport must not choose")
end
function core_discourse:player_abort()
    error("bridge transport must not abort")
end
function core_discourse:technical_failure()
    error("bridge transport must not mutate failure state")
end
local core_controller = core_controller_module.create(
    core_discourse,
    {
        offlineDialogueTreeEnabled = true,
        nativeDialoguePresenterEnabled = true,
        agentAdapterEnabled = true,
        agentDefaultLocale = "zh-CN",
    },
    {
        resolveAgentBridge = function() return bridge end,
        nowUtc = function() return "2026-08-07T12:00:00Z" end,
    }
)
local core_submitted = core_controller:submit_agent_turn(
    core_discourse.session.sessionId,
    "Core 生成的真实请求。",
    {
        worldKey = "world-local",
        playerKey = "player-local",
        locale = "zh-CN",
        contextKeys = { "example.guide.met_player" },
    }
)
assert(core_submitted.ok and core_submitted.reason == "agent-request-submitted")
local core_payload = json.decode(read_file(
    bridge_root .. "/inbox/" .. core_submitted.requestId .. ".json"
))
assert(core_payload.schemaVersion == "1.0.0")
assert(core_payload.characterId == "example_guide")
assert(core_payload.allowedChoices[1].choiceId == "continue")
assert(core_payload.playerText == "Core 生成的真实请求。")
assert(core_payload.affinityDelta == nil and core_payload.questCompleted == nil)
write_file(
    bridge_root .. "/outbox/" .. core_submitted.requestId .. ".json",
    json.encode({
        schemaVersion = "1.0.0",
        requestId = core_submitted.requestId,
        createdAt = "2026-08-07T12:00:01Z",
        characterId = "example_guide",
        provider = "mock",
        dialogue = "Core 可以安全展示这段提议。",
        proposedChoice = "continue",
        resultTags = json.array(),
    })
)
local core_ready = core_controller:poll_agent_turn(core_submitted.requestId)
assert(core_ready.ok and core_ready.reason == "agent-response-ready")
assert(core_ready.response.dialogue == "Core 可以安全展示这段提议。")
assert(core_ready.response.proposedChoice == "continue")

-- The Lua boundary uses the same character limits as the Rust domain. This
-- accepts 8,000 UTF-8 characters without mistaking their byte length for a
-- protocol violation, but rejects 8,001 ASCII characters that Rust rejects.
local utf8_limit = bridge:submit_request(
    request_with("lua-player-text-limit", string.rep("界", 8000))
)
assert(utf8_limit.ok)
local over_text_limit = bridge:submit_request(
    request_with("lua-player-text-over-limit", string.rep("x", 8001))
)
assert(not over_text_limit.ok)
assert(over_text_limit.reason == "request-contract-invalid")

-- The sidecar owns directory creation. If it has not created inbox/outbox yet,
-- submission fails closed and never reports a request as accepted.
local missing_directory_bridge = bridge_module.create({
    root = missing_bridge_root,
    allowMockProvider = true,
})
local missing_directory = missing_directory_bridge:submit_request(
    request_with("lua-missing-directory")
)
assert(not missing_directory.ok)
assert(missing_directory.reason == "request-write-failed")

write_file(bridge_root .. "/outbox/lua-e2e-1.json", json.encode({
    schemaVersion = "1.0.0",
    requestId = "lua-e2e-1",
    createdAt = "2026-08-07T12:00:01Z",
    characterId = "example_guide",
    provider = "mock",
    dialogue = "我听见了。",
    proposedChoice = "continue",
    resultTags = json.array({ "heard_player" }),
}))

local response = bridge:poll_response({
    requestId = "lua-e2e-1",
    characterId = "example_guide",
    allowedChoiceIds = { "continue" },
    allowedResultTags = { "heard_player" },
})
assert(response.ok and response.reason == "response-validated")
assert(response.dialogue == "我听见了。")
assert(response.proposedChoice == "continue")
assert(response.resultTags[1] == "heard_player")
assert(response.affinityDelta == nil)

-- Pending requests have a bounded lifetime. An expired request stays terminal
-- even if an outbox file appears later, so stale model output cannot be shown.
local expires = bridge:submit_request(request_with("lua-expires"))
assert(expires.ok)
local pending = bridge:poll_response({
    requestId = "lua-expires",
    characterId = "example_guide",
    allowedChoiceIds = { "continue" },
    allowedResultTags = { "heard_player" },
})
assert(not pending.ok and pending.reason == "response-pending")
assert(pending.requestState == "pending")
now_epoch = 1006
local expired = bridge:poll_response({
    requestId = "lua-expires",
    characterId = "example_guide",
    allowedChoiceIds = { "continue" },
    allowedResultTags = { "heard_player" },
})
assert(not expired.ok and expired.reason == "request-expired")
assert(expired.requestState == "expired")
write_file(bridge_root .. "/outbox/lua-expires.json", json.encode({
    schemaVersion = "1.0.0",
    requestId = "lua-expires",
    createdAt = "2026-08-07T12:10:00Z",
    characterId = "example_guide",
    provider = "mock",
    dialogue = "迟到的响应不应被展示。",
    proposedChoice = "continue",
    resultTags = json.array({ "heard_player" }),
}))
local still_expired = bridge:poll_response({
    requestId = "lua-expires",
    characterId = "example_guide",
    allowedChoiceIds = { "continue" },
    allowedResultTags = { "heard_player" },
})
assert(not still_expired.ok and still_expired.reason == "request-expired")

assert(bridge:submit_request(request_with("lua-malicious")).ok)
write_file(bridge_root .. "/outbox/lua-malicious.json", json.encode({
    schemaVersion = "1.0.0",
    requestId = "lua-malicious",
    createdAt = "2026-08-07T12:00:02Z",
    characterId = "example_guide",
    provider = "mock",
    dialogue = "malicious",
    proposedChoice = json.null,
    resultTags = json.array(),
    questCompleted = true,
}))
local malicious = bridge:poll_response({
    requestId = "lua-malicious",
    characterId = "example_guide",
    allowedChoiceIds = {},
    allowedResultTags = {},
})
assert(not malicious.ok and malicious.reason == "response-json-invalid")
assert(malicious.requestState == "rejected")
local rejected_again = bridge:poll_response({
    requestId = "lua-malicious",
    characterId = "example_guide",
    allowedChoiceIds = {},
    allowedResultTags = {},
})
assert(not rejected_again.ok and rejected_again.reason == "response-rejected")
assert(rejected_again.requestState == "rejected")

assert(bridge:submit_request(request_with("lua-dialogue-too-long")).ok)
write_file(bridge_root .. "/outbox/lua-dialogue-too-long.json", json.encode({
    schemaVersion = "1.0.0",
    requestId = "lua-dialogue-too-long",
    createdAt = "2026-08-07T12:00:02Z",
    characterId = "example_guide",
    provider = "mock",
    dialogue = string.rep("界", 4001),
    proposedChoice = json.null,
    resultTags = json.array(),
}))
local dialogue_too_long = bridge:poll_response({
    requestId = "lua-dialogue-too-long",
    characterId = "example_guide",
    allowedChoiceIds = {},
    allowedResultTags = {},
})
assert(not dialogue_too_long.ok)
assert(dialogue_too_long.reason == "response-contract-invalid")

assert(bridge:submit_request(request_with("lua-response-too-large")).ok)
write_file(
    bridge_root .. "/outbox/lua-response-too-large.json",
    string.rep("x", 64 * 1024 + 1)
)
local response_too_large = bridge:poll_response({
    requestId = "lua-response-too-large",
    characterId = "example_guide",
    allowedChoiceIds = {},
    allowedResultTags = {},
})
assert(not response_too_large.ok)
assert(response_too_large.reason == "response-too-large")
assert(response_too_large.requestState == "rejected")

write_file(bridge_root .. "/outbox/lua-unauthorized.json", json.encode({
    schemaVersion = "1.0.0",
    requestId = "lua-unauthorized",
    createdAt = "2026-08-07T12:00:03Z",
    characterId = "example_guide",
    provider = "mock",
    dialogue = "unauthorized",
    proposedChoice = "grant_reward",
    resultTags = json.array({ "change_world" }),
}))
local unauthorized = bridge:poll_response({
    requestId = "lua-unauthorized",
    characterId = "example_guide",
    allowedChoiceIds = { "continue" },
    allowedResultTags = { "heard_player" },
})
assert(not unauthorized.ok and unauthorized.reason == "response-choice-not-authorized")

local status = bridge:status()
assert(status.directStateMutation == false)
assert(status.authority == "presentation-and-proposals-only")
assert(status.maximumRequestBytes == 256 * 1024)
assert(status.maximumPlayerTextCharacters == 8000)
assert(status.maximumDialogueCharacters == 4000)
assert(status.requestTtlSeconds == 5)
assert(status.directoryOwner == "pal-agent-dialogue-sidecar")

print("PASS UE4SS Lua bridge matched Core/Rust limits, atomically wrote inbox requests, failed closed on missing directories, expired stale work, and rejected authority fields")
