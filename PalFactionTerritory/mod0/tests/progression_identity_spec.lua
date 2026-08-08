package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local ProgressionIdentity =
    require("pwft.progression_identity")

local world = "e0d5ecdc-46b3-7982-9f8f-31a729acfd92"
local player = {
    A = -1,
    B = 0x12345678,
    C = -2147483648,
    D = 1,
}
assert(
    ProgressionIdentity.normalize_world_directory(world)
        == "E0D5ECDC46B379829F8F31A729ACFD92"
)
local fstring_like_world = setmetatable({}, {
    __tostring = function()
        return "FString(E0D5ECDC-46B3-7982-9F8F-31A729ACFD92)"
    end,
})
assert(
    ProgressionIdentity.normalize_world_directory(fstring_like_world)
        == "E0D5ECDC46B379829F8F31A729ACFD92"
)
assert(
    ProgressionIdentity.normalize_world_directory(setmetatable({}, {
        __tostring = function()
            return "FString: 0000022DE3ECDF78"
        end,
    })) == nil
)
local fstring_to_string_world = setmetatable({
    ToString = function()
        return "E0D5ECDC46B379829F8F31A729ACFD92"
    end,
}, {
    __tostring = function()
        return "FString: 0000022DE3ECDF78"
    end,
})
assert(
    ProgressionIdentity.normalize_guid(player)
        == "FFFFFFFF123456788000000000000001"
)
assert(ProgressionIdentity.normalize_guid({
    A = 0,
    B = 0,
    C = 0,
    D = 0,
}) == nil)
assert(
    ProgressionIdentity.normalize_world_directory("../SaveGames")
        == nil
)

local expected_player =
    "D9AB288B1234567887654321ABCDEF01"
local controller = {
    GetPlayerUId = function()
        return {
            A = -643094389,
            B = 305419896,
            C = -2023406815,
            D = -1412567295,
        }
    end,
    IsValid = function()
        return true
    end,
}
local game_state = {
    GetWorldSaveDirectoryName = function()
        return fstring_to_string_world
    end,
    IsValid = function()
        return true
    end,
}
local utility = {
    GetPalGameStateInGame = function(_, received_controller)
        assert(received_controller == controller)
        return game_state
    end,
    IsValid = function()
        return true
    end,
}
local identity, identity_error =
    ProgressionIdentity.resolve_native({
        getPlayerController = function()
            return controller
        end,
        getPalUtility = function()
            return utility
        end,
    })
assert(identity_error == nil)
assert(identity.readOnly == true)
assert(
    identity.worldDirectory
        == "E0D5ECDC46B379829F8F31A729ACFD92"
)
assert(identity.playerUid == expected_player)
assert(
    identity.profileKey
        == "world-E0D5ECDC46B379829F8F31A729ACFD92"
            .. ".player-"
            .. expected_player
)
assert(
    identity.sources.player
        == "PalPlayerController.GetPlayerUId"
)

local not_ready, not_ready_error =
    ProgressionIdentity.resolve_native({
        getPlayerController = function()
            return nil
        end,
        findFirstOf = function()
            return nil
        end,
    })
assert(not_ready == nil)
assert(not_ready_error == "local-player-controller-not-ready")

print("progression identity tests passed")
