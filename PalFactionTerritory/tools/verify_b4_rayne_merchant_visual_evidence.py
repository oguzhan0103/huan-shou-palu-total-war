from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_EVIDENCE = (
    PROJECT_ROOT
    / "evidence"
    / "live-tests"
    / "build24575825-20260823-b4-rayne-merchant-visual"
    / "verification.json"
)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def jpeg_dimensions(path: Path) -> tuple[int, int]:
    data = path.read_bytes()
    require(data[:2] == b"\xff\xd8", f"not a JPEG: {path.name}")
    cursor = 2
    sof_markers = {0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF}
    while cursor + 4 <= len(data):
        while cursor < len(data) and data[cursor] != 0xFF:
            cursor += 1
        while cursor < len(data) and data[cursor] == 0xFF:
            cursor += 1
        require(cursor < len(data), f"truncated JPEG marker: {path.name}")
        marker = data[cursor]
        cursor += 1
        if marker in {0x01, 0xD8, 0xD9}:
            continue
        require(cursor + 2 <= len(data), f"truncated JPEG segment: {path.name}")
        length = int.from_bytes(data[cursor : cursor + 2], "big")
        require(length >= 2 and cursor + length <= len(data), f"invalid JPEG segment: {path.name}")
        if marker in sof_markers:
            require(length >= 7, f"invalid JPEG SOF segment: {path.name}")
            height = int.from_bytes(data[cursor + 3 : cursor + 5], "big")
            width = int.from_bytes(data[cursor + 5 : cursor + 7], "big")
            return width, height
        cursor += length
    raise AssertionError(f"JPEG dimensions not found: {path.name}")


def verify_file(base: Path, item: dict[str, Any], *, jpeg: bool = False) -> None:
    path = base / item["file"]
    require(path.is_file(), f"missing evidence file: {item['file']}")
    require(path.stat().st_size == item["bytes"], f"file size drifted: {item['file']}")
    require(sha256(path) == item["sha256"], f"file hash drifted: {item['file']}")
    if jpeg:
        require(jpeg_dimensions(path) == (item["width"], item["height"]), f"image dimensions drifted: {item['file']}")


def verify_text_file(base: Path, item: dict[str, Any]) -> Path:
    path = base / item["file"]
    require(path.is_file(), f"missing evidence file: {item['file']}")
    normalized = path.read_text(encoding="utf-8").replace("\r\n", "\n").replace("\r", "\n").encode("utf-8")
    require(len(normalized) == item["normalizedBytes"], f"normalized text size drifted: {item['file']}")
    require(hashlib.sha256(normalized).hexdigest() == item["normalizedSha256"], f"normalized text hash drifted: {item['file']}")
    return path


def verify(evidence: dict[str, Any], evidence_path: Path) -> None:
    require(evidence["schemaVersion"] == "1.0.0", "unsupported evidence schema")
    require(evidence["result"] == "PASS", "B4 evidence is not PASS")
    require(evidence["gameBuild"] == "24575825", "game build drifted")
    require(evidence["acceptanceGate"] == "b4-rayne-merchant-friendly-hostile-friendly", "wrong acceptance gate")

    base = evidence_path.parent
    visuals = evidence["visualEvidence"]
    for key in ("friendlyShop", "hostileAttack", "hostileDefeat", "friendlyRecovered"):
        verify_file(base, visuals[key], jpeg=True)
        require(visuals[key]["bytes"] >= 250_000, f"visual evidence is unexpectedly small: {key}")

    require(visuals["friendlyShop"]["nativeShopVisible"] is True, "friendly native shop was not visible")
    require(visuals["hostileAttack"]["redHostilityVisible"] is True, "hostile state was not visible")
    require(visuals["friendlyRecovered"]["singleMerchantVisible"] is True, "final single merchant was not visible")

    catalog = evidence["catalog"]
    require(catalog["shopRow"] == "PFT_Rayne_AllPaldex", "shop row drifted")
    require(catalog["uniquePaldexEntryCount"] == 288, "full Paldex catalog count drifted")

    runtime = evidence["cleanRoundTrip"]
    require(runtime["initialRelation"] == "Friendly", "wrong initial relation")
    require(runtime["hostileRelation"] == "Hostile", "hostile leg missing")
    require(runtime["finalRelation"] == "Friendly", "friendly recovery missing")
    require(runtime["allMerchantActorsFromNativeSpawner"] is True, "merchant actor ownership was not native-spawner-only")
    require(runtime["nearbyScanActorBindings"] == 0, "nearby actor fallback was used")
    require(runtime["hostileInteractionEnabled"] is False, "hostile merchant remained interactable")
    require(runtime["hostileAiActive"] is True and runtime["hostileBattleMode"] is True, "hostile AI policy failed")
    require(runtime["friendlyInteractionEnabled"] is True, "friendly merchant was not interactable")
    require(runtime["friendlyAiActive"] is False and runtime["friendlyBattleMode"] is False, "friendly AI policy failed")
    require(runtime["friendlyInteractionRouteDispatched"] is True, "friendly shop interaction route was not dispatched")
    require(runtime["palworldSaveWrites"] == 0, "live QA mutated the Palworld save through the mod")

    excerpt = evidence["publicLogExcerpt"]
    excerpt_path = verify_text_file(base, excerpt)
    lines = excerpt_path.read_text(encoding="utf-8").splitlines()
    require(len(lines) == 16, "public log excerpt line count drifted")
    sequence = [
        "NATIVE_SPAWNER_CREATED count=1",
        "RELATION_INTERACTION_POLICY relation=Friendly",
        "NATIVE_MERCHANT_READY actor=BP_NPC_DarkTrader_C actorSource=spawner-handle",
        "DESTROYED reason=relation-change-Hostile",
        "previous=Friendly relation=Hostile revision=15 saveWrites=0",
        "NATIVE_SPAWNER_CREATED count=4",
        "RELATION_INTERACTION_POLICY relation=Hostile hostile=true interactEnabled=false aiActive=true battleMode=true",
        "NATIVE_MERCHANT_READY actor=BP_NPC_DarkTrader_BOSS_C actorSource=spawner-handle",
        "SHOP_ACCESS_BLOCKED relation=Hostile",
        "HOSTILE_TARGET_ADDED",
        "DESTROYED reason=relation-change-Friendly",
        "previous=Hostile relation=Friendly revision=16 saveWrites=0",
        "NATIVE_SPAWNER_CREATED count=5",
        "RELATION_INTERACTION_POLICY relation=Friendly hostile=false interactEnabled=true aiActive=false battleMode=false",
        "NATIVE_MERCHANT_READY actor=BP_NPC_DarkTrader_BOSS_C actorSource=spawner-handle",
        "ECONOMY_MERCHANT_INTERACTION_ROUTED ok=true reason=rayne-native-pal-shop-dispatched",
    ]
    require(all(token in line for token, line in zip(sequence, lines, strict=True)), "round-trip log sequence drifted")
    require(all("actorSource=nearby-scan" not in line for line in lines), "nearby-scan binding leaked into clean run")

    restore = evidence["restore"]
    require(restore["result"] == "PASS" and restore["gameRunning"] is False, "environment restore failed")
    require(restore["saveFiles"] == 384 and restore["saveDiffCount"] == 0, "SaveGames restore drifted")
    require(restore["ue4ssSnapshotFiles"] == 176, "UE4SS snapshot count drifted")
    require(restore["ue4ssSnapshotDiffCountBeforeFormalDeploy"] == 0, "UE4SS restore drifted")
    require(restore["assetModPakFiles"] == 2 and restore["logicModPakFiles"] == 1, "PAK count drifted")
    require(restore["pakDiffCount"] == 0, "PAK restore drifted")
    require(restore["appManifestRestored"] is True and restore["proxyDllRestored"] is True, "installation restore failed")
    require(len(restore["designatedLevelSavSha256"]) == 64, "Level.sav hash is invalid")
    require(restore["formalDeploymentFiles"] == 82, "formal deployment count drifted")
    require(restore["deploymentMatchesCurrentSource"] is True, "formal deployment drifted")
    require(len(restore["formalConfigSha256"]) == 64, "formal config hash is invalid")
    require(restore["mapFastTravelSelectionProbeEnabled"] is False, "map QA probe remained enabled")
    require(restore["relationLiveTestEnabled"] is False, "B4 relation QA route remained enabled")
    require(restore["contentModulesEmpty"] is True, "acceptance content remained enabled")

    boundary = evidence["evidenceBoundary"]
    require(boundary["screenshotsSpanSameBuildAttempts"] is True, "visual provenance is ambiguous")
    require(boundary["cleanRoundTripLogFromFinalRerun"] is True, "clean rerun log boundary is ambiguous")
    require(boundary["freshShopUiReopenedAfterFinalRecovery"] is False, "fresh UI reopening was overstated")
    require(boundary["finalFriendlyInteractionDispatchObserved"] is True, "final interaction dispatch missing")
    require(boundary["rawLogPrivate"] is True, "raw log privacy boundary missing")
    require(len(boundary["rawLogSha256"]) == 64, "raw log hash is invalid")
    require(boundary["userAcceptance"] == "not-performed", "agent evidence claimed user acceptance")


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify Build 24575825 B4 Rayne merchant visual evidence.")
    parser.add_argument("--evidence", type=Path, default=DEFAULT_EVIDENCE)
    args = parser.parse_args()
    evidence = json.loads(args.evidence.read_text(encoding="utf-8"))
    verify(evidence, args.evidence)
    print("PASS B4 Rayne merchant visual round-trip evidence (Build 24575825)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
