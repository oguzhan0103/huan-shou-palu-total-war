package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local Json = require("pwft.json")
local Registry = require("pwft.registry")
local Progression = require("pwft.faction_progression")
local ProgressionStore = require("pwft.progression_store")

local files = {}
local filesystem = {
    read = function(path)
        if files[path] == nil then
            return nil, "not-found"
        end
        return files[path]
    end,
    write = function(path, content)
        files[path] = content
        return true
    end,
    exists = function(path)
        return files[path] ~= nil
    end,
    rename = function(source, target)
        if files[source] == nil then
            return false, "not-found"
        end
        if files[target] ~= nil then
            return false, "target-exists"
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

local disabled = ProgressionStore.create({
    enabled = false,
    mode = "mod-sidecar-json",
    reason = "profile-key-pending",
})
assert(disabled:status().enabled == false)
assert(disabled:save({ revision = 1 }).skipped == true)

local unsafe_ok = pcall(ProgressionStore.create, {
    enabled = true,
    profileKey = "../SaveGames",
    rootPath = "state",
}, filesystem)
assert(unsafe_ok == false)

local store = ProgressionStore.create({
    enabled = true,
    mode = "mod-sidecar-json",
    profileKey = "world-001.player-002",
    rootPath = "state",
    now = function()
        return 1722140000
    end,
}, filesystem)

local first = {
    schemaVersion = "1.0.0",
    revision = 1,
    factions = {
        rayne = { reputation = 25 },
    },
}
local first_save = store:save(first)
assert(first_save.ok == true)
assert(files[store.primaryPath] ~= nil)
assert(files[store.temporaryPath] == nil)
local first_load = store:load()
assert(first_load.source == "primary")
assert(first_load.snapshot.revision == 1)
assert(first_load.snapshot.factions.rayne.reputation == 25)

local second = {
    schemaVersion = "1.0.0",
    revision = 2,
    factions = {
        rayne = { reputation = 40 },
    },
}
local second_save = store:save(second)
assert(second_save.ok == true)
assert(files[store.backupPath] ~= nil)
assert(store:load().snapshot.revision == 2)

files[store.primaryPath] = "{broken"
local fallback = store:load()
assert(fallback.source == "backup")
assert(fallback.snapshot.revision == 1)
assert(string.find(fallback.primaryError, "invalid-json", 1, true) ~= nil)

local decoded_backup = Json.decode(files[store.backupPath])
decoded_backup.profileKey = "other-profile"
files[store.backupPath] = Json.encode(decoded_backup)
local missing, load_error = store:load()
assert(missing == nil)
assert(string.find(load_error, "profile-key-mismatch", 1, true) ~= nil)

local migration_store = ProgressionStore.create({
    enabled = true,
    mode = "mod-sidecar-json",
    profileKey = "world-migration.player-001",
    rootPath = "state",
    now = function()
        return 1722140001
    end,
}, filesystem)
local legacy_progression = Progression.create(
    Registry.progression
):export_snapshot()
legacy_progression.schemaVersion = "1.0.0"
legacy_progression.processedReputationOperations = nil
legacy_progression.extensionProbe = { preserved = "primary" }
assert(migration_store:save(legacy_progression).ok)
local legacy_primary = migration_store:load()
assert(legacy_primary.source == "primary")
local migrated_primary = Progression.create(
    Registry.progression,
    legacy_primary.snapshot
)
assert(migrated_primary:status().schemaVersion == "1.1.0")
assert(migrated_primary:status().lastMigration.fromSchemaVersion == "1.0.0")
assert(migrated_primary:export_snapshot().extensionProbe.preserved == "primary")

local current_progression = migrated_primary:export_snapshot()
current_progression.revision = current_progression.revision + 1
assert(migration_store:save(current_progression).ok)
files[migration_store.primaryPath] = "{broken"
local legacy_backup = migration_store:load()
assert(legacy_backup.source == "backup")
local migrated_backup = Progression.create(
    Registry.progression,
    legacy_backup.snapshot
)
assert(migrated_backup:status().schemaVersion == "1.1.0")
assert(migrated_backup:status().lastMigration.fromSchemaVersion == "1.0.0")
assert(migrated_backup:export_snapshot().extensionProbe.preserved == "primary")

print("PASS versioned progression sidecar store with primary/backup payload migration")
