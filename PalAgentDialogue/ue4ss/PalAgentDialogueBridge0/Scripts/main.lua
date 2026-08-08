local bridge_module = require("pad.bridge")

local bridge_root = os.getenv("PAL_AGENT_BRIDGE_ROOT")
if type(bridge_root) ~= "string" or bridge_root == "" then
    _G.PAL_AGENT_DIALOGUE_BRIDGE_V1 = {
        ready = false,
        reason = "PAL_AGENT_BRIDGE_ROOT is not configured",
    }
    print("[PalAgentDialogueBridge0] disabled: PAL_AGENT_BRIDGE_ROOT is not configured")
    return
end

local ok, bridge = pcall(bridge_module.create, { root = bridge_root })
if not ok then
    _G.PAL_AGENT_DIALOGUE_BRIDGE_V1 = {
        ready = false,
        reason = "bridge initialization failed",
    }
    print("[PalAgentDialogueBridge0] disabled: bridge initialization failed")
    return
end

_G.PAL_AGENT_DIALOGUE_BRIDGE_V1 = bridge
print("[PalAgentDialogueBridge0] ready api=1.0.0 authority=presentation-and-proposals-only")
