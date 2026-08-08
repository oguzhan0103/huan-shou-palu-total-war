return {
    schemaVersion = "0.2.0",
    expectedSteamBuildId = "24467282",
    addHotkey = "F6",
    recallAllHotkey = "F7",

    -- Party slots are zero-based in Palworld. Index 1 is the player's second
    -- party slot and is preferred for the first two-Pal prototype.
    preferredAuxiliarySlotIndex = 1,
    maxPartySlots = 5,
    maxAuxiliaryCount = 4,

    -- Spawn the auxiliary slightly behind and to the right of the player so
    -- it does not overlap the trainer or the primary Pal.
    spawnOffsetForward = -120.0,
    spawnOffsetRight = 280.0,
    spawnOffsetUp = 40.0,
    formationOffsets = {
        { forward = -120.0, right = 280.0, up = 40.0 },
        { forward = -120.0, right = -280.0, up = 40.0 },
        { forward = -380.0, right = 190.0, up = 40.0 },
        { forward = -380.0, right = -190.0, up = 40.0 },
    },

    -- This flag is the key to keeping Palworld's existing primary Otomo ID
    -- unchanged while a second party handle is activated.
    keepPrimaryActiveOtomoId = true,

    -- Inactivate immediately. Delayed reserve handling belongs to the native
    -- ball-return presentation and is unnecessary for this prototype.
    delayedReserveOnRecall = false,
    recallSpacingMs = 250,
    verificationDelayMs = 900,
}
