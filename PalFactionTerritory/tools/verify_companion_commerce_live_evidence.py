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
    / "build24575825-20260823-companion-commerce"
    / "verification.json"
)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def verify(evidence: dict[str, Any]) -> None:
    require(evidence["schemaVersion"] == "1.0.0", "unsupported evidence schema")
    require(evidence["result"] == "PASS", "companion commerce evidence is not PASS")
    require(evidence["gameBuild"] == "24575825", "game build drifted")
    require(
        evidence["acceptanceGate"] == "companion-commerce-json-boundary-repair",
        "wrong acceptance gate",
    )

    implementation = evidence["implementation"]
    require(
        implementation["internalVendorMetadataRetained"] is True,
        "internal merchant routing metadata was weakened",
    )
    require(
        implementation["merchantEventUsesPublicAllowlist"] is True,
        "merchant event is not explicitly projected",
    )
    require(
        implementation["publicProjectionBypassesPairsMetamethod"] is True,
        "public projection may invoke runtime __pairs",
    )
    require(
        implementation["strictLedgerMethodsRemainFailClosed"] is True,
        "strict ledger semantics were weakened",
    )

    automated = evidence["automatedVerification"]
    require(automated["focusedCommerceSpec"] == "PASS", "commerce regression failed")
    require(automated["focusedCompanionSpec"] == "PASS", "companion regression failed")
    require(automated["luaSourceFiles"] == 78, "Lua source coverage drifted")
    require(automated["luaTests"] == 72, "Lua test coverage drifted")
    require(automated["trackedTextFiles"] >= 398, "tracked text scan coverage drifted")

    live = evidence["liveRun"]
    require(live["result"] == "PASS", "live run is not PASS")
    require(live["sessionEvents"] == 25, "live companion event count drifted")
    require(live["firstSequence"] == 1 and live["lastSequence"] == 25, "event sequence is not contiguous")
    require(live["merchantRegisteredEvents"] == 8, "merchant registration event count drifted")
    require(live["uniqueMerchantFactions"] == 7, "human faction coverage drifted")
    require(live["guildCatalogRegistrations"] == 7, "Merchant Guild catalog coverage drifted")
    require(live["specialMerchantRegistrations"] == 1, "special merchant boundary drifted")
    require(live["eternalPyreRegistrations"] == 1, "original failing faction was not covered")
    require(live["companionFailureMarkers"] == 0, "companion failure marker remained")
    require(live["publicProjectionMarkers"] == 0, "live payload still required redaction")

    restore = evidence["restore"]
    require(restore["result"] == "PASS" and restore["gameRunning"] is False, "environment restore failed")
    require(restore["saveFiles"] == 384 and restore["saveDiffCount"] == 0, "SaveGames restore drifted")
    require(restore["stateFiles"] == 12 and restore["stateDiffCount"] == 0, "State restore drifted")
    require(restore["formalDeploymentFiles"] == 76, "formal deployment count drifted")

    boundary = evidence["evidenceBoundary"]
    require(boundary["merchantRegistrationObserved"] is True, "merchant registration was not observed")
    require(boundary["companionJsonAppendObserved"] is True, "companion append was not observed")
    require(boundary["merchantBuySellPerformed"] is False, "buy/sell was overstated")
    require(boundary["userAcceptance"] == "not-performed", "agent evidence claimed user acceptance")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Verify Build 24575825 companion-commerce JSON boundary live evidence."
    )
    parser.add_argument("--evidence", type=Path, default=DEFAULT_EVIDENCE)
    args = parser.parse_args()
    evidence = json.loads(args.evidence.read_text(encoding="utf-8"))
    verify(evidence)
    print("PASS companion-commerce JSON boundary live evidence (public, Build 24575825)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
