from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
CONTRACT_PATH = PROJECT_ROOT / "contracts" / "unique_pal_native_assets.v1.json"
EVIDENCE_PATH = (
    PROJECT_ROOT
    / "evidence"
    / "contracts"
    / "unique-pal-native-assets-build24575825.json"
)
MAPPED_PARAMETER_PATH = (
    PROJECT_ROOT / "evidence" / "asset_json" / "DT_PalMonsterParameter.mapped.json"
)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def verify_catalog(contract: dict, evidence: dict) -> None:
    require(contract["schemaVersion"] == "1.0.0", "catalog schema drifted")
    require(evidence["schemaVersion"] == "1.0.0", "evidence schema drifted")
    require(
        contract["PalworldBuildId"] == evidence["steamBuildId"] == "24575825",
        "catalog/evidence Build ID mismatch",
    )
    require(MAPPED_PARAMETER_PATH.exists(), "mapped parameter source is missing")
    mapped_parameter_hash = hashlib.sha256(MAPPED_PARAMETER_PATH.read_bytes()).hexdigest().upper()
    require(
        mapped_parameter_hash == evidence["source"]["mappedParameterJsonSha256"],
        "mapped parameter source hash drifted",
    )
    policy = contract["activationPolicy"]
    require(policy["nativeSpawnEnabledByCatalog"] is False, "catalog cannot spawn")
    require(
        policy["irreversibleWorldEffectsEnabledByCatalog"] is False,
        "catalog cannot enable irreversible world effects",
    )
    require(
        policy["assetPresenceIsNotLiveBindingEvidence"] is True,
        "asset inventory must not be treated as a live binding",
    )

    entries = contract["confirmedEntries"]
    require(len(entries) == 5, "exactly five user-confirmed native entries expected")
    expected = {
        "PinkCat": ("BOSS_PinkCat", "pwft.faction.rayne_syndicate"),
        "Anubis": ("Boss_Anubis", "pwft.faction.pidf"),
        "WeaselDragon": ("BOSS_WeaselDragon", "pwft.faction.free_pal_alliance"),
        "BlackMetalDragon": ("BOSS_BlackMetalDragon", "pwft.faction.eternal_pyre"),
        "Ronin": ("BOSS_Ronin", "pwft.island.sakurajima"),
    }
    parameter_rows = {row["rowId"]: row for row in evidence["parameterRows"]}
    evidence_asset_paths = {entry["path"] for entry in evidence["assetEntries"]}
    candidate_spawner_paths: set[str] = set()
    for entry in entries:
        species_id = entry["speciesId"]
        require(species_id in expected, f"unexpected species mapping: {species_id}")
        row_id, target_id = expected[species_id]
        boss = entry["nativeBoss"]
        require(entry["target"]["id"] == target_id, f"target drifted: {species_id}")
        require(boss["parameterRowId"] == row_id, f"Boss row drifted: {species_id}")
        require(boss["nativeBossAvailable"] is True, f"native Boss lost: {species_id}")
        require(boss["route"] == "native-existing", f"route drifted: {species_id}")
        require(
            boss["bindingStatus"].startswith("pending-"),
            f"unverified Boss binding was enabled: {species_id}",
        )
        candidates = boss["candidateSpawners"]
        require(len(candidates) > 0, f"spawner candidate missing: {species_id}")
        for candidate in candidates:
            path = candidate["pakAssetPath"]
            require(
                path in evidence_asset_paths,
                f"spawner candidate lacks current-PAK evidence: {species_id} -> {path}",
            )
            candidate_spawner_paths.add(path)
        row = parameter_rows[row_id]
        require(
            row["speciesId"] == species_id
            and row["isBoss"] is True
            and row["useBossHpGauge"] is True,
            f"parameter evidence mismatch: {species_id}",
        )

    tentative = contract["tentativeEntries"]
    require(len(tentative) == 1, "one tentative Feybreak entry expected")
    require(
        tentative[0]["displayNameZhHans"] == "空涡龙"
        and tentative[0]["speciesId"] is None
        and tentative[0]["target"]["id"] == "pwft.island.feybreak",
        "Feybreak entry must remain tentative and unbound",
    )
    conclusion = evidence["conclusion"]
    require(
        conclusion["confirmedNativeBossParameterRows"] == 5
        and conclusion["confirmedNativeBossActorAssets"] == 5
        and conclusion["confirmedCandidateSpawnerAssets"]
        == len(candidate_spawner_paths)
        and conclusion["replacementSlotRequiredForConfirmedFive"] is False
        and conclusion["liveSpawnerBindingsConfirmed"] == 0
        and conclusion["activationAllowed"] is False,
        "native asset conclusion or fail-closed boundary drifted",
    )


def verify_installed_pak(evidence: dict, pak: Path, repak: Path) -> None:
    pak = pak.resolve(strict=True)
    repak = repak.resolve(strict=True)
    for entry in evidence["assetEntries"]:
        completed = subprocess.run(
            [str(repak), "get", str(pak), entry["path"]],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        data = completed.stdout
        require(len(data) == entry["bytes"], f"asset size drifted: {entry['path']}")
        digest = hashlib.sha256(data).hexdigest().upper()
        require(digest == entry["sha256"], f"asset hash drifted: {entry['path']}")
        for value in entry.get("containsAsciiNames", []):
            require(value.encode("ascii") in data, f"asset name missing: {entry['path']} -> {value}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Verify the fail-closed unique-Pal native asset catalog."
    )
    parser.add_argument("--pak", type=Path, help="Optional installed Pal-Windows.pak")
    parser.add_argument("--repak", type=Path, help="repak v0.2.3 executable")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    contract = load_json(CONTRACT_PATH)
    evidence = load_json(EVIDENCE_PATH)
    verify_catalog(contract, evidence)
    if args.pak is not None or args.repak is not None:
        require(args.pak is not None and args.repak is not None, "--pak and --repak are required together")
        verify_installed_pak(evidence, args.pak, args.repak)
        print(f"PASS current installed PAK asset hashes: {len(evidence['assetEntries'])} entries")
    print("PASS unique-Pal native asset catalog: 5 confirmed, 1 tentative, 0 live bindings")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
