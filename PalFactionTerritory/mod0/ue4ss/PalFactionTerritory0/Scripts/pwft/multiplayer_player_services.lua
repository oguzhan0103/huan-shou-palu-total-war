local ProgressionIdentity = require("pwft.progression_identity")

local MultiplayerPlayerServices = {}

local API_VERSION = "1.0.0"

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

local function count(values)
    local total = 0
    for _ in pairs(values or {}) do total = total + 1 end
    return total
end

local function valid_context(context)
    return type(context) == "table"
        and type(context.rewardDeliveryBus) == "table"
        and type(context.rewardDeliveryBus.register_channel) == "function"
        and type(context.rewardDeliveryBus.settle) == "function"
        and type(context.rewardDeliveryBus.bind_world) == "function"
        and type(context.rewardDeliveryBus.unbind_world) == "function"
        and type(context.palReconciliation) == "table"
        and type(context.palReconciliation.register_content) == "function"
end

function MultiplayerPlayerServices.create()
    return setmetatable({
        version = API_VERSION,
        worldGeneration = nil,
        contextsByPlayer = {},
        rewardChannelsById = {},
        palContentByFaction = {},
        attachedCount = 0,
        detachedCount = 0,
        rewardSettlementCount = 0,
        rejectedCount = 0,
        lastError = nil,
        capabilities = {
            exactPlayerUidRouting = true,
            perPlayerRewardLedger = true,
            perPlayerPalReconciliation = true,
            lateJoinContentReplay = true,
            serverAuthorityRequiredByDownstreamServices = true,
            modelAuthority = false,
            directPalworldSaveMutation = false,
            UObjectPersistence = false,
        },
    }, { __index = MultiplayerPlayerServices })
end

function MultiplayerPlayerServices:bind_world(world_generation)
    if type(world_generation) ~= "number" or world_generation < 1
        or world_generation ~= math.floor(world_generation) then
        return result(false,
            "multiplayer-player-services-generation-invalid")
    end
    if self.worldGeneration ~= nil
        and self.worldGeneration ~= world_generation then
        self:unbind_world("multiplayer-player-services-world-rebound")
    end
    self.worldGeneration = world_generation
    return result(true, "multiplayer-player-services-world-bound", {
        worldGeneration = world_generation,
    })
end

function MultiplayerPlayerServices:_replay_context(context)
    local bound = context.rewardDeliveryBus:bind_world(
        self.worldGeneration)
    if type(bound) ~= "table" or bound.ok ~= true then
        return result(false,
            "multiplayer-player-reward-world-bind-failed", {
                downstreamReason = type(bound) == "table"
                        and bound.reason
                    or "invalid-result",
            })
    end
    for channel_id, definition in pairs(self.rewardChannelsById) do
        local registered = context.rewardDeliveryBus
            :register_channel(copy(definition))
        if type(registered) ~= "table" or registered.ok ~= true then
            return result(false,
                "multiplayer-player-reward-channel-replay-failed", {
                    channelId = channel_id,
                    downstreamReason = type(registered) == "table"
                            and registered.reason
                        or "invalid-result",
                })
        end
    end
    for faction_id, content in pairs(self.palContentByFaction) do
        local registered = context.palReconciliation
            :register_content(faction_id, copy(content))
        if type(registered) ~= "table" or registered.ok ~= true then
            return result(false,
                "multiplayer-player-pal-content-replay-failed", {
                    factionId = faction_id,
                    downstreamReason = type(registered) == "table"
                            and registered.reason
                        or "invalid-result",
                })
        end
    end
    return result(true, "multiplayer-player-context-replayed")
end

function MultiplayerPlayerServices:attach_context(context)
    if self.worldGeneration == nil then
        return result(false,
            "multiplayer-player-services-world-not-bound")
    end
    if not valid_context(context) then
        self.rejectedCount = self.rejectedCount + 1
        return result(false,
            "multiplayer-player-service-context-incomplete")
    end
    local player_uid = ProgressionIdentity.normalize_guid(
        context.playerUid
            or (context.identity and context.identity.playerUid))
    if player_uid == nil then
        self.rejectedCount = self.rejectedCount + 1
        return result(false,
            "multiplayer-player-service-uid-invalid")
    end
    local replayed = self:_replay_context(context)
    if not replayed.ok then
        self.rejectedCount = self.rejectedCount + 1
        self.lastError = replayed.reason
        return replayed
    end
    local existing = self.contextsByPlayer[player_uid]
    self.contextsByPlayer[player_uid] = context
    if existing == nil then self.attachedCount = self.attachedCount + 1 end
    return result(true, existing
            and "multiplayer-player-service-context-rebound"
            or "multiplayer-player-service-context-attached", {
        playerUid = player_uid,
        idempotent = existing == context,
    })
end

function MultiplayerPlayerServices:detach_context(player_uid, reason)
    local normalized = ProgressionIdentity.normalize_guid(player_uid)
    if normalized == nil then
        return result(false,
            "multiplayer-player-service-uid-invalid")
    end
    local context = self.contextsByPlayer[normalized]
    if context == nil then
        return result(true,
            "multiplayer-player-service-context-already-detached", {
                removed = false,
            })
    end
    context.rewardDeliveryBus:unbind_world(
        reason or "multiplayer-player-service-context-detached")
    self.contextsByPlayer[normalized] = nil
    self.detachedCount = self.detachedCount + 1
    return result(true,
        "multiplayer-player-service-context-detached", {
            playerUid = normalized,
            removed = true,
        })
end

function MultiplayerPlayerServices:register_reward_channel(definition)
    if type(definition) ~= "table"
        or type(definition.channelId) ~= "string"
        or definition.channelId == "" then
        self.rejectedCount = self.rejectedCount + 1
        return result(false,
            "multiplayer-reward-channel-definition-invalid")
    end
    local failures = {}
    for player_uid, context in pairs(self.contextsByPlayer) do
        local registered = context.rewardDeliveryBus
            :register_channel(copy(definition))
        if type(registered) ~= "table" or registered.ok ~= true then
            failures[#failures + 1] = player_uid
        end
    end
    if #failures > 0 then
        self.rejectedCount = self.rejectedCount + 1
        self.lastError = "multiplayer-reward-channel-broadcast-failed"
        table.sort(failures)
        return result(false, self.lastError, {
            failedPlayerIds = failures,
            partial = true,
        })
    end
    self.rewardChannelsById[definition.channelId] = copy(definition)
    return result(true, "multiplayer-reward-channel-registered", {
        channelId = definition.channelId,
        playerContextCount = count(self.contextsByPlayer),
    })
end

function MultiplayerPlayerServices:register_pal_content(
    faction_id,
    content
)
    if type(faction_id) ~= "string" or faction_id == ""
        or type(content) ~= "table" then
        self.rejectedCount = self.rejectedCount + 1
        return result(false,
            "multiplayer-pal-content-definition-invalid")
    end
    local failures = {}
    for player_uid, context in pairs(self.contextsByPlayer) do
        local registered = context.palReconciliation
            :register_content(faction_id, copy(content))
        if type(registered) ~= "table" or registered.ok ~= true then
            failures[#failures + 1] = player_uid
        end
    end
    if #failures > 0 then
        self.rejectedCount = self.rejectedCount + 1
        self.lastError = "multiplayer-pal-content-broadcast-failed"
        table.sort(failures)
        return result(false, self.lastError, {
            failedPlayerIds = failures,
            partial = true,
        })
    end
    self.palContentByFaction[faction_id] = copy(content)
    return result(true, "multiplayer-pal-content-registered", {
        factionId = faction_id,
        playerContextCount = count(self.contextsByPlayer),
    })
end

function MultiplayerPlayerServices:settle_reward(
    player_uid,
    input,
    options
)
    local normalized = ProgressionIdentity.normalize_guid(player_uid)
    if normalized == nil then
        self.rejectedCount = self.rejectedCount + 1
        return result(false,
            "multiplayer-reward-player-uid-invalid")
    end
    local context = self.contextsByPlayer[normalized]
    if context == nil then
        self.rejectedCount = self.rejectedCount + 1
        return result(false,
            "multiplayer-reward-player-context-unavailable")
    end
    local settled = context.rewardDeliveryBus:settle(
        copy(input), copy(options or {}))
    if type(settled) ~= "table" then
        self.rejectedCount = self.rejectedCount + 1
        return result(false,
            "multiplayer-reward-settlement-invalid")
    end
    if settled.ok == true then
        self.rewardSettlementCount = self.rewardSettlementCount + 1
    else
        self.rejectedCount = self.rejectedCount + 1
    end
    settled.playerUid = normalized
    return settled
end

function MultiplayerPlayerServices:unbind_world(reason)
    local previous = self.worldGeneration
    local failures = {}
    for player_uid, context in pairs(self.contextsByPlayer) do
        local unbound = context.rewardDeliveryBus:unbind_world(
            reason or "multiplayer-player-services-world-unloading")
        if type(unbound) ~= "table" or unbound.ok ~= true then
            failures[#failures + 1] = player_uid
        end
    end
    self.contextsByPlayer = {}
    self.worldGeneration = nil
    table.sort(failures)
    return result(#failures == 0,
        #failures == 0
            and "multiplayer-player-services-world-unbound"
            or "multiplayer-player-services-world-unbind-partial", {
            previousWorldGeneration = previous,
            failedPlayerIds = failures,
        })
end

function MultiplayerPlayerServices:status()
    return {
        apiVersion = self.version,
        worldGeneration = self.worldGeneration,
        playerContextCount = count(self.contextsByPlayer),
        rewardChannelCount = count(self.rewardChannelsById),
        palContentCount = count(self.palContentByFaction),
        attachedCount = self.attachedCount,
        detachedCount = self.detachedCount,
        rewardSettlementCount = self.rewardSettlementCount,
        rejectedCount = self.rejectedCount,
        lastError = self.lastError,
        capabilities = copy(self.capabilities),
    }
end

return MultiplayerPlayerServices
