from __future__ import annotations

import json
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
EVIDENCE_ROOT = (
    PROJECT_ROOT
    / "evidence"
    / "live-tests"
    / "build24575825-20260824-a9-native-reward"
)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> int:
    verification = json.loads(
        (EVIDENCE_ROOT / "verification.json").read_text(encoding="utf-8")
    )
    excerpt = (EVIDENCE_ROOT / "reward-delivery-excerpt.log").read_text(
        encoding="utf-8"
    )

    require(verification["result"] == "PASS", "A9 live result must be PASS")
    require(
        verification["steamBuildId"] == "24575825",
        "A9 live evidence Build drifted",
    )
    require(
        verification["nativeRoute"]
        == "PalPlayerInventoryData.AddItem_ServerInternal",
        "A9 host native route drifted",
    )
    require(
        verification["inventoryOwnership"] == "exact OwnerPlayerUId match",
        "A9 inventory ownership boundary drifted",
    )

    first = verification["firstRun"]
    duplicate = verification["duplicateRun"]
    require(
        first == {
            "stage": "applied",
            "beforeCount": 0,
            "afterCount": 1,
            "dispatchAttemptCount": 1,
            "idempotent": False,
        },
        "A9 first native grant evidence drifted",
    )
    require(
        duplicate == {
            "stage": "applied",
            "beforeCount": 0,
            "afterCount": 1,
            "dispatchAttemptCount": 1,
            "idempotent": True,
            "secondVisiblePickup": False,
        },
        "A9 duplicate-operation evidence drifted",
    )

    restoration = verification["restoration"]
    require(
        restoration["result"] == "PASS"
        and restoration["saveFiles"] == 446
        and restoration["stateFiles"] == 12
        and restoration["formalConfigSha256"]
        == restoration["restoredConfigSha256"]
        and restoration["restoredStateContainsTestOperation"] is False
        and restoration["deploymentParity"] == "107/107",
        "A9 restoration evidence drifted",
    )

    require(
        "run=1" in excerpt
        and "before=0 after=1 dispatches=1 idempotent=false" in excerpt,
        "A9 first-run log evidence is missing",
    )
    require(
        "run=2" in excerpt
        and "before=0 after=1 dispatches=1 idempotent=true" in excerpt,
        "A9 idempotent replay log evidence is missing",
    )
    require(
        set(verification["notVerified"])
        == {
            "remote multiplayer client RequestAddItem_ToServer",
            "full inventory capacity failure",
            "forced process interruption after dispatch fence",
        },
        "A9 unverified-boundary disclosure drifted",
    )
    require(
        "C:\\Users" not in excerpt and "E:\\SteamLibrary" not in excerpt,
        "A9 public excerpt leaks a local path",
    )

    print(
        "PASS A9 native reward live evidence "
        "(Build 24575825, host 0->1, duplicate dispatch=1, exact restore)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
