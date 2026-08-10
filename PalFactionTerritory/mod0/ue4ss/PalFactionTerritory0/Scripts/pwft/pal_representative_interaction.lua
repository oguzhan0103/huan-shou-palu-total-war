local PalRepresentativeInteraction = {}

local API_VERSION = "1.0.0"

local function copy(value)
    if type(value) ~= "table" then
        return value
    end
    local output = {}
    for key, item in pairs(value) do
        output[copy(key)] = copy(item)
    end
    return output
end

local function result(ok, reason, extra)
    local value = extra or {}
    value.ok = ok
    value.reason = reason
    return value
end

local function non_empty_string(value, maximum)
    return type(value) == "string"
        and value ~= ""
        and (maximum == nil or #value <= maximum)
end

local function is_valid_object(object)
    if object == nil then
        return false
    end
    local ok, valid = pcall(function()
        return object:IsValid()
    end)
    return ok and valid == true
end

local function safe_full_name(object)
    if not is_valid_object(object) then
        return "<invalid>"
    end
    local ok, value = pcall(function()
        return object:GetFullName()
    end)
    return ok and tostring(value) or "<unreadable>"
end

local function default_location_provider(actor)
    if not is_valid_object(actor) then
        return nil, "actor-invalid"
    end
    local called, location = pcall(function()
        return actor:K2_GetActorLocation()
    end)
    if not called or location == nil then
        return nil, "actor-location-unavailable"
    end
    local x = location.X or location.x
    local y = location.Y or location.y
    local z = location.Z or location.z
    if type(x) ~= "number"
        or type(y) ~= "number"
        or type(z) ~= "number" then
        return nil, "actor-location-invalid"
    end
    return { X = x, Y = y, Z = z }, nil
end

local function distance_between(first, second)
    local dx = first.X - second.X
    local dy = first.Y - second.Y
    local dz = first.Z - second.Z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

function PalRepresentativeInteraction.create(
    discourse,
    presenter,
    configuration,
    options
)
    assert(
        type(discourse) == "table",
        "Pal discourse runtime is required"
    )
    assert(
        type(discourse.representative_status) == "function",
        "Pal representative status API is required"
    )
    assert(
        type(discourse.offer) == "function",
        "Pal discourse offer API is required"
    )
    assert(
        type(discourse.confirm) == "function",
        "Pal discourse confirmation API is required"
    )
    assert(
        type(presenter) == "table"
            and type(presenter.open) == "function"
            and type(presenter.status) == "function"
            and type(presenter.technical_failure) == "function",
        "Pal dialogue presenter is required"
    )
    assert(
        type(configuration) == "table",
        "Pal representative interaction configuration is required"
    )
    assert(
        type(configuration.representativeInteractionRouterEnabled)
            == "boolean",
        "Pal representative interaction-router flag is required"
    )
    options = options or {}
    assert(
        options.locationProvider == nil
            or type(options.locationProvider) == "function",
        "representative location provider must be a function"
    )
    local maximum_distance =
        configuration.representativeInteractionDistance or 500
    assert(
        type(maximum_distance) == "number"
            and maximum_distance >= 50
            and maximum_distance <= 2000,
        "representative interaction distance is invalid"
    )
    return setmetatable({
        version = API_VERSION,
        discourse = discourse,
        presenter = presenter,
        enabled = configuration
            .representativeInteractionRouterEnabled,
        defaultMaximumDistance = maximum_distance,
        locationProvider = options.locationProvider
            or default_location_provider,
        bindings = {},
        offers = {},
        registrationCount = 0,
        proximityRejectedCount = 0,
        offerCount = 0,
        confirmedCount = 0,
        declinedCount = 0,
        technicalRefundCount = 0,
        capabilities = {
            registeredRepresentativesOnly = true,
            exactActorBinding = true,
            proximityGate = true,
            explicitIrreversibleConfirmation = true,
            presenterReadinessBeforeTokenConsume = true,
            presenterFailureTechnicalRefund = true,
            deterministicRuleEngineOwnsOutcome = true,
            directInteractionStateMutation = false,
            nativeDelegateBinding = false,
            PalworldSaveMutation = false,
            storyContentIncluded = false,
        },
    }, { __index = PalRepresentativeInteraction })
end

function PalRepresentativeInteraction:register(
    representative_id,
    actor,
    metadata
)
    if not self.enabled then
        return result(false, "pal-representative-interaction-router-disabled")
    end
    if not non_empty_string(representative_id, 256) then
        return result(false, "pal-representative-id-invalid")
    end
    local representative = self.discourse:representative_status(
        representative_id
    )
    if representative == nil then
        return result(false, "unknown-pal-representative")
    end
    if not is_valid_object(actor) then
        return result(false, "pal-representative-actor-invalid")
    end
    metadata = metadata or {}
    local maximum_distance = metadata.maximumDistance
        or self.defaultMaximumDistance
    if type(maximum_distance) ~= "number"
        or maximum_distance < 50
        or maximum_distance > 2000 then
        return result(false, "pal-representative-distance-invalid")
    end
    local existing = self.bindings[representative_id]
    if existing ~= nil then
        if existing.actor == actor then
            return result(
                true,
                "pal-representative-actor-already-registered",
                {
                    representativeId = representative_id,
                    actor = safe_full_name(actor),
                    maximumDistance = existing.maximumDistance,
                }
            )
        end
        return result(false, "pal-representative-actor-conflict")
    end
    self.bindings[representative_id] = {
        representativeId = representative_id,
        factionId = representative.factionId,
        contentPackId = representative.contentPackId,
        contentVersion = representative.contentVersion,
        actor = actor,
        actorName = safe_full_name(actor),
        maximumDistance = maximum_distance,
        sourceKind = metadata.sourceKind
            or "content-pack-representative",
    }
    self.registrationCount = self.registrationCount + 1
    return result(true, "pal-representative-actor-registered", {
        representativeId = representative_id,
        actor = safe_full_name(actor),
        maximumDistance = maximum_distance,
    })
end

function PalRepresentativeInteraction:unregister(
    representative_id,
    actor
)
    local binding = self.bindings[representative_id]
    if binding == nil then
        return result(true, "pal-representative-actor-already-unregistered")
    end
    if actor ~= nil and binding.actor ~= actor then
        return result(false, "pal-representative-actor-mismatch")
    end
    self.bindings[representative_id] = nil
    return result(true, "pal-representative-actor-unregistered")
end

function PalRepresentativeInteraction:_proximity(
    representative_id,
    player_actor
)
    local binding = self.bindings[representative_id]
    if binding == nil then
        return nil, "pal-representative-actor-not-registered"
    end
    if not is_valid_object(binding.actor) then
        self.bindings[representative_id] = nil
        return nil, "pal-representative-actor-stale"
    end
    if not is_valid_object(player_actor) then
        return nil, "pal-dialogue-player-actor-invalid"
    end
    local representative_location, representative_error =
        self.locationProvider(binding.actor)
    if representative_location == nil then
        return nil, representative_error
    end
    local player_location, player_error =
        self.locationProvider(player_actor)
    if player_location == nil then
        return nil, player_error
    end
    local distance = distance_between(
        representative_location,
        player_location
    )
    if distance > binding.maximumDistance then
        self.proximityRejectedCount =
            self.proximityRejectedCount + 1
        return nil, "player-not-near-pal-representative", {
            distance = distance,
            maximumDistance = binding.maximumDistance,
        }
    end
    return {
        binding = binding,
        distance = distance,
    }, nil
end

function PalRepresentativeInteraction:offer(
    representative_id,
    player_actor,
    token_instance_id,
    request_id
)
    if not self.enabled then
        return result(false, "pal-representative-interaction-router-disabled")
    end
    local proximity, proximity_error, proximity_detail =
        self:_proximity(representative_id, player_actor)
    if proximity == nil then
        return result(false, proximity_error, proximity_detail)
    end
    local offered = self.discourse:offer(
        representative_id,
        token_instance_id,
        request_id
    )
    if not offered.ok then
        return copy(offered)
    end
    self.offers[offered.offerId] = {
        offerId = offered.offerId,
        representativeId = representative_id,
        actor = proximity.binding.actor,
        playerActor = player_actor,
        distanceAtOffer = proximity.distance,
        state = "pending-confirmation",
    }
    self.offerCount = self.offerCount + 1
    offered.distance = proximity.distance
    offered.maximumDistance =
        proximity.binding.maximumDistance
    offered.actor = proximity.binding.actorName
    offered.stateMutationApplied = false
    return copy(offered)
end

function PalRepresentativeInteraction:confirm(
    offer_id,
    confirmation_id,
    accepted
)
    local record = self.offers[offer_id]
    if record == nil then
        return result(false, "unknown-pal-representative-interaction-offer")
    end
    if type(accepted) ~= "boolean" then
        return result(false, "pal-representative-confirmation-invalid")
    end
    if record.state ~= "pending-confirmation" then
        return result(
            true,
            "pal-representative-interaction-already-resolved",
            copy(record.resolution)
        )
    end
    if accepted and self.presenter:status().backendAvailable ~= true then
        return result(
            false,
            "dialogue-presenter-backend-unavailable-token-preserved",
            {
                offerId = offer_id,
                tokenConsumed = false,
                stateMutationApplied = false,
            }
        )
    end
    local confirmed = self.discourse:confirm(
        offer_id,
        confirmation_id,
        accepted
    )
    if not confirmed.ok then
        return copy(confirmed)
    end
    if not accepted then
        record.state = "declined"
        record.resolution = copy(confirmed)
        self.declinedCount = self.declinedCount + 1
        return result(true, "pal-representative-interaction-declined", {
            offer = copy(confirmed),
            tokenConsumed = false,
            stateMutationApplied = false,
        })
    end
    local opened = self.presenter:open(confirmed.sessionId)
    if not opened.ok then
        local failure_id = "pal-representative-presenter:"
            .. confirmation_id
        local refunded = nil
        if opened.presentationId ~= nil then
            refunded = self.presenter:technical_failure(
                opened.presentationId,
                failure_id,
                opened.reason
            )
        end
        if type(refunded) == "table" and refunded.ok then
            self.technicalRefundCount =
                self.technicalRefundCount + 1
        end
        record.state = "technical-failure"
        record.resolution = {
            sessionId = confirmed.sessionId,
            presentation = copy(opened),
            refund = copy(refunded),
        }
        return result(
            false,
            "pal-representative-presentation-failed",
            copy(record.resolution)
        )
    end
    record.state = "active"
    record.resolution = {
        sessionId = confirmed.sessionId,
        presentationId = opened.presentationId,
    }
    self.confirmedCount = self.confirmedCount + 1
    return result(true, "pal-representative-dialogue-opened", {
        sessionId = confirmed.sessionId,
        presentationId = opened.presentationId,
        offer = copy(confirmed),
        view = copy(opened.view),
        stateMutationApplied = false,
    })
end

function PalRepresentativeInteraction:binding_status(
    representative_id
)
    local binding = self.bindings[representative_id]
    if binding == nil then
        return nil
    end
    local value = copy(binding)
    value.actor = nil
    value.actorValid = is_valid_object(binding.actor)
    return value
end

function PalRepresentativeInteraction:status()
    local binding_count = 0
    local valid_binding_count = 0
    local pending_offer_count = 0
    for _, binding in pairs(self.bindings) do
        binding_count = binding_count + 1
        if is_valid_object(binding.actor) then
            valid_binding_count = valid_binding_count + 1
        end
    end
    for _, offer in pairs(self.offers) do
        if offer.state == "pending-confirmation" then
            pending_offer_count = pending_offer_count + 1
        end
    end
    return {
        apiVersion = self.version,
        enabled = self.enabled,
        registeredBindingCount = binding_count,
        validBindingCount = valid_binding_count,
        pendingOfferCount = pending_offer_count,
        registrationCount = self.registrationCount,
        proximityRejectedCount = self.proximityRejectedCount,
        offerCount = self.offerCount,
        confirmedCount = self.confirmedCount,
        declinedCount = self.declinedCount,
        technicalRefundCount = self.technicalRefundCount,
        defaultMaximumDistance = self.defaultMaximumDistance,
        exactActorBinding = true,
        proximityGate = true,
        explicitIrreversibleConfirmation = true,
        presenterReadinessBeforeTokenConsume = true,
        nativeDelegateBinding = false,
        deterministicRuleEngineOwnsOutcome = true,
        directInteractionStateMutation = false,
        storyContentIncluded = false,
    }
end

return PalRepresentativeInteraction
