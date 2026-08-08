local SourcePath = debug.getinfo(1, "S").source
if string.sub(SourcePath, 1, 1) == "@" then
    SourcePath = string.sub(SourcePath, 2)
end

local ScriptDirectory = string.match(SourcePath, "^(.*)[/\\]") or "."
package.path = table.concat({
    ScriptDirectory .. "/?.lua",
    ScriptDirectory .. "/?/init.lua",
    package.path,
}, ";")

local Config = require("pmo.config")
local Runtime = require("pmo.runtime")

-- Keep callbacks and runtime-only auxiliary state alive for the entire UE4SS
-- mod lifetime.
_G.PAL_MULTI_OTOMO0_STATE = Runtime.start(Config)

