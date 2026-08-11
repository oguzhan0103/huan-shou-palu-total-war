package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local Registry = require("pwft.registry")
local Progression = require("pwft.faction_progression")
local PalReconciliation = require("pwft.pal_reconciliation")
local PalRaidResultAdapter = require("pwft.pal_raid_result_adapter")
local PalRaidNativeBinding = require("pwft.pal_raid_native_binding")

local function object(name, fields)
    local value = fields or {}
    value.name = name
    function value:IsValid() return true end
    function value:GetFullName() return self.name end
    return value
end

local function parameter(value)
    return { get = function() return value end }
end

local progression = Progression.create(Registry.progression)
local reconciliation = PalReconciliation.create(
    Registry.palReconciliation,
    progression,
    { randomIndex = function() return 1 end }
)
local faction_id = "pwft.faction.desert_pal_tribe"
assert(reconciliation:register_content(faction_id, {
    contentPackId = "test.native.raid",
    contentVersion = "1.0.0",
    tokenQuota = 3,
    maximumAffinityPerDiscourse = 10,
}).ok)

local adapter = PalRaidResultAdapter.create(reconciliation, {
    normalizedRaidAdapterEnabled = true,
    nativeRaidResultBindingEnabled = true,
    attendanceRaidResultBindingEnabled = true,
    leaderDesignation = "first-spawn-of-final-wave",
})

local callbacks = {}
local logs = {}
local local_controller = object("local-controller", {
    GetPlayerUId = function() return "uid-local" end,
})
local local_pawn = object("local-pawn", {
    GetController = function() return local_controller end,
})
local_controller.K2_GetPawn = function() return local_pawn end

local owned_pal = object("owned-pal")
local utility = object("PalUtility", {
    IsPlayersOtomo = function(_, actor)
        return actor == owned_pal
    end,
    GetTrainerPlayerController_ForServer = function(_, actor)
        if actor == owned_pal then return local_controller end
        return nil
    end,
})

local binding = PalRaidNativeBinding.create(adapter, {
    nativeRaidResultBindingEnabled = true,
}, {
    registerHook = function(path, callback)
        callbacks[path] = callback
        return "pre:" .. path, "post:" .. path
    end,
    loadAsset = function() return true end,
    getLocalPlayerController = function() return local_controller end,
    getPalUtility = function() return utility end,
    objectKey = function(value) return value and value.name or nil end,
    logger = function(message) logs[#logs + 1] = message end,
})

assert(binding:register_source(
    "Invader_Group_Monster_Test",
    faction_id,
    { contentPackId = "test.native.raid", contentVersion = "1.0.0" }
).ok)
assert(binding:register_source(
    "Invader_Group_Monster_Test",
    faction_id
).reason == "native-raid-source-already-registered")
assert(not binding:register_source(
    "Invader_Group_Monster_Test",
    "pwft.faction.dark_nocturnal_pal_tribe"
).ok)

local started = binding:start()
assert(started.ok and binding:status().ready)
assert(binding:status().hookCount == 4)
assert(binding:status().sourceCount == 1)

local paths = PalRaidNativeBinding.paths

-- Unknown native groups are observed but never attributed to a Pal faction.
callbacks[paths.start](parameter(object("manager")), parameter({
    ChosenInvaderData = { GroupName = "unbound" },
    GroupGuid = "guid-unbound",
    WaveInfo = { CurrentWave = 1, WaveMax = 3 },
}))
assert(binding:status().ignoredUnboundStarts == 1)
assert(adapter:event_status("native-pal-raid:guid-unbound") == nil)

-- The authoritative manager start creates one event. The first spawn in the
-- final wave becomes the deterministic leader.
callbacks[paths.start](parameter(object("manager")), parameter({
    ChosenInvaderData = { GroupName = "Invader_Group_Monster_Test" },
    GroupGuid = "guid-direct",
    WaveInfo = { CurrentWave = 1, WaveMax = 3 },
}))
local incident = object("incident-direct", {
    GroupGuid = "guid-direct",
    NewVar = object("info-direct", {
        CurrentWave = 1,
        GetCurrentWave = function(self) return self.CurrentWave end,
    }),
})
local first = object("raid-member-first")
callbacks[paths.spawn](parameter(incident), parameter(first))
incident.NewVar.CurrentWave = 3
local leader = object("raid-member-leader")
callbacks[paths.spawn](parameter(incident), parameter(leader))
local event = adapter:event_status("native-pal-raid:guid-direct")
assert(event.memberCount == 2)
assert(event.leaderActorKey == "raid-member-leader")

callbacks[paths.death](parameter(incident), parameter({
    SelfActor = leader,
    LastAttacker = local_pawn,
}))
assert(adapter:event_status("native-pal-raid:guid-direct").leaderKillCredited)
callbacks[paths.finish](parameter(object("manager")), parameter({
    GroupGuid = "guid-direct",
    WaveInfo = {
        CurrentWave = 3,
        WaveMax = 3,
        bCompleteAllWave = true,
    },
}))
assert(reconciliation:status(faction_id).tokensAwarded == 1)
assert(binding:status().settlements == 1)

-- An owned Pal is accepted only when both IsPlayersOtomo and the native
-- trainer controller UID resolve to the local player.
callbacks[paths.start](parameter(object("manager")), parameter({
    ChosenInvaderData = { GroupName = "Invader_Group_Monster_Test" },
    GroupGuid = "guid-owned",
    WaveInfo = { CurrentWave = 1, WaveMax = 1 },
}))
local owned_incident = object("incident-owned", {
    GroupGuid = "guid-owned",
    NewVar = object("info-owned", {
        CurrentWave = 1,
        GetCurrentWave = function(self) return self.CurrentWave end,
    }),
})
local owned_leader = object("raid-owned-leader")
callbacks[paths.spawn](parameter(owned_incident), parameter(owned_leader))
callbacks[paths.death](parameter(owned_incident), parameter({
    SelfActor = owned_leader,
    LastAttacker = owned_pal,
}))
callbacks[paths.finish](parameter(object("manager")), parameter({
    GroupGuid = "guid-owned",
    WaveInfo = {
        CurrentWave = 1,
        WaveMax = 1,
        bCompleteAllWave = true,
    },
}))
assert(reconciliation:status(faction_id).tokensAwarded == 2)

-- Timeout/incomplete wave is an authoritative end but never a player win.
callbacks[paths.start](parameter(object("manager")), parameter({
    ChosenInvaderData = { GroupName = "Invader_Group_Monster_Test" },
    GroupGuid = "guid-timeout",
    WaveInfo = { CurrentWave = 1, WaveMax = 2 },
}))
callbacks[paths.finish](parameter(object("manager")), parameter({
    GroupGuid = "guid-timeout",
    WaveInfo = {
        CurrentWave = 1,
        WaveMax = 2,
        bCompleteAllWave = false,
    },
}))
assert(reconciliation:status(faction_id).tokensAwarded == 2)

-- Missing local UID fails closed even if every other signal looks local.
local_controller.GetPlayerUId = function() return nil end
callbacks[paths.start](parameter(object("manager")), parameter({
    ChosenInvaderData = { GroupName = "Invader_Group_Monster_Test" },
    GroupGuid = "guid-no-uid",
    WaveInfo = { CurrentWave = 1, WaveMax = 1 },
}))
local uid_incident = object("incident-no-uid", {
    GroupGuid = "guid-no-uid",
    NewVar = object("info-no-uid", {
        CurrentWave = 1,
        GetCurrentWave = function(self) return self.CurrentWave end,
    }),
})
local uid_leader = object("raid-no-uid-leader")
callbacks[paths.spawn](parameter(uid_incident), parameter(uid_leader))
callbacks[paths.death](parameter(uid_incident), parameter({
    SelfActor = uid_leader,
    LastAttacker = local_pawn,
}))
callbacks[paths.finish](parameter(object("manager")), parameter({
    GroupGuid = "guid-no-uid",
    WaveInfo = {
        CurrentWave = 1,
        WaveMax = 1,
        bCompleteAllWave = true,
    },
}))
assert(reconciliation:status(faction_id).tokensAwarded == 2)

local saw_ready = false
local saw_settlement = false
for _, line in ipairs(logs) do
    if string.find(line, "PAL_RAID_NATIVE_BINDING_READY", 1, true) then
        saw_ready = true
    end
    if string.find(line, "PAL_RAID_NATIVE_SETTLED", 1, true) then
        saw_settlement = true
    end
end
assert(saw_ready and saw_settlement)

-- Blueprint incident functions do not exist at the title screen on the live
-- build. Manager hooks may register immediately while the enemy Blueprint
-- hooks become available only after the world-load callback.
local delayed_callbacks = {}
local world_loaded = false
local delayed_binding = PalRaidNativeBinding.create(adapter, {
    nativeRaidResultBindingEnabled = true,
}, {
    registerHook = function(path, callback)
        if not world_loaded
            and (path == paths.spawn or path == paths.death) then
            error("UFunction-not-loaded")
        end
        delayed_callbacks[path] = callback
        return "pre:" .. path, "post:" .. path
    end,
    loadAsset = function() return true end,
    logger = function(message) logs[#logs + 1] = message end,
})
local delayed_start = delayed_binding:start()
assert(not delayed_start.ok)
assert(delayed_binding:status().hookCount == 2)
world_loaded = true
local delayed_retry = delayed_binding:on_world_loaded("test-load-map-post")
assert(delayed_retry.ok)
assert(delayed_binding:status().ready)
assert(delayed_binding:status().hookCount == 4)
assert(type(delayed_callbacks[paths.spawn]) == "function")
assert(type(delayed_callbacks[paths.death]) == "function")

print("PASS native Pal raid hooks, source mapping, direct/owned-Pal leader credit, timeout, UID fail-closed, and finite token settlement")
