# UE4SS File Bridge Protocol v1

The bridge is a transport boundary, not an authority transfer. UE4SS or another
deterministic adapter writes requests to `inbox/`; PalAgentDialogue writes only
validated dialogue proposals to `outbox/`.

## Producer rules

1. Create the request in a temporary file outside `inbox/`.
2. Flush and close it.
3. Atomically rename it into `inbox/<requestId>.json`.
4. Use a unique portable `requestId` and never reuse it for different content.
5. Whitelist choices, context keys, and result tags from the loaded character
   pack. Do not send secrets or raw save data.

Maximum request size is 256 KiB.

Example request:

```json
{
  "schemaVersion": "1.0.0",
  "requestId": "meeting-0001-turn-0001",
  "createdAt": "2026-08-07T12:00:00Z",
  "characterId": "example_guide",
  "sessionId": "meeting-0001",
  "worldKey": "locally-derived-stable-world-key",
  "playerKey": "locally-derived-stable-player-key",
  "locale": "zh-CN",
  "playerText": "我们继续谈吧。",
  "contextKeys": ["example.guide.met_player"],
  "allowedChoices": [
    {"choiceId": "continue", "textKey": "example.choice.continue"}
  ],
  "allowedResultTags": ["heard_player"]
}
```

## Consumer rules

The deterministic Core watches `outbox/<requestId>.json`, verifies the same
schema and current session, then decides how to display or interpret the
proposal. It must not treat a tag as proof that an event happened.

Example response:

```json
{
  "schemaVersion": "1.0.0",
  "requestId": "meeting-0001-turn-0001",
  "createdAt": "2026-08-07T12:00:02Z",
  "characterId": "example_guide",
  "provider": "ollama",
  "dialogue": "我听见了。我们可以继续。",
  "proposedChoice": "continue",
  "resultTags": ["heard_player"]
}
```

The response schema has `additionalProperties: false`. There is deliberately no
field for affinity, task, item, currency, reward, save, combat, ownership,
faction, or world-state mutation.

## Failure and retry

- A successful request is moved to `archive/` after its outbox response and
  local memory are written.
- A duplicate request whose outbox response already exists is archived without
  contacting the provider.
- Invalid requests and rejected model replies move to `failed/` with a sanitized
  error report. Raw model output is never written.
- Provider/network errors are marked retryable, but the adapter decides whether
  to create a new request ID and retry.
- Requests remain untouched in `inbox/` while Palworld is not the foreground
  process.

