package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?/init.lua",
    package.path,
}, ";")

function FName(value)
    return value
end

local RayneMerchant = require("pwft.rayne_merchant")
local test = RayneMerchant._test

local function wrapper(initial)
    local value = initial
    return {
        get = function()
            return value
        end,
        set = function(_, replacement)
            value = replacement
        end,
    }
end

local product_a = {
    IsValid = function() return true end,
}
local product_b = {
    IsValid = function() return true end,
}
local wrapped_products = {
    wrapper(product_a),
    wrapper(product_b),
}
local product_array = {
    ForEach = function(_, callback)
        for index, element in ipairs(wrapped_products) do
            if callback(index, element) == true then
                break
            end
        end
    end,
}

local visited = {}
assert(test.for_each_array(product_array, function(_, element)
    table.insert(visited, test.unwrap_remote_value(element))
end))
assert(#visited == 2)
assert(visited[1] == product_a)
assert(visited[2] == product_b)

local passive_wrappers = {
    wrapper("OldPassiveA"),
    wrapper("OldPassiveB"),
}
local passive_array = {
    ForEach = function(_, callback)
        for index, element in ipairs(passive_wrappers) do
            if callback(index, element) == true then
                break
            end
        end
    end,
}
assert(test.replace_first_passives(
    passive_array,
    { "WorldTree_ATK", "Mining_up10" }
) == 2)
assert(passive_wrappers[1]:get() == "WorldTree_ATK")
assert(passive_wrappers[2]:get() == "Mining_up10")

local growing_values = {}
local growing_passive_array = setmetatable({
    ForEach = function() end,
    GetArrayNum = function()
        return #growing_values
    end,
}, {
    __index = function(_, key)
        if type(key) == "number" then
            return growing_values[key]
        end
    end,
    __newindex = function(target, key, value)
        if type(key) == "number" then
            growing_values[key] = value
        else
            rawset(target, key, value)
        end
    end,
})
local grown, grown_verified, grown_error, grown_slots =
    test.replace_first_passives(
        growing_passive_array,
        { "WorldTree_DEF" }
    )
assert(grown == 1)
assert(grown_verified == 1)
assert(grown_error == nil)
assert(grown_slots == 0)
assert(growing_values[1] == "WorldTree_DEF")

local nearby_vendor = {
    IsValid = function() return true end,
}
local nearby_actor = {
    IsValid = function() return true end,
    GetFullName = function()
        return "BP_NPC_DarkTrader_C /Game/Test.Nearby"
    end,
    BP_PalShopVenderDataComponent = nearby_vendor,
    K2_GetActorLocation = function()
        return { X = 110.0, Y = 100.0, Z = 100.0 }
    end,
}
local distant_actor = {
    IsValid = function() return true end,
    GetFullName = function()
        return "BP_NPC_DarkTrader_C /Game/Test.Distant"
    end,
    BP_PalShopVenderDataComponent = nearby_vendor,
    K2_GetActorLocation = function()
        return { X = 5000.0, Y = 100.0, Z = 100.0 }
    end,
}
FindAllOf = function(class_name)
    assert(class_name == "BP_NPC_DarkTrader_C")
    return { distant_actor, nearby_actor }
end
local found_actor, found_distance, find_error =
    test.find_nearby_native_merchant({
        expectedActorClassToken = "BP_NPC_DarkTrader_C",
        nativeActorFallbackRadius = 2500.0,
    }, {
        X = 100.0,
        Y = 100.0,
        Z = 100.0,
    })
assert(found_actor == nearby_actor)
assert(found_distance == 10.0)
assert(find_error == nil)

print("PASS Rayne merchant wrapper traversal, mutation, and native actor fallback")
