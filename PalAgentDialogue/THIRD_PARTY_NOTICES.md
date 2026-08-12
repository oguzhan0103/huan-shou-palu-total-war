# Third-party notices

PalAgentDialogue first-party source is MIT licensed. `Cargo.lock` pins Rust
dependency versions and checksums; those dependencies remain under their own
licenses. Before distributing a compiled sidecar, the distributor must generate
and review an SBOM plus a dependency-license report from the exact locked graph.
The public GitHub package is source-only and does not bundle the compiled Rust
binary or vendored dependency source.

The architecture was generalized from the project's own MIT-licensed external
NPC runtime work. No character-specific story, generated output, game asset,
voice asset, `node_modules`, `dist`, or compiled target directory was copied.

Palworld and related names and assets are trademarks or copyrighted works of
their respective owners. This project includes no Palworld game asset or code
and is not affiliated with Pocketpair.

UE4SS is an optional integration dependency installed separately by the user.
It is not bundled in this repository or runtime.
