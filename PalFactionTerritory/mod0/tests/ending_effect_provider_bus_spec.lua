package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local Registry = require("pwft.registry")
local Progression = require("pwft.faction_progression")
local StrategicWorld = require("pwft.strategic_world")
local EndingRuntime = require("pwft.ending_runtime")
local EndingEffectProviderBus = require("pwft.ending_effect_provider_bus")

local rayne = "pwft.faction.rayne_syndicate"
local world_pack = {
    schemaVersion = "pwft.strategic-world.pack.v1",
    contentPackId = "spec.ending.provider.world",
    contentVersion = "1.0.0",
    uniquePals = {{
        id = "spec.ending.provider.unique-pal",
        speciesId = "SheepBall",
        displayNameKey = "spec.loc.unique-pal.name",
        initialOwner = { kind = "wild" },
    }},
    cities = {{
        id = "spec.ending.provider.city",
        factionId = rayne,
        displayNameKey = "spec.loc.city.name",
        requiredUniquePalId = "spec.ending.provider.unique-pal",
        restorable = true,
    }},
}
local ending_pack = {
    schemaVersion = "pwft.ending-routes.pack.v1",
    contentPackId = "spec.ending.provider.routes",
    contentVersion = "1.0.0",
    routes = {{
        id = "spec.ending.provider.route",
        displayNameKey = "spec.loc.ending.name",
        priority = 100,
        conditions = {{
            kind = "flag_equals",
            key = "spec.ending.provider.ready",
            value = true,
        }},
        effects = {
            { kind = "set_title", titleKey = "spec.loc.ending.title" },
            { kind = "set_world_disposition", value = "pacified" },
            {
                kind = "set_faction_disposition",
                factionId = rayne,
                value = "non_hostile_until_attacked",
            },
            {
                kind = "city_transition",
                cityId = "spec.ending.provider.city",
                status = "active",
                ownerFactionId = rayne,
            },
            { kind = "set_flag", key = "spec.ending.provider.postgame", value = true },
        },
    }},
}

local progression = Progression.create(Registry.progression)
local world = StrategicWorld.create(progression)
assert(world:register_pack(world_pack).ok)
local endings = EndingRuntime.create(progression, world)
assert(endings:register_pack(ending_pack).ok)
assert(endings:set_flag(
    "spec.ending.provider.ready",
    true,
    "spec.ending.provider.ready.operation"
).ok)

local bus = EndingEffectProviderBus.create(endings)
local available = bus:available_preview()
assert(available.ok and available.readOnly == true)
assert(available.routes[1].id == "spec.ending.provider.route")
assert(available.routes[1].ready == true)

local preview = bus:preview(
    "spec.ending.provider.route",
    "spec.ending.preview.1",
    { requesterKind = "model", requesterId = "local-ollama" }
)
assert(preview.ok and preview.ready)
assert(preview.explicitConfirmationRequired == true)
assert(bus:preview(
    "spec.ending.provider.route",
    "spec.ending.preview.1",
    { requesterKind = "player", requesterId = "player-1" }
).reason == "ending-preview-id-conflict")
assert(bus:confirm(
    "spec.ending.preview.1",
    "spec.ending.confirmation.model",
    { authorityKind = "model", explicitConfirmed = true, playerId = "player-1" }
).reason == "model-has-no-ending-confirmation-authority")

local confirmed = bus:confirm(
    "spec.ending.preview.1",
    "spec.ending.confirmation.1",
    { authorityKind = "player", explicitConfirmed = true, playerId = "player-1" }
)
assert(confirmed.ok and confirmed.reason == "ending-explicitly-confirmed")
local second_preview = bus:preview(
    "spec.ending.provider.route",
    "spec.ending.preview.2",
    { requesterKind = "player", requesterId = "player-1" }
)
assert(second_preview.ok)
local second_confirmation = bus:confirm(
    "spec.ending.preview.2",
    "spec.ending.confirmation.2",
    { authorityKind = "player", explicitConfirmed = true, playerId = "player-1" }
)
assert(second_confirmation.ok)
assert(bus:confirm(
    "spec.ending.preview.2",
    "spec.ending.confirmation.1",
    { authorityKind = "player", explicitConfirmed = true, playerId = "player-1" }
).reason == "ending-confirmation-id-conflict")
assert(bus:commit(
    "spec.ending.confirmation.1",
    "spec.ending.commit.model",
    { authorityKind = "model", playerId = "player-1" }
).reason == "model-has-no-ending-commit-authority")

local calls = {}
local fail_world_once = true
local provider_definition = {
    providerId = "spec.ending.effects.provider",
    effectKinds = {
        "set_title",
        "set_world_disposition",
        "set_faction_disposition",
        "city_transition",
    },
    idempotentDeliveryIds = true,
    readOnlyInput = true,
}
local function provider(output, context)
    calls[#calls + 1] = {
        deliveryId = output.deliveryId,
        kind = output.kind,
        readOnly = output.readOnly,
        scopeKind = context.scopeKind,
    }
    if output.kind == "set_world_disposition" and fail_world_once then
        fail_world_once = false
        return {
            ok = false,
            applied = false,
            deliveryId = output.deliveryId,
            reason = "injected-provider-failure",
        }
    end
    return {
        ok = true,
        applied = true,
        deliveryId = output.deliveryId,
        reason = "applied-by-spec-provider",
    }
end
assert(bus:register_provider(provider_definition, provider).ok)
assert(bus:register_provider({
    providerId = "spec.ending.invalid.provider",
    effectKinds = { "set_flag" },
    idempotentDeliveryIds = true,
    readOnlyInput = true,
}, provider).reason == "invalid-ending-effect-provider")
assert(bus:register_provider({
    providerId = "spec.ending.conflicting.provider",
    effectKinds = { "set_title" },
    idempotentDeliveryIds = true,
    readOnlyInput = true,
}, provider).reason == "ending-effect-kind-provider-conflict")

local first_commit = bus:commit(
    "spec.ending.confirmation.1",
    "spec.ending.commit.1",
    { authorityKind = "player", playerId = "player-1" }
)
assert(first_commit.ok == false)
assert(first_commit.reason == "ending-committed-effects-pending")
assert(first_commit.coreCommitted == true)
assert(first_commit.outputCount == 4)
assert(first_commit.appliedCount == 3)
assert(first_commit.pendingCount == 1)
assert(first_commit.retryable == true)
assert(endings:post_ending_policy().completed == true)
assert(endings.state.flags["spec.ending.provider.postgame"] == true)
assert(bus:commit(
    "spec.ending.confirmation.2",
    "spec.ending.commit.1",
    { authorityKind = "player", playerId = "player-1" }
).reason == "ending-commit-operation-id-conflict")

local retried = bus:commit(
    "spec.ending.confirmation.1",
    "spec.ending.commit.1",
    { authorityKind = "player", playerId = "player-1" }
)
assert(retried.ok)
assert(retried.reason == "ending-committed-effects-applied")
assert(retried.pendingCount == 0 and retried.appliedCount == 4)
local duplicate = bus:commit(
    "spec.ending.confirmation.1",
    "spec.ending.commit.1",
    { authorityKind = "player", playerId = "player-1" }
)
assert(duplicate.ok and duplicate.reason == "duplicate-ending-commit")
assert(duplicate.idempotent == true)

local snapshot = bus:export_snapshot()
assert(snapshot.handlers == nil)
local restored = EndingEffectProviderBus.create(endings, { snapshot = snapshot })
assert(restored:status().providerCount == 1)
assert(restored:status().activeProviderHandlerCount == 0)
assert(restored:status().handlersPersisted == false)

local missing_provider_replay = restored:replay_world_load(
    "spec.ending.world-load.1"
)
assert(missing_provider_replay.ok == false)
assert(missing_provider_replay.reason == "ending-world-replay-pending")
assert(missing_provider_replay.pendingCount == 4)

local replay_calls = {}
assert(restored:register_provider(
    provider_definition,
    function(output, context)
        replay_calls[#replay_calls + 1] = {
            deliveryId = output.deliveryId,
            kind = output.kind,
            scopeKind = context.scopeKind,
        }
        return {
            ok = true,
            applied = true,
            deliveryId = output.deliveryId,
            reason = "replayed-by-spec-provider",
        }
    end
).reason == "ending-effect-provider-rebound")
local replayed = restored:replay_world_load("spec.ending.world-load.1")
assert(replayed.ok and replayed.reason == "ending-world-replay-applied")
assert(replayed.appliedCount == 4 and replayed.pendingCount == 0)
assert(#replay_calls == 4)
local duplicate_replay = restored:replay_world_load("spec.ending.world-load.1")
assert(duplicate_replay.ok)
assert(duplicate_replay.reason == "duplicate-ending-world-replay")
assert(#replay_calls == 4)

local restored_snapshot = restored:export_snapshot()
assert(restored_snapshot.handlers == nil)
assert(restored_snapshot.providers[1].providerId
    == "spec.ending.effects.provider")
local status = restored:status()
assert(status.pendingDeliveryCount == 0)
assert(status.modelCommitAuthority == false)
assert(status.directUEMutation == false)
assert(status.PalworldSaveMutation == false)

for _, call in ipairs(calls) do assert(call.readOnly == true) end
print("PASS ending provider bus previews availability, requires player confirmation, retries honest failures, replays world load, and never grants model commit authority")
