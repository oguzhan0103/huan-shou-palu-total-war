PalFactionTerritory0 Mod-owned state directory.

After the read-only native identity probe resolves a stable world/player key,
the runtime writes versioned pwft-progression-v1-world-*.player-*.json files,
their atomic backups, and pwft-companion state/event files here. This directory
is not part of Palworld SaveGames and never replaces or edits a .sav file.
