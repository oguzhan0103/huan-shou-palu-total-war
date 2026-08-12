local SourcePath = debug.getinfo(1, "S").source
if string.sub(SourcePath, 1, 1) == "@" then
    SourcePath = string.sub(SourcePath, 2)
end

local ScriptDirectory = string.match(SourcePath, "^(.*)[/\\]") or "."
local ModDirectory =
    string.match(ScriptDirectory, "^(.*)[/\\]Scripts$")
assert(
    ModDirectory ~= nil and ModDirectory ~= "",
    "PalFactionTerritory0 Mod directory could not be derived"
)
package.path = table.concat({
    ScriptDirectory .. "/?.lua",
    ScriptDirectory .. "/?/init.lua",
    package.path,
}, ";")

local Config = require("pwft.config")
local Registry = require("pwft.registry")
local Policy = require("pwft.policy")
local Runtime = require("pwft.runtime")

-- State remains entirely Mod-owned. The shipped State directory is beside
-- Scripts, never under Palworld's SaveGames. Runtime activates the external
-- ledger only after it has resolved a stable world/player identity.
Config.factionProgression.persistence.rootPath =
    ModDirectory .. "/State"
Config.palReconciliation.agentBridge.rootPath =
    ModDirectory .. "/State/AgentDialogue"
Config.palReconciliation.agentBridge.operatorInputPath =
    ModDirectory .. "/State/pwft-agent-operator-input-v1.json"
Config.palReconciliation.agentBridge.operatorStatusPath =
    ModDirectory .. "/State/pwft-agent-operator-status-v1.json"

-- Keep the runtime state reachable for the entire Lua mod lifetime. UE4SS's
-- callback garbage collector may release hooks whose Lua closures are no
-- longer reachable after main.lua finishes executing.
_G.PWFT_RUNTIME_STATE = Runtime.start(Config, Registry, Policy)
