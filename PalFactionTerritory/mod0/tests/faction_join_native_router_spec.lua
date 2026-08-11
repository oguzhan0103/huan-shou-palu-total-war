package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local FactionJoin = require("pwft.faction_join")
local Presenter = require("pwft.faction_join_native_presenter")
local Router = require("pwft.faction_join_native_router")

local joined = false
local join_calls = 0
local faction_api = {}
function faction_api:faction_status(faction_id)
    if faction_id ~= "pwft.faction.rayne_syndicate" then
        return nil
    end
    return { factionId = faction_id, kind = "Human" }
end
function faction_api:join_preview(faction_id)
    if joined then
        return {
            ok = false,
            reason = "already-joined",
            factionId = faction_id,
        }
    end
    return {
        ok = true,
        reason = "join-available",
        factionId = faction_id,
        reputation = 20,
        requiredReputation = 0,
        projectedRankId = "Member",
        multipleMembershipsAllowed = true,
        diplomacyChanges = {
            {
                factionId = "pwft.faction.free_pal_alliance",
                before = "Friendly",
                after = "Hostile",
            },
        },
    }
end
function faction_api:join_human(faction_id, action_id)
    assert(faction_id == "pwft.faction.rayne_syndicate")
    assert(string.find(action_id, "join-interaction:", 1, true))
    join_calls = join_calls + 1
    joined = true
    return {
        ok = true,
        reason = "joined",
        factionId = faction_id,
        rankId = "Member",
        diplomacyChanges = {
            {
                factionId = "pwft.faction.free_pal_alliance",
                before = "Friendly",
                after = "Hostile",
            },
        },
    }
end

local policy = {
    enabled = true,
    apiVersion = "1.0.0",
    requiresRegisteredSource = true,
    requiresExplicitConfirmation = true,
}
local join = FactionJoin.create(faction_api, policy)
local source_id = "pwft.join.source.rayne_syndicate"
assert(join:register_source(
    source_id,
    "pwft.faction.rayne_syndicate",
    { enabled = true }
).ok)

local backend = {
    mode = "hidden",
    views = {},
    hides = {},
}
function backend:show_text(message, mode, payload)
    self.mode = mode
    self.views[#self.views + 1] = {
        message = message,
        mode = mode,
        payload = payload,
    }
    return true, nil
end
function backend:hide(payload)
    self.mode = "hidden"
    self.hides[#self.hides + 1] = payload
    return true
end
function backend:status()
    return { mode = self.mode }
end

local actor = {
    valid = true,
    name = "BP_HumanFactionRepresentative_C_1",
    location = { X = 0, Y = 0, Z = 0 },
}
function actor:IsValid() return self.valid end
function actor:GetFullName() return self.name end
function actor:K2_GetActorLocation() return self.location end

local other_actor = {
    valid = true,
    name = "BP_UnregisteredNPC_C_1",
    location = { X = 0, Y = 0, Z = 0 },
}
function other_actor:IsValid() return self.valid end
function other_actor:GetFullName() return self.name end
function other_actor:K2_GetActorLocation() return self.location end

local player = {
    valid = true,
    name = "BP_Player_C_1",
    location = { X = 900, Y = 0, Z = 0 },
}
function player:IsValid() return self.valid end
function player:GetFullName() return self.name end
function player:K2_GetActorLocation() return self.location end

local component = { valid = true, owner = actor }
function component:IsValid() return self.valid end
function component:GetOwner() return self.owner end

local presenter = Presenter.create(backend)
assert(join:register_presenter(presenter).ok)

Key = { F1 = "F1", F2 = "F2" }
local key_callbacks = {}
function RegisterKeyBind(key, callback)
    key_callbacks[key] = callback
end
local hook_callback = nil
function RegisterHook(path, callback)
    assert(
        path
            == "/Script/Pal.PalNPCInteractionComponent:OnTriggerInteract"
    )
    hook_callback = callback
    return 31, 32
end
function ExecuteInGameThread(callback) callback() end

local router = Router.create(
    join,
    presenter,
    backend,
    {
        nativeJoinRepresentativeEnabled = true,
        representativeInteractionDistance = 500,
    }
)
local started, start_error = router:start()
assert(started and start_error == nil)
assert(hook_callback ~= nil)
assert(router:status().nativeHookReady == true)
assert(router:status().keyBindingCount == 2)

assert(
    router:register("pwft.join.source.unknown", actor).reason
        == "unknown-join-source"
)
local registered = router:register(source_id, actor)
assert(registered.ok)
assert(registered.factionId == "pwft.faction.rayne_syndicate")
assert(router:register(source_id, actor).reason
    == "join-representative-already-registered")
assert(router:status().bindingCount == 1)

local function wrapped(value)
    return { get = function() return value end }
end

-- An unrelated NPC never opens or mutates the join flow.
component.owner = other_actor
hook_callback(wrapped(component), wrapped(player))
assert(#backend.views == 0)
assert(router:status().pendingOffer == false)
assert(join_calls == 0)

-- The exact registered representative is still distance-gated.
component.owner = actor
hook_callback(wrapped(component), wrapped(player))
assert(router:status().proximityRejectedCount == 1)
assert(router:status().pendingOffer == false)
assert(backend.views[#backend.views].mode == "human-faction-join-notice")
assert(join_calls == 0)

-- Near interaction shows the system-owned preview. F2 declines without join.
player.location = { X = 100, Y = 0, Z = 0 }
hook_callback(wrapped(component), wrapped(player))
assert(router:status().pendingOffer == true)
local first_offer = backend.views[#backend.views]
assert(first_offer.mode == "human-faction-join-offer")
assert(string.find(first_offer.message, "势力加入确认", 1, true))
assert(string.find(first_offer.message, "F1", 1, true))
assert(string.find(first_offer.message, "F2", 1, true))
assert(join_calls == 0)
key_callbacks.F2()
assert(router:status().pendingOffer == false)
assert(router:status().declinedCount == 1)
assert(joined == false)
assert(join_calls == 0)
assert(backend.mode == "human-faction-join-resolution")

-- A new offer requires F1 before the deterministic core joins the faction.
hook_callback(wrapped(component), wrapped(player))
assert(router:status().pendingOffer == true)
assert(join_calls == 0)
key_callbacks.F1()
assert(join_calls == 1)
assert(joined == true)
assert(router:status().pendingOffer == false)
assert(router:status().confirmedCount == 1)
assert(router:status().joinedCount == 1)
assert(backend.mode == "human-faction-join-resolution")
assert(string.find(
    backend.views[#backend.views].message,
    "已加入：pwft.faction.rayne_syndicate",
    1,
    true
))

-- Re-interaction after joining is a notice; bare F1 cannot join twice.
hook_callback(wrapped(component), wrapped(player))
assert(router:status().pendingOffer == false)
assert(backend.mode == "human-faction-join-notice")
key_callbacks.F1()
assert(join_calls == 1)

assert(router:unregister(source_id, other_actor).reason
    == "join-representative-actor-mismatch")
assert(router:unregister(source_id, actor).ok)
assert(router:status().bindingCount == 0)

assert(router:status().exactRegisteredActorOnly == true)
assert(router:status().proximityGate == true)
assert(router:status().explicitConfirmation == true)
assert(router:status().directStateMutation == false)
assert(router:status().storyContentIncluded == false)
assert(presenter:status().deterministicRuleEngineOwnsOutcome == true)

print("PASS native human faction join router binds exact representative, gates distance, previews diplomacy, and requires F1/F2 confirmation")
