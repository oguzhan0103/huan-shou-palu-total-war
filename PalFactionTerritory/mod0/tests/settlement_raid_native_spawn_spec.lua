package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?/init.lua",
    package.path,
}, ";")

-- Build 24467282 did not expose UE4SS's optional global FName constructor in
-- the live run. Exercise the reflected Kismet conversion route instead.
FName = nil

local function valid_object(full_name)
    return {
        IsValid = function()
            return true
        end,
        GetFullName = function()
            return full_name
        end,
    }
end

local string_library = valid_object(
    "KismetStringLibrary /Script/Engine.Default__KismetStringLibrary"
)
function string_library:Conv_StringToName(value)
    return "NativeName:" .. value
end

local controller_class = valid_object(
    "Class /Script/Pal.PalAIController"
)
local manager = valid_object("PalNPCManager Test")
manager.NPCAIControllerBaseClass = controller_class
local requests = {}
function manager:SpawnNPCForServer(spawn_info, callback)
    assert(callback == nil)
    table.insert(requests, spawn_info)
    return valid_object(
        "PalIndividualCharacterHandle Test" .. tostring(#requests)
    )
end

local player_controller = valid_object("PalPlayerController Test")
local utility = valid_object("PalUtility /Script/Pal.Default__PalUtility")
function utility:GetNPCManager(context)
    assert(context == player_controller)
    return manager
end

function StaticFindObject(path)
    if path == "/Script/Engine.Default__KismetStringLibrary" then
        return string_library
    end
    if path == "/Script/Pal.Default__PalUtility" then
        return utility
    end
    return nil
end

local Config = require("pwft.config")
local SettlementRaid = require("pwft.settlement_raid")
local test = SettlementRaid._test

local native_name, name_error = test.make_native_name("NegativeKoala")
assert(name_error == nil)
assert(native_name == "NativeName:NegativeKoala")

local instance = {
    config = Config.settlementRaid,
}
local player_location = {
    X = -346100.0,
    Y = 191750.0,
    Z = -100.0,
}
local handles, spawn_error = test.spawn_native_attendance_wave(
    instance,
    player_controller,
    player_location
)

assert(spawn_error == nil)
assert(#handles == 4)
assert(#requests == 4)
for index, request in ipairs(requests) do
    local expected_id = Config.settlementRaid.attendanceSimulation
        .nativeCountdownSpawn.palIds[index]
    local offset = Config.settlementRaid.attendanceSimulation
        .nativeCountdownSpawn.offsets[index]
    assert(request.ControllerClass == controller_class)
    assert(request.CharacterID == "NativeName:" .. expected_id)
    assert(request.Level == 80)
    assert(request.Location.X == player_location.X + offset.X)
    assert(request.Location.Y == player_location.Y + offset.Y)
    assert(request.Location.Z == player_location.Z + offset.Z)
    assert(request.Yaw == 0.0)
    assert(request.Squad == nil)
end

local destroyed = {}
local attacker_one = valid_object("PalCharacter SpawnedAttacker1")
function attacker_one:K2_DestroyActor()
    destroyed[self:GetFullName()] = true
end
local attacker_two = valid_object("PalCharacter SpawnedAttacker2")
function attacker_two:K2_DestroyActor()
    destroyed[self:GetFullName()] = true
end
local handle_one = valid_object("PalIndividualCharacterHandle Cleanup1")
function handle_one:TryGetIndividualActor()
    return attacker_one
end
local handle_two = valid_object("PalIndividualCharacterHandle Cleanup2")
function handle_two:TryGetIndividualActor()
    return attacker_two
end
local cleanup_instance = {
    attackers = { attacker_one },
    attendanceNativeSpawnHandles = { handle_one, handle_two },
    attendanceSpawnedActorNames = {
        [attacker_one:GetFullName()] = true,
    },
    attendanceDestroyedCount = 0,
    attendanceDestroyFailureCount = 0,
}
local destroyed_count, destroy_failures =
    test.destroy_attendance_attackers(
        cleanup_instance,
        "offline-spec"
    )
assert(destroyed_count == 2)
assert(destroy_failures == 0)
assert(destroyed[attacker_one:GetFullName()] == true)
assert(destroyed[attacker_two:GetFullName()] == true)
assert(#cleanup_instance.attendanceNativeSpawnHandles == 0)
assert(next(cleanup_instance.attendanceSpawnedActorNames) == nil)

print("PASS settlement raid native countdown spawn (Kismet FName fallback; four immediate NPC-manager requests; resident-priority siege; explicit actor cleanup; no loaded-world fallback)")
