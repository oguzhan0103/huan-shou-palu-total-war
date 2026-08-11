local PalRepresentativeNativeRouter = {}

local PREFIX = "[PalFactionTerritory0][PalRepresentativeNative]"
local INTERACTION_PATH =
    "/Script/Pal.PalNPCInteractionComponent:OnTriggerInteract"

local NUMBER_KEYS = {
    "NUM_ONE",
    "NUM_TWO",
    "NUM_THREE",
    "NUM_FOUR",
    "NUM_FIVE",
    "NUM_SIX",
    "NUM_SEVEN",
    "NUM_EIGHT",
    "NUM_NINE",
}

local function log(message)
    print(string.format("%s %s\n", PREFIX, tostring(message)))
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
    if ok and value ~= nil then
        return value
    end
    return parameter
end

local function get_owner(component)
    if not is_valid(component) then
        return nil
    end
    local ok, value = pcall(function()
        return component:GetOwner()
    end)
    if ok and is_valid(value) then
        return value
    end
    ok, value = pcall(function()
        return component.Owner
    end)
    if ok and is_valid(value) then
        return value
    end
    -- BP_NPCInteractionComponent is an ActorComponent whose UObject outer is
    -- the NPC actor in live Palworld builds, even when GetOwner is not
    -- reflected to Lua.
    ok, value = pcall(function()
        return component:GetOuter()
    end)
    return ok and is_valid(value) and value or nil
end

local function run_in_game_thread(callback)
    if type(ExecuteInGameThread) == "function" then
        ExecuteInGameThread(callback)
    else
        callback()
    end
end

local function result(ok, reason, extra)
    local value = extra or {}
    value.ok = ok
    value.reason = reason
    return value
end

function PalRepresentativeNativeRouter.create(
    interaction,
    presenter,
    backend,
    configuration
)
    assert(
        type(interaction) == "table"
            and type(interaction.offer_for_actor) == "function",
        "Pal representative interaction router is required"
    )
    assert(
        type(presenter) == "table"
            and type(presenter.choose_authored) == "function",
        "Pal dialogue presenter is required"
    )
    assert(
        type(backend) == "table"
            and type(backend.show_offer) == "function",
        "native Pal dialogue backend is required"
    )
    return setmetatable({
        version = "1.0.0",
        enabled = configuration.nativeDialoguePresenterEnabled == true
            and configuration.representativeInteractionRouterEnabled
                == true,
        interaction = interaction,
        presenter = presenter,
        backend = backend,
        hook = nil,
        callbacks = {},
        keyBindings = {},
        nextRequestOrdinal = 0,
        nextConfirmationOrdinal = 0,
        nextActionOrdinal = 0,
        pendingOffer = nil,
        activePresentationId = nil,
        handledInteractionCount = 0,
        ignoredInteractionCount = 0,
        confirmedCount = 0,
        declinedCount = 0,
        choiceCount = 0,
        abortCount = 0,
        agentConfirmationCount = 0,
        lastError = nil,
    }, { __index = PalRepresentativeNativeRouter })
end

function PalRepresentativeNativeRouter:_next_id(kind)
    if kind == "request" then
        self.nextRequestOrdinal = self.nextRequestOrdinal + 1
        return string.format(
            "native-pal-interaction-request:%08d",
            self.nextRequestOrdinal
        )
    elseif kind == "confirmation" then
        self.nextConfirmationOrdinal =
            self.nextConfirmationOrdinal + 1
        return string.format(
            "native-pal-interaction-confirmation:%08d",
            self.nextConfirmationOrdinal
        )
    end
    self.nextActionOrdinal = self.nextActionOrdinal + 1
    return string.format(
        "native-pal-dialogue-action:%08d",
        self.nextActionOrdinal
    )
end

function PalRepresentativeNativeRouter:_active_record()
    if self.activePresentationId == nil then
        return nil
    end
    return self.presenter:presentation_status(
        self.activePresentationId
    )
end

function PalRepresentativeNativeRouter:handle_interaction(
    component,
    player_actor
)
    local representative_actor = get_owner(component)
    if not is_valid(representative_actor)
        or not is_valid(player_actor) then
        return result(false, "pal-native-interaction-actor-unavailable")
    end
    local representative_id =
        self.interaction:representative_id_for_actor(
            representative_actor
        )
    if representative_id == nil then
        self.ignoredInteractionCount =
            self.ignoredInteractionCount + 1
        return result(false, "actor-is-not-a-registered-pal-representative")
    end

    local active = self:_active_record()
    if active ~= nil and active.state == "active" then
        local refreshed = self.presenter:refresh(
            self.activePresentationId
        )
        log(string.format(
            "INTERACTION_REFRESH representative=%s presentation=%s ok=%s reason=%s",
            representative_id,
            self.activePresentationId,
            tostring(refreshed.ok),
            tostring(refreshed.reason)
        ))
        return refreshed
    end
    if self.pendingOffer ~= nil then
        self.backend:show_offer(self.pendingOffer.offer)
        return result(true, "pal-discourse-offer-already-visible", {
            offerId = self.pendingOffer.offer.offerId,
        })
    end

    local offered = self.interaction:offer_for_actor(
        representative_actor,
        player_actor,
        self:_next_id("request")
    )
    self.handledInteractionCount =
        self.handledInteractionCount + 1
    if not offered.ok then
        local message = offered.reason == "no-discourse-ready-token"
                and "当前没有已完成前置任务、可用于论道的信物。"
            or "当前无法开始论道：" .. tostring(offered.reason)
        self.backend:show_notice(message)
        self.lastError = offered.reason
        log(string.format(
            "OFFER_UNAVAILABLE representative=%s actor=%s reason=%s mutation=false",
            representative_id,
            safe_full_name(representative_actor),
            tostring(offered.reason)
        ))
        return offered
    end
    local shown, show_error = self.backend:show_offer(offered)
    if not shown then
        self.lastError = show_error
        return result(false, "pal-discourse-offer-presentation-failed", {
            offerId = offered.offerId,
            presentationError = show_error,
            tokenConsumed = false,
            stateMutationApplied = false,
        })
    end
    self.pendingOffer = {
        offer = offered,
        representativeActor = representative_actor,
        playerActor = player_actor,
    }
    self.lastError = nil
    log(string.format(
        "OFFER_PRESENTED representative=%s actor=%s offer=%s token=%s confirmationRequired=true mutation=false",
        representative_id,
        safe_full_name(representative_actor),
        tostring(offered.offerId),
        tostring(offered.tokenInstanceId)
    ))
    return offered
end

function PalRepresentativeNativeRouter:confirm_pending(accepted)
    if self.pendingOffer == nil then
        return result(false, "no-pending-pal-discourse-offer")
    end
    local pending = self.pendingOffer
    local confirmed = self.interaction:confirm(
        pending.offer.offerId,
        self:_next_id("confirmation"),
        accepted == true
    )
    if not confirmed.ok then
        self.lastError = confirmed.reason
        log("CONFIRM_FAILED reason=" .. tostring(confirmed.reason))
        return confirmed
    end
    self.pendingOffer = nil
    if accepted == true then
        self.activePresentationId = confirmed.presentationId
        self.confirmedCount = self.confirmedCount + 1
    else
        self.backend:hide({
            reason = "pal-discourse-offer-declined",
        })
        self.declinedCount = self.declinedCount + 1
    end
    self.lastError = nil
    log(string.format(
        "CONFIRM_RESOLVED accepted=%s offer=%s presentation=%s tokenConsumed=%s",
        tostring(accepted == true),
        tostring(pending.offer.offerId),
        tostring(confirmed.presentationId or "none"),
        tostring(confirmed.tokenConsumed == true)
    ))
    return confirmed
end

function PalRepresentativeNativeRouter:choose(index)
    local record = self:_active_record()
    if record == nil or record.state ~= "active"
        or type(record.lastView) ~= "table" then
        return result(false, "no-active-pal-dialogue-presentation")
    end
    local choice = record.lastView.choices
        and record.lastView.choices[index]
    if type(choice) ~= "table" then
        return result(false, "pal-dialogue-choice-index-unavailable")
    end
    local chosen = self.presenter:choose_authored(
        self.activePresentationId,
        choice.choiceId,
        self:_next_id("action")
    )
    if chosen.ok then
        self.choiceCount = self.choiceCount + 1
        local updated = self:_active_record()
        if updated == nil or updated.state ~= "active" then
            self.activePresentationId = nil
        end
    else
        self.lastError = chosen.reason
    end
    local settlement = type(chosen.choiceResult) == "table"
            and chosen.choiceResult.settlement
        or nil
    local settled_session = type(settlement) == "table"
            and settlement.session
        or nil
    log(string.format(
        "CHOICE_ROUTED index=%d choice=%s ok=%s reason=%s tokenConsumed=%s affinityApplied=%s outcome=%s",
        index,
        tostring(choice.choiceId),
        tostring(chosen.ok),
        tostring(chosen.reason),
        tostring(type(settled_session) == "table"
            and settled_session.tokenConsumed == true),
        tostring(type(settled_session) == "table"
            and settled_session.affinityApplied or 0),
        tostring(type(settled_session) == "table"
            and settled_session.outcome or "pending")
    ))
    return chosen
end

function PalRepresentativeNativeRouter:confirm_agent_proposal()
    local record = self:_active_record()
    local view = record and record.lastView or nil
    local agent = type(view) == "table" and view.agent or nil
    if type(agent) ~= "table"
        or agent.requiresPlayerConfirmation ~= true
        or type(agent.requestId) ~= "string" then
        return result(false, "no-agent-proposal-awaiting-player-confirmation")
    end
    local confirmed = self.presenter:confirm_agent_proposal(
        self.activePresentationId,
        agent.requestId,
        self:_next_id("action")
    )
    if confirmed.ok then
        self.agentConfirmationCount =
            self.agentConfirmationCount + 1
    else
        self.lastError = confirmed.reason
    end
    return confirmed
end

function PalRepresentativeNativeRouter:abort_active()
    local record = self:_active_record()
    if record == nil or record.state ~= "active" then
        return result(false, "no-active-pal-dialogue-presentation")
    end
    local aborted = self.presenter:player_abort(
        self.activePresentationId,
        self:_next_id("action")
    )
    if aborted.ok then
        self.abortCount = self.abortCount + 1
        self.activePresentationId = nil
    else
        self.lastError = aborted.reason
    end
    return aborted
end

function PalRepresentativeNativeRouter:_bind_key(key_value, name, callback)
    if key_value == nil or type(RegisterKeyBind) ~= "function" then
        return false
    end
    local wrapped = function()
        run_in_game_thread(function()
            local ok, error_message = pcall(callback)
            if not ok then
                self.lastError = tostring(error_message)
                log(string.format(
                    "KEY_ERROR key=%s error=%s",
                    name,
                    tostring(error_message)
                ))
            end
        end)
    end
    RegisterKeyBind(key_value, wrapped)
    self.callbacks["key:" .. name] = wrapped
    self.keyBindings[name] = true
    return true
end

function PalRepresentativeNativeRouter:start()
    if not self.enabled then
        return false, "native-pal-representative-router-disabled"
    end
    if type(RegisterHook) ~= "function" then
        return false, "RegisterHook-unavailable"
    end
    if type(Key) ~= "table"
        or type(RegisterKeyBind) ~= "function" then
        return false, "RegisterKeyBind-unavailable"
    end
    local interaction_callback = function(context, other_parameter)
        local component = unwrap(context)
        local player_actor = unwrap(other_parameter)
        local representative_actor = get_owner(component)
        if self.interaction:representative_id_for_actor(
            representative_actor
        ) == nil then
            self.ignoredInteractionCount =
                self.ignoredInteractionCount + 1
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
        return RegisterHook(INTERACTION_PATH, interaction_callback)
    end)
    if not ok then
        self.lastError = tostring(first_id)
        return false, "native-pal-interaction-hook-failed:"
            .. tostring(first_id)
    end
    self.hook = {
        firstId = first_id,
        secondId = second_id,
        callback = interaction_callback,
    }
    self.callbacks.interaction = interaction_callback

    self:_bind_key(Key.F1, "F1", function()
        self:confirm_pending(true)
    end)
    self:_bind_key(Key.F2, "F2", function()
        if self.pendingOffer ~= nil then
            self:confirm_pending(false)
        elseif self.backend:status().mode == "notice" then
            self.backend:hide({ reason = "notice-dismissed" })
        end
    end)
    self:_bind_key(Key.F3, "F3", function()
        self:confirm_agent_proposal()
    end)
    self:_bind_key(Key.F4, "F4", function()
        self:abort_active()
    end)
    for index, key_name in ipairs(NUMBER_KEYS) do
        local selected = index
        self:_bind_key(Key[key_name], key_name, function()
            self:choose(selected)
        end)
    end
    log(string.format(
        "ROUTER_READY hook=%s keys=%d confirmation=F1/F2 choices=NUM_ONE..NUM_NINE agentConfirm=F3 abort=F4 mutation=false",
        INTERACTION_PATH,
        self:status().keyBindingCount
    ))
    return true, nil
end

function PalRepresentativeNativeRouter:status()
    local key_count = 0
    for _ in pairs(self.keyBindings) do
        key_count = key_count + 1
    end
    return {
        apiVersion = self.version,
        enabled = self.enabled,
        nativeHookReady = self.hook ~= nil,
        nativeHookPath = INTERACTION_PATH,
        keyBindingCount = key_count,
        pendingOffer = self.pendingOffer ~= nil,
        activePresentationId = self.activePresentationId,
        handledInteractionCount = self.handledInteractionCount,
        ignoredInteractionCount = self.ignoredInteractionCount,
        confirmedCount = self.confirmedCount,
        declinedCount = self.declinedCount,
        choiceCount = self.choiceCount,
        abortCount = self.abortCount,
        agentConfirmationCount = self.agentConfirmationCount,
        lastError = self.lastError,
        exactRegisteredActorOnly = true,
        explicitIrreversibleConfirmation = true,
        deterministicRuleEngineOwnsOutcome = true,
        directStateMutation = false,
        storyContentIncluded = false,
    }
end

return PalRepresentativeNativeRouter
