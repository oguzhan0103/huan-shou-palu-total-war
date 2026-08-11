-- Copy this directory into PalFactionTerritory0/Scripts, then add
-- "minimal-content-pack.content_module" to config.contentModules.modules.
-- The loader validates and commits the whole bundle atomically.
return {
    bundle = require("minimal-content-pack.bundle"),
}
