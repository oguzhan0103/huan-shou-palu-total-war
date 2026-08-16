package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local Json = require("pwft.json")
local CompanionLedger = require("pwft.companion_ledger")

local files = {}
local fail_next_append = false
local fail_next_promote_target = nil
local filesystem = {
    write = function(path, content)
        files[path] = content
        return true
    end,
    append = function(path, content)
        if fail_next_append then
            fail_next_append = false
            return false, "injected-append-failure"
        end
        files[path] = (files[path] or "") .. content
        return true
    end,
    exists = function(path)
        return files[path] ~= nil
    end,
    rename = function(source, target)
        if files[source] == nil then
            return false, "not-found"
        end
        if target == fail_next_promote_target
            and source == target .. ".tmp" then
            fail_next_promote_target = nil
            return false, "injected-promote-failure"
        end
        files[target] = files[source]
        files[source] = nil
        return true
    end,
    remove = function(path)
        if files[path] == nil then
            return false, "not-found"
        end
        files[path] = nil
        return true
    end,
}

local ledger = CompanionLedger.create({
    enabled = true,
    rootPath = "state",
    now = function()
        return 1722140000
    end,
}, filesystem)

local activated = ledger:activate({
    profileKey = "world-ABC.player-DEF",
    worldDirectory = "ABC",
    playerUid = "DEF",
})
assert(activated == true)
assert(ledger:status().active == true)

local recorded = ledger:record({
    type = "commerce-sale-confirmed",
    factionId = "pwft.faction.rayne_syndicate",
    applied = 12,
})
assert(recorded == true)

local published = ledger:publish({
    releaseId = "PalFactionTerritory0-mod0",
    progression = {
        revision = 3,
        factions = {
            ["pwft.faction.rayne_syndicate"] = {
                reputation = 12,
            },
        },
    },
})
assert(published == true)

local status = ledger:status()
local active = Json.decode(files[status.activePath])
local state = Json.decode(files[status.statePath])
assert(active.profileKey == "world-ABC.player-DEF")
assert(active.stateFile == "pwft-companion-state-v1-world-ABC.player-DEF.json")
assert(state.progression.revision == 3)
assert(state.eventSequence == 2)
assert(string.find(files[status.eventsPath], "profile%-activated") ~= nil)
assert(string.find(files[status.eventsPath], "commerce%-sale%-confirmed") ~= nil)

local previous_state = files[status.statePath]
fail_next_promote_target = status.statePath
local failed_publish, failed_publish_reason = ledger:publish({
    releaseId = "must-not-replace-previous-state",
})
assert(failed_publish == false)
assert(string.find(
    failed_publish_reason,
    "temporary%-promote%-failed"
) ~= nil)
assert(files[status.statePath] == previous_state)
assert(files[status.statePath .. ".tmp"] == nil)
local recovered_publish = ledger:publish({
    releaseId = "replacement-after-failure",
})
assert(recovered_publish == true)
assert(
    Json.decode(files[status.statePath]).releaseId
        == "replacement-after-failure"
)
assert(files[status.statePath .. ".bak"] == previous_state)
assert(ledger:status().lastError == nil)

local sequence_before_failure = ledger:status().eventSequence
fail_next_append = true
local failed_record = ledger:record({ type = "must-not-advance" })
assert(failed_record == false)
assert(ledger:status().eventSequence == sequence_before_failure)
local retried_record, retried_envelope = ledger:record({
    type = "append-retried",
})
assert(retried_record == true)
assert(retried_envelope.sequence == sequence_before_failure + 1)

local sequence_before_encode_failure = ledger:status().eventSequence
local encoded_record, encoded_record_reason = ledger:record({
    type = "invalid-numeric-object-key",
    invalid = { [0] = "zero" },
})
assert(encoded_record == false)
assert(string.find(encoded_record_reason, "event%-encode%-failed") ~= nil)
assert(ledger:status().eventSequence == sequence_before_encode_failure)

local state_before_encode_failure = files[status.statePath]
local encoded_publish, encoded_publish_reason = ledger:publish({
    releaseId = "must-not-replace-on-encode-failure",
    invalid = { [0] = "zero" },
})
assert(encoded_publish == false)
assert(string.find(
    encoded_publish_reason,
    "encode%-failed:invalid"
) ~= nil)
assert(files[status.statePath] == state_before_encode_failure)
assert(files[status.statePath .. ".tmp"] == nil)

local hostile_pairs = setmetatable({}, {
    __pairs = function()
        error("hostile-pairs")
    end,
})
local sequence_before_copy_failure = ledger:status().eventSequence
local copied_record, copied_record_reason = ledger:record({
    type = "invalid-copy-source",
    invalid = hostile_pairs,
})
assert(copied_record == false)
assert(string.find(copied_record_reason, "event%-copy%-failed") ~= nil)
assert(ledger:status().eventSequence == sequence_before_copy_failure)

local state_before_copy_failure = files[status.statePath]
local copied_publish, copied_publish_reason = ledger:publish({
    releaseId = "must-not-replace-on-copy-failure",
    invalid = hostile_pairs,
})
assert(copied_publish == false)
assert(string.find(copied_publish_reason, "state%-copy%-failed") ~= nil)
assert(files[status.statePath] == state_before_copy_failure)
assert(files[status.statePath .. ".tmp"] == nil)

print("PASS external companion ledger transaction stream and failure-safe replacement")
