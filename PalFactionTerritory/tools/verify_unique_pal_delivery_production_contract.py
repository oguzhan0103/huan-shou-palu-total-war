from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CONTRACT = ROOT / "contracts" / "unique_pal_delivery_production.v1.json"
CONFIG = (
    ROOT
    / "mod0"
    / "ue4ss"
    / "PalFactionTerritory0"
    / "Scripts"
    / "pwft"
    / "config.lua"
)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> int:
    contract = json.loads(CONTRACT.read_text(encoding="utf-8"))
    config = CONFIG.read_text(encoding="utf-8")
    require(contract["schemaVersion"] == "1.0.0", "schema drifted")
    require(contract["gameBuild"] == "24575825", "Build drifted")
    approved = contract["approvedSpeciesByUniquePalId"]
    require(
        approved
        == {
            "pwft.unique.pinkcat": "PinkCat",
            "pwft.unique.anubis": "Anubis",
            "pwft.unique.weasel_dragon": "WeaselDragon",
            "pwft.unique.black_metal_dragon": "BlackMetalDragon",
            "pwft.unique.ronin": "Ronin",
        },
        "confirmed unique-Pal whitelist drifted",
    )
    require(
        contract["tentativeMappings"]["feybreakCloudWhirlEnabled"] is False,
        "tentative Feybreak mapping must remain fail-closed",
    )
    binding = contract["contentBinding"]
    require(binding["required"] is True, "content binding must be required")
    require(
        binding["baseRegisteredBindingCount"] == 0,
        "mechanics base must not invent a content binding",
    )
    product = contract["ransomProduct"]
    require(
        product["nativeChannel"] == "ItemShop"
        and product["stock"] == 1
        and product["buyQuantity"] == 1
        and product["commerceReputationAward"] == 0,
        "ransom product safety policy drifted",
    )
    guarantees = contract["transactionGuarantees"]
    for field in (
        "logicalOwnershipAfterConfirmedPaymentOnly",
        "nativeDeliveryAfterOwnershipTransfer",
        "capacityPreflight",
        "singleEntityCreation",
        "singleCaptureCommit",
        "exactIndividualReadback",
        "idempotentPaymentReplay",
        "idempotentEntityDelivery",
    ):
        require(guarantees[field] is True, f"transaction guarantee lost: {field}")
    require(
        guarantees["rawMutatingAdapterPublic"] is False
        and
        guarantees["directContainerMutation"] is False
        and guarantees["palworldSaveMutation"] is False,
        "save/container mutation boundary drifted",
    )
    whitelist = config.split("approvedSpeciesByUniquePalId = {", 1)[1].split(
        "        },", 1
    )[0]
    for unique_pal_id, species_id in approved.items():
        require(
            f'["{unique_pal_id}"] = "{species_id}"' in whitelist,
            f"runtime whitelist is missing {unique_pal_id}",
        )
    require(
        '["pwft.unique.feybreak"]' not in whitelist,
        "runtime enabled the tentative Feybreak mapping",
    )
    print(
        "PASS unique-Pal production delivery contract: "
        "Build=24575825 approved=5 baseBindings=0 stock=1 reputation=0 "
        "Feybreak=false"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
