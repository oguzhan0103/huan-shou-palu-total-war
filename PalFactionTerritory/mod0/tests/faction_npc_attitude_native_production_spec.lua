package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local Bus = require("pwft.faction_npc_attitude_bus")
local Production =
    require("pwft.faction_npc_attitude_native_production")
local Definitions =
    require("pwft_b7_unique_pals.npc_attitude_bindings")

local faction_id = "pwft.faction.rayne_syndicate"
local faction = { id = faction_id, kind = "Human", relation = "Friendly" }
local faction_api = {}
function faction_api:faction_status(id)
    return id == faction_id and faction or nil
end

local provider_id = "pwft.native.NPC-attitude.production"
local authority = "pwft.native.NPC-attitude.authority"
local bus = Bus.create(faction_api, nil, {
    providerWhitelist = { [provider_id] = authority },
})

local controller = {
    aiStates = {},
    targets = {},
}
function controller:IsValid() return true end
function controller:SetActiveAI(active)
    self.aiStates[#self.aiStates + 1] = active
end
function controller:AddTargetPlayer_ForEnemy(player)
    self.targets[#self.targets + 1] = player
end
local actor = {
    battleStates = {},
    actorKey = "PalNPC:rayne-dark-trader:001",
    actorClassKey = "/Game/Pal/BP_NPC_DarkTrader_C",
}
function actor:IsValid() return true end
function actor:GetController() return controller end
function actor:ChangeBattleModeFlag_ToAll(active)
    self.battleStates[#self.battleStates + 1] = active
end
local player = {}
function player:IsValid() return true end

local production = Production.create(bus, {
    enabled = true,
    providerId = provider_id,
    authoritySource = authority,
}, {
    adapters = {
        actorKey = function(candidate)
            return candidate.actorKey
        end,
        actorClassKey = function(candidate)
            return candidate.actorClassKey
        end,
        localPlayer = function() return player end,
    },
})
assert(production:activate(Definitions).ok)
assert(bus:status().readyProviderCount == 1)
local bound = production:bind_actor(
    "pwft.native.NPC-attitude.rayne-merchant",
    actor
)
assert(bound.ok and bound.disposition == "friendly")
assert(bus:status().bindingCount == 1)
assert(controller.aiStates[1] == false)
assert(actor.battleStates[1] == false)

faction.relation = "Hostile"
local hostile = bus:refresh_faction(faction_id, {
    trigger = "relation-changed",
    force = true,
})
assert(hostile.ok and hostile.responses[1].disposition == "hostile")
assert(controller.aiStates[#controller.aiStates] == true)
assert(actor.battleStates[#actor.battleStates] == true)
assert(controller.targets[#controller.targets] == player)

local wrong = {
    actorKey = "PalNPC:wrong:001",
    actorClassKey = "/Game/Pal/BP_Forged_C",
}
function wrong:IsValid() return true end
assert(production:bind_actor(
    "pwft.native.NPC-attitude.rayne-merchant",
    wrong
).ok == false)
local unbound = production:unbind_actor(
    "pwft.native.NPC-attitude.rayne-merchant"
)
assert(unbound.ok and bus:status().bindingCount == 0)
local status = production:status()
assert(status.hostileApplyCount == 1)
assert(status.peacefulApplyCount == 1)
assert(status.exactActorBindingsOnly == true)
assert(status.broadActorScan == false)
assert(status.PalworldSaveMutation == false)

print("PASS native NPC attitude production exact-binds the proven Rayne actor, applies peaceful and hostile native routes, and unbinds safely")
