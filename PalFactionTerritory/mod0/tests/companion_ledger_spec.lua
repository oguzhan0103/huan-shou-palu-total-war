package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local Json = require("pwft.json")
local CompanionLedger = require("pwft.companion_ledger")

local files = {}
local filesystem = {
    write = function(path, content)
        files[path] = content
        return true
    end,
    append = function(path, content)
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

print("PASS external companion ledger and transaction stream")
