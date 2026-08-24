from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_EVIDENCE = (
    PROJECT_ROOT
    / "evidence"
    / "live-tests"
    / "build24575825-20260822-world-level-80"
    / "verification.json"
)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def verify(evidence: dict[str, Any]) -> None:
    require(evidence["schemaVersion"] == "1.0.0", "unsupported evidence schema")
    require(evidence["result"] == "PASS", "B1 evidence is not PASS")
    require(evidence["gameBuild"] == "24575825", "game build drifted")
    require(evidence["acceptanceGate"] == "B1-world-level-80", "wrong acceptance gate")

    staging = evidence["staging"]
    require(staging["targetLevel"] == 80, "target level drifted")
    require(staging["levelOverride"] is True, "B1 level gate was not enabled")
    require(staging["liveAudit"] is True, "live audit was not enabled")
    require(staging["bossProbe"] is True, "Boss probe was not enabled")
    require(staging["palFactionRage"] is False, "B2 rage leaked into B1")
    require(staging["loadedActorReconcile"] is False, "loaded-actor scan leaked into B1")
    require(staging["broadActorScan"] is False, "broad actor scan was enabled")

    implementation = evidence["implementation"]
    require(implementation["eventScopedExactTarget"] is True, "level route was not event-scoped")
    require(implementation["postHookRegistered"] is False, "unsafe post hook remained enabled")
    require(
        implementation["playerAndOwnedExclusionBeforeWrite"] is True,
        "player/owned exclusion did not precede the runtime level write",
    )

    final_round = evidence["finalRound"]
    require(final_round["result"] == "PASS", "final live round is not PASS")
    require(final_round["applied"] == final_round["verified"] == 35, "35/35 verification drifted")
    categories = final_round["categories"]
    require(sum(categories.values()) == 35, "category totals do not match verified targets")
    require(categories == {"palWorld": 22, "palBoss": 1, "npcFriendly": 9, "npcMerchant": 3}, "category coverage drifted")
    require(set(final_round["readback"].values()) == {80}, "four-layer readback is not all 80")
    excluded = final_round["excluded"]
    require(excluded["playerCharacter"] == 1 and excluded["playerLevel"] == 29, "player exclusion drifted")
    require(excluded["ownedOrWorker"] == 5, "owned/worker exclusion drifted")
    require(excluded["playerGuildGroup4"] == 14, "player-guild exclusion drifted")
    boss = final_round["bossProbe"]
    require(boss["requestedLevel"] == 1 and boss["observedLevel"] == 80, "Boss level proof drifted")
    require(boss["destroyed"] is True and boss["cleanupDelayMs"] == 15000, "Boss cleanup proof drifted")
    require(final_round["broadScanFalseObservations"] >= 1, "broadScan=false was not observed")
    require(final_round["newCrashCount"] == 0, "final live round crashed")

    restore = evidence["restore"]
    require(restore["result"] == "PASS", "test environment was not restored")
    require(restore["gameRunning"] is False, "game remained running")
    require(restore["saveFiles"] == 383 and restore["saveDiffCount"] == 0, "SaveGames restore drifted")
    require(restore["stateFiles"] == 12 and restore["stateDiffCount"] == 0, "State restore drifted")
    require(restore["formalDeploymentFiles"] == 76, "formal deployment count drifted")
    require(restore["formalRiskGatesDisabled"] is True, "formal risk gates were not disabled")

    boundary = evidence["evidenceBoundary"]
    require(boundary["runtimeCharacterSaveParameterLevelMutation"] is True, "runtime mutation was hidden")
    require(boundary["palworldSaveSnapshotRestored"] is True, "Palworld save snapshot was not restored")
    require(boundary["userAcceptance"] == "not-performed", "agent test claimed user acceptance")
    require(boundary["b2Accepted"] is False, "B1 evidence incorrectly closed B2")


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify Build 24575825 world-level B1 live evidence.")
    parser.add_argument("--evidence", type=Path, default=DEFAULT_EVIDENCE)
    args = parser.parse_args()
    evidence = json.loads(args.evidence.read_text(encoding="utf-8"))
    verify(evidence)
    print("PASS world-level B1 live evidence (public, Build 24575825)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
