-- Copy this directory into PalFactionTerritory0/Scripts, then add
-- "minimal-content-pack.content_module" to config.contentModules.modules.
-- The loader validates and commits the whole bundle atomically.
return {
    bundle = require("minimal-content-pack.bundle"),
    activate = function(context)
        if type(context) ~= "table"
            or type(context.rewardDeliveryBus) ~= "table" then
            return {
                ok = false,
                reason = "reward-delivery-bus-unavailable",
            }
        end
        -- This is technical sample data, not a base-game reward choice.  A
        -- real content pack replaces both the channel namespace and native
        -- item ID. Registration is idempotent because activate() is replayed
        -- after every map load to rebuild generation-scoped native bindings.
        return context.rewardDeliveryBus:register_channel({
            schemaVersion = "pwft.reward-delivery-channel.v1",
            channelId = "example.minimal.reward.channel.quest",
            providerId = "pwft.native.reward-item.production",
            rewardKind = "item",
            nativeItemId = "StainlessSteel",
            maximumUnitsPerDelivery = 2,
        })
    end,
}
