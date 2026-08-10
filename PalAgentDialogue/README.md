# PalAgentDialogue

PalAgentDialogue is an external, content-pack-driven multi-NPC Agent runtime for
Palworld mods. It supports local Ollama servers and OpenAI-compatible chat
endpoints without injecting a model into the game process or giving a model
authority over game state.

This repository contains no official Palworld story, character dialogue, game
asset, save file, model weight, API key, or Pocketpair code. It is an
independent community project and is not affiliated with or endorsed by
Pocketpair.

## Safety boundary

The model can return only:

- `dialogue`: text to present to the player;
- `proposedChoice`: `null` or one choice ID whitelisted by deterministic Core;
- `resultTags`: a subset of tags whitelisted by deterministic Core.

Strict deserialization rejects unknown fields. A response that tries to return
`affinityDelta`, quest completion, inventory changes, rewards, save data, or any
other authority field is rejected and moved to the bridge `failed/` directory.
The deterministic Mod Core remains the sole authority for affinity, tasks,
items, commerce, factions, combat consequences, and world state.

The inbox is consumed only while the exact foreground process is
`Palworld-Win64-Shipping.exe`. The observer asks Windows only for the foreground
window owner's executable path. It does not read process memory, inject code,
start the game, or read/write Palworld saves.

## Character packs

Characters and plot context are replaceable JSON content packs. A character
must use either:

- `contentOrigin: "localization_keys_only"` with `personaKey` and no inline
  persona; or
- `contentOrigin: "user_authored"` with text the pack author has the right to
  distribute.

The included pack is deliberately fictional and contains keys only:
[`character-packs/example-minimal.json`](character-packs/example-minimal.json).
The runtime does not ship official character biographies or story text.

Validate a pack:

```powershell
cargo run -- validate-pack .\character-packs\example-minimal.json
```

## Providers

Ollama is the default and is restricted to loopback unless the operator
explicitly sets `PAL_AGENT_ALLOW_REMOTE_OLLAMA=1`:

```powershell
$env:PAL_AGENT_PROVIDER = 'ollama'
$env:PAL_AGENT_MODEL = 'qwen3:8b'
$env:PAL_AGENT_OLLAMA_BASE_URL = 'http://127.0.0.1:11434'
```

OpenAI-compatible mode reads its key from the current process environment:

```powershell
$env:PAL_AGENT_PROVIDER = 'openai-compatible'
$env:PAL_AGENT_MODEL = 'your-model'
$env:PAL_AGENT_OPENAI_BASE_URL = 'https://your-compatible-endpoint.example/v1'
$env:PAL_AGENT_OPENAI_API_KEY = '<set-in-session-only>'
```

The key is held in memory, redacted from `Debug`, omitted from bridge and memory
documents, and never written to settings. The runtime deliberately has no
`.env` loader. See [PRIVACY.md](PRIVACY.md) and [SECURITY.md](SECURITY.md).

## UE4SS file bridge

Create a bridge root anywhere outside the game save directory. The runtime
creates:

```text
bridge-data/
  inbox/       UE4SS writes one request JSON here
  processing/  atomically claimed requests
  outbox/      validated responses for deterministic Core
  failed/      failed request plus sanitized error report
  archive/     processed requests
  memory/      local per-character, per-world, per-player memory
```

Run continuously:

```powershell
cargo run --release -- run `
  .\character-packs\example-minimal.json `
  .\bridge-data
```

Process at most one request:

```powershell
cargo run -- process-once `
  .\character-packs\example-minimal.json `
  .\bridge-data
```

`process-once` still enforces the real foreground-process gate. Mock tests inject
a test gate; the production CLI has no bypass flag.

The wire contract is documented in [contracts/PROTOCOL.md](contracts/PROTOCOL.md)
and machine-readable JSON Schemas live beside it.

### Minimal UE4SS adapter

The public adapter is packaged at:

```text
ue4ss/PalAgentDialogueBridge0/
  enabled.txt
  Scripts/main.lua
  Scripts/pad/json.lua
  Scripts/pad/bridge.lua
```

Set `PAL_AGENT_BRIDGE_ROOT` to the same bridge root used by the Rust runtime,
then install `PalAgentDialogueBridge0` as a normal UE4SS Mod. It exports
`_G.PAL_AGENT_DIALOGUE_BRIDGE_V1` with only three methods:

- `submit_request(request)` atomically writes a schema-checked inbox request;
- `poll_response(authorization)` reads an outbox response and rechecks exact
  fields plus choice/tag authorization;
- `status()` reports the presentation-only authority boundary.

The adapter has no state-mutation method. `poll_response` returns only
`dialogue`, `proposedChoice`, and `resultTags`; deterministic Core decides how
to display them and whether a proposal has any effect. If the environment
variable is absent, the UE4SS module stays disabled and exports a fail-closed
status instead of guessing a game/save path.

## Long-term local memory

Validated turns persist across runtime restarts. Profile filenames are SHA-256
hashes of pack, character, world, and player keys, so those identifiers are not
exposed in filenames. The model sees only the 20 most recent turns. When an
active profile exceeds 2,000 turns, the oldest 1,000 are moved into an archive
file rather than silently deleted.

Memory contains dialogue text and can therefore be sensitive. It remains local,
is not uploaded except as prompt context to the provider selected by the user,
and can be removed by deleting the chosen bridge root while the runtime is
stopped.

## Build and test

Requirements: Rust 1.85 or newer.

```powershell
cargo fmt --all -- --check
cargo test --all-targets
cargo build --release
& .\scripts\test-ue4ss-bridge.ps1
& .\scripts\build-release.ps1
```

Tests cover pack validation, exact process-name matching, API-key redaction,
endpoint safety, strict model output, authority-field rejection, choice/tag
allowlists, foreground gating, idempotent delivery, file output, and memory
persistence. The Lua bridge test executes the exact packaged Lua modules inside
a vendored Lua 5.4 test host and performs a real inbox/outbox filesystem round
trip, including rejection of authority fields and unauthorized proposals.

## Integration status

The external runtime, file protocol, and minimal UE4SS adapter are implemented
and testable with a mock provider. `PalFactionTerritory0` now contains a Core
controller that submits and polls this adapter, independently revalidates the
response, falls back to the authored offline tree, and requires player
confirmation before a proposed choice reaches deterministic state. It also
contains a backend-neutral presentation and representative-proximity router.
The cooked/native dialogue Widget and NPC interaction delegate are still not
connected or accepted in game. Offline tests do not claim live UI or game
integration acceptance.
