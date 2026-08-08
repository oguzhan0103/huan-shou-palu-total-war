local UEHelpers = require("UEHelpers")

local PREFIX = "[PalFactionTerritoryQAHarness0]"
local SETTLEMENT_LOCATION = {
    X = -346617.56,
    Y = 191706.60,
    -- Five metres above the registry centre lets native collision/physics
    -- settle the player onto the village terrain after the move.
    Z = 500.00,
}
local SETTLEMENT_ROTATION = {
    Pitch = 0.0,
    Yaw = 0.0,
    Roll = 0.0,
}
local callbacks = {}

local function log(message)
    print(string.format("%s %s\n", PREFIX, tostring(message)))
end

local function is_valid(object)
    if object == nil then
        return false
    end
    local ok, valid = pcall(function()
        return object:IsValid()
    end)
    return ok and valid == true
end

local function get_player()
    local ok, controller = pcall(function()
        return UEHelpers.GetPlayerController()
    end)
    if not ok or not is_valid(controller) then
        return nil, "player-controller-not-ready"
    end

    local pawn = nil
    pcall(function()
        pawn = controller.Pawn
    end)
    if not is_valid(pawn) then
        pcall(function()
            pawn = controller.AcknowledgedPawn
        end)
    end
    if not is_valid(pawn) then
        return nil, "player-pawn-not-ready"
    end
    return pawn, nil
end

local function distance_to_settlement(location)
    local dx = location.X - SETTLEMENT_LOCATION.X
    local dy = location.Y - SETTLEMENT_LOCATION.Y
    local dz = location.Z - SETTLEMENT_LOCATION.Z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function probe(label)
    local pawn, player_error = get_player()
    if player_error ~= nil then
        log(string.format(
            "QA_PROBE label=%s result=%s raidMutation=false saveWrite=false",
            tostring(label),
            tostring(player_error)
        ))
        return
    end

    local location = nil
    pcall(function()
        location = pawn:K2_GetActorLocation()
    end)
    if location == nil then
        log(string.format(
            "QA_PROBE label=%s playerLocation=<unreadable> raidMutation=false saveWrite=false",
            tostring(label)
        ))
        return
    end

    log(string.format(
        "QA_PROBE label=%s playerLocation=(%.3f,%.3f,%.3f) distanceToSettlement=%.1f raidMutation=false saveWrite=false",
        tostring(label),
        location.X,
        location.Y,
        location.Z,
        distance_to_settlement(location)
    ))
end

local function schedule_probe(delay_ms, label)
    local callback = function()
        if type(ExecuteInGameThread) == "function" then
            ExecuteInGameThread(function()
                probe(label)
            end)
        else
            probe(label)
        end
    end
    callbacks[label] = callback
    if type(ExecuteWithDelay) == "function" then
        ExecuteWithDelay(delay_ms, callback)
    elseif type(ExecuteInGameThreadWithDelay) == "function" then
        ExecuteInGameThreadWithDelay(delay_ms, callback)
    end
end

local function teleport_to_settlement()
    local apply = function()
        local pawn, player_error = get_player()
        if player_error ~= nil then
            log("QA_TELEPORT_FAILED reason=" .. tostring(player_error))
            return
        end

        local hit_result = {}
        local ok, result = pcall(function()
            return pawn:K2_SetActorLocationAndRotation(
                SETTLEMENT_LOCATION,
                SETTLEMENT_ROTATION,
                false,
                hit_result,
                true
            )
        end)
        if not ok then
            log("QA_TELEPORT_FAILED reason=" .. tostring(result))
            return
        end

        log(string.format(
            "QA_TELEPORT_REQUESTED success=%s destination=(%.3f,%.3f,%.3f) raidMutation=false saveWrite=false",
            tostring(result),
            SETTLEMENT_LOCATION.X,
            SETTLEMENT_LOCATION.Y,
            SETTLEMENT_LOCATION.Z
        ))
        schedule_probe(1000, "after-teleport-1s")
        schedule_probe(3000, "after-teleport-3s")
        schedule_probe(8000, "after-teleport-8s")
    end

    if type(ExecuteInGameThread) == "function" then
        ExecuteInGameThread(apply)
    else
        apply()
    end
end

if type(RegisterKeyBind) == "function"
    and Key ~= nil
    and Key.F9 ~= nil
    and Key.F10 ~= nil
    and ModifierKey ~= nil
    and ModifierKey.CONTROL ~= nil then
    callbacks.teleport = teleport_to_settlement
    callbacks.probe = function()
        if type(ExecuteInGameThread) == "function" then
            ExecuteInGameThread(function()
                probe("manual-Ctrl+F9")
            end)
        else
            probe("manual-Ctrl+F9")
        end
    end
    RegisterKeyBind(Key.F10, { ModifierKey.CONTROL }, callbacks.teleport)
    RegisterKeyBind(Key.F9, { ModifierKey.CONTROL }, callbacks.probe)
    log("QA_READY teleport=Ctrl+F10 probe=Ctrl+F9 raidMutation=false saveWrite=false")
else
    log("QA_KEYBIND_UNAVAILABLE")
end

_G.PAL_FACTION_TERRITORY_QA_HARNESS0 = {
    settlementLocation = SETTLEMENT_LOCATION,
    callbacks = callbacks,
}
