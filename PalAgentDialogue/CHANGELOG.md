# Changelog

## 1.0.1 - Unreleased

- Added `doctor`, `provider-check`, and `run-owned` operator diagnostics.
- Added the content-author SDK character pack used by PalFactionTerritory.
- Hardened the production UE4SS bridge with absolute path validation, atomic
  inbox delivery, Rust-aligned UTF-8 limits, bounded reads, and terminal
  pending/expired/rejected states.
- Added an end-to-end test that submits the current deterministic Core payload,
  reads a strict outbox response, and proves authority fields cannot cross the
  bridge.
- Kept API keys memory-only and local Ollama as the default no-key provider.

## 1.0.0 - 2026-08-07

- Added content-pack-driven multi-NPC runtime.
- Added Ollama and OpenAI-compatible providers.
- Added strict dialogue/choice/tag output validation and fail-closed authority
  boundary.
- Added exact Palworld foreground-process gate.
- Added atomic UE4SS inbox/outbox bridge contract.
- Added persistent, hashed-profile local memory with archival.
- Added mock-provider tests, public schemas, privacy and security documentation.
