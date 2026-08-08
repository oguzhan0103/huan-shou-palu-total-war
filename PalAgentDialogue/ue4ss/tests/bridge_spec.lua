local project_root = assert(
    rawget(_G, "PAL_AGENT_TEST_PROJECT_ROOT") or os.getenv("PAL_AGENT_TEST_PROJECT_ROOT"),
    "test project root is required"
)
local bridge_root = assert(
    rawget(_G, "PAL_AGENT_TEST_BRIDGE_ROOT") or os.getenv("PAL_AGENT_TEST_BRIDGE_ROOT"),
    "test bridge root is required"
)

package.path = table.concat({
    project_root .. "/ue4ss/PalAgentDialogueBridge0/Scripts/?.lua",
    project_root .. "/ue4ss/PalAgentDialogueBridge0/Scripts/?/init.lua",
    package.path,
}, ";")

local json = require("pad.json")
local bridge_module = require("pad.bridge")
local bridge = bridge_module.create({ root = bridge_root, allowMockProvider = true })

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

local base_request = {
    schemaVersion = "1.0.0",
    requestId = "lua-e2e-1",
    createdAt = "2026-08-07T12:00:00Z",
    characterId = "example_guide",
    sessionId = "meeting-1",
    worldKey = "world-local",
    playerKey = "player-local",
    locale = "zh-CN",
    playerText = "我们继续谈吧。",
    contextKeys = { "example.guide.met_player" },
    allowedChoices = {
        { choiceId = "continue", textKey = "example.choice.continue" },
    },
    allowedResultTags = { "heard_player" },
}

local forbidden_request = {}
for key, value in pairs(base_request) do forbidden_request[key] = value end
forbidden_request.requestId = "lua-forbidden"
forbidden_request.affinityDelta = 999
local forbidden = bridge:submit_request(forbidden_request)
assert(not forbidden.ok and forbidden.reason == "request-fields-not-allowed")

local submitted = bridge:submit_request(base_request)
assert(submitted.ok and submitted.reason == "request-submitted")

local inbox_path = bridge_root .. "/inbox/lua-e2e-1.json"
local encoded_request = json.decode(read_file(inbox_path))
assert(encoded_request.requestId == "lua-e2e-1")
assert(encoded_request.playerText == "我们继续谈吧。")
assert(encoded_request.affinityDelta == nil)
assert(#encoded_request.allowedChoices == 1)

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

print("PASS UE4SS Lua bridge atomically wrote inbox request, strictly read outbox response, and rejected authority fields plus unauthorized proposals")
