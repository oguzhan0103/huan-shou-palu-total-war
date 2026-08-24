local Manifest = require("pwft_b7_unique_pals.manifest")

local HUMAN_FACTIONS = {
    "pwft.faction.rayne_syndicate",
    "pwft.faction.free_pal_alliance",
    "pwft.faction.eternal_pyre",
    "pwft.faction.pidf",
    "pwft.faction.pal_genetic_research_unit",
    "pwft.faction.moonflower",
    "pwft.faction.feybreak_army",
}

local function candidates(excluded)
    local values = {}
    for _, faction_id in ipairs(HUMAN_FACTIONS) do
        if faction_id ~= excluded then values[#values + 1] = faction_id end
    end
    return values
end

local function definition(id, species_id, target_kind, target_id,
    affected_factions)
    return {
        id = id,
        target = {
            kind = target_kind,
            id = target_id,
            affectedFactionIds = affected_factions,
        },
        boss = {
            speciesId = species_id,
            nativeBossAvailable = true,
            bindingStatus = "bound",
            strengthProfile = "raid-slab",
        },
        -- One logical tick is one production minute. The real release opens
        -- a window after 60-120 minutes, warns five minutes in advance and
        -- leaves the capturable Boss active for twenty minutes. QA can force
        -- the same state transitions without changing these release values.
        schedule = {
            minimumIntervalTicks = 60,
            maximumIntervalTicks = 120,
            noticeTicks = 5,
            openTicks = 20,
        },
        ransomPrice = 100000000,
        candidateFactionIds = candidates(
            target_kind == "faction" and target_id or nil
        ),
    }
end

return {
    schemaVersion = "pwft.unique-pal-campaign.pack.v1",
    contentPackId = Manifest.contentPackId,
    contentVersion = Manifest.contentVersion,
    uniquePals = {
        definition(
            "pwft.unique.pinkcat",
            "PinkCat",
            "faction",
            "pwft.faction.rayne_syndicate",
            { "pwft.faction.rayne_syndicate" }
        ),
        definition(
            "pwft.unique.anubis",
            "Anubis",
            "faction",
            "pwft.faction.pidf",
            { "pwft.faction.pidf" }
        ),
        definition(
            "pwft.unique.weasel_dragon",
            "WeaselDragon",
            "faction",
            "pwft.faction.free_pal_alliance",
            { "pwft.faction.free_pal_alliance" }
        ),
        definition(
            "pwft.unique.black_metal_dragon",
            "BlackMetalDragon",
            "faction",
            "pwft.faction.eternal_pyre",
            { "pwft.faction.eternal_pyre" }
        ),
        definition(
            "pwft.unique.ronin",
            "Ronin",
            "strategic-target",
            "pwft.island.sakurajima",
            -- The destruction target remains Sakurajima itself. Moonflower
            -- is listed only as the human faction whose residents and
            -- Merchant Guild counter are affected by that island-state.
            { "pwft.faction.moonflower" }
        ),
    },
}
