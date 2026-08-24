return {
    {
        bindingId = "pwft.native.NPC-attitude.rayne-merchant",
        factionId = "pwft.faction.rayne_syndicate",
        actorRole = "faction-special-merchant",
        allowedActorClassTokens = {
            "BP_NPC_DarkTrader_C",
            "BP_NPC_DarkTrader_BOSS_C",
        },
        -- This exact actor already uses the same safe policy: peaceful
        -- relations suspend its aggressive Dark Trader AI; hostile-to-
        -- peaceful changes respawn the actor to clear native hate safely.
        peacefulAiPolicy = "suspend",
    },
}
