local FactionJoin = {}

local API_VERSION = "1.0.0"

local function require_non_empty_string(value, name)
    assert(
        type(value) == "string" and value ~= "",
        name .. " must be a non-empty string"
    )
    return value
end

local function copy(value)
    if type(value) ~= "table" then
        return value
    end
    local result = {}
    for key, item in pairs(value) do
        result[copy(key)] = copy(item)
    end
    return result
end

local function result(ok, reason, extra)
    local value = extra or {}
    value.ok = ok
    value.reason = reason
    return value
end

local function presenter_call(instance, method, payload)
    if instance.presenter == nil
        or type(instance.presenter[method]) ~= "function" then
        return nil
    end
    local ok, presenter_result = pcall(
        instance.presenter[method],
        instance.presenter,
        copy(payload)
    )
    return {
        ok = ok,
        result = ok and presenter_result or nil,
        error = ok and nil or tostring(presenter_result),
    }
end

function FactionJoin.create(faction_api, policy)
    assert(type(faction_api) == "table", "faction API is required")
    assert(
        type(faction_api.join_preview) == "function"
            and type(faction_api.join_human) == "function",
        "faction API lacks join operations"
    )
    assert(
        type(policy) == "table"
            and policy.enabled == true
            and policy.apiVersion == API_VERSION,
        "join interaction policy is required"
    )
    assert(
        policy.requiresRegisteredSource == true
            and policy.requiresExplicitConfirmation == true,
        "join interaction safety policy is invalid"
    )
    return setmetatable({
        version = API_VERSION,
        factionApi = faction_api,
        policy = copy(policy),
        sources = {},
        offers = {},
        requestIds = {},
        confirmationIds = {},
        presenter = nil,
        capabilities = {
            registeredSourcesOnly = true,
            explicitConfirmation = true,
            diplomacyPreview = true,
            multipleHumanMemberships = true,
            authoredDialogue = false,
            nativePresenter = false,
            PalworldSaveMutation = false,
        },
    }, { __index = FactionJoin })
end

function FactionJoin:register_source(
    source_id,
    faction_id,
    metadata
)
    require_non_empty_string(source_id, "join source ID")
    require_non_empty_string(faction_id, "join faction ID")
    metadata = metadata or {}
    assert(
        type(metadata) == "table",
        "join source metadata must be a table"
    )
    local faction = self.factionApi:faction_status(faction_id)
    if faction == nil then
        return result(false, "unknown-faction")
    end
    if faction.kind ~= "Human" then
        return result(false, "human-faction-source-required")
    end
    local existing = self.sources[source_id]
    if existing ~= nil then
        if existing.factionId ~= faction_id then
            return result(false, "join-source-conflict", {
                sourceId = source_id,
                factionId = existing.factionId,
            })
        end
        return result(true, "join-source-already-registered", {
            source = copy(existing),
        })
    end
    local source = {
        sourceId = source_id,
        factionId = faction_id,
        sourceKind =
            metadata.sourceKind or "content-representative",
        enabled = metadata.enabled ~= false,
        bindingStatus =
            metadata.bindingStatus
            or "content-endpoint-ready-native-interactor-pending",
        metadata = copy(metadata),
    }
    self.sources[source_id] = source
    return result(true, "join-source-registered", {
        source = copy(source),
    })
end

function FactionJoin:set_source_enabled(source_id, enabled)
    require_non_empty_string(source_id, "join source ID")
    assert(type(enabled) == "boolean", "enabled must be boolean")
    local source = self.sources[source_id]
    if source == nil then
        return result(false, "unknown-join-source")
    end
    source.enabled = enabled
    return result(true, "join-source-updated", {
        source = copy(source),
    })
end

function FactionJoin:register_presenter(presenter)
    assert(type(presenter) == "table", "join presenter is required")
    assert(
        type(presenter.present_offer) == "function",
        "join presenter must implement present_offer"
    )
    self.presenter = presenter
    self.capabilities.nativePresenter =
        presenter.native == true
    return result(true, "join-presenter-registered", {
        native = self.capabilities.nativePresenter,
    })
end

function FactionJoin:offer(
    source_id,
    player_id,
    request_id
)
    require_non_empty_string(source_id, "join source ID")
    require_non_empty_string(player_id, "join player ID")
    require_non_empty_string(request_id, "join request ID")
    local existing_offer_id = self.requestIds[request_id]
    if existing_offer_id ~= nil then
        local existing = self.offers[existing_offer_id]
        if existing.sourceId ~= source_id
            or existing.playerId ~= player_id then
            return result(false, "join-request-id-conflict")
        end
        return result(
            true,
            "join-offer-already-created",
            copy(existing)
        )
    end

    local source = self.sources[source_id]
    if source == nil then
        return result(false, "unknown-join-source")
    end
    if source.enabled ~= true then
        return result(false, "join-source-disabled", {
            sourceId = source_id,
            factionId = source.factionId,
        })
    end
    local preview =
        self.factionApi:join_preview(source.factionId)
    if preview.ok ~= true
        or preview.reason ~= "join-available" then
        return result(false, "join-unavailable", {
            sourceId = source_id,
            factionId = source.factionId,
            eligibilityReason = preview.reason,
            preview = copy(preview),
        })
    end

    local offer_id = "join-offer:" .. request_id
    local offer = {
        offerId = offer_id,
        requestId = request_id,
        sourceId = source_id,
        sourceKind = source.sourceKind,
        factionId = source.factionId,
        playerId = player_id,
        state = "pending-confirmation",
        explicitConfirmationRequired = true,
        dialogueContentIncluded = false,
        preview = copy(preview),
    }
    self.offers[offer_id] = offer
    self.requestIds[request_id] = offer_id
    local presentation =
        presenter_call(self, "present_offer", offer)
    local response = copy(offer)
    response.presentation = presentation
    return result(true, "join-offer-ready", response)
end

function FactionJoin:confirm(
    offer_id,
    confirmation_id,
    accepted
)
    require_non_empty_string(offer_id, "join offer ID")
    require_non_empty_string(
        confirmation_id,
        "join confirmation ID"
    )
    assert(type(accepted) == "boolean", "accepted must be boolean")
    local previous_offer_id =
        self.confirmationIds[confirmation_id]
    if previous_offer_id ~= nil then
        if previous_offer_id ~= offer_id then
            return result(
                false,
                "join-confirmation-id-conflict"
            )
        end
        return result(
            true,
            "join-confirmation-already-processed",
            copy(self.offers[offer_id].resolution)
        )
    end

    local offer = self.offers[offer_id]
    if offer == nil then
        return result(false, "unknown-join-offer")
    end
    if offer.state ~= "pending-confirmation" then
        return result(
            true,
            "join-offer-already-resolved",
            copy(offer.resolution)
        )
    end

    self.confirmationIds[confirmation_id] = offer_id
    if not accepted then
        offer.state = "declined"
        offer.resolution = {
            offerId = offer_id,
            confirmationId = confirmation_id,
            factionId = offer.factionId,
            playerId = offer.playerId,
            joined = false,
        }
        presenter_call(
            self,
            "present_resolution",
            offer.resolution
        )
        return result(
            true,
            "join-declined",
            copy(offer.resolution)
        )
    end

    local preview =
        self.factionApi:join_preview(offer.factionId)
    if preview.ok ~= true
        or preview.reason ~= "join-available" then
        offer.state = "stale"
        offer.resolution = {
            offerId = offer_id,
            confirmationId = confirmation_id,
            factionId = offer.factionId,
            playerId = offer.playerId,
            joined = false,
            eligibilityReason = preview.reason,
            preview = copy(preview),
        }
        presenter_call(
            self,
            "present_resolution",
            offer.resolution
        )
        return result(
            false,
            "join-offer-stale",
            copy(offer.resolution)
        )
    end

    local join_outcome = self.factionApi:join_human(
        offer.factionId,
        "join-interaction:"
            .. offer.sourceId
            .. ":"
            .. confirmation_id
    )
    offer.state =
        join_outcome.ok and "joined" or "failed"
    offer.resolution = {
        offerId = offer_id,
        confirmationId = confirmation_id,
        sourceId = offer.sourceId,
        factionId = offer.factionId,
        playerId = offer.playerId,
        joined =
            join_outcome.ok
            and (
                join_outcome.reason == "joined"
                or join_outcome.reason == "already-joined"
            ),
        outcome = copy(join_outcome),
    }
    local presentation = presenter_call(
        self,
        "present_resolution",
        offer.resolution
    )
    local response = copy(offer.resolution)
    response.presentation = presentation
    return result(
        join_outcome.ok == true,
        join_outcome.ok
            and "join-confirmed"
            or "join-failed",
        response
    )
end

function FactionJoin:status(source_id)
    if source_id ~= nil then
        require_non_empty_string(source_id, "join source ID")
        local source = self.sources[source_id]
        return source and copy(source) or nil
    end
    local source_count = 0
    local enabled_source_count = 0
    local pending_offer_count = 0
    local resolved_offer_count = 0
    for _, source in pairs(self.sources) do
        source_count = source_count + 1
        if source.enabled then
            enabled_source_count =
                enabled_source_count + 1
        end
    end
    for _, offer in pairs(self.offers) do
        if offer.state == "pending-confirmation" then
            pending_offer_count =
                pending_offer_count + 1
        else
            resolved_offer_count =
                resolved_offer_count + 1
        end
    end
    return {
        version = self.version,
        sourceCount = source_count,
        enabledSourceCount = enabled_source_count,
        pendingOfferCount = pending_offer_count,
        resolvedOfferCount = resolved_offer_count,
        presenterReady = self.presenter ~= nil,
        nativePresenter =
            self.capabilities.nativePresenter,
        dialogueContentIncluded = false,
    }
end

return FactionJoin
