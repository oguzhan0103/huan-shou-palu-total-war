package.path = table.concat({
    "mod0/ue4ss/PalMultiOtomo0/Scripts/?.lua",
    "mod0/ue4ss/PalMultiOtomo0/Scripts/?/init.lua",
    package.path,
}, ";")

local registered_callbacks = {}
local delayed_callbacks = 0
local logs = {}

local original_print = print
print = function(message)
    table.insert(logs, tostring(message))
end

Key = { F6 = "F6", F7 = "F7" }
RegisterKeyBind = function(key, callback)
    registered_callbacks[key] = callback
end
ExecuteInGameThread = function(callback)
    callback()
end
ExecuteWithDelay = function(_, callback)
    delayed_callbacks = delayed_callbacks + 1
    callback()
end

local function valid_object(name)
    return {
        name = name,
        IsValid = function()
            return true
        end,
        GetFullName = function(self)
            return self.name
        end,
    }
end

local function pal_actor(name, active)
    local actor = valid_object(name)
    actor.active = active
    actor.GetActiveActorFlag = function(self)
        return self.active
    end
    return actor
end

local owner = valid_object("BP_Player_C test-owner")
owner.IsLocallyControlled = function()
    return true
end
owner.K2_GetActorLocation = function()
    return { X = 1000.0, Y = 2000.0, Z = 300.0 }
end
owner.K2_GetActorRotation = function()
    return { Pitch = 0.0, Yaw = 90.0, Roll = 0.0 }
end
owner.GetActorForwardVector = function()
    return { X = 0.0, Y = 1.0, Z = 0.0 }
end
owner.GetActorRightVector = function()
    return { X = -1.0, Y = 0.0, Z = 0.0 }
end

local handles = {}
for slot_index = 0, 4 do
    local handle = valid_object("PalIndividualCharacterHandle slot-" .. tostring(slot_index))
    handle.slotIndex = slot_index
    handles[slot_index] = handle
end

local holder = valid_object("BP_OtomoPalHolderComponent_C test-holder")
holder.actors = {
    [0] = pal_actor("BP_PalCharacter_C primary", true),
    [1] = pal_actor("BP_PalCharacter_C reserve-1", false),
    [2] = pal_actor("BP_PalCharacter_C reserve-2", false),
    [3] = pal_actor("BP_PalCharacter_C reserve-3", false),
    [4] = pal_actor("BP_PalCharacter_C reserve-4", false),
}
holder.activationCalls = {}
holder.recallCalls = {}
holder.restoreCalls = {}
holder.primarySlot = 0
holder.IsControlledByPlayer = function()
    return true
end
holder.TryGetOwnerControlledCharacter = function()
    return owner
end
holder.GetSpawnedOtomoID = function(self)
    return self.primarySlot
end
holder.TryGetSpawnedOtomo = function(self)
    return self.actors[0]
end
holder.GetMaxOtomoNum = function()
    return 5
end
holder.GetOtomoIndividualHandle = function(_, slot_index)
    return handles[slot_index]
end
holder.TryGetOtomoActorBySlotIndex = function(self, slot_index)
    return self.actors[slot_index]
end
holder.ActivatePalByHandle = function(self, handle, location, rotation, keep_primary)
    table.insert(self.activationCalls, {
        handle = handle,
        location = location,
        rotation = rotation,
        keepPrimary = keep_primary,
    })
    self.actors[handle.slotIndex].active = true
end
holder["Inactivate Otomo By Handle"] = function(self, handle, delayed, success_out)
    assert(type(success_out) == "table", "boolean out parameter placeholder missing")
    table.insert(self.recallCalls, {
        handle = handle,
        delayed = delayed,
    })
    self.actors[handle.slotIndex].active = false
    -- The current Palworld Blueprint clears ActivatedOtomoSlotID even when
    -- the inactivated handle is an auxiliary kept outside the primary ID.
    self.primarySlot = -1
    success_out.IsSuccess = true
end
holder.SetActivateOtomoID_ToALL = function(self, slot_index)
    table.insert(self.restoreCalls, slot_index)
    self.primarySlot = slot_index
end

local function holder_wrapper()
    return setmetatable({}, {
        __index = holder,
    })
end

FindAllOf = function(class_name)
    assert(class_name == "BP_OtomoPalHolderComponent_C", "unexpected class scan")
    -- UE4SS may return a different Lua userdata wrapper for the same UObject
    -- on a later FindAllOf call. The runtime must compare stable UObject
    -- identity rather than Lua wrapper equality.
    return { holder_wrapper() }
end

local Config = require("pmo.config")
local Runtime = require("pmo.runtime")
local state = Runtime.start(Config)

assert(type(registered_callbacks[Key.F6]) == "function", "F6 callback not registered")
assert(type(registered_callbacks[Key.F7]) == "function", "F7 callback not registered")
assert(state.mode == "idle", "unexpected initial state")

registered_callbacks[Key.F6]()
assert(#holder.activationCalls == 1, "auxiliary activation not called exactly once")
assert(holder.activationCalls[1].handle == handles[1], "second party slot was not preferred")
assert(holder.activationCalls[1].keepPrimary == true, "primary Otomo ID was not preserved")
assert(holder.activationCalls[1].location.X == 720.0, "right-side spawn offset incorrect")
assert(holder.activationCalls[1].location.Y == 1880.0, "rear spawn offset incorrect")
assert(holder.actors[0] ~= nil, "primary Pal was removed during auxiliary spawn")
assert(holder.actors[1].active == true, "auxiliary Pal was not active after verification")
assert(state.mode == "auxiliary-active", "spawn was not verified")

registered_callbacks[Key.F6]()
registered_callbacks[Key.F6]()
registered_callbacks[Key.F6]()
assert(#holder.activationCalls == 4, "four auxiliaries were not activated")
assert(holder.activationCalls[2].handle == handles[2], "third party slot was not activated second")
assert(holder.activationCalls[3].handle == handles[3], "fourth party slot was not activated third")
assert(holder.activationCalls[4].handle == handles[4], "fifth party slot was not activated fourth")
assert(holder.activationCalls[2].location.X == 1280.0, "left-side formation offset incorrect")
assert(holder.actors[1].active == true, "first auxiliary not active")
assert(holder.actors[2].active == true, "second auxiliary not active")
assert(holder.actors[3].active == true, "third auxiliary not active")
assert(holder.actors[4].active == true, "fourth auxiliary not active")

registered_callbacks[Key.F6]()
assert(#holder.activationCalls == 4, "auxiliary limit was not enforced")

registered_callbacks[Key.F7]()
assert(#holder.recallCalls == 4, "recall-all did not call every auxiliary")
assert(holder.recallCalls[1].handle == handles[1], "wrong first Pal handle recalled")
assert(holder.recallCalls[4].handle == handles[4], "wrong final Pal handle recalled")
assert(holder.recallCalls[1].delayed == false, "unexpected delayed recall")
assert(holder.actors[0] ~= nil, "primary Pal was removed during auxiliary recall")
assert(holder.actors[1].active == false, "auxiliary Pal remained active after recall")
assert(holder.actors[2].active == false, "second auxiliary remained active after recall")
assert(holder.actors[3].active == false, "third auxiliary remained active after recall")
assert(holder.actors[4].active == false, "fourth auxiliary remained active after recall")
assert(state.mode == "idle", "recall was not verified")
assert(#holder.restoreCalls == 1 and holder.restoreCalls[1] == 0, "primary slot ID was not restored")
assert(holder.primarySlot == 0, "primary slot remained cleared after recall")
assert(delayed_callbacks == 10, "unexpected staged callback count")

-- Simulate an auxiliary left active after a prior prototype lost its Lua
-- state. F6 must discover and recall it before considering another spawn.
holder.actors[2].active = true
registered_callbacks[Key.F7]()
assert(#holder.recallCalls == 5, "orphaned auxiliary was not discovered and recalled")
assert(holder.recallCalls[5].handle == handles[2], "wrong orphaned auxiliary recalled")
assert(holder.actors[2].active == false, "orphaned auxiliary remained active")

holder.actors[0].active = false
registered_callbacks[Key.F6]()
assert(#holder.activationCalls == 4, "activation occurred without a primary Pal")

print = original_print
print("PASS PalMultiOtomo0 runtime smoke")
