package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    "examples/?.lua",
    package.path,
}, ";")

local Registry = require("pwft.registry")
local Progression = require("pwft.faction_progression")
local FactionApi = require("pwft.faction_api")
local ContentPackRegistry = require("pwft.content_pack_registry")
local StrategicWorld = require("pwft.strategic_world")
local EndingRuntime = require("pwft.ending_runtime")
local ContentActionRuntime = require("pwft.content_action_runtime")
local Example = require("minimal-content-pack.pack")

local progression = Progression.create(Registry.progression)
local faction_api = FactionApi.create(progression)
local packs = ContentPackRegistry.create({ coreVersion = "1.0.0" })
assert(packs:register(Example.manifest).ok)
local world = StrategicWorld.create(progression, { contentPackRegistry = packs })
assert(world:register_pack(Example.strategicWorld).ok)
local endings = EndingRuntime.create(progression, world, {
    contentPackRegistry = packs,
})
assert(endings:register_pack(Example.endingRoutes).ok)
local actions = ContentActionRuntime.create(faction_api, world, endings, packs)

local player_id = "player-content-action-spec"
local action_pack = {
    schemaVersion = "pwft.content-actions.pack.v1",
    contentPackId = Example.manifest.contentPackId,
    contentVersion = Example.manifest.contentVersion,
    actions = {
        {
            actionId = "example.minimal.action.task-award",
            kind = "award_task_reputation",
            parameters = {
                factionId = "pwft.faction.rayne_syndicate",
                amount = 12,
            },
            requiresPlayerConfirmation = false,
        },
        {
            actionId = "example.minimal.action.claim-keystone",
            kind = "transfer_unique_pal",
            parameters = {
                uniquePalId = "example.minimal.unique.keystone",
                expectedOwner = { kind = "wild" },
                newOwner = { kind = "player" },
            },
            requiresPlayerConfirmation = true,
        },
        {
            actionId = "example.minimal.action.destroy-city",
            kind = "destroy_city",
            parameters = {
                cityId = "example.minimal.city.primary",
                actor = { kind = "player" },
            },
            requiresPlayerConfirmation = true,
        },
        {
            actionId = "example.minimal.action.ending-flag",
            kind = "set_ending_flag",
            parameters = {
                key = "example.minimal.flag.route.preserve",
                value = true,
            },
            requiresPlayerConfirmation = false,
        },
        {
            actionId = "example.minimal.action.commit-ending",
            kind = "commit_ending_route",
            parameters = {
                routeId = "example.minimal.ending.route.preserve",
            },
            requiresPlayerConfirmation = true,
        },
    },
}

local registered = actions:register_pack(action_pack)
assert(registered.ok and registered.actionCount == 5)
assert(actions:register_pack(action_pack).reason
    == "content-action-pack-already-registered")

local unconfirmed = actions:dispatch(
    "example.minimal.action.claim-keystone",
    "example.minimal.event.claim-unconfirmed",
    {
        sourceKind = "quest-completion",
        sourceId = "example.minimal.quest.instance.one",
        playerConfirmed = false,
        playerId = player_id,
    }
)
assert(not unconfirmed.ok and unconfirmed.reason == "player-confirmation-required")
assert(world:unique_pal_status("example.minimal.unique.keystone").owner.kind == "wild")

local awarded = actions:dispatch(
    "example.minimal.action.task-award",
    "example.minimal.event.task-award",
    {
        sourceKind = "quest-completion",
        sourceId = "example.minimal.quest.instance.one",
        playerConfirmed = true,
        playerId = player_id,
    }
)
assert(awarded.ok and awarded.applied == 12)
local replayed = actions:dispatch(
    "example.minimal.action.task-award",
    "example.minimal.event.task-award",
    {
        sourceKind = "quest-completion",
        sourceId = "example.minimal.quest.instance.one",
        playerConfirmed = true,
        playerId = player_id,
    }
)
assert(replayed.ok and replayed.reason == "content-action-already-dispatched")
assert(faction_api:faction_status("pwft.faction.rayne_syndicate").reputation == 12)
local structured = actions:dispatch_structured_result(
    { contentActionId = "example.minimal.action.ending-flag" },
    "example.minimal.event.structured-result",
    {
        sourceKind = "quest-completion",
        sourceId = "example.minimal.quest.instance.structured",
        playerConfirmed = true,
        playerId = player_id,
    }
)
assert(structured.ok and structured.dispatchedCount == 1)
local conflict = actions:dispatch(
    "example.minimal.action.task-award",
    "example.minimal.event.task-award",
    {
        sourceKind = "native-event",
        sourceId = "example.minimal.native.different",
        playerConfirmed = true,
        playerId = player_id,
    }
)
assert(not conflict.ok and conflict.reason == "content-action-event-id-conflict")

local claimed = actions:dispatch(
    "example.minimal.action.claim-keystone",
    "example.minimal.event.claim-keystone",
    {
        sourceKind = "player-confirmed-choice",
        sourceId = "example.minimal.choice.claim",
        playerConfirmed = true,
        playerId = player_id,
    }
)
assert(claimed.ok and claimed.owner.id == player_id)

local destroyed = actions:dispatch(
    "example.minimal.action.destroy-city",
    "example.minimal.event.destroy-city",
    {
        sourceKind = "player-confirmed-choice",
        sourceId = "example.minimal.choice.destroy",
        playerConfirmed = true,
        playerId = player_id,
    }
)
assert(destroyed.ok and world:city_status(
    "example.minimal.city.primary"
).status == "destroyed")

-- A fresh runtime proves deterministic ending dispatch without sharing the
-- destructive branch above.
local ending_progression = Progression.create(Registry.progression)
local ending_api = FactionApi.create(ending_progression)
local ending_packs = ContentPackRegistry.create({ coreVersion = "1.0.0" })
assert(ending_packs:register(Example.manifest).ok)
local ending_world = StrategicWorld.create(ending_progression, {
    contentPackRegistry = ending_packs,
})
assert(ending_world:register_pack(Example.strategicWorld).ok)
local ending_routes = EndingRuntime.create(ending_progression, ending_world, {
    contentPackRegistry = ending_packs,
})
assert(ending_routes:register_pack(Example.endingRoutes).ok)
local ending_actions = ContentActionRuntime.create(
    ending_api,
    ending_world,
    ending_routes,
    ending_packs
)
assert(ending_actions:register_pack(action_pack).ok)
assert(ending_actions:dispatch(
    "example.minimal.action.claim-keystone",
    "example.minimal.event.ending-claim-keystone",
    {
        sourceKind = "player-confirmed-choice",
        sourceId = "example.minimal.choice.ending-claim",
        playerConfirmed = true,
        playerId = player_id,
    }
).ok)
assert(ending_actions:dispatch(
    "example.minimal.action.ending-flag",
    "example.minimal.event.ending-flag",
    {
        sourceKind = "quest-completion",
        sourceId = "example.minimal.quest.ending",
        playerConfirmed = true,
        playerId = player_id,
    }
).ok)
local committed = ending_actions:dispatch(
    "example.minimal.action.commit-ending",
    "example.minimal.event.commit-ending",
    {
        sourceKind = "player-confirmed-choice",
        sourceId = "example.minimal.choice.ending",
        playerConfirmed = true,
        playerId = player_id,
    }
)
assert(committed.ok and committed.reason == "ending-committed")
assert(ending_routes:post_ending_policy().worldDisposition == "pacified")

local invalid_confirmation = {
    schemaVersion = action_pack.schemaVersion,
    contentPackId = action_pack.contentPackId,
    contentVersion = action_pack.contentVersion,
    actions = {
        {
            actionId = "example.minimal.action.unsafe-destroy",
            kind = "destroy_city",
            parameters = {
                cityId = "example.minimal.city.primary",
                actor = { kind = "player" },
            },
            requiresPlayerConfirmation = false,
        },
    },
}
assert(actions:register_pack(invalid_confirmation).reason
    == "invalid-content-action-pack")

local state_before_rebind = actions.state
assert(progression:restore_snapshot(progression:export_snapshot()).ok)
assert(actions.state ~= state_before_rebind)
assert(actions:status().processedEventCount == 4)

print("PASS registered content actions, confirmation gates, deterministic dispatch, idempotency, and rebind")
