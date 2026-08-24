local UniquePalWorldEffectNativeProduction = {}

local API_VERSION = "1.0.0"
local ALL_DELIVERY_KINDS = {
    "war-notice",
    "player-defense-request",
    "world-spawn-suppression",
    "loaded-actor-cleanup",
    "empty-city",
    "merchant-filter",
    "ransom-offer",
    "pal-delivery",
}

local function copy(value)
    if type(value) ~= "table" then return value end
    local output = {}
    for key, child in pairs(value) do output[copy(key)] = copy(child) end
    return output
end

local function result(ok, reason, extra)
    local value = extra or {}
    value.ok = ok
    value.reason = reason
    return value
end

local function require_text(value, name)
    assert(type(value) == "string" and value ~= "",
        name .. " must be a non-empty string")
    return value
end

local function stable_id(value, name)
    require_text(value, name)
    assert(string.find(value, ".", 1, true) ~= nil,
        name .. " must be namespaced")
    return value
end

local function stable_hash(value)
    -- Keep the accumulator below Lua's exact signed-integer boundary.  UE4SS
    -- and the pinned offline Lua runtime must choose the same deterministic
    -- delay/outcome without relying on implementation-specific overflow.
    local hash = 5381
    for index = 1, #value do
        hash = (hash * 33 + string.byte(value, index)) % 2147483647
    end
    return hash
end

local function is_valid_object(value)
    if value == nil then return false end
    if type(value.IsValid) == "function" then
        local ok, valid = pcall(value.IsValid, value)
        return ok and valid == true
    end
    return true
end

local function safe_call(object, method, ...)
    if not is_valid_object(object) then return nil end
    local fn = object[method]
    if type(fn) ~= "function" then return nil end
    local ok, value = pcall(fn, object, ...)
    return ok and value or nil
end

local function local_player_character()
    local controller = nil
    if _G.UEHelpers ~= nil
        and type(_G.UEHelpers.GetPlayerController) == "function" then
        local ok, value = pcall(_G.UEHelpers.GetPlayerController)
        if ok and is_valid_object(value) then controller = value end
    end
    if controller == nil and type(_G.FindFirstOf) == "function" then
        for _, class_name in ipairs({
            "PalPlayerController", "PalPlayerController_C",
        }) do
            local ok, value = pcall(_G.FindFirstOf, class_name)
            if ok and is_valid_object(value) then
                controller = value
                break
            end
        end
    end
    if controller == nil then return nil end
    local character = safe_call(controller, "GetDefaultPlayerCharacter")
        or safe_call(controller, "K2_GetPawn")
        or controller.AcknowledgedPawn
        or controller.Pawn
    return is_valid_object(character) and character or nil
end

local function show_warning(message)
    if type(_G.StaticFindObject) ~= "function"
        or type(_G.FindAllOf) ~= "function" then
        return false
    end
    local text_ok, text_library = pcall(
        _G.StaticFindObject,
        "/Script/Engine.Default__KismetTextLibrary"
    )
    if not text_ok or not is_valid_object(text_library) then return false end
    local warning_text = safe_call(
        text_library,
        "Conv_StringToText",
        tostring(message)
    )
    if warning_text == nil then return false end
    local found, surfaces = pcall(_G.FindAllOf, "PalHUDService")
    if not found or type(surfaces) ~= "table" then return false end
    for _, surface in pairs(surfaces) do
        if is_valid_object(surface) then
            local shown = pcall(function()
                surface:ShowCommonWarning({
                    Message = warning_text,
                    DisplayType = 0,
                })
            end)
            if shown then return true end
        end
    end
    return false
end

local function suffix(value)
    return string.match(value or "", "([^%.]+)$") or tostring(value)
end

local function faction_label(faction_id)
    local labels = {
        ["pwft.faction.rayne_syndicate"] = "盗猎集团",
        ["pwft.faction.free_pal_alliance"] = "帕鲁保护协会",
        ["pwft.faction.eternal_pyre"] = "永言同心会",
        ["pwft.faction.pidf"] = "帕鲁防卫队",
        ["pwft.faction.pal_genetic_research_unit"] = "基因研究部队",
        ["pwft.faction.moonflower"] = "樱岛势力",
        ["pwft.faction.feybreak_army"] = "天坠之地势力",
    }
    return labels[faction_id] or faction_id
end

local function pal_label(unique_pal_id)
    local labels = {
        ["pwft.unique.pinkcat"] = "捣蛋猫",
        ["pwft.unique.anubis"] = "阿努比斯",
        ["pwft.unique.weasel_dragon"] = "疾漩鼬",
        ["pwft.unique.black_metal_dragon"] = "魔渊龙",
        ["pwft.unique.ronin"] = "浪刃武士",
    }
    return labels[unique_pal_id] or unique_pal_id
end

local function delivery_response(payload, applied, reason, extra)
    local value = extra or {}
    value.ok = applied == true
    value.applied = applied == true
    value.deliveryId = payload.deliveryId
    value.reason = reason
    return value
end

function UniquePalWorldEffectNativeProduction.create(
    world_effect_bus,
    campaign,
    native_delivery_production,
    ransom_shop_bridge,
    configuration,
    options
)
    assert(type(world_effect_bus) == "table"
            and type(world_effect_bus.register_provider) == "function"
            and type(world_effect_bus.bind_target) == "function",
        "unique-Pal world-effect bus is required")
    assert(type(campaign) == "table"
            and type(campaign.declare_destruction_war) == "function"
            and type(campaign.campaign_status) == "function",
        "unique-Pal campaign is required")
    assert(type(native_delivery_production) == "table"
            and type(native_delivery_production.register) == "function",
        "unique-Pal native delivery production is required")
    assert(type(ransom_shop_bridge) == "table"
            and type(ransom_shop_bridge.accept_offer) == "function",
        "unique-Pal ransom shop bridge is required")
    configuration = configuration or {}
    options = options or {}
    assert(type(configuration.enabled) == "boolean",
        "unique-Pal world-effect production flag is required")
    assert(type(configuration.autoWarEnabled) == "boolean",
        "unique-Pal auto-war flag is required")
    local minimum_delay = tonumber(configuration.minimumWarDelayMs)
    local maximum_delay = tonumber(configuration.maximumWarDelayMs)
    assert(minimum_delay ~= nil and minimum_delay >= 1000,
        "minimum unique-Pal war delay is invalid")
    assert(maximum_delay ~= nil and maximum_delay >= minimum_delay,
        "maximum unique-Pal war delay is invalid")
    local background_delay = tonumber(configuration.backgroundResolveDelayMs)
    assert(background_delay ~= nil and background_delay >= 0,
        "background war resolution delay is invalid")
    local win_percent = tonumber(configuration.backgroundAttackerWinPercent)
    assert(win_percent ~= nil and win_percent >= 0 and win_percent <= 100,
        "background attacker win percent is invalid")
    local schedule = options.schedule
    if schedule == nil then
        schedule = function(delay_ms, callback)
            if type(_G.ExecuteWithDelay) ~= "function" then return false end
            _G.ExecuteWithDelay(delay_ms, callback)
            return true
        end
    end
    return setmetatable({
        version = API_VERSION,
        bus = world_effect_bus,
        campaign = campaign,
        nativeDeliveryProduction = native_delivery_production,
        ransomShopBridge = ransom_shop_bridge,
        enabled = configuration.enabled == true,
        buildId = require_text(configuration.buildId,
            "unique-Pal world-effect Build ID"),
        providerId = stable_id(configuration.providerId,
            "unique-Pal world-effect provider ID"),
        authoritySource = stable_id(configuration.authoritySource,
            "unique-Pal world-effect authority"),
        autoWarEnabled = configuration.autoWarEnabled == true,
        minimumWarDelayMs = minimum_delay,
        maximumWarDelayMs = maximum_delay,
        backgroundResolveDelayMs = background_delay,
        backgroundAttackerWinPercent = win_percent,
        defenseCountdownSeconds = tonumber(
            configuration.defenseCountdownSeconds) or 30,
        ransomInteractionKey = configuration.ransomInteractionKey or "F7",
        ransomInteractionRequireControlModifier =
            configuration.ransomInteractionRequireControlModifier ~= false,
        ransomInteractionRadius = tonumber(
            configuration.ransomInteractionRadius) or 700,
        ransomProductItemId = require_text(
            configuration.ransomProductItemId,
            "unique-Pal ransom product item ID"),
        schedule = schedule,
        logger = options.logger,
        active = false,
        worldGeneration = 0,
        activationGeneration = 0,
        definitionsByUniquePalId = {},
        bindingsByTargetKey = {},
        merchantRuntimes = nil,
        settlementRaid = nil,
        scheduledWarTokens = {},
        queuedDefenseWarIds = {},
        defensesByRaidEventId = {},
        processedDeliveryIds = {},
        activationCount = 0,
        targetBindingCount = 0,
        nativeDeliveryBindingCount = 0,
        warScheduleCount = 0,
        warDeclarationCount = 0,
        backgroundResolutionCount = 0,
        playerDefenseRequestCount = 0,
        playerDefenseResolutionCount = 0,
        spawnSuppressionCount = 0,
        cleanupCount = 0,
        emptyCityCount = 0,
        merchantFilterCount = 0,
        ransomOfferCount = 0,
        lastError = nil,
        keyBound = false,
    }, { __index = UniquePalWorldEffectNativeProduction })
end

function UniquePalWorldEffectNativeProduction:_log(message)
    if self.logger ~= nil then
        pcall(self.logger, "[UniquePalWorldEffectProduction] " .. message)
    end
end

function UniquePalWorldEffectNativeProduction:_schedule(delay_ms, callback)
    local generation = self.activationGeneration
    local ok, scheduled = pcall(self.schedule, delay_ms, function()
        if self.active ~= true or self.activationGeneration ~= generation then
            return
        end
        local called, message = pcall(callback)
        if not called then
            self.lastError = tostring(message)
            self:_log("SCHEDULED_CALLBACK_FAILED error=" .. tostring(message))
        end
    end)
    return ok and scheduled ~= false
end

function UniquePalWorldEffectNativeProduction:_binding_for_payload(payload)
    return self.bindingsByTargetKey[payload.targetKey]
end

function UniquePalWorldEffectNativeProduction:_notify_for_war(payload)
    local campaign = payload.uniquePalId
        and self.campaign:campaign_status(payload.uniquePalId) or nil
    local owner = campaign and campaign.owner or nil
    if payload.sourceEventType == "unique-pal-destruction-war-declared" then
        return show_warning(string.format(
            "【唯一帕鲁战争】%s凭借%s向目标势力发动了毁灭战争。",
            faction_label(payload.attackerFactionId),
            pal_label(payload.uniquePalId)
        ))
    elseif payload.sourceEventType
        == "unique-pal-destruction-target-destroyed" then
        return show_warning(string.format(
            "【势力毁灭】%s的城镇已停止刷新，商人商会对应柜台永久关闭。",
            tostring(payload.targetId)
        ))
    elseif payload.sourceEventType
        == "unique-pal-destruction-target-survived" then
        return show_warning("【防卫成功】目标势力从唯一帕鲁战争中存续下来。")
    elseif payload.sourceEventType == "unique-pal-ransom-settled" then
        return show_warning(string.format(
            "【赎回成功】%s已经转交给玩家，正在进行原生帕鲁交付。",
            pal_label(payload.uniquePalId)
        ))
    end
    return owner ~= nil
end

function UniquePalWorldEffectNativeProduction:_resolve_background_war(
    payload,
    context,
    forced_attacker_won
)
    local binding = self:_binding_for_payload(payload)
    if binding == nil then return false end
    local attacker_won = forced_attacker_won
    if attacker_won == nil then
        attacker_won = (stable_hash(payload.warId .. "|background") % 100)
            < self.backgroundAttackerWinPercent
    end
    local response = self.bus:confirm_background_war({
        callbackId = "pwft.production.background-war." .. payload.warId,
        providerId = self.providerId,
        authoritySource = self.authoritySource,
        bindingId = binding.bindingId,
        worldGeneration = context.worldGeneration,
        warId = payload.warId,
        backgroundWarResolverKey =
            binding.nativeRoutes.backgroundWarResolverKey,
        attackerWon = attacker_won,
    })
    if response.ok then
        self.backgroundResolutionCount = self.backgroundResolutionCount + 1
        self:_log(string.format(
            "BACKGROUND_WAR_RESOLVED war=%s attackerWon=%s targetDestroyed=%s",
            tostring(payload.warId),
            tostring(attacker_won),
            tostring(response.targetDestroyed == true)
        ))
    else
        self.lastError = response.reason
    end
    return response.ok == true
end

function UniquePalWorldEffectNativeProduction:_deactivate_factions(
    faction_ids,
    reason
)
    if self.merchantRuntimes == nil then
        return false, "merchant-runtimes-unavailable", 0
    end
    local applied = 0
    for _, faction_id in ipairs(faction_ids or {}) do
        local economy = self.merchantRuntimes.economy
        if economy ~= nil and type(economy.deactivate_faction) == "function" then
            local outcome = economy:deactivate_faction(faction_id, reason)
            if outcome.ok ~= true then return false, outcome.reason, applied end
            applied = applied + 1
        end
        local legacy = self.merchantRuntimes.legacy
        if legacy ~= nil then
            if type(legacy.deactivate_faction) == "function" then
                local outcome = legacy:deactivate_faction(faction_id, reason)
                if outcome.ok ~= true then return false, outcome.reason, applied end
                applied = applied + 1
            elseif type(legacy.recall_caravan) == "function" then
                local outcome = legacy:recall_caravan(faction_id, reason)
                if outcome.ok ~= true then return false, outcome.reason, applied end
            end
        end
    end
    return true, "destroyed-faction-runtime-actors-deactivated", applied
end

function UniquePalWorldEffectNativeProduction:_handle_delivery(payload, context)
    if payload.deliveryKind == "war-notice" then
        self:_notify_for_war(payload)
        if payload.sourceEventType == "unique-pal-destruction-war-declared"
            and payload.route == "background" then
            local scheduled = self:_schedule(
                self.backgroundResolveDelayMs,
                function() self:_resolve_background_war(payload, context) end
            )
            if not scheduled then
                return delivery_response(payload, false,
                    "background-war-scheduler-unavailable")
            end
        end
        return delivery_response(payload, true,
            "native-war-notice-presented")
    end

    if payload.deliveryKind == "player-defense-request" then
        if self.settlementRaid == nil
            or type(self.settlementRaid.force_start) ~= "function" then
            return {
                ok = false,
                accepted = false,
                deliveryId = payload.deliveryId,
                reason = "settlement-defense-runtime-unavailable",
            }
        end
        local native_raid_id = payload.deliveryId .. ":native-raid"
        local binding = self:_binding_for_payload(payload)
        local record = {
            warId = payload.warId,
            nativeRaidId = native_raid_id,
            bindingId = context.bindingId,
            worldGeneration = context.worldGeneration,
            defenseRaidKey = binding.nativeRoutes.defenseRaidKey,
        }
        self.queuedDefenseWarIds[#self.queuedDefenseWarIds + 1] = record
        local started, start_reason = self.settlementRaid:force_start(
            "unique-pal-defense:" .. tostring(payload.warId),
            self.defenseCountdownSeconds
        )
        if started ~= true then
            table.remove(self.queuedDefenseWarIds,
                #self.queuedDefenseWarIds)
            return {
                ok = false,
                accepted = false,
                deliveryId = payload.deliveryId,
                reason = "unique-pal-defense-raid-start-failed:"
                    .. tostring(start_reason),
            }
        end
        self.playerDefenseRequestCount = self.playerDefenseRequestCount + 1
        show_warning("【唯一帕鲁防卫】你加入的势力正遭到毁灭战争，请参加并守住本轮袭击。")
        return {
            ok = true,
            accepted = true,
            deliveryId = payload.deliveryId,
            nativeRaidId = native_raid_id,
            reason = "unique-pal-player-defense-native-raid-started",
        }
    end

    if payload.deliveryKind == "world-spawn-suppression" then
        self.spawnSuppressionCount = self.spawnSuppressionCount + 1
        return delivery_response(payload, true,
            "destroyed-faction-spawn-policy-activated")
    end

    if payload.deliveryKind == "loaded-actor-cleanup" then
        local ok, reason, count = self:_deactivate_factions(
            payload.merchantCounterFactionIds,
            "unique-pal-destruction-loaded-actor-cleanup"
        )
        if ok then self.cleanupCount = self.cleanupCount + count end
        return delivery_response(payload, ok, reason, {
            cleanedRuntimeCount = count,
        })
    end

    if payload.deliveryKind == "empty-city" then
        self.emptyCityCount = self.emptyCityCount + #(
            payload.cityBindings or {})
        return delivery_response(payload, true,
            "destroyed-city-resident-and-function-spawners-suppressed", {
                preserveBuildings = true,
                cityCount = #(payload.cityBindings or {}),
            })
    end

    if payload.deliveryKind == "merchant-filter" then
        local ok, reason, count = self:_deactivate_factions(
            payload.merchantCounterFactionIds,
            "unique-pal-destruction-merchant-filter"
        )
        if ok then self.merchantFilterCount = self.merchantFilterCount + count end
        return delivery_response(payload, ok, reason, {
            filteredRuntimeCount = count,
        })
    end

    if payload.deliveryKind == "ransom-offer" then
        local economy = self.merchantRuntimes
            and self.merchantRuntimes.economy or nil
        if economy == nil
            or type(economy.configure_unique_pal_ransom) ~= "function" then
            return {
                ok = false,
                accepted = false,
                deliveryId = payload.deliveryId,
                reason = "native-ransom-merchant-runtime-unavailable",
            }
        end
        local native_offer = economy:configure_unique_pal_ransom(
            payload.previousHolderFactionId,
            {
                nativeOfferId = payload.offerId .. ":merchant-guild",
                uniquePalId = payload.uniquePalId,
                productItemId = self.ransomProductItemId,
                unitPrice = payload.amount,
                currency = payload.currency,
                buyQuantity = 1,
                singlePurchaseStock = true,
                serverAuthoritativePrice = true,
                serverAuthoritativePaymentResult = true,
                ransomPaymentKey = payload.nativeRoutes.ransomPaymentKey,
            }
        )
        if native_offer.ok ~= true then
            return {
                ok = false,
                accepted = false,
                deliveryId = payload.deliveryId,
                reason = native_offer.reason,
            }
        end
        local accepted = self.ransomShopBridge:accept_offer(
            payload,
            context,
            native_offer
        )
        if accepted.ok then
            self.ransomOfferCount = self.ransomOfferCount + 1
            show_warning(string.format(
                "【唯一帕鲁赎回】购买当前商人的%s即可支付%d金币赎回%s；该交易不增加好感度。",
                self.ransomProductItemId,
                payload.amount,
                pal_label(payload.uniquePalId)
            ))
        end
        return accepted
    end

    if payload.deliveryKind == "pal-delivery" then
        return self.nativeDeliveryProduction:handle_delivery(payload, context)
    end

    return delivery_response(payload, false,
        "unsupported-native-unique-pal-world-effect")
end

function UniquePalWorldEffectNativeProduction:_schedule_war(unique_pal_id)
    if self.autoWarEnabled ~= true or self.active ~= true then return false end
    local campaign = self.campaign:campaign_status(unique_pal_id)
    if campaign == nil or campaign.owner == nil
        or campaign.owner.kind ~= "faction"
        or campaign.activeWarId ~= nil then
        return false
    end
    local target = campaign.definition and campaign.definition.target
    local target_status = target and self.campaign:target_status(
        target.kind, target.id) or nil
    if target_status == nil or target_status.status == "destroyed" then
        return false
    end
    local token = tostring(self.activationGeneration) .. ":"
        .. unique_pal_id .. ":" .. tostring(campaign.owner.id)
    if self.scheduledWarTokens[unique_pal_id] == token then return true end
    self.scheduledWarTokens[unique_pal_id] = token
    local span = self.maximumWarDelayMs - self.minimumWarDelayMs + 1
    local delay_ms = self.minimumWarDelayMs
        + (stable_hash(token) % span)
    local scheduled = self:_schedule(delay_ms, function()
        if self.scheduledWarTokens[unique_pal_id] ~= token then return end
        self.scheduledWarTokens[unique_pal_id] = nil
        self:declare_war(unique_pal_id, nil, "automatic")
    end)
    if scheduled then
        self.warScheduleCount = self.warScheduleCount + 1
        self:_log(string.format(
            "NPC_DESTRUCTION_WAR_SCHEDULED uniquePal=%s holder=%s delayMs=%d",
            tostring(unique_pal_id),
            tostring(campaign.owner.id),
            delay_ms
        ))
    else
        self.scheduledWarTokens[unique_pal_id] = nil
    end
    return scheduled
end

function UniquePalWorldEffectNativeProduction:declare_war(
    unique_pal_id,
    forced_attacker_won,
    source
)
    local status = self.campaign:campaign_status(unique_pal_id)
    if status == nil then return result(false, "unknown-unique-pal-campaign") end
    local logical_tick = (tonumber(self.campaign:status().logicalTick) or 0) + 1
    local sequence = tostring(logical_tick) .. "."
        .. tostring(stable_hash(unique_pal_id .. "|" .. tostring(source)))
    local war_id = "pwft.unique-pal-war." .. suffix(unique_pal_id)
        .. "." .. sequence
    local declared = self.campaign:declare_destruction_war(
        unique_pal_id,
        war_id,
        logical_tick,
        war_id .. ".declare"
    )
    if not declared.ok then
        self.lastError = declared.reason
        return declared
    end
    self.warDeclarationCount = self.warDeclarationCount + 1
    if forced_attacker_won ~= nil and declared.war.route == "background" then
        local target_key = declared.war.targetKey
        local binding = self.bindingsByTargetKey[target_key]
        local resolved = self.bus:confirm_background_war({
            callbackId = war_id .. ".forced-result",
            providerId = self.providerId,
            authoritySource = self.authoritySource,
            bindingId = binding.bindingId,
            worldGeneration = self.worldGeneration,
            warId = war_id,
            backgroundWarResolverKey =
                binding.nativeRoutes.backgroundWarResolverKey,
            attackerWon = forced_attacker_won == true,
        })
        declared.forcedResolution = resolved
    end
    return declared
end

function UniquePalWorldEffectNativeProduction:observe_campaign_event(event)
    if type(event) ~= "table" then
        return result(false, "unique-pal-campaign-event-required")
    end
    if event.type == "unique-pal-opening-expired-assigned" then
        self:_schedule_war(event.uniquePalId)
    elseif event.type == "unique-pal-owner-synchronized"
        and event.owner ~= nil and event.owner.kind == "faction" then
        self:_schedule_war(event.uniquePalId)
    elseif event.type == "unique-pal-destruction-target-survived" then
        self:_schedule_war(event.uniquePalId)
    elseif event.type == "unique-pal-ransom-settled" then
        local economy = self.merchantRuntimes
            and self.merchantRuntimes.economy or nil
        if economy ~= nil
            and type(economy.clear_unique_pal_ransom) == "function" then
            economy:clear_unique_pal_ransom(
                event.previousHolderFactionId,
                event.uniquePalId
            )
        end
    end
    return result(true, "unique-pal-campaign-event-observed")
end

function UniquePalWorldEffectNativeProduction:set_merchant_runtimes(
    legacy_runtime,
    economy_runtime
)
    self.merchantRuntimes = {
        legacy = legacy_runtime,
        economy = economy_runtime,
    }
    local retried = self.bus:retry_pending()
    return result(true, "unique-pal-merchant-runtimes-bound", {
        retry = retried,
    })
end

function UniquePalWorldEffectNativeProduction:set_settlement_raid(raid)
    assert(type(raid) == "table" and type(raid.force_start) == "function",
        "settlement raid runtime is required")
    self.settlementRaid = raid
    local retried = self.bus:retry_pending()
    return result(true, "unique-pal-settlement-defense-runtime-bound", {
        retry = retried,
    })
end

function UniquePalWorldEffectNativeProduction:on_attendance_start(raid_start)
    if #self.queuedDefenseWarIds == 0 then
        return result(true, "non-unique-pal-defense-raid-ignored", {
            ignored = true,
        })
    end
    local record = table.remove(self.queuedDefenseWarIds, 1)
    record.raidEventId = raid_start.raidEventId
    self.defensesByRaidEventId[raid_start.raidEventId] = record
    return result(true, "unique-pal-defense-raid-attributed", {
        warId = record.warId,
        nativeRaidId = record.nativeRaidId,
    })
end

function UniquePalWorldEffectNativeProduction:on_attendance_result(raid_result)
    local record = self.defensesByRaidEventId[raid_result.raidEventId]
    if record == nil then
        return result(true, "non-unique-pal-defense-result-ignored", {
            ignored = true,
        })
    end
    local response = self.bus:confirm_player_defense({
        callbackId = "pwft.production.player-defense."
            .. raid_result.raidEventId,
        providerId = self.providerId,
        authoritySource = self.authoritySource,
        bindingId = record.bindingId,
        worldGeneration = record.worldGeneration,
        warId = record.warId,
        nativeRaidId = record.nativeRaidId,
        defenseRaidKey = record.defenseRaidKey,
        playerParticipated = raid_result.playerParticipated == true,
        playerSideWon = raid_result.playerSideWon == true,
    })
    if response.ok then
        self.defensesByRaidEventId[raid_result.raidEventId] = nil
        self.playerDefenseResolutionCount =
            self.playerDefenseResolutionCount + 1
    else
        self.lastError = response.reason
    end
    return response
end

function UniquePalWorldEffectNativeProduction:on_attendance_cancel(raid_cancel)
    local record = self.defensesByRaidEventId[raid_cancel.raidEventId]
    if record == nil then
        return result(true, "non-unique-pal-defense-cancel-ignored", {
            ignored = true,
        })
    end
    return self:on_attendance_result({
        raidEventId = raid_cancel.raidEventId,
        playerParticipated = false,
        playerSideWon = false,
    })
end

function UniquePalWorldEffectNativeProduction:request_nearest_ransom()
    local economy = self.merchantRuntimes
        and self.merchantRuntimes.economy or nil
    if economy == nil or type(economy.nearest_faction) ~= "function" then
        return result(false, "native-ransom-merchant-runtime-unavailable")
    end
    local player = local_player_character()
    if player == nil then return result(false, "local-player-unavailable") end
    -- Resolve eligibility before distance.  Otherwise an unrelated but closer
    -- Merchant Guild counter can shadow the holder's counter and make a valid
    -- ransom impossible even while the player is inside the holder's radius.
    local eligible = {}
    for unique_pal_id in pairs(self.definitionsByUniquePalId) do
        local status = self.campaign:campaign_status(unique_pal_id)
        local quote = self.campaign:ransom_quote(unique_pal_id, "local-player")
        if status ~= nil and status.owner ~= nil
            and status.owner.kind == "faction"
            and quote.ok then
            eligible[#eligible + 1] = {
                uniquePalId = unique_pal_id,
                factionId = status.owner.id,
            }
        end
    end
    table.sort(eligible, function(left, right)
        if left.factionId == right.factionId then
            return left.uniquePalId < right.uniquePalId
        end
        return left.factionId < right.factionId
    end)
    local nearest = nil
    local eligible_unique_pal_id = nil
    for _, candidate in ipairs(eligible) do
        local holder = economy:nearest_faction(
            player,
            self.ransomInteractionRadius,
            candidate.factionId
        )
        if holder.ok and (nearest == nil
            or (tonumber(holder.distance) or math.huge)
                < (tonumber(nearest.distance) or math.huge)) then
            nearest = holder
            eligible_unique_pal_id = candidate.uniquePalId
        end
    end
    if nearest == nil or eligible_unique_pal_id == nil then
        show_warning("当前商人没有可供你赎回的唯一帕鲁，或你尚未加入其目标势力。")
        return result(false, "no-nearby-eligible-unique-pal-ransom")
    end
    local offer_id = "pwft.ransom." .. suffix(eligible_unique_pal_id)
        .. ".g" .. tostring(self.worldGeneration)
    local offered = self.bus:offer_ransom(
        eligible_unique_pal_id,
        "local-player",
        offer_id
    )
    if not offered.ok then return offered end
    local opened = economy:interact_nearest(
        player,
        self.ransomInteractionRadius,
        nearest.factionId
    )
    offered.shopOpened = opened.ok == true
    offered.shopReason = opened.reason
    return offered
end

function UniquePalWorldEffectNativeProduction:_bind_ransom_key()
    if self.keyBound then return true end
    if type(_G.RegisterKeyBind) ~= "function"
        or _G.Key == nil or _G.Key[self.ransomInteractionKey] == nil then
        return false
    end
    if self.ransomInteractionRequireControlModifier
        and (_G.ModifierKey == nil
            or _G.ModifierKey.CONTROL == nil) then
        return false
    end
    local callback = function()
        local run = function()
            local outcome = self:request_nearest_ransom()
            self:_log(string.format(
                "RANSOM_INTERACTION ok=%s reason=%s",
                tostring(outcome.ok == true),
                tostring(outcome.reason)
            ))
        end
        if type(_G.ExecuteInGameThread) == "function" then
            _G.ExecuteInGameThread(run)
        else
            run()
        end
    end
    if self.ransomInteractionRequireControlModifier then
        _G.RegisterKeyBind(
            _G.Key[self.ransomInteractionKey],
            { _G.ModifierKey.CONTROL },
            callback
        )
    else
        _G.RegisterKeyBind(
            _G.Key[self.ransomInteractionKey],
            callback
        )
    end
    self.keyBound = true
    return true
end

function UniquePalWorldEffectNativeProduction:activate(definitions)
    if self.enabled ~= true then
        return result(false, "unique-pal-world-effect-production-disabled")
    end
    assert(type(definitions) == "table"
            and type(definitions.provider) == "table"
            and type(definitions.targetBindings) == "table"
            and #definitions.targetBindings > 0
            and type(definitions.nativeDeliveryBindings) == "table",
        "unique-Pal world-effect production bindings are required")
    self.activationGeneration = self.activationGeneration + 1
    self.worldGeneration = self.bus:status().worldGeneration
    self.bindingsByTargetKey = {}
    self.definitionsByUniquePalId = copy(
        definitions.definitionsByUniquePalId or {})
    local provider = copy(definitions.provider)
    provider.providerId = self.providerId
    provider.authoritySource = self.authoritySource
    provider.deliveryKinds = copy(ALL_DELIVERY_KINDS)
    provider.idempotentDeliveryIds = true
    provider.generationFencedCallbacks = true
    local registered = self.bus:register_provider(
        provider,
        function(payload, context)
            return self:_handle_delivery(payload, context)
        end
    )
    if not registered.ok then return registered end
    local bound = 0
    for _, definition in ipairs(definitions.targetBindings) do
        local binding = copy(definition)
        binding.providerId = self.providerId
        binding.buildId = self.buildId
        local activated = self.bus:bind_target(binding)
        if not activated.ok then return activated end
        local target_key = binding.targetKind .. ":" .. binding.targetId
        self.bindingsByTargetKey[target_key] = binding
        bound = bound + 1
    end
    local delivery_bound = 0
    for _, definition in ipairs(definitions.nativeDeliveryBindings) do
        local binding = copy(definition)
        binding.providerId = self.providerId
        binding.worldGeneration = self.worldGeneration
        local activated = self.nativeDeliveryProduction:register(binding)
        if not activated.ok then return activated end
        delivery_bound = delivery_bound + 1
    end
    self.active = true
    self.targetBindingCount = bound
    self.nativeDeliveryBindingCount = delivery_bound
    self.activationCount = self.activationCount + 1
    self:_bind_ransom_key()
    self.bus:retry_pending()
    for unique_pal_id in pairs(self.definitionsByUniquePalId) do
        self:_schedule_war(unique_pal_id)
    end
    self:_log(string.format(
        "ACTIVATED provider=%s targets=%d deliveryBindings=%d generation=%d ransomKey=%s%s",
        self.providerId,
        bound,
        delivery_bound,
        self.worldGeneration,
        self.ransomInteractionRequireControlModifier and "Ctrl+" or "",
        self.ransomInteractionKey
    ))
    return result(true,
        "unique-pal-world-effect-native-production-activated", {
            targetBindingCount = bound,
            nativeDeliveryBindingCount = delivery_bound,
            worldGeneration = self.worldGeneration,
            storyContentIncluded = false,
        })
end

function UniquePalWorldEffectNativeProduction:unbind_world(reason)
    self.active = false
    self.activationGeneration = self.activationGeneration + 1
    self.scheduledWarTokens = {}
    self.queuedDefenseWarIds = {}
    self.defensesByRaidEventId = {}
    self.lastError = reason or "world-unloading"
    return result(true, "unique-pal-world-effect-production-unbound")
end

function UniquePalWorldEffectNativeProduction:status()
    local queued_defenses = #self.queuedDefenseWarIds
    local active_defenses = 0
    for _ in pairs(self.defensesByRaidEventId) do
        active_defenses = active_defenses + 1
    end
    local scheduled_wars = 0
    for _ in pairs(self.scheduledWarTokens) do scheduled_wars = scheduled_wars + 1 end
    return {
        apiVersion = self.version,
        active = self.active,
        buildId = self.buildId,
        providerId = self.providerId,
        authoritySource = self.authoritySource,
        worldGeneration = self.worldGeneration,
        targetBindingCount = self.targetBindingCount,
        nativeDeliveryBindingCount = self.nativeDeliveryBindingCount,
        merchantRuntimesBound = self.merchantRuntimes ~= nil,
        settlementRaidBound = self.settlementRaid ~= nil,
        ransomInteractionKey =
            (self.ransomInteractionRequireControlModifier and "Ctrl+" or "")
            .. self.ransomInteractionKey,
        ransomProductItemId = self.ransomProductItemId,
        scheduledWarCount = scheduled_wars,
        queuedDefenseCount = queued_defenses,
        activeDefenseCount = active_defenses,
        warScheduleCount = self.warScheduleCount,
        warDeclarationCount = self.warDeclarationCount,
        backgroundResolutionCount = self.backgroundResolutionCount,
        playerDefenseRequestCount = self.playerDefenseRequestCount,
        playerDefenseResolutionCount = self.playerDefenseResolutionCount,
        spawnSuppressionCount = self.spawnSuppressionCount,
        cleanupCount = self.cleanupCount,
        emptyCityCount = self.emptyCityCount,
        merchantFilterCount = self.merchantFilterCount,
        ransomOfferCount = self.ransomOfferCount,
        activationCount = self.activationCount,
        lastError = self.lastError,
        storyContentIncluded = false,
        directMapActorDeletion = false,
        PalworldSaveMutation = false,
    }
end

return UniquePalWorldEffectNativeProduction
