package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local Router = require("pwft.pal_representative_native_router")

local actor = { valid = true, name = "BP_TestPalRepresentative_C_1" }
function actor:IsValid() return self.valid end
function actor:GetFullName() return self.name end

local player = { valid = true, name = "BP_Player_C_1" }
function player:IsValid() return self.valid end
function player:GetFullName() return self.name end

local component = { valid = true }
function component:IsValid() return self.valid end
function component:GetOwner() return nil end
function component:GetOuter() return actor end

local interaction = {
    nextOffer = 0,
    confirms = {},
}
function interaction:representative_id_for_actor(candidate)
    return candidate == actor and "fan.representative.v1" or nil
end
function interaction:offer_for_actor(
    candidate,
    candidate_player,
    request_id
)
    assert(candidate == actor)
    assert(candidate_player == player)
    self.nextOffer = self.nextOffer + 1
    return {
        ok = true,
        reason = "pal-discourse-offer-ready",
        offerId = "offer-" .. tostring(self.nextOffer),
        representativeId = "fan.representative.v1",
        representativeNameKey = "fan.representative.name",
        factionId = "pwft.faction.desert_pal_tribe",
        tokenInstanceId = "token-" .. tostring(self.nextOffer),
        selectedToken = { cityStateId = "pwft.faction.rayne_syndicate" },
        readyTokenCount = 1,
    }
end
function interaction:confirm(offer_id, confirmation_id, accepted)
    self.confirms[#self.confirms + 1] = {
        offerId = offer_id,
        confirmationId = confirmation_id,
        accepted = accepted,
    }
    if not accepted then
        return {
            ok = true,
            reason = "pal-representative-interaction-declined",
            tokenConsumed = false,
        }
    end
    return {
        ok = true,
        reason = "pal-representative-dialogue-opened",
        presentationId = "presentation-" .. offer_id,
        tokenConsumed = false,
    }
end

local presenter = {
    records = {},
    choices = {},
    aborts = {},
    agentConfirms = {},
}
function presenter:presentation_status(presentation_id)
    return self.records[presentation_id]
end
function presenter:refresh(presentation_id)
    return {
        ok = self.records[presentation_id] ~= nil,
        reason = "pal-dialogue-presentation-updated",
    }
end
function presenter:choose_authored(
    presentation_id,
    choice_id,
    action_id
)
    self.choices[#self.choices + 1] = {
        presentationId = presentation_id,
        choiceId = choice_id,
        actionId = action_id,
    }
    self.records[presentation_id].state = "resolved"
    return {
        ok = true,
        reason = "pal-dialogue-authored-choice-routed",
    }
end
function presenter:confirm_agent_proposal(
    presentation_id,
    request_id,
    action_id
)
    self.agentConfirms[#self.agentConfirms + 1] = {
        presentationId = presentation_id,
        requestId = request_id,
        actionId = action_id,
    }
    return { ok = true, reason = "agent-proposal-committed-by-player" }
end
function presenter:player_abort(presentation_id, action_id)
    self.aborts[#self.aborts + 1] = {
        presentationId = presentation_id,
        actionId = action_id,
    }
    self.records[presentation_id].state = "resolved"
    return { ok = true, reason = "pal-discourse-player-abort-consumed" }
end

local backend = {
    mode = "hidden",
    offers = {},
    notices = {},
    hides = {},
}
function backend:show_offer(offer)
    self.mode = "offer"
    self.offers[#self.offers + 1] = offer
    return true
end
function backend:show_notice(message)
    self.mode = "notice"
    self.notices[#self.notices + 1] = message
    return true
end
function backend:hide(payload)
    self.mode = "hidden"
    self.hides[#self.hides + 1] = payload
    return true
end
function backend:status()
    return { mode = self.mode }
end

Key = {
    F1 = "F1",
    F2 = "F2",
    F3 = "F3",
    F4 = "F4",
    NUM_ONE = "NUM_ONE",
    NUM_TWO = "NUM_TWO",
    NUM_THREE = "NUM_THREE",
    NUM_FOUR = "NUM_FOUR",
    NUM_FIVE = "NUM_FIVE",
    NUM_SIX = "NUM_SIX",
    NUM_SEVEN = "NUM_SEVEN",
    NUM_EIGHT = "NUM_EIGHT",
    NUM_NINE = "NUM_NINE",
}
local key_callbacks = {}
function RegisterKeyBind(key, callback)
    key_callbacks[key] = callback
end
local hook_callback = nil
function RegisterHook(path, callback)
    assert(path == "/Script/Pal.PalNPCInteractionComponent:OnTriggerInteract")
    hook_callback = callback
    return 11, 12
end
function ExecuteInGameThread(callback) callback() end

local router = Router.create(
    interaction,
    presenter,
    backend,
    {
        nativeDialoguePresenterEnabled = true,
        representativeInteractionRouterEnabled = true,
    }
)
local started, start_error = router:start()
assert(started and start_error == nil)
assert(hook_callback ~= nil)
assert(router:status().nativeHookReady == true)
assert(router:status().keyBindingCount == 13)

local function wrapped(value)
    return { get = function() return value end }
end

-- Native F interaction presents a non-mutating offer; F1 is the only route
-- that confirms and opens the already-tested deterministic presenter.
hook_callback(wrapped(component), wrapped(player))
assert(router:status().pendingOffer == true)
assert(#backend.offers == 1)
assert(#interaction.confirms == 0)
key_callbacks.F1()
assert(#interaction.confirms == 1)
assert(interaction.confirms[1].accepted == true)
local first_presentation = "presentation-offer-1"
presenter.records[first_presentation] = {
    state = "active",
    lastView = {
        choices = {
            { choiceId = "continue" },
            { choiceId = "leave" },
        },
    },
}
assert(router.activePresentationId == first_presentation)
key_callbacks.NUM_TWO()
assert(#presenter.choices == 1)
assert(presenter.choices[1].choiceId == "leave")
assert(router.activePresentationId == nil)

-- Decline is explicit and cannot consume a token.
hook_callback(wrapped(component), wrapped(player))
key_callbacks.F2()
assert(#interaction.confirms == 2)
assert(interaction.confirms[2].accepted == false)
assert(router:status().declinedCount == 1)
assert(backend.mode == "hidden")

-- Active abort remains separate from pre-confirmation decline.
hook_callback(wrapped(component), wrapped(player))
key_callbacks.F1()
local third_presentation = "presentation-offer-3"
presenter.records[third_presentation] = {
    state = "active",
    lastView = { choices = {} },
}
key_callbacks.F4()
assert(#presenter.aborts == 1)
assert(router:status().abortCount == 1)

-- Agent text can only propose an authored deterministic choice. F3 is the
-- explicit player confirmation gate for that proposal.
hook_callback(wrapped(component), wrapped(player))
key_callbacks.F1()
local fourth_presentation = "presentation-offer-4"
presenter.records[fourth_presentation] = {
    state = "active",
    lastView = {
        choices = {},
        agent = {
            requestId = "agent-request-1",
            requiresPlayerConfirmation = true,
        },
    },
}
key_callbacks.F3()
assert(#presenter.agentConfirms == 1)
assert(presenter.agentConfirms[1].requestId == "agent-request-1")
assert(router:status().agentConfirmationCount == 1)
assert(router:status().directStateMutation == false)
assert(router:status().storyContentIncluded == false)

print("PASS native representative router binds F interaction, explicit confirmation, numeric choices, Agent confirmation, and abort without direct mutation")
