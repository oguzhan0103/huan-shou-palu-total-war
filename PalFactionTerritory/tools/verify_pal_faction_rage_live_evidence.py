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
    / "build24575825-20260823-pal-faction-rage"
    / "verification.json"
)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def verify(evidence: dict[str, Any]) -> None:
    require(evidence["schemaVersion"] == "1.0.0", "unsupported evidence schema")
    require(evidence["result"] == "PASS", "B2 evidence is not PASS")
    require(evidence["gameBuild"] == "24575825", "game build drifted")
    require(evidence["acceptanceGate"] == "B2-pal-faction-rage", "wrong acceptance gate")

    staging = evidence["staging"]
    require(staging["targetLevel"] == 80, "target level drifted")
    require(staging["levelOverride"] is False, "B1 leaked into B2")
    require(staging["palFactionRage"] is True, "B2 rage gate was not enabled")
    require(staging["rageLiveAudit"] is True, "B2 audit was not enabled")
    require(staging["loadedActorReconcile"] is False, "loaded actor scan leaked into B2")
    require(staging["broadActorScan"] is False, "broad actor scan was enabled")

    implementation = evidence["implementation"]
    require(implementation["palFactionIslandCount"] == 5, "Pal island count drifted")
    require(implementation["eventScopedExactTarget"] is True, "B2 route was not event scoped")
    require(
        implementation["groupZeroRequiresReadableEmptyOwnerGuid"] is True
        and implementation["ownerStateUnavailableFailsClosed"] is True,
        "group-0 owner safety gate drifted",
    )
    require(
        implementation["playerOwnedWorkerAndNonWorldGroupExclusionBeforeWrite"] is True,
        "protected targets were not excluded before mutation",
    )

    target = evidence["targetRun"]
    require(target["result"] == "PASS", "target run is not PASS")
    require(target["verifiedInstances"] == 11, "target instance count drifted")
    require(target["exactMaxHpDoublingInstances"] == 11, "exact MaxHP proof drifted")
    require(target["firstAuditSummary"] == {"applied": 4, "verified": 4, "excluded": 6, "failed": 0}, "first audit summary drifted")
    require(target["laterStreamingVerified"] == 7, "streaming target count drifted")
    require(target["before"] == {"predator": False, "hpRate": 1.0, "damageRate": 1.0, "spawnedType": 0, "uncapturable": False}, "target baseline drifted")
    require(target["after"] == {"predator": True, "hpRate": 2.0, "damageRate": 2.0, "spawnedType": 8, "uncapturable": True}, "target readback drifted")
    require(target["failedMarkers"] == 0, "target run has failure markers")
    require(target["broadScan"] is False and target["levelOverride"] is False, "B2 isolation drifted")
    require(target["excluded"]["playerCharacter"] == 1, "player exclusion drifted")
    require(target["excluded"]["ownedOrWorker"] == 5, "owned/worker exclusion drifted")
    require(target["excluded"]["allLoggedNativeFieldsUnchanged"] is True, "excluded fields changed")

    control = evidence["negativeControl"]
    require(control["result"] == "PASS", "negative control is not PASS")
    require(control["method"] == "installed-runtime-only-forced-mask-miss", "control method drifted")
    require(control["organicOutsideGeography"] is False, "controlled mask miss was misreported as organic geography")
    require(control["sourceMaskUnchanged"] is True, "source mask was modified")
    require(control["naturalWildPalsExcluded"] >= 7, "outside control coverage drifted")
    require(control["summary"] == {"applied": 0, "verified": 0, "excluded": 14, "failed": 0}, "control summary drifted")
    require(control["unchanged"] == {"predator": False, "hpRate": 1.0, "damageRate": 1.0, "spawnedType": 0, "uncapturable": False}, "control fields changed")

    restore = evidence["restore"]
    require(restore["result"] == "PASS" and restore["gameRunning"] is False, "environment restore failed")
    require(restore["saveFiles"] == 385 and restore["saveDiffCount"] == 0, "SaveGames restore drifted")
    require(restore["stateFiles"] == 12 and restore["stateDiffCount"] == 0, "State restore drifted")
    require(restore["formalDeploymentFiles"] == 76, "formal deployment count drifted")
    require(restore["formalRiskGatesDisabled"] is True, "formal gates remained enabled")
    require(restore["runtimeMaskMatchesSource"] is True, "temporary mask remained installed")

    boundary = evidence["evidenceBoundary"]
    require(boundary["nativePropertyReadback"] is True, "native readback proof missing")
    require(boundary["visualCombatObserved"] is False, "combat was overstated")
    require(boundary["visualCaptureAttemptObserved"] is False, "capture attempt was overstated")
    require(boundary["probeConfiguredButNoSample"] is True, "probe boundary was hidden")
    require(boundary["palworldSaveSnapshotRestored"] is True, "save snapshot restore missing")
    require(boundary["userAcceptance"] == "not-performed", "agent evidence claimed user acceptance")


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify Build 24575825 Pal-faction rage B2 live evidence.")
    parser.add_argument("--evidence", type=Path, default=DEFAULT_EVIDENCE)
    args = parser.parse_args()
    evidence = json.loads(args.evidence.read_text(encoding="utf-8"))
    verify(evidence)
    print("PASS Pal-faction rage B2 live evidence (public, Build 24575825)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
