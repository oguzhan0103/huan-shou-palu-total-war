local FactionJoinNativeRouter = {}

local PREFIX = "[PalFactionTerritory0][FactionJoinNative]"
local INTERACTION_PATH =
    "/Script/Pal.PalNPCInteractionComponent:OnTriggerInteract"

local function log(message)
    print(string.format("%s %s\n", PREFIX, tostring(message)))
end

local function result(ok, reason, extra)
    local value = extra or {}
    value.ok = ok
    value.reason = reason
    return value
end

local function is_valid(object)
    if object == nil then
        return false
    end
    local ok, value = pcall(function()
        return object:IsValid()
    end)
    return ok and value == true
end

local function safe_full_name(object)
    if not is_valid(object) then
        return "<invalid>"
    end
    local ok, value = pcall(function()
        return object:GetFullName()
    end)
    return ok and tostring(value) or "<unreadable>"
end

local function unwrap(parameter)
    if parameter == nil then
        return nil
    end
    local ok, value = pcall(function()
        return parameter:get()
    end)
    return ok and value or parameter
end

local function get_owner(component)
    if not is_valid(component) then
        return nil
    end
    for _, method in ipairs({ "GetOwner", "GetOuter" }) do
        local ok, value = pcall(function()
            return component[method](component)
        end)
        if ok and is_valid(value) then
            return value
        end
    end
    local ok, value = pcall(function()
        return component.Owner
    end)
    return ok and is_valid(value) and value or nil
end

local function default_location_provider(actor)
    if not is_valid(actor) then
        return nil, "actor-invalid"
    end
    local ok, value = pcall(function()
        return actor:K2_GetActorLocation()
    end)
    if not ok or value == nil then
        return nil, "actor-location-unavailable"
    end
    local x = value.X or value.x
    local y = value.Y or value.y
    local z = value.Z or value.z
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

local function run_in_game_thread(callback)
    if type(ExecuteInGameThread) == "function" then
        ExecuteInGameThread(callback)
    else
        callback()
    end
end

function FactionJoinNativeRouter.create(
    join,
    presenter,
    backend,
    configuration,
    options
)
    assert(
        type(join) == "table"
            and type(join.offer) == "function"
            and type(join.confirm) == "function",
        "faction join service is required"
    )
    assert(
        type(presenter) == "table"
            and type(presenter.present_offer) == "function",
        "faction join native presenter is required"
    )
    assert(
        type(backend) == "table"
            and type(backend.show_text) == "function"
            and type(backend.hide) == "function",
        "native text backend is required"
    )
    configuration = configuration or {}
    options = options or {}
    local maximum_distance =
        configuration.representativeInteractionDistance or 500
    assert(
        type(maximum_distance) == "number"
            and maximum_distance >= 50
            and maximum_distance <= 2000,
        "join representative interaction distance is invalid"
    )
    return setmetatable({
        version = "1.0.0",
        enabled = configuration.nativeJoinRepresentativeEnabled == true,
        join = join,
        presenter = presenter,
        backend = backend,
        defaultMaximumDistance = maximum_distance,
        locationProvider = options.locationProvider
            or default_location_provider,
        bindings = {},
        hook = nil,
        callbacks = {},
        keyBindings = {},
        pending = nil,
        nextRequestOrdinal = 0,
        nextConfirmationOrdinal = 0,
        registrationCount = 0,
        handledInteractionCount = 0,
        ignoredInteractionCount = 0,
        proximityRejectedCount = 0,
        confirmedCount = 0,
        declinedCount = 0,
        joinedCount = 0,
        lastError = nil,
    }, { __index = FactionJoinNativeRouter })
end

function FactionJoinNativeRouter:_next_id(kind)
    if kind == "request" then
        self.nextRequestOrdinal = self.nextRequestOrdinal + 1
        return string.format(
            "native-human-join-request:%08d",
            self.nextRequestOrdinal
        )
    end
    self.nextConfirmationOrdinal =
        self.nextConfirmationOrdinal + 1
    return string.format(
        "native-human-join-confirmation:%08d",
        self.nextConfirmationOrdinal
    )
end

function FactionJoinNativeRouter:register(source_id, actor, metadata)
    if not self.enabled then
        return result(false, "native-human-join-router-disabled")
    end
    if type(source_id) ~= "string" or source_id == "" then
        return result(false, "join-source-id-invalid")
    end
    local source = self.join:status(source_id)
    if source == nil then
        return result(false, "unknown-join-source")
    end
    if source.enabled ~= true then
        return result(false, "join-source-disabled")
    end
    if not is_valid(actor) then
        return result(false, "join-representative-actor-invalid")
    end
    metadata = metadata or {}
    local maximum_distance = metadata.maximumDistance
        or self.defaultMaximumDistance
    if type(maximum_distance) ~= "number"
        or maximum_distance < 50
        or maximum_distance > 2000 then
        return result(false, "join-representative-distance-invalid")
    end
    local existing = self.bindings[source_id]
    if existing ~= nil then
        if existing.actor == actor then
            return result(
                true,
                "join-representative-already-registered",
                { sourceId = source_id, actor = existing.actorName }
            )
        end
        return result(false, "join-representative-actor-conflict")
    end
    local actor_name = safe_full_name(actor)
    self.bindings[source_id] = {
        sourceId = source_id,
        factionId = source.factionId,
        actor = actor,
        actorName = actor_name,
        maximumDistance = maximum_distance,
        sourceKind = metadata.sourceKind
            or "content-faction-representative",
    }
    self.registrationCount = self.registrationCount + 1
    log(string.format(
        "REPRESENTATIVE_REGISTERED source=%s faction=%s actor=%s distance=%.1f story=false mutation=false",
        source_id,
        tostring(source.factionId),
        actor_name,
        maximum_distance
    ))
    return result(true, "join-representative-registered", {
        sourceId = source_id,
        factionId = source.factionId,
        actor = actor_name,
        maximumDistance = maximum_distance,
    })
end

function FactionJoinNativeRouter:unregister(source_id, actor)
    local binding = self.bindings[source_id]
    if binding == nil then
        return result(true, "join-representative-already-unregistered")
    end
    if actor ~= nil and binding.actor ~= actor then
        return result(false, "join-representative-actor-mismatch")
    end
    self.bindings[source_id] = nil
    if self.pending ~= nil and self.pending.sourceId == source_id then
        self.pending = nil
        self.backend:hide({ reason = "join-representative-unregistered" })
    end
    return result(true, "join-representative-unregistered")
end

function FactionJoinNativeRouter:source_id_for_actor(actor)
    if not is_valid(actor) then
        return nil
    end
    local actor_name = safe_full_name(actor)
    for source_id, binding in pairs(self.bindings) do
        if not is_valid(binding.actor) then
            self.bindings[source_id] = nil
        elseif binding.actor == actor
            or (actor_name ~= "<invalid>"
                and actor_name ~= "<unreadable>"
                and binding.actorName == actor_name) then
            return source_id
        end
    end
    return nil
end

function FactionJoinNativeRouter:_proximity(source_id, player_actor)
    local binding = self.bindings[source_id]
    if binding == nil or not is_valid(binding.actor) then
        self.bindings[source_id] = nil
        return nil, "join-representative-actor-stale"
    end
    if not is_valid(player_actor) then
        return nil, "join-player-actor-invalid"
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
        return nil, "player-not-near-join-representative"
    end
    return { binding = binding, distance = distance }, nil
end

function FactionJoinNativeRouter:_show_notice(reason)
    self.backend:show_text(
        "势力加入\n\n当前无法发起加入："
            .. tostring(reason)
            .. "\n\nF2 关闭",
        "human-faction-join-notice",
        { reason = reason }
    )
end

function FactionJoinNativeRouter:handle_interaction(
    component,
    player_actor
)
    local actor = get_owner(component)
    local source_id = self:source_id_for_actor(actor)
    if source_id == nil then
        self.ignoredInteractionCount =
            self.ignoredInteractionCount + 1
        return result(
            false,
            "actor-is-not-a-registered-join-representative"
        )
    end
    if self.pending ~= nil then
        self.presenter:present_offer(self.pending.offer)
        return result(true, "join-offer-already-visible", {
            offerId = self.pending.offer.offerId,
        })
    end
    local proximity, proximity_error =
        self:_proximity(source_id, player_actor)
    if proximity == nil then
        self.lastError = proximity_error
        self:_show_notice(proximity_error)
        return result(false, proximity_error)
    end
    local offered = self.join:offer(
        source_id,
        safe_full_name(player_actor),
        self:_next_id("request")
    )
    self.handledInteractionCount =
        self.handledInteractionCount + 1
    if not offered.ok then
        self.lastError = offered.reason
        self:_show_notice(offered.eligibilityReason or offered.reason)
        log(string.format(
            "OFFER_UNAVAILABLE source=%s faction=%s actor=%s reason=%s mutation=false",
            source_id,
            tostring(proximity.binding.factionId),
            safe_full_name(actor),
            tostring(offered.eligibilityReason or offered.reason)
        ))
        return offered
    end
    local presentation = offered.presentation
    local presenter_result = type(presentation) == "table"
            and presentation.result
        or nil
    if type(presentation) ~= "table"
        or presentation.ok ~= true
        or type(presenter_result) ~= "table"
        or presenter_result.ok ~= true then
        self.lastError = type(presentation) == "table"
                and (presentation.error
                    or (type(presenter_result) == "table"
                        and presenter_result.reason))
            or "join-presenter-missing"
        return result(false, "join-offer-presentation-failed", {
            offerId = offered.offerId,
            stateMutationApplied = false,
            presentationError = self.lastError,
        })
    end
    self.pending = {
        sourceId = source_id,
        actor = actor,
        playerActor = player_actor,
        offer = offered,
    }
    self.lastError = nil
    log(string.format(
        "OFFER_PRESENTED source=%s faction=%s actor=%s offer=%s distance=%.1f confirmation=F1/F2 mutation=false",
        source_id,
        tostring(proximity.binding.factionId),
        safe_full_name(actor),
        tostring(offered.offerId),
        proximity.distance
    ))
    return offered
end

function FactionJoinNativeRouter:confirm_pending(accepted)
    if self.pending == nil then
        return result(false, "no-pending-human-join-offer")
    end
    local pending = self.pending
    local confirmed = self.join:confirm(
        pending.offer.offerId,
        self:_next_id("confirmation"),
        accepted == true
    )
    if not confirmed.ok
        and confirmed.reason ~= "join-offer-stale" then
        self.lastError = confirmed.reason
        return confirmed
    end
    self.pending = nil
    if accepted == true then
        self.confirmedCount = self.confirmedCount + 1
        if confirmed.joined == true then
            self.joinedCount = self.joinedCount + 1
        end
    else
        self.declinedCount = self.declinedCount + 1
    end
    self.lastError = confirmed.ok and nil or confirmed.reason
    log(string.format(
        "CONFIRM_RESOLVED accepted=%s source=%s faction=%s offer=%s joined=%s reason=%s",
        tostring(accepted == true),
        pending.sourceId,
        tostring(pending.offer.factionId),
        tostring(pending.offer.offerId),
        tostring(confirmed.joined == true),
        tostring(confirmed.reason)
    ))
    return confirmed
end

function FactionJoinNativeRouter:_bind_key(key_value, name, callback)
    if key_value == nil or type(RegisterKeyBind) ~= "function" then
        return false
    end
    local wrapped = function()
        run_in_game_thread(function()
            local ok, error_message = pcall(callback)
            if not ok then
                self.lastError = tostring(error_message)
                log("KEY_ERROR key=" .. name
                    .. " error=" .. tostring(error_message))
            end
        end)
    end
    RegisterKeyBind(key_value, wrapped)
    self.callbacks["key:" .. name] = wrapped
    self.keyBindings[name] = true
    return true
end

function FactionJoinNativeRouter:start()
    if not self.enabled then
        return false, "native-human-join-router-disabled"
    end
    if type(RegisterHook) ~= "function" then
        return false, "RegisterHook-unavailable"
    end
    if type(Key) ~= "table"
        or type(RegisterKeyBind) ~= "function" then
        return false, "RegisterKeyBind-unavailable"
    end
    local callback = function(context, other_parameter)
        local component = unwrap(context)
        local player_actor = unwrap(other_parameter)
        local actor = get_owner(component)
        if self:source_id_for_actor(actor) == nil then
            return
        end
        run_in_game_thread(function()
            local ok, error_message = pcall(function()
                self:handle_interaction(component, player_actor)
            end)
            if not ok then
                self.lastError = tostring(error_message)
                log("INTERACTION_ERROR error=" .. tostring(error_message))
            end
        end)
    end
    local ok, first_id, second_id = pcall(function()
        return RegisterHook(INTERACTION_PATH, callback)
    end)
    if not ok then
        self.lastError = tostring(first_id)
        return false, "native-human-join-hook-failed:"
            .. tostring(first_id)
    end
    self.hook = {
        firstId = first_id,
        secondId = second_id,
        callback = callback,
    }
    self.callbacks.interaction = callback
    self:_bind_key(Key.F1, "F1", function()
        self:confirm_pending(true)
    end)
    self:_bind_key(Key.F2, "F2", function()
        if self.pending ~= nil then
            self:confirm_pending(false)
        else
            local mode = self.backend:status().mode
            if type(mode) == "string"
                and string.find(
                    mode,
                    "human-faction-join",
                    1,
                    true
                ) then
                self.backend:hide({
                    reason = "human-join-panel-dismissed",
                })
            end
        end
    end)
    log(string.format(
        "ROUTER_READY hook=%s keys=%d confirmation=F1/F2 exactActor=true distance=%.1f story=false mutation=false",
        INTERACTION_PATH,
        self:status().keyBindingCount,
        self.defaultMaximumDistance
    ))
    return true, nil
end

function FactionJoinNativeRouter:status()
    local binding_count = 0
    local key_count = 0
    for _ in pairs(self.bindings) do
        binding_count = binding_count + 1
    end
    for _ in pairs(self.keyBindings) do
        key_count = key_count + 1
    end
    return {
        apiVersion = self.version,
        enabled = self.enabled,
        nativeHookReady = self.hook ~= nil,
        nativeHookPath = INTERACTION_PATH,
        keyBindingCount = key_count,
        bindingCount = binding_count,
        pendingOffer = self.pending ~= nil,
        registrationCount = self.registrationCount,
        handledInteractionCount = self.handledInteractionCount,
        ignoredInteractionCount = self.ignoredInteractionCount,
        proximityRejectedCount = self.proximityRejectedCount,
        confirmedCount = self.confirmedCount,
        declinedCount = self.declinedCount,
        joinedCount = self.joinedCount,
        lastError = self.lastError,
        exactRegisteredActorOnly = true,
        proximityGate = true,
        explicitConfirmation = true,
        multipleHumanMemberships = true,
        directStateMutation = false,
        storyContentIncluded = false,
    }
end

return FactionJoinNativeRouter
