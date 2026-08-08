package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local Registry = require("pwft.registry")
local FactionApi = require("pwft.faction_api")
local FactionJoin = require("pwft.faction_join")
local FactionProgression =
    require("pwft.faction_progression")

local progression =
    FactionProgression.create(Registry.progression)
local api = FactionApi.create(progression)
local join = FactionJoin.create(
    api,
    Registry.progression.membershipPolicy
        .joinInteraction
)

local rayne = "pwft.faction.rayne_syndicate"
local free_pal =
    "pwft.faction.free_pal_alliance"
local pal_tribe =
    "pwft.faction.desert_pal_tribe"
local rayne_source =
    "pwft.join.source.rayne_syndicate"
local free_pal_source =
    "pwft.join.source.free_pal_alliance"

assert(join.capabilities.registeredSourcesOnly)
assert(join.capabilities.explicitConfirmation)
assert(join.capabilities.diplomacyPreview)
assert(join.capabilities.authoredDialogue == false)
assert(
    join:register_source(
        "pwft.join.source.invalid-pal",
        pal_tribe
    ).reason
        == "human-faction-source-required"
)
assert(
    join:register_source(
        rayne_source,
        rayne
    ).ok
)
assert(
    join:register_source(
        free_pal_source,
        free_pal
    ).ok
)
assert(
    join:register_source(
        rayne_source,
        free_pal
    ).reason
        == "join-source-conflict"
)

local presented_offers = 0
local presented_resolutions = 0
assert(join:register_presenter({
    native = false,
    present_offer = function(_, offer)
        presented_offers = presented_offers + 1
        assert(offer.explicitConfirmationRequired)
        return "presented"
    end,
    present_resolution = function(_, resolution)
        presented_resolutions =
            presented_resolutions + 1
        return resolution.joined
    end,
}).ok)

local rayne_offer = join:offer(
    rayne_source,
    "local-player",
    "request-rayne-001"
)
assert(rayne_offer.ok)
assert(rayne_offer.reason == "join-offer-ready")
assert(rayne_offer.dialogueContentIncluded == false)
assert(rayne_offer.preview.reason == "join-available")
assert(#rayne_offer.preview.diplomacyChanges == 1)
assert(
    rayne_offer.preview.diplomacyChanges[1]
        .factionId
        == free_pal
)
assert(
    rayne_offer.preview.diplomacyChanges[1]
        .after
        == "Hostile"
)
assert(presented_offers == 1)
local duplicate_offer = join:offer(
    rayne_source,
    "local-player",
    "request-rayne-001"
)
assert(
    duplicate_offer.reason
        == "join-offer-already-created"
)
assert(presented_offers == 1)

local declined_offer = join:offer(
    free_pal_source,
    "local-player",
    "request-free-pal-decline"
)
assert(declined_offer.ok)
local declined = join:confirm(
    declined_offer.offerId,
    "confirm-free-pal-decline",
    false
)
assert(declined.ok)
assert(declined.reason == "join-declined")
assert(api:faction_status(free_pal).joined == false)

local joined = join:confirm(
    rayne_offer.offerId,
    "confirm-rayne-001",
    true
)
assert(joined.ok)
assert(joined.reason == "join-confirmed")
assert(joined.joined)
assert(api:faction_status(rayne).joined)
assert(api:faction_status(free_pal).relation == "Hostile")
assert(presented_resolutions == 2)
local duplicate_confirm = join:confirm(
    rayne_offer.offerId,
    "confirm-rayne-001",
    true
)
assert(
    duplicate_confirm.reason
        == "join-confirmation-already-processed"
)
assert(progression:status().eventCount == 1)

local blocked = join:offer(
    free_pal_source,
    "local-player",
    "request-free-pal-blocked"
)
assert(blocked.ok == false)
assert(blocked.reason == "join-unavailable")
assert(
    blocked.eligibilityReason
        == "diplomacy-hostility-unresolved"
)
assert(
    blocked.preview.diplomacyHostilitySources[1]
        == rayne
)

local stale_progression =
    FactionProgression.create(Registry.progression)
local stale_api =
    FactionApi.create(stale_progression)
local stale_join = FactionJoin.create(
    stale_api,
    Registry.progression.membershipPolicy
        .joinInteraction
)
assert(
    stale_join:register_source(
        rayne_source,
        rayne
    ).ok
)
assert(
    stale_join:register_source(
        free_pal_source,
        free_pal
    ).ok
)
local stale_offer = stale_join:offer(
    free_pal_source,
    "local-player",
    "request-stale-001"
)
assert(stale_offer.ok)
assert(
    stale_api:join_human(
        rayne,
        "external-rayne-join"
    ).ok
)
local stale_resolution = stale_join:confirm(
    stale_offer.offerId,
    "confirm-stale-001",
    true
)
assert(stale_resolution.ok == false)
assert(stale_resolution.reason == "join-offer-stale")
assert(
    stale_resolution.eligibilityReason
        == "diplomacy-hostility-unresolved"
)
assert(stale_api:faction_status(free_pal).joined == false)

local status = join:status()
assert(status.sourceCount == 2)
assert(status.pendingOfferCount == 0)
assert(status.resolvedOfferCount == 2)
assert(status.presenterReady)
assert(status.nativePresenter == false)

print(
    "PASS registered faction join offers, explicit confirmation, diplomacy preview, and stale guards"
)
