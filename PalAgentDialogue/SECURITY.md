# Security policy

## Supported version

Security fixes are provided for the latest tagged release.

## Reporting

Report vulnerabilities privately to the repository maintainers. Do not include
API keys, save files, private dialogue logs, crash dumps, or other users' data in
a public issue.

## Security invariants

- The exact foreground executable is `Palworld-Win64-Shipping.exe`.
- There is no production foreground-gate bypass flag.
- Model output is strict JSON with unknown fields denied.
- Choices and result tags must be pre-authorized by deterministic Core and the
  loaded character pack.
- The model cannot write affinity, task, inventory, currency, reward, save,
  combat, faction, ownership, or world-state fields.
- API keys exist only in process memory and are redacted from debug output.
- Provider URLs must be HTTP(S), may not contain credentials, and remote Ollama
  requires explicit opt-in.
- Raw model failures are not persisted.
- Request and provider response sizes are bounded.

Treat character packs as untrusted distribution artifacts. Review their
license, persona text, and localization content before installation. A pack may
influence dialogue but cannot expand the output schema or authority boundary.

