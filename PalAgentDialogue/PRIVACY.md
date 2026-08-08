# Privacy

PalAgentDialogue is local-first, but dialogue itself can contain personal or
sensitive information.

## Stored locally

The selected bridge root stores request archives, validated responses, failed
requests, sanitized failure reports, and per-profile dialogue memory. Memory
profile filenames are hashes; the JSON content still includes player dialogue,
NPC dialogue, session IDs, choices, and result tags.

The runtime does not read Palworld saves, process memory, browser data, Steam
credentials, or unrelated files.

## Sent to a provider

Each model request includes the selected character-pack data, current player
text, permitted context keys, permitted choices/tags, and up to 20 recent local
turns for that profile.

- Ollama defaults to `127.0.0.1`.
- An OpenAI-compatible URL may be remote. Its operator's privacy policy then
  applies.
- Remote Ollama is blocked by default.

## API keys

OpenAI-compatible API keys are read only from `PAL_AGENT_OPENAI_API_KEY` in the
current process environment. They are not accepted on the command line, loaded
from `.env`, serialized, logged, or included in error reports.

## Deletion and retention

Stop the runtime and delete the bridge root you selected to remove all local
requests, responses, archives, and memory. The project does not maintain a
cloud account or remote deletion endpoint.

