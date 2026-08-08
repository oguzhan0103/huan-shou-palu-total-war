$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $PSScriptRoot
Push-Location $ProjectRoot
try {
    & cargo test --locked --test lua_bridge -- --nocapture
    if ($LASTEXITCODE -ne 0) {
        throw "UE4SS Lua bridge test failed"
    }
}
finally {
    Pop-Location
}
