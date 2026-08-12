local FactionEconomyMerchantPresence = {}

local API_VERSION = "1.0.0"

local function result(ok, reason, extra)
    local value = extra or {}
    value.ok = ok
    value.reason = reason
    return value
end

local function distance_squared(left, right)
    local dx = (left.X or 0) - (right.X or 0)
    local dy = (left.Y or 0) - (right.Y or 0)
    local dz = (left.Z or 0) - (right.Z or 0)
    return dx * dx + dy * dy + dz * dz
end

local function copy_location(value)
    return {
        X = tonumber(value.X) or 0,
        Y = tonumber(value.Y) or 0,
        Z = tonumber(value.Z) or 0,
    }
end

local function copy_rotation(value)
    return {
        Pitch = tonumber(value.Pitch) or 0,
        Yaw = tonumber(value.Yaw) or 0,
        Roll = tonumber(value.Roll) or 0,
    }
end

function FactionEconomyMerchantPresence.create(
    merchant_runtime,
    commerce_contract,
    config
)
    assert(type(merchant_runtime) == "table", "merchant runtime is required")
    assert(type(merchant_runtime.status) == "function", "merchant status is required")
    assert(type(merchant_runtime.activate_market) == "function", "market activation is required")
    assert(type(merchant_runtime.deactivate_market) == "function", "market deactivation is required")
    assert(type(commerce_contract) == "table", "commerce contract is required")
    assert(type(commerce_contract.merchantIsland) == "table", "merchant island is required")
    assert(type(config) == "table", "merchant presence config is required")
    assert(type(config.enabled) == "boolean", "merchant presence enabled flag is required")
    assert(type(config.activationRadius) == "number" and config.activationRadius > 0,
        "merchant activation radius must be positive")
    assert(type(config.deactivationRadius) == "number"
            and config.deactivationRadius > config.activationRadius,
        "merchant deactivation radius must exceed activation radius")
    assert(type(config.pollIntervalMs) == "number" and config.pollIntervalMs >= 250,
        "merchant presence poll interval is invalid")

    local island = commerce_contract.merchantIsland
    assert(type(island.rootLocation) == "table", "accepted market root location is required")
    assert(type(island.rootRotation) == "table", "accepted market root rotation is required")

    return setmetatable({
        version = API_VERSION,
        merchantRuntime = merchant_runtime,
        enabled = config.enabled == true,
        acceptedRootLocation = copy_location(island.rootLocation),
        acceptedRootRotation = copy_rotation(island.rootRotation),
        rootLocation = copy_location(island.rootLocation),
        rootRotation = copy_rotation(island.rootRotation),
        activationRadius = config.activationRadius,
        deactivationRadius = config.deactivationRadius,
        pollIntervalMs = config.pollIntervalMs,
        generation = 0,
        worldLoadCount = 0,
        activationAttemptCount = 0,
        deactivationAttemptCount = 0,
        tickCount = 0,
        lastDistance = nil,
        lastReason = "waiting-for-world",
    }, { __index = FactionEconomyMerchantPresence })
end

function FactionEconomyMerchantPresence:on_world_loaded(source)
    self.generation = self.generation + 1
    self.worldLoadCount = self.worldLoadCount + 1
    -- Failed or callback-only adapter records are not reflected by the market's
    -- active/pending counters. Always clear world-scoped routing on a load so a
    -- stale failed record cannot block the same faction in the next UWorld.
    self.deactivationAttemptCount = self.deactivationAttemptCount + 1
    local removed = self.merchantRuntime:deactivate_market(
        "merchant-presence-world-reload"
    )
    -- World origin rebasing can change between map loads.  Never reuse a live
    -- FTPoint90 transform from the previous world while the new partition is
    -- still loading; start from the accepted persistent-map contract and let
    -- runtime.lua resolve the current world's live transform again.
    self.rootLocation = copy_location(self.acceptedRootLocation)
    self.rootRotation = copy_rotation(self.acceptedRootRotation)
    self.liveRootSource = nil
    self.lastDistance = nil
    self.lastReason = "world-loaded"
    return result(true, "merchant-presence-world-loaded", {
        source = source or "unknown",
        generation = self.generation,
        removed = removed,
    })
end

function FactionEconomyMerchantPresence:on_world_unloading(source)
    -- Fence every scheduled poll before UWorld teardown starts. The runtime's
    -- world-reload branch changes Lua-owned state only and deliberately leaves
    -- destruction of actors to the outgoing UWorld.
    self.generation = self.generation + 1
    self.deactivationAttemptCount = self.deactivationAttemptCount + 1
    local removed = self.merchantRuntime:deactivate_market(
        "merchant-presence-world-reload"
    )
    self.lastDistance = nil
    self.lastReason = "world-unloading"
    return result(removed ~= nil and removed.ok == true,
        "merchant-presence-world-unloading", {
        source = source or "unknown",
        generation = self.generation,
        removed = removed,
    })
end

function FactionEconomyMerchantPresence:tick(player_location)
    self.tickCount = self.tickCount + 1
    if not self.enabled then
        self.lastReason = "merchant-presence-disabled"
        return result(false, self.lastReason)
    end
    if type(player_location) ~= "table" then
        self.lastReason = "local-player-unavailable"
        return result(false, self.lastReason)
    end

    local distance = math.sqrt(distance_squared(
        player_location,
        self.rootLocation
    ))
    self.lastDistance = distance
    local runtime_status = self.merchantRuntime:status()
    local present = runtime_status.activeCount > 0
        or runtime_status.pendingCount > 0

    if distance <= self.activationRadius then
        if present then
            self.lastReason = "merchant-market-already-present"
            return result(true, self.lastReason, {
                distance = distance,
                transitioned = false,
            })
        end
        self.activationAttemptCount = self.activationAttemptCount + 1
        local activated = self.merchantRuntime:activate_market(
            self.rootLocation,
            self.rootRotation
        )
        self.lastReason = activated.reason
        activated.distance = distance
        activated.transitioned = activated.ok == true
        return activated
    end

    if distance >= self.deactivationRadius and present then
        self.deactivationAttemptCount = self.deactivationAttemptCount + 1
        local removed = self.merchantRuntime:deactivate_market(
            "merchant-presence-player-departed"
        )
        self.lastReason = removed.reason
        removed.distance = distance
        removed.transitioned = removed.ok == true
        return removed
    end

    self.lastReason = present
        and "merchant-market-retained"
        or "merchant-market-out-of-range"
    return result(true, self.lastReason, {
        distance = distance,
        transitioned = false,
    })
end

function FactionEconomyMerchantPresence:set_live_root(location, rotation, source)
    if type(location) ~= "table" then
        return result(false, "merchant-presence-live-root-location-invalid")
    end
    local x = tonumber(location.X)
    local y = tonumber(location.Y)
    local z = tonumber(location.Z)
    if x == nil or y == nil or z == nil then
        return result(false, "merchant-presence-live-root-coordinates-invalid")
    end
    self.rootLocation = { X = x, Y = y, Z = z }
    if type(rotation) == "table" then
        self.rootRotation = {
            Pitch = tonumber(rotation.Pitch) or 0,
            Yaw = tonumber(rotation.Yaw) or self.rootRotation.Yaw or 0,
            Roll = tonumber(rotation.Roll) or 0,
        }
    end
    self.liveRootSource = source or "unknown"
    return result(true, "merchant-presence-live-root-updated", {
        rootLocation = self.rootLocation,
        rootRotation = self.rootRotation,
        source = self.liveRootSource,
    })
end

function FactionEconomyMerchantPresence:status()
    local runtime_status = self.merchantRuntime:status()
    return {
        version = self.version,
        enabled = self.enabled,
        generation = self.generation,
        worldLoadCount = self.worldLoadCount,
        activationRadius = self.activationRadius,
        deactivationRadius = self.deactivationRadius,
        pollIntervalMs = self.pollIntervalMs,
        lastDistance = self.lastDistance,
        lastReason = self.lastReason,
        activationAttemptCount = self.activationAttemptCount,
        deactivationAttemptCount = self.deactivationAttemptCount,
        tickCount = self.tickCount,
        liveRootSource = self.liveRootSource,
        activeCount = runtime_status.activeCount,
        pendingCount = runtime_status.pendingCount,
    }
end

return FactionEconomyMerchantPresence
