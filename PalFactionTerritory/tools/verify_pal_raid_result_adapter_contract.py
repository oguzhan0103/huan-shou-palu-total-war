from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
EVIDENCE_PATH = (
    PROJECT_ROOT
    / "evidence"
    / "contracts"
    / "pal-raid-result-adapter-build24467282.json"
)
DEFAULT_MANIFEST = Path(r"E:\SteamLibrary\steamapps\appmanifest_1623730.acf")
DEFAULT_GAME_ROOT = Path(r"E:\SteamLibrary\steamapps\common\Palworld")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Verify the offline Build 24467282 Pal raid adapter baseline."
    )
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--game-root", type=Path, default=DEFAULT_GAME_ROOT)
    parser.add_argument(
        "--hash-pak",
        action="store_true",
        help="Also recompute the 40 GB main PAK hash.",
    )
    args = parser.parse_args()

    evidence = json.loads(EVIDENCE_PATH.read_text(encoding="utf-8"))
    expected_build = evidence["gameBuild"]
    manifest_text = args.manifest.read_text(encoding="utf-8")
    build_ids = re.findall(r'"(?:buildid|TargetBuildID)"\s+"(\d+)"', manifest_text)
    require(build_ids == [expected_build, expected_build], "Steam build IDs drifted")

    exe = args.game_root / "Pal" / "Binaries" / "Win64" / "Palworld-Win64-Shipping.exe"
    pak = args.game_root / "Pal" / "Content" / "Paks" / "Pal-Windows.pak"
    object_dump = (
        args.game_root
        / "Pal"
        / "Binaries"
        / "Win64"
        / "ue4ss"
        / "UE4SS_ObjectDump.txt"
    )
    require(exe.stat().st_size == evidence["steam"]["shippingExe"]["length"], "shipping EXE length drifted")
    require(sha256(exe) == evidence["steam"]["shippingExe"]["sha256"], "shipping EXE hash drifted")
    require(pak.stat().st_size == evidence["steam"]["mainPak"]["length"], "main PAK length drifted")
    if args.hash_pak:
        require(sha256(pak) == evidence["steam"]["mainPak"]["sha256"], "main PAK hash drifted")

    executable_bytes = exe.read_bytes()
    missing_binary_names = [
        name
        for name in evidence["shippingExecutableNameEvidence"]
        if name.encode("ascii") not in executable_bytes
    ]
    require(not missing_binary_names, f"shipping EXE names missing: {missing_binary_names}")

    for asset in evidence["currentPakAssets"]:
        path = PROJECT_ROOT / Path(asset["path"])
        require(path.is_file(), f"extracted current-build asset missing: {path}")
        require(path.stat().st_size == asset["length"], f"asset length drifted: {path}")
        require(sha256(path) == asset["sha256"], f"asset hash drifted: {path}")

    blueprint = evidence["blueprintEvidence"]
    base_text = (PROJECT_ROOT / blueprint["baseJson"]).read_text(encoding="utf-8")
    enemy_text = (PROJECT_ROOT / blueprint["enemyJson"]).read_text(encoding="utf-8")
    for name in blueprint["baseFunctions"]:
        require(f'"{name}"' in base_text, f"base Blueprint function missing: {name}")
    for name in blueprint["enemyNamesAndImports"]:
        require(f'"{name}"' in enemy_text, f"enemy Blueprint name/import missing: {name}")
    require(
        f'"{blueprint["onCharacterSpawnedParameter"]}"' in base_text,
        "OnCharacterSpawned parameter evidence missing",
    )

    stale = evidence["staleReflectionBoundary"]
    require(sha256(object_dump) == stale["sha256"], "recorded ObjectDump changed; recapture its provenance")
    require(object_dump.stat().st_mtime < exe.stat().st_mtime, "ObjectDump is no longer older than the current EXE")
    require(stale["acceptedAsCurrentRuntimeProof"] is False, "stale ObjectDump cannot be accepted as current proof")

    config_text = (
        PROJECT_ROOT
        / "mod0"
        / "ue4ss"
        / "PalFactionTerritory0"
        / "Scripts"
        / "pwft"
        / "config.lua"
    ).read_text(encoding="utf-8")
    require(f'expectedSteamBuildId = "{expected_build}"' in config_text, "runtime build gate drifted")
    require("normalizedRaidAdapterEnabled = true" in config_text, "normalized adapter is not enabled")
    require("nativeRaidResultBindingEnabled = false" in config_text, "native binding must remain disabled")

    pak_mode = "hash" if args.hash_pak else "metadata-only"
    print(
        "PASS Build 24467282 Pal raid adapter offline contract "
        f"(EXE hash; PAK {pak_mode}; current assets; stale ObjectDump rejected; native binding disabled)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
