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
    GetArrayNum = function()
        return #wrapped_products
    end,
    ForEach = function(_, callback)
        error("native ForEach must not be used when fixed-length indexing is available")
    end,
}
setmetatable(product_array, {
    __index = function(_, key)
        if type(key) == "number" then
            return wrapped_products[key]
        end
    end,
})

local foreach_only_array = {
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

local foreach_only_visited = {}
assert(test.for_each_array(foreach_only_array, function(_, element)
    table.insert(foreach_only_visited, test.unwrap_remote_value(element))
end))
assert(#foreach_only_visited == 2)

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
local hostile_actor = {
    IsValid = function() return true end,
    GetFullName = function()
        return "BP_NPC_DarkTrader_BOSS_C /Game/Test.Hostile"
    end,
    BP_PalShopVenderDataComponent = nearby_vendor,
    K2_GetActorLocation = function()
        return { X = 120.0, Y = 100.0, Z = 100.0 }
    end,
}
FindAllOf = function(class_name)
    if class_name == "BP_NPC_DarkTrader_C" then
        return { distant_actor, nearby_actor }
    end
    assert(class_name == "BP_NPC_DarkTrader_BOSS_C")
    return { hostile_actor }
end
local found_actor, found_distance, find_error =
    test.find_nearby_native_merchant({
        expectedActorClassToken = "BP_NPC_DarkTrader_C",
        expectedActorClassTokens = {
            "BP_NPC_DarkTrader_C",
            "BP_NPC_DarkTrader_BOSS_C",
        },
        nativeActorFallbackRadius = 2500.0,
    }, {
        X = 100.0,
        Y = 100.0,
        Z = 100.0,
    })
assert(found_actor == nearby_actor)
assert(found_distance == 10.0)
assert(find_error == nil)
local fallback_actor, fallback_distance, fallback_error =
    test.find_nearby_native_merchant({
        expectedActorClassToken = "BP_NPC_DarkTrader_C",
        expectedActorClassTokens = {
            "BP_NPC_DarkTrader_C",
            "BP_NPC_DarkTrader_BOSS_C",
        },
        nativeActorFallbackRadius = 2500.0,
    }, {
        X = 100.0,
        Y = 100.0,
        Z = 100.0,
    }, {
        [nearby_actor:GetFullName()] = true,
        [distant_actor:GetFullName()] = true,
    })
assert(fallback_actor == hostile_actor)
assert(fallback_distance == 20.0)
assert(fallback_error == nil)
local baseline_actor_names =
    test.collect_native_merchant_actor_names({
        expectedActorClassToken = "BP_NPC_DarkTrader_C",
        expectedActorClassTokens = {
            "BP_NPC_DarkTrader_C",
            "BP_NPC_DarkTrader_BOSS_C",
        },
    })
assert(baseline_actor_names[nearby_actor:GetFullName()] == true)
assert(baseline_actor_names[hostile_actor:GetFullName()] == true)
local matches_hostile, hostile_name, hostile_token =
    test.actor_matches_config(hostile_actor, {
        expectedActorClassToken = "BP_NPC_DarkTrader_C",
        expectedActorClassTokens = {
            "BP_NPC_DarkTrader_C",
            "BP_NPC_DarkTrader_BOSS_C",
        },
    })
assert(matches_hostile)
assert(string.find(hostile_name, "BP_NPC_DarkTrader_BOSS_C", 1, true))
assert(hostile_token == "BP_NPC_DarkTrader_BOSS_C")

local relation_interaction = {
    IsValid = function() return true end,
    bDisableTalk = false,
    bDisableTalkWhenCaptured = false,
    OnRep_DisableTalk = function(self)
        self.replicationCount = (self.replicationCount or 0) + 1
    end,
}
local relation_actor = {
    IsValid = function() return true end,
    GetFullName = function()
        return "BP_NPC_DarkTrader_C /Game/Test.Relation"
    end,
    BP_NPCInteractionComponent = relation_interaction,
    SetActive_Interact_ToAll = function(self, active)
        self.interactActive = active
        self.activationCount = (self.activationCount or 0) + 1
    end,
    ChangeBattleModeFlag_ToAll = function(self, active)
        self.battleMode = active
        self.battleModeChangeCount = (self.battleModeChangeCount or 0) + 1
    end,
}
local relation_controller = {
    IsValid = function() return true end,
    GetFullName = function()
        return "BP_NPCAIController_C /Game/Test.RelationController"
    end,
    SetActiveAI = function(self, active)
        self.aiActive = active
        self.activationCount = (self.activationCount or 0) + 1
    end,
}
relation_actor.GetController = function()
    return relation_controller
end
local hostile_ok, hostile_reason =
    test.apply_relation_interaction_policy(relation_actor, "Hostile")
assert(hostile_ok)
assert(hostile_reason == "hostile-interaction-disabled")
assert(relation_interaction.bDisableTalk == true)
assert(relation_interaction.bDisableTalkWhenCaptured == true)
assert(relation_actor.interactActive == false)
assert(relation_controller.aiActive == true)
assert(relation_actor.battleMode == true)

local friendly_ok, friendly_reason =
    test.apply_relation_interaction_policy(relation_actor, "Friendly")
assert(friendly_ok)
assert(friendly_reason == "peaceful-interaction-enabled")
assert(relation_interaction.bDisableTalk == false)
assert(relation_interaction.bDisableTalkWhenCaptured == false)
assert(relation_actor.interactActive == true)
assert(relation_controller.aiActive == false)
assert(relation_actor.battleMode == false)
assert(relation_interaction.replicationCount == 2)
assert(relation_actor.activationCount == 2)
assert(relation_controller.activationCount == 2)
assert(relation_actor.battleModeChangeCount == 2)

print("PASS Rayne merchant traversal, native fallback, and relation interaction policy")
