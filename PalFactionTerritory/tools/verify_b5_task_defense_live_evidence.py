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
    / "build24575825-20260823-b5-task-defense"
    / "verification.json"
)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def verify(evidence: dict[str, Any]) -> None:
    require(evidence["schemaVersion"] == "1.0.0", "unsupported evidence schema")
    require(evidence["result"] == "PASS", "B5 evidence is not PASS")
    require(evidence["gameBuild"] == "24575825", "game build drifted")
    require(
        evidence["acceptanceGate"] == "b5-task-defense-authoritative-closure",
        "wrong acceptance gate",
    )

    module = evidence["contentModule"]
    require(module["moduleId"] == "pwft.foundation.b5-acceptance", "wrong content module")
    require(module["registered"] is True and module["activated"] is True, "B5 module was not active")
    require(module["defaultEnabled"] is False, "acceptance module must remain default-disabled")
    require(module["storyContentIncluded"] is False, "acceptance module included story content")
    require(module["questTemplateCount"] == 1 and module["activeQuestInstances"] == 1, "quest count drifted")

    travel = evidence["fastTravel"]
    require(travel["mapPoint"] == "FTPoint24", "wrong fast-travel point")
    require(travel["mapIconClickEvent"] is True and travel["nativeConfirmation"] is True, "native travel was not observed")
    require(travel["destinationSettlementId"] == "pwft.settlement.small_settlement", "wrong destination")

    raid = evidence["authoritativeRaid"]
    require(raid["authority"] == "pwft-attendance-all-members-dead-v1", "wrong raid authority")
    require(raid["playerPresent"] is True and raid["playerWithinAggroRange"] is True, "player attendance failed")
    require(raid["configuredAttackers"] == 4 and raid["spawnedAttackers"] == 4, "attacker count drifted")
    require(raid["readyAttackers"] == 4 and raid["deathCallbacks"] == 4, "attacker lifecycle incomplete")
    require(raid["playerOwnedPalKillCredit"] is True and raid["leaderKillCredited"] is True, "kill credit failed")
    require(raid["allMembersDead"] is True and raid["playerSideWon"] is True, "authoritative victory failed")

    closure = evidence["closure"]
    require(closure["result"] == "PASS", "closure is not PASS")
    require(closure["factionId"] == "pwft.faction.rayne_syndicate", "wrong defense faction")
    require(closure["territoryId"] == "pwft.island.central_southeast_archipelago", "wrong defense territory")
    require(closure["playerParticipated"] is True and closure["playerSideWon"] is True, "closure attendance failed")
    require(closure["credited"] is True and closure["reputationApplied"] == 50, "defense reputation failed")
    require(closure["defenseReason"] == "human-defense-reputation-awarded", "wrong defense result")
    require(closure["questReason"] == "quest-objective-event-applied", "quest event was not applied")
    require(closure["questTransitionCount"] == 1 and closure["replayed"] is False, "quest transition drifted")
    require(closure["storyContentIncluded"] is False and closure["palworldSaveWrites"] == 0, "safety boundary failed")

    durable = evidence["durableState"]
    require(durable["rayneReputation"] == 50 and durable["rayneDefenseSourceTotal"] == 50, "durable reputation drifted")
    require(durable["questState"] == "completed" and durable["questSequence"] == 1, "durable quest state drifted")
    require(durable["processedReputationOperations"] == 1, "reputation idempotency drifted")
    require(durable["processedQuestObjectiveEvents"] == 1, "quest idempotency drifted")

    automated = evidence["automatedBoundaries"]
    require(automated["automatedTestOnly"] is True, "automated/live boundary is ambiguous")
    require(automated["replayReputationApplied"] == 0, "replay awarded reputation")
    require(automated["absenceReputationApplied"] == 0, "absence awarded reputation")
    require(automated["defeatReputationApplied"] == 0, "defeat awarded reputation")
    require(automated["missingTerritoryMappingFailsClosed"] is True, "mapping gate is not fail-closed")
    require(automated["focusedLuaSpec"] == "PASS" and automated["fullVerification"] == "PASS", "automated verification failed")
    require(automated["luaSourceFiles"] == 84 and automated["luaTests"] == 73, "Lua coverage drifted")

    restore = evidence["restore"]
    require(restore["result"] == "PASS" and restore["gameRunning"] is False, "environment restore failed")
    require(restore["saveFiles"] == 384 and restore["saveDiffCount"] == 0, "SaveGames restore drifted")
    require(restore["stateFiles"] == 12 and restore["stateDiffCount"] == 0, "State restore drifted")
    require(restore["formalDeploymentFiles"] == 82, "formal deployment count drifted")
    require(restore["deploymentMatchesCurrentSource"] is True, "formal deployment drifted")
    require(restore["mapFastTravelSelectionProbeEnabled"] is False, "map QA probe remained enabled")
    require(restore["qaHotkeyEnabled"] is False, "QA hotkey remained enabled")
    require(restore["contentModulesEmpty"] is True, "acceptance module remained enabled")
    require(restore["formalWorldLevel"] == 80, "formal world level drifted")

    boundary = evidence["evidenceBoundary"]
    require(boundary["positiveTaskDefenseClosureObserved"] is True, "live positive closure was not observed")
    require(boundary["negativeBranchesObservedInLiveRun"] is False, "negative live branches were overstated")
    require(boundary["negativeBranchesCoveredByAutomatedTests"] is True, "negative test boundary missing")
    require(boundary["rawLogsStateAndSavesPrivate"] is True, "private evidence boundary missing")
    require(len(boundary["rawLogSha256"]) == 64, "raw log hash is invalid")
    require(boundary["palworldSaveMutationByMod"] is False, "Mod save mutation was overstated")
    require(boundary["userAcceptance"] == "not-performed", "agent evidence claimed user acceptance")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Verify Build 24575825 B5 task-defense live evidence."
    )
    parser.add_argument("--evidence", type=Path, default=DEFAULT_EVIDENCE)
    args = parser.parse_args()
    evidence = json.loads(args.evidence.read_text(encoding="utf-8"))
    verify(evidence)
    print("PASS B5 task-defense live evidence (public, Build 24575825)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
