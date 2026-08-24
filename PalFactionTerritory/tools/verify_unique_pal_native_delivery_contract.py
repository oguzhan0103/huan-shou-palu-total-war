from __future__ import annotations

import json
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
EVIDENCE_PATH = (
    PROJECT_ROOT
    / "evidence"
    / "contracts"
    / "unique-pal-native-delivery-build24575825.json"
)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> int:
    evidence = json.loads(EVIDENCE_PATH.read_text(encoding="utf-8"))
    require(evidence["schemaVersion"] == "1.1.0", "evidence schema drifted")
    require(evidence["steamBuildId"] == "24575825", "Build ID drifted")
    source = evidence["source"]
    require(source["bytes"] == 46_370_831, "ObjectDump byte count drifted")
    require(
        source["sha256"]
        == "3E84E8A6936B7D1C33DE6CFC034C4A200655A3E762CBC2EC4C6A57516476EC78",
        "ObjectDump hash drifted",
    )
    require(source["gameSaveWasEntered"] is False, "title-only evidence drifted")
    require(source["gameFilesWereModified"] is False, "source capture mutated game")

    signatures = evidence["signatures"]
    expected_tokens = {
        "capacity": (
            "PalPlayerState:GetPalStorage",
            "GetPageIndexExistEmptySlot",
            "TargetContainer",
            "FindEmptySlot",
            "IsEmpty",
        ),
        "spawn": ("SpawnNPCForServer", "PalNPCSpawnInfo:CharacterID"),
        "capture": ("PalUtility:PalCaptureSuccess",),
        "identityAndReadback": (
            "GetIndividualID",
            "TryGetIndividualActor",
            "FindByHandle",
        ),
    }
    for group, tokens in expected_tokens.items():
        joined = "\n".join(signatures[group])
        for token in tokens:
            require(token in joined, f"missing reflected signature: {group} -> {token}")

    runtime = evidence["runtimeVerification"]
    require(runtime["spawnNpcForServerExistingProjectLiveEvidence"] is True,
            "existing spawn evidence lost")
    require(runtime["palStorageObjectChainRead"] is True,
            "live storage object-chain proof is missing")
    require(runtime["capacityRead"] is True,
            "live capacity proof is missing")
    require(runtime["palCaptureSuccessCall"] is True,
            "live capture acceptance proof is missing")
    require(runtime["postCaptureExactIndividualReadback"] is True,
            "exact-individual delivery readback proof is missing")
    probe = runtime["readOnlyProbe"]
    require(
        probe["worldGeneration"] == 4
        and probe["pageCount"] == 32
        and probe["firstEmptyPageIndex"] == 6
        and probe["emptySlotIndex"] == 191
        and probe["capacityAvailable"] is True
        and probe["mutation"] is False,
        "live read-only storage probe result drifted",
    )
    require(
        probe["sourceLogBytesAfterExit"] == 309_642
        and probe["sourceLogSha256AfterExit"]
        == "A1D5A0C6DAF47BEE4892D2155D3126898973FF56AB20C0A7BFDA1B02B0D25A11",
        "live probe source-log identity drifted",
    )
    acceptance = runtime["mutatingLiveAcceptance"]
    require(
        acceptance["worldName"] == "oguzhan"
        and acceptance["worldId"] == "E0D5ECDC46B379829F8F31A729ACFD92"
        and acceptance["worldGeneration"] == 4
        and acceptance["speciesId"] == "Anubis"
        and acceptance["deliveryId"] == "qa.native-pal-delivery.g4.r1"
        and acceptance["individualKey"]
        == "pal-00000000000000000000000000000001-8E0F25AB4226BF458C679D91DC9EE50C"
        and acceptance["identityAttemptCount"] == 1
        and acceptance["captureAttemptCount"] == 1
        and acceptance["storageReadbackAttemptCount"] == 1
        and acceptance["result"] == "native-pal-delivery-live-test-verified"
        and acceptance["sameIndividualReadBack"] is True
        and acceptance["directContainerMutation"] is False
        and acceptance["callbackExceptionAfterMainWorldReady"] is False,
        "mutating live-acceptance result drifted",
    )
    require(
        acceptance["sourceLogBytesAfterExit"] == 315_873
        and acceptance["sourceLogSha256AfterExit"]
        == "3574D89EB7A345F3E8F43E538ACD0432493195EF149B2ED5FEF854A421C9938A",
        "live acceptance source-log identity drifted",
    )
    require(
        acceptance["preflightSnapshotFileCount"] == 363
        and acceptance["restoredFileCount"] == 363
        and acceptance["restoredHashMismatchCount"] == 0
        and acceptance["qaConfigRestoredDisabled"] is True
        and acceptance["formalRuntimeRedeployedAndAudited"] is True,
        "save/config restoration evidence drifted",
    )

    development = evidence["developmentStatus"]
    require(
        development["sourceAdapterImplemented"] is True
        and development["offlineContractTestsPassed"] is True
        and development["qaHarnessImplemented"] is True
        and development["productionBridgeBindingRegistered"] is False
        and development["mutatingDeliveryDefaultEnabled"] is False
        and development["directContainerMutationImplemented"] is False
        and development["captureAndExactReadbackLiveAccepted"] is True,
        "native delivery development/live-acceptance boundary drifted",
    )

    conclusion = evidence["conclusion"]
    require(conclusion["currentBuildSignaturesPresent"] is True,
            "current-build signature evidence missing")
    require(conclusion["readOnlyProbeAllowed"] is True,
            "read-only probe must remain allowed")
    require(conclusion["nativeCaptureDeliveryActivationAllowed"] is True,
            "accepted native delivery route was disabled")
    require(conclusion["productionBridgeBindingRegistered"] is False,
            "production binding was claimed without a content binding")
    require(conclusion["formalConfigDefaultEnabled"] is False,
            "QA delivery must remain disabled in formal config")
    require(conclusion["saveMutatingAcceptanceTestCompletedUnderUserAuthorization"] is True,
            "authorized mutating acceptance was not recorded")
    require(conclusion["directContainerMutationAllowed"] is False,
            "direct container mutation must stay forbidden")
    require(conclusion["saveMutatingAcceptanceTestAllowedByThisEvidence"] is False,
            "signature inventory cannot authorize a save mutation")
    print("PASS unique-Pal native delivery current-build contract: signatures=yes, runtime storage=yes, capture=yes, exact-readback=yes, production-binding=no")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
