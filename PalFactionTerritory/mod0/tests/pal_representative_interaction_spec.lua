package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local PalRepresentativeInteraction =
    require("pwft.pal_representative_interaction")

local function actor(name, x, y, z)
    local value = {
        name = name,
        location = { X = x, Y = y, Z = z },
        valid = true,
    }
    function value:IsValid()
        return self.valid
    end
    function value:GetFullName()
        return self.name
    end
    function value:K2_GetActorLocation()
        return self.location
    end
    return value
end

local function make_discourse()
    local discourse = {
        offerCalls = {},
        confirmCalls = {},
    }
    function discourse:representative_status(representative_id)
        if representative_id ~= "fan.guide.v1" then
            return nil
        end
        return {
            representativeId = representative_id,
            factionId = "pwft.faction.desert_pal_tribe",
            nameKey = "fan.guide.name",
            contentPackId = "fan.pack.v1",
            contentVersion = "1.0.0",
        }
    end
    function discourse:offer(
        representative_id,
        token_instance_id,
        request_id
    )
        self.offerCalls[#self.offerCalls + 1] = {
            representativeId = representative_id,
            tokenInstanceId = token_instance_id,
            requestId = request_id,
        }
        return {
            ok = true,
            reason = "pal-discourse-offer-ready",
            offerId = "offer:" .. request_id,
            representativeId = representative_id,
            tokenInstanceId = token_instance_id,
            state = "pending-confirmation",
            explicitConfirmationRequired = true,
            irreversible = true,
        }
    end
    function discourse:confirm(
        offer_id,
        confirmation_id,
        accepted
    )
        self.confirmCalls[#self.confirmCalls + 1] = {
            offerId = offer_id,
            confirmationId = confirmation_id,
            accepted = accepted,
        }
        if not accepted then
            return {
                ok = true,
                reason = "pal-discourse-declined-token-preserved",
                tokenConsumed = false,
            }
        end
        return {
            ok = true,
            reason = "pal-discourse-session-started",
            sessionId = "session:" .. confirmation_id,
            tokenConsumed = false,
        }
    end
    return discourse
end

local function make_presenter(backend_ready, open_ok)
    local presenter = {
        backendReady = backend_ready,
        openOk = open_ok ~= false,
        openCalls = {},
        failureCalls = {},
    }
    function presenter:status()
        return { backendAvailable = self.backendReady }
    end
    function presenter:open(session_id)
        self.openCalls[#self.openCalls + 1] = session_id
        if not self.openOk then
            return {
                ok = false,
                reason = "native-widget-show-failed",
                presentationId = "presentation-failed",
            }
        end
        return {
            ok = true,
            reason = "pal-dialogue-presentation-opened",
            presentationId = "presentation-1",
            view = {
                sessionId = session_id,
                textKey = "fan.guide.opening",
            },
        }
    end
    function presenter:technical_failure(
        presentation_id,
        failure_id,
        reason
    )
        self.failureCalls[#self.failureCalls + 1] = {
            presentationId = presentation_id,
            failureId = failure_id,
            reason = reason,
        }
        return {
            ok = true,
            reason = "pal-discourse-technical-failure-refunded",
        }
    end
    return presenter
end

local configuration = {
    representativeInteractionRouterEnabled = true,
    representativeInteractionDistance = 500,
}

local representative = actor("BP_PalRepresentative_C_1", 0, 0, 0)
local near_player = actor("BP_Player_C_1", 300, 0, 0)
local far_player = actor("BP_Player_C_2", 900, 0, 0)

local discourse = make_discourse()
local presenter = make_presenter(true, true)
local interaction = PalRepresentativeInteraction.create(
    discourse,
    presenter,
    configuration
)

local unknown = interaction:register(
    "fan.unknown.v1",
    representative
)
assert(not unknown.ok and unknown.reason == "unknown-pal-representative")

local registered = interaction:register(
    "fan.guide.v1",
    representative,
    {
        maximumDistance = 500,
        sourceKind = "content-pack-representative",
    }
)
assert(registered.ok)
assert(registered.reason == "pal-representative-actor-registered")
assert(registered.actor == "BP_PalRepresentative_C_1")

local duplicate = interaction:register(
    "fan.guide.v1",
    representative
)
assert(duplicate.ok)
assert(
    duplicate.reason
        == "pal-representative-actor-already-registered"
)

local far = interaction:offer(
    "fan.guide.v1",
    far_player,
    "token-1",
    "request-far"
)
assert(not far.ok)
assert(far.reason == "player-not-near-pal-representative")
assert(far.distance == 900)
assert(far.maximumDistance == 500)
assert(#discourse.offerCalls == 0)

local offered = interaction:offer(
    "fan.guide.v1",
    near_player,
    "token-1",
    "request-near"
)
assert(offered.ok and offered.reason == "pal-discourse-offer-ready")
assert(offered.offerId == "offer:request-near")
assert(offered.distance == 300)
assert(offered.maximumDistance == 500)
assert(offered.explicitConfirmationRequired == true)
assert(offered.stateMutationApplied == false)
assert(#discourse.offerCalls == 1)

local opened = interaction:confirm(
    offered.offerId,
    "confirmation-1",
    true
)
assert(opened.ok)
assert(opened.reason == "pal-representative-dialogue-opened")
assert(opened.sessionId == "session:confirmation-1")
assert(opened.presentationId == "presentation-1")
assert(opened.stateMutationApplied == false)
assert(#discourse.confirmCalls == 1)
assert(#presenter.openCalls == 1)

local repeated = interaction:confirm(
    offered.offerId,
    "confirmation-1",
    true
)
assert(repeated.ok)
assert(
    repeated.reason
        == "pal-representative-interaction-already-resolved"
)
assert(#discourse.confirmCalls == 1)
assert(#presenter.openCalls == 1)

-- Declining never needs a native presenter and preserves the token.
local decline_offer = interaction:offer(
    "fan.guide.v1",
    near_player,
    "token-2",
    "request-decline"
)
local declined = interaction:confirm(
    decline_offer.offerId,
    "confirmation-decline",
    false
)
assert(declined.ok)
assert(declined.reason == "pal-representative-interaction-declined")
assert(declined.tokenConsumed == false)

-- The irreversible session is not started when no UI backend can actually
-- present it. This preserves the finite token before Core confirmation.
local no_backend_discourse = make_discourse()
local no_backend_presenter = make_presenter(false, true)
local no_backend = PalRepresentativeInteraction.create(
    no_backend_discourse,
    no_backend_presenter,
    configuration
)
assert(no_backend:register("fan.guide.v1", representative).ok)
local no_backend_offer = no_backend:offer(
    "fan.guide.v1",
    near_player,
    "token-3",
    "request-no-backend"
)
local blocked = no_backend:confirm(
    no_backend_offer.offerId,
    "confirmation-no-backend",
    true
)
assert(not blocked.ok)
assert(
    blocked.reason
        == "dialogue-presenter-backend-unavailable-token-preserved"
)
assert(blocked.tokenConsumed == false)
assert(#no_backend_discourse.confirmCalls == 0)
assert(#no_backend_presenter.openCalls == 0)

-- A backend that reports ready but fails during Show causes Core to settle a
-- technical failure and refund the already-started finite opportunity.
local failing_discourse = make_discourse()
local failing_presenter = make_presenter(true, false)
local failing = PalRepresentativeInteraction.create(
    failing_discourse,
    failing_presenter,
    configuration
)
assert(failing:register("fan.guide.v1", representative).ok)
local failing_offer = failing:offer(
    "fan.guide.v1",
    near_player,
    "token-4",
    "request-failing-ui"
)
local failed = failing:confirm(
    failing_offer.offerId,
    "confirmation-failing-ui",
    true
)
assert(not failed.ok)
assert(failed.reason == "pal-representative-presentation-failed")
assert(failed.refund.ok == true)
assert(
    failed.refund.reason
        == "pal-discourse-technical-failure-refunded"
)
assert(#failing_discourse.confirmCalls == 1)
assert(#failing_presenter.openCalls == 1)
assert(#failing_presenter.failureCalls == 1)
assert(
    failing_presenter.failureCalls[1].reason
        == "native-widget-show-failed"
)

local binding = interaction:binding_status("fan.guide.v1")
assert(binding.actorValid == true)
assert(binding.factionId == "pwft.faction.desert_pal_tribe")
assert(binding.contentPackId == "fan.pack.v1")
assert(binding.actor == nil)

local status = interaction:status()
assert(status.enabled == true)
assert(status.registeredBindingCount == 1)
assert(status.validBindingCount == 1)
assert(status.proximityRejectedCount == 1)
assert(status.offerCount == 2)
assert(status.confirmedCount == 1)
assert(status.declinedCount == 1)
assert(status.exactActorBinding == true)
assert(status.proximityGate == true)
assert(status.explicitIrreversibleConfirmation == true)
assert(status.presenterReadinessBeforeTokenConsume == true)
assert(status.nativeDelegateBinding == false)
assert(status.directInteractionStateMutation == false)

representative.valid = false
local stale = interaction:offer(
    "fan.guide.v1",
    near_player,
    "token-5",
    "request-stale"
)
assert(not stale.ok)
assert(stale.reason == "pal-representative-actor-stale")
assert(interaction:binding_status("fan.guide.v1") == nil)

print("PASS representative interaction requires exact registered actor proximity, explicit confirmation, ready presenter, and technical refund")
