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
    / "build24575825-20260822-progression-sidecar"
    / "verification.json"
)

ALLOWED_REBIND_DIFFS = {
    "payload.uniquePalBossProviderBus.worldGeneration",
    "payload.uniquePalWorldEffectBus.worldGeneration",
}
ALLOWED_ENVELOPE_DIFFS = {"savedAtEpoch"}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest().upper()


def collect_diffs(left: Any, right: Any, path: str = "") -> list[dict[str, Any]]:
    if type(left) is not type(right):
        return [{"path": path, "left": left, "right": right}]
    if isinstance(left, dict):
        diffs: list[dict[str, Any]] = []
        for key in sorted(set(left) | set(right)):
            child = f"{path}.{key}" if path else key
            if key not in left or key not in right:
                diffs.append(
                    {
                        "path": child,
                        "left": left.get(key, "<missing>"),
                        "right": right.get(key, "<missing>"),
                    }
                )
            else:
                diffs.extend(collect_diffs(left[key], right[key], child))
        return diffs
    if isinstance(left, list):
        if len(left) != len(right):
            return [{"path": f"{path}.length", "left": len(left), "right": len(right)}]
        diffs = []
        for index, (left_item, right_item) in enumerate(zip(left, right, strict=True)):
            diffs.extend(collect_diffs(left_item, right_item, f"{path}[{index}]"))
        return diffs
    if left != right:
        return [{"path": path, "left": left, "right": right}]
    return []


def verify_public_evidence(evidence: dict[str, Any]) -> None:
    require(evidence["schemaVersion"] == "1.0.0", "unsupported evidence schema")
    require(evidence["result"] == "PASS", "live evidence is not PASS")
    require(evidence["gameBuild"] == "24575825", "game build drifted")

    profile = evidence["profile"]
    expected_profile = f"world-{profile['worldGuid']}.player-{profile['playerGuid']}"
    require(profile["profileKey"] == expected_profile, "world/player profile key drifted")
    require(profile["revision"] == 2, "accepted progression revision drifted")

    restart = evidence["restartAcceptance"]
    require(restart["fullProcessRestarts"] >= 2, "two full process restarts are required")
    require(
        restart["identityReadyReasons"] == ["active:primary", "active:primary"],
        "restart identity must restore from the primary sidecar",
    )
    require(restart["durableStateDiffCount"] == 0, "durable state changed across restart")
    rebind_paths = {item["path"] for item in restart["allowedRuntimeRebindDiffs"]}
    require(rebind_paths == ALLOWED_REBIND_DIFFS, "unexpected runtime rebind diff set")

    recovery = evidence["backupRecovery"]
    require(recovery["identityReadyReason"] == "active:backup", "backup recovery did not run")
    require(recovery["recoveredRevision"] == profile["revision"], "revision was not recovered")
    require(recovery["blockedRecoveryCount"] == 0, "recovery was blocked")
    require(recovery["regeneratedPrimaryValid"] is True, "primary was not regenerated")
    require(recovery["backupRotatedToInjectedCorruption"] is True, "corrupt primary was not rotated")
    require(
        recovery["injectedCorruptPrimarySha256"]
        not in {recovery["primaryBeforeSha256"], recovery["backupBeforeSha256"]},
        "corruption fixture does not differ from both valid sidecars",
    )

    isolation = evidence["worldIsolation"]
    require(isolation["distinctProfiles"] >= 2, "two distinct profiles are required")
    require(isolation["otherWorldGuid"] != profile["worldGuid"], "world isolation fixture reused world")
    require(isolation["profileFilenameSeparation"] is True, "profile filenames are not separated")

    restore = evidence["restore"]
    require(restore["result"] == "PASS", "test environment was not restored")
    require(restore["gameRunning"] is False, "game remained running after acceptance")
    require(restore["saveDiffCount"] == 0, "Palworld save restore differs from preflight")
    require(restore["stateDiffCount"] == 0, "Mod state restore differs from preflight")
    require(restore["saveFiles"] == 56, "designated world save file count drifted")
    require(restore["stateFiles"] == 12, "Mod state file count drifted")

    boundary = evidence["evidenceBoundary"]
    require(boundary["palworldSaveWritesEnabled"] is False, "Mod must not write Palworld save data")
    require(boundary["rawStateAndLogsPrivate"] is True, "raw user state must remain private")
    require(boundary["userAcceptance"] == "not-performed", "agent test must not claim user acceptance")


def verify_private_evidence(evidence: dict[str, Any], private_root: Path) -> None:
    profile_filename = (
        "pwft-progression-v1-"
        + evidence["profile"]["profileKey"]
        + ".json"
    )
    before = private_root / "state-before-corruption"
    after = private_root / "state-after-backup-recovery"
    before_primary = before / profile_filename
    before_backup = before / f"{profile_filename}.bak"
    after_primary = after / profile_filename
    after_backup = after / f"{profile_filename}.bak"
    for path in (before_primary, before_backup, after_primary, after_backup):
        require(path.is_file(), f"missing private state evidence: {path}")

    recovery = evidence["backupRecovery"]
    require(sha256(before_primary) == recovery["primaryBeforeSha256"], "pre-corruption primary hash drifted")
    require(sha256(before_backup) == recovery["backupBeforeSha256"], "pre-corruption backup hash drifted")
    require(sha256(after_primary) == recovery["recoveredPrimarySha256"], "recovered primary hash drifted")
    require(sha256(after_backup) == recovery["injectedCorruptPrimarySha256"], "rotated corruption hash drifted")

    baseline = json.loads(before_backup.read_text(encoding="utf-8-sig"))
    recovered = json.loads(after_primary.read_text(encoding="utf-8-sig"))
    diffs = collect_diffs(baseline, recovered)
    require(
        {item["path"] for item in diffs} == ALLOWED_REBIND_DIFFS | ALLOWED_ENVELOPE_DIFFS,
        "recovered envelope has unexpected diffs",
    )
    generation_diffs = [item for item in diffs if item["path"] in ALLOWED_REBIND_DIFFS]
    require(
        all(item["right"] == item["left"] + 1 for item in generation_diffs),
        "runtime generation did not advance exactly once",
    )
    saved_at_diff = next(item for item in diffs if item["path"] == "savedAtEpoch")
    require(saved_at_diff["right"] > saved_at_diff["left"], "recovery save timestamp did not advance")

    restart_log = (private_root / "UE4SS-after-restart-2.log").read_text(
        encoding="utf-8-sig", errors="replace"
    )
    recovery_log = (private_root / "UE4SS-after-backup-recovery.log").read_text(
        encoding="utf-8-sig", errors="replace"
    )
    profile_key = evidence["profile"]["profileKey"]
    require(
        f"profile={profile_key}" in restart_log and "sidecarReason=active:primary" in restart_log,
        "restart log lacks active primary identity",
    )
    require(
        f"profile={profile_key}" in recovery_log and "sidecarReason=active:backup" in recovery_log,
        "recovery log lacks active backup identity",
    )
    recovery_tail = recovery_log.rsplit("sidecarReason=active:backup", 1)[-1]
    require(
        "FACTION_PROGRESSION_RECOVERY_BLOCKED" not in recovery_tail,
        "recovery was blocked after backup activation",
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify Build 24575825 progression-sidecar live evidence.")
    parser.add_argument("--evidence", type=Path, default=DEFAULT_EVIDENCE)
    parser.add_argument("--private-root", type=Path)
    args = parser.parse_args()

    evidence = json.loads(args.evidence.read_text(encoding="utf-8"))
    verify_public_evidence(evidence)
    if args.private_root is not None:
        verify_private_evidence(evidence, args.private_root.resolve())
    mode = "public+private" if args.private_root is not None else "public"
    print(f"PASS progression sidecar live evidence ({mode}, Build 24575825)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
