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
    / "build24575825-20260823-b6-dynamic-economy-war"
    / "verification.json"
)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def verify(evidence: dict[str, Any]) -> None:
    require(evidence["schemaVersion"] == "1.0.0", "unsupported evidence schema")
    require(evidence["result"] == "PASS", "B6 evidence is not PASS")
    require(evidence["gameBuild"] == "24575825", "game build drifted")
    require(
        evidence["acceptanceGate"] == "b6-dynamic-economy-war-restart-closure",
        "wrong acceptance gate",
    )

    attempts = evidence["attemptHistory"]
    require(attempts["attemptCount"] == 2, "attempt history was hidden or drifted")
    require(attempts["firstAttemptResult"] == "FAIL_CLOSED", "first failure was overstated")
    require(
        attempts["firstAttemptReason"] == "native-product-array-is-ue4ss-tarray-not-lua-table",
        "wrong first-attempt failure",
    )
    require(attempts["staticMarketFallbackAvailable"] is True, "static fallback was unavailable")
    require(attempts["secondAttemptResult"] == "PASS", "acceptance rerun did not pass")

    market = evidence["nativeDynamicMarket"]
    require(market["activeCounters"] == 7, "not all fixed counters were active")
    require(market["auditedDynamicItemIds"] == 9, "audited item scope drifted")
    require(market["unrelatedNativeRowsUntouched"] is True, "unrelated rows were mutated")
    initial = market["initial"]
    require(
        (initial["quantity"], initial["sellPrice"], initial["stock"])
        == (150, 240, 66),
        "initial market drifted",
    )
    limited = market["limitedSale"]
    require(
        (limited["quantity"], limited["sellPrice"], limited["stock"])
        == (50, 280, 25),
        "limited market drifted",
    )
    require(limited["sameMerchant"] is True and limited["nativeRefresh"] is True, "limited native refresh failed")
    scarce = market["scarceProcurement"]
    require(
        (scarce["quantity"], scarce["procurementPrice"], scarce["procurementQuota"])
        == (49, 290, 62),
        "procurement market drifted",
    )
    require(
        scarce["nativeSellRows"] == 0 and scarce["nativeProcurementSoldOutRows"] == 1,
        "native scarce row did not fail closed to sold out",
    )
    require(scarce["sameMerchant"] is True and scarce["nativeRefresh"] is True, "scarce native refresh failed")

    war = evidence["economyWar"]
    require(
        war["transitions"] == ["trade_requested", "threat", "war"],
        "economy-war transition order drifted",
    )
    require(war["supplierFactionId"] == "pwft.faction.pal_genetic_research_unit", "wrong supplier")
    require(war["restartRequiredAtWar"] is True, "war did not require restart proof")

    restart = evidence["restartPersistence"]
    require(restart["worldDirectory"] == "E0D5ECDC46B379829F8F31A729ACFD92", "wrong accepted world")
    require(restart["quantityAfterRestart"] == 49, "resource quantity did not persist")
    require(restart["conflictAfterRestart"] == "war", "war state did not persist")
    require(restart["ledgerRevisionAfterRestart"] == 2, "ledger revision did not persist")
    require(restart["persistenceConfirmed"] is True, "restart persistence not confirmed")
    require(restart["activeCountersAfterRestart"] == 7, "counter presence did not recover")

    recovery = evidence["recovery"]
    require(
        (recovery["quantityAfterSupplyRestore"], recovery["sellPrice"], recovery["stock"])
        == (150, 240, 66),
        "supply recovery market drifted",
    )
    require(
        recovery["firstConflictResult"] == "ceasefire"
        and recovery["finalConflictResult"] == "stable",
        "conflict did not recover through ceasefire",
    )
    require(recovery["sameMerchant"] is True and recovery["nativeRefresh"] is True, "recovery spawned or missed merchant")
    require(recovery["finalPhase"] == "complete" and recovery["finalStepCount"] == 7, "live route incomplete")

    safety = evidence["safety"]
    require(safety["storyContentIncluded"] is False, "B6 included story content")
    require(safety["palworldSaveWritesByMod"] == 0, "Mod wrote Palworld saves")
    require(safety["formalQaHotkeyEnabled"] is False, "formal QA hotkey remained enabled")
    require(safety["fixedMerchantDuplicatesObserved"] == 0, "duplicate fixed merchants observed")
    require(safety["nativeCurrencyMutation"] is False, "native currency was mutated")

    recovery_event = evidence["operatorRecovery"]
    require(recovery_event["b6HotkeyUsedInWrongWorld"] is False, "wrong world was mutated by B6")
    require(recovery_event["wrongWorldRestoredFromPreflight"] is True, "wrong world was not restored")
    require(recovery_event["wrongWorldSidecarsQuarantined"] == 4, "wrong-world sidecars drifted")

    automated = evidence["automatedVerification"]
    require(automated["dynamicEconomySpec"] == "PASS", "dynamic economy spec failed")
    require(automated["economyWarLiveRouteSpec"] == "PASS", "B6 route spec failed")
    require(automated["nativeContractFields"] == 13, "native contract field count drifted")
    require(automated["fullVerification"] == "PASS", "full verification failed")
    require(automated["luaSourceFiles"] == 86 and automated["luaTests"] == 75, "Lua acceptance counts drifted")

    restore = evidence["restore"]
    require(restore["result"] == "PASS" and restore["gameRunning"] is False, "environment restore failed")
    require(
        restore["saveSnapshotFiles"] == restore["saveCurrentFiles"] == 384
        and restore["saveMissing"] == restore["saveExtra"] == restore["saveChanged"] == 0,
        "SaveGames restore drifted",
    )
    require(
        restore["stateSnapshotFiles"] == restore["stateCurrentFiles"] == 12
        and restore["stateMissing"] == restore["stateExtra"] == restore["stateChanged"] == 0,
        "State restore drifted",
    )
    require(restore["extraSaveBackupsQuarantined"] == 33, "extra save quarantine drifted")
    require(restore["formalDeploymentFiles"] == 84, "formal deployment count drifted")
    require(restore["formalQaHotkeyEnabled"] is False, "installed QA hotkey remained enabled")
    require(restore["steamCloudEnabled"] is True, "Steam Cloud was not re-enabled")
    require(restore["steamCloudSynchronized"] is False, "Steam Cloud synchronization was overstated")
    require(restore["steamCloudUiStatus"] == "out-of-date", "Steam Cloud UI status was hidden")
    require(restore["steamCloudOverwriteChoiceMade"] is False, "a cloud overwrite choice was made")

    cloud = evidence["postAcceptanceCloudRecovery"]
    require(cloud["result"] == "PASS", "post-acceptance Steam Cloud recovery failed")
    require(
        cloud["recoveryMethod"] == "restart-steam-and-resume-sync",
        "Steam Cloud recovery method drifted",
    )
    require(cloud["steamCloudUiStatus"] == "synchronized-checkmark", "Steam Cloud UI did not recover")
    require(cloud["steamCloudLogResult"] == "Upload complete, result OK", "Steam Cloud log did not close OK")
    require(cloud["gameRunning"] is False, "game was running during cloud recovery evidence")
    require(cloud["palworldLaunchedForRecovery"] is False, "Palworld was launched for cloud recovery")
    require(cloud["steamCloudOverwriteChoiceMade"] is False, "a cloud overwrite choice was made during recovery")
    require(cloud["mainSaveHashesMatchAcceptance"] is True, "main save hashes changed during cloud recovery")
    require(cloud["levelSavSha256"] == restore["levelSavSha256"], "Level.sav hash drifted after cloud recovery")
    require(
        cloud["levelMetaSavSha256"] == restore["levelMetaSavSha256"],
        "LevelMeta.sav hash drifted after cloud recovery",
    )
    require(cloud["cloudHistoryMayReconcileBackupFiles"] is True, "cloud backup-history boundary was hidden")

    boundary = evidence["evidenceBoundary"]
    require(len(boundary["preRestartRawLogSha256"]) == 64, "pre-restart log hash invalid")
    require(len(boundary["postRestartRawLogSha256"]) == 64, "post-restart log hash invalid")
    require(boundary["rawLogsStateSavesAndQuarantinePrivate"] is True, "private evidence boundary missing")
    require(boundary["positiveRouteObservedInLiveRun"] is True, "live positive route missing")
    require(boundary["negativeBoundariesCoveredByAutomatedTests"] is True, "negative coverage missing")
    require(boundary["userAcceptance"] == "not-performed", "agent evidence claimed user acceptance")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Verify Build 24575825 B6 dynamic economy-war live evidence."
    )
    parser.add_argument("--evidence", type=Path, default=DEFAULT_EVIDENCE)
    args = parser.parse_args()
    evidence = json.loads(args.evidence.read_text(encoding="utf-8"))
    verify(evidence)
    print("PASS B6 dynamic economy-war live evidence (public, Build 24575825)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
