use std::fs;

use mlua::{Lua, Table, Value};

#[test]
fn ue4ss_lua_adapter_round_trips_real_inbox_and_outbox_files() {
    let project_root = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let temporary = tempfile::tempdir().expect("temporary bridge root");
    let bridge_root = temporary.path();
    fs::create_dir_all(bridge_root.join("inbox")).expect("inbox");
    fs::create_dir_all(bridge_root.join("outbox")).expect("outbox");

    let lua = Lua::new();
    let globals = lua.globals();
    globals
        .set(
            "PAL_AGENT_TEST_PROJECT_ROOT",
            project_root.to_string_lossy().replace('\\', "/"),
        )
        .expect("project-root global");
    globals
        .set(
            "PAL_AGENT_TEST_BRIDGE_ROOT",
            bridge_root.to_string_lossy().replace('\\', "/"),
        )
        .expect("bridge-root global");

    let package: Table = globals.get("package").expect("Lua package table");
    let loaded: Table = package.get("loaded").expect("Lua loaded-module table");
    let json_source =
        fs::read_to_string(project_root.join("ue4ss/PalAgentDialogueBridge0/Scripts/pad/json.lua"))
            .expect("read Lua JSON module");
    let json_module: Value = lua
        .load(&json_source)
        .set_name("pad/json.lua")
        .eval()
        .expect("load Lua JSON module");
    loaded
        .set("pad.json", json_module)
        .expect("register Lua JSON module");
    let bridge_source = fs::read_to_string(
        project_root.join("ue4ss/PalAgentDialogueBridge0/Scripts/pad/bridge.lua"),
    )
    .expect("read Lua bridge module");
    let bridge_module: Value = lua
        .load(&bridge_source)
        .set_name("pad/bridge.lua")
        .eval()
        .expect("load Lua bridge module");
    loaded
        .set("pad.bridge", bridge_module)
        .expect("register Lua bridge module");

    let test_script = fs::read_to_string(project_root.join("ue4ss/tests/bridge_spec.lua"))
        .expect("read Lua bridge spec");
    lua.load(&test_script)
        .set_name("ue4ss/tests/bridge_spec.lua")
        .exec()
        .expect("Lua bridge spec");

    assert!(bridge_root.join("inbox/lua-e2e-1.json").is_file());
    assert!(bridge_root.join("outbox/lua-e2e-1.json").is_file());
}
