from __future__ import annotations

import hashlib
import json
import subprocess
from pathlib import Path
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[1]
CONTRACT_PATH = PROJECT_ROOT / "contracts" / "faction_economy_shops.v1.json"
ECONOMY_PATH = PROJECT_ROOT / "contracts" / "faction_economy.v1.json"
GENERATED_ROOT = PROJECT_ROOT / "generated" / "faction-economy-shops"
SOURCE_JSON_ROOT = (
    PROJECT_ROOT
    / "evidence"
    / "faction-economy-assets-20260729"
    / "Pal"
    / "Content"
    / "Pal"
    / "DataTable"
    / "ItemShop"
)
COMPILED_ROOT = (
    PROJECT_ROOT
    / "build"
    / "faction-economy-shops-data"
    / "Pal"
    / "Content"
    / "Pal"
    / "DataTable"
    / "ItemShop"
)
ROUNDTRIP_ROOT = PROJECT_ROOT / "build" / "faction-economy-shops-roundtrip"
PAK_PATH = (
    PROJECT_ROOT
    / "artifacts"
    / "faction-economy-shops"
    / "PalFactionTerritory_FactionEconomyShops_P.pak"
)
REPAK_PATH = (
    PROJECT_ROOT.parent
    / "1.0文本资料库"
    / "_tools"
    / "repak-v0.2.3"
    / "repak.exe"
)
UASSETGUI_PATH = (
    PROJECT_ROOT
    / "tools"
    / "vendor"
    / "UAssetGUI-v1.1.0"
    / "UAssetGUI.exe"
)
MAPPING_PATH = (
    UASSETGUI_PATH.parent
    / "Data"
    / "Mappings"
    / "Palworld_1_0_1.usmap"
)
NATIVE_MERCHANT_ROOT = (
    PROJECT_ROOT
    / "evidence"
    / "native-merchant-assets-20260728"
    / "Pal"
    / "Content"
    / "Pal"
)

TABLES = {
    "createData": {
        "source_json": "DT_ItemShopCreateData.json",
        "generated_json": "DT_ItemShopCreateData.PFT_Economy.json",
        "asset": "DT_ItemShopCreateData",
        "kind": "create",
    },
    "createDataCommon": {
        "source_json": "DT_ItemShopCreateData_Common.json",
        "generated_json": "DT_ItemShopCreateData_Common.PFT_Economy.json",
        "asset": "DT_ItemShopCreateData_Common",
        "kind": "create",
    },
    "lotteryData": {
        "source_json": "DT_ItemShopLotteryData.json",
        "generated_json": "DT_ItemShopLotteryData.PFT_Economy.json",
        "asset": "DT_ItemShopLotteryData",
        "kind": "lottery",
    },
    "lotteryDataCommon": {
        "source_json": "DT_ItemShopLotteryData_Common.json",
        "generated_json": "DT_ItemShopLotteryData_Common.PFT_Economy.json",
        "asset": "DT_ItemShopLotteryData_Common",
        "kind": "lottery",
    },
}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def read_json(path: Path) -> Any:
    require(path.is_file(), f"missing JSON file: {path}")
    return json.loads(path.read_text(encoding="utf-8"))


def sha256(path: Path) -> str:
    require(path.is_file(), f"missing file for SHA256: {path}")
    return hashlib.sha256(path.read_bytes()).hexdigest().upper()


def table_rows(document: dict[str, Any]) -> list[dict[str, Any]]:
    for export in document.get("Exports", []):
        table = export.get("Table")
        if isinstance(table, dict) and isinstance(table.get("Data"), list):
            return table["Data"]
    raise AssertionError("UAsset JSON does not contain a DataTable export")


def property_value(properties: list[dict[str, Any]], name: str) -> Any:
    for item in properties:
        if item.get("Name") == name:
            return item.get("Value")
    raise AssertionError(f"missing property: {name}")


def decode_create_row(row: dict[str, Any]) -> list[dict[str, Any]]:
    products = property_value(row["Value"], "productDataArray")
    result: list[dict[str, Any]] = []
    for product in products:
        values = product["Value"]
        result.append(
            {
                "itemId": property_value(values, "StaticItemId"),
                "productType": property_value(values, "ProductType"),
                "overridePrice": property_value(values, "OverridePrice"),
                "productNum": property_value(values, "ProductNum"),
                "stock": property_value(values, "Stock"),
            }
        )
    return result


def decode_lottery_row(row: dict[str, Any]) -> list[dict[str, Any]]:
    groups = property_value(row["Value"], "lotteryDataArray")
    result: list[dict[str, Any]] = []
    for group in groups:
        values = group["Value"]
        result.append(
            {
                "shopGroupName": property_value(values, "ShopGroupName"),
                "weight": property_value(values, "Weight"),
            }
        )
    return result


def verify_contract(
    contract: dict[str, Any],
    economy: dict[str, Any],
) -> None:
    require(contract["schemaVersion"] == "1.0.0", "shop schema drifted")
    require(
        contract["baselineStatus"]
        == "offline_shop_asset_and_catalog_ready_runtime_disabled_2026-07-29",
        "shop baseline is not the offline-ready disabled baseline",
    )
    policy = contract["designPolicy"]
    require(
        policy["merchantOrganisationId"] == "pwft.commerce.merchant_guild",
        "merchant organisation ID drifted",
    )
    require(
        policy["fixedCountersAreMerchantGuildEmployees"] is True,
        "fixed counters must be Merchant Guild employees",
    )
    require(
        policy["fixedCountersAreFactionMembers"] is False,
        "fixed counters cannot be faction members",
    )
    require(
        policy["allCountersUseItemShop"] is True,
        "all seven counters must use ordinary ItemShop",
    )
    require(
        policy["raynePalMerchantIsExcludedSpecialCase"] is True,
        "Rayne Pal merchant must remain an excluded special case",
    )

    representatives = contract["representatives"]
    require(len(representatives) == 7, "expected seven shop representatives")
    expected_factions = {row["factionId"] for row in economy["factions"]}
    observed_factions = {
        row["representedFactionId"] for row in representatives
    }
    require(
        observed_factions == expected_factions,
        "shop representatives do not cover the seven economy factions",
    )
    require(
        {row["slotIndex"] for row in representatives} == set(range(7)),
        "shop slots must cover zero through six",
    )
    for key in (
        "nativeCharacterId",
        "nativeCharacterClassPath",
        "lotteryRowName",
        "productGroupRowName",
    ):
        require(
            len({row[key] for row in representatives}) == 7,
            f"representative {key} values must be unique",
        )
    require(
        {row["nativeCharacterId"] for row in representatives}
        == {f"NPC_Male_Trader01_v{version:02d}" for version in range(4, 11)},
        "representatives must use the seven ordinary v04-v10 traders",
    )

    rayne = next(
        row
        for row in representatives
        if row["representedFactionId"] == "pwft.faction.rayne_syndicate"
    )
    require(
        rayne["nativeCharacterId"] == "NPC_Male_Trader01_v10",
        "Rayne ItemShop representative must use v10",
    )
    require(
        rayne["sourceNativeShopRowName"] == "CaravanShop5",
        "Rayne v10 source ItemShop row drifted",
    )
    require(
        "DarkTrader" not in rayne["nativeCharacterClassPath"]
        and "PalShop" not in rayne["nativeCharacterClassPath"],
        "Rayne economy counter cannot use the Pal merchant special case",
    )

    procurement = contract["procurementAdapter"]
    require(
        procurement["nativeItemShopRequestedItemFilterAvailable"] is False,
        "native requested-item filter must remain unavailable",
    )
    require(
        procurement["nativeItemShopProcurementPriceOverrideAvailable"] is False,
        "native procurement price override must remain unavailable",
    )
    require(
        procurement["targetPriceSettlementMode"]
        == "native_sale_plus_mod_bonus_after_confirmed_server_success",
        "procurement settlement contract drifted",
    )
    require(
        procurement["serverSuccessSignalStatus"]
        == "native_server_request_plus_inventory_replication_confirmation_enabled",
        "server sale settlement must require native request plus inventory replication",
    )
    require(
        procurement["moneyBonusMutationEnabled"] is False
        and procurement["commerceReputationSettlementEnabled"] is True,
        "procurement reputation must use the confirmed native-sale gate without money mutation",
    )

    activation = contract["runtimeActivation"]
    require(
        activation["customProductRowsReady"] is True,
        "custom rows must be marked ready",
    )
    for key in (
        "customProductRowsEnabled",
        "nativeMerchantSpawnEnabled",
        "nativeShopBindingEnabled",
    ):
        require(activation[key] is True, f"{key} must be enabled for live acceptance")
    for key in (
        "dynamicRestockEnabled",
        "procurementMoneyBonusEnabled",
    ):
        require(activation[key] is False, f"{key} must remain disabled")
    require(
        activation["procurementCommerceReputationEnabled"] is True,
        "confirmed requested-sale reputation settlement must be enabled",
    )


def verify_sources(contract: dict[str, Any]) -> None:
    native_assets = contract["nativeItemShopAssets"]
    for contract_key, table in TABLES.items():
        source_info = native_assets[contract_key]
        source_asset = PROJECT_ROOT / source_info["sourceAsset"]
        require(
            sha256(source_asset) == source_info["sourceSha256"],
            f"source asset hash drifted: {contract_key}",
        )
        source_rows = table_rows(
            read_json(SOURCE_JSON_ROOT / table["source_json"])
        )
        require(
            len(source_rows) == source_info["sourceRowCount"] == 38,
            f"source row count drifted: {contract_key}",
        )
        require(
            not any(
                row["Name"].startswith("PFT_Economy_")
                for row in source_rows
            ),
            f"source table already contains custom rows: {contract_key}",
        )

    require(
        sha256(UASSETGUI_PATH)
        == "B7D75C0893F1A60E565853AE638BC21F2416CD12C2D9D854E297ABB87CEB3263",
        "official UAssetGUI v1.1.0 executable hash drifted",
    )
    require(MAPPING_PATH.is_file(), "Palworld UAssetGUI mapping is missing")


def verify_v10_native_asset() -> None:
    character_base = (
        NATIVE_MERCHANT_ROOT
        / "Blueprint"
        / "Character"
        / "NPC"
        / "Normal"
        / "BP_NPC_Male_Trader01_v10"
    )
    character_bytes = (
        character_base.with_suffix(".uasset").read_bytes()
        + character_base.with_suffix(".uexp").read_bytes()
    )
    for token in (
        b"NPC_Male_Trader01_v10",
        b"BP_NPC_Male_Trader01_v10_C",
        b"CaravanShop5",
    ):
        require(token in character_bytes, f"v10 native asset lacks {token!r}")

    human_parameter_base = (
        NATIVE_MERCHANT_ROOT
        / "DataTable"
        / "Character"
        / "DT_PalHumanParameter"
    )
    human_parameter_bytes = (
        human_parameter_base.with_suffix(".uasset").read_bytes()
        + human_parameter_base.with_suffix(".uexp").read_bytes()
    )
    require(
        b"NPC_Male_Trader01_v10" in human_parameter_bytes,
        "v10 trader is missing from DT_PalHumanParameter",
    )


def verify_catalog_and_json(
    contract: dict[str, Any],
    economy: dict[str, Any],
) -> None:
    catalog = read_json(GENERATED_ROOT / "catalog.v1.json")
    require(
        catalog["economyContractSha256"] == sha256(ECONOMY_PATH),
        "catalog economy contract hash is stale",
    )
    require(
        catalog["shopContractSha256"] == sha256(CONTRACT_PATH),
        "catalog shop contract hash is stale",
    )
    require(
        catalog["balanceProfileId"]
        == "pwft.economy.balance.supply_band_v1",
        "catalog balance profile drifted",
    )
    require(
        catalog["totals"]
        == {
            "representatives": 7,
            "productRows": 26,
            "requestedRows": 37,
            "marketSignals": 63,
        },
        "catalog totals drifted",
    )
    require(
        catalog["runtimeActivation"] == contract["runtimeActivation"],
        "catalog runtime activation differs from shop contract",
    )
    require(
        catalog["procurementSettlement"]["moneyBonusMutationEnabled"] is False
        and catalog["procurementSettlement"][
            "commerceReputationSettlementEnabled"
        ]
        is True,
        "catalog requested-sale reputation settlement must be enabled without money mutation",
    )

    catalog_representatives = {
        row["representedFactionId"]: row for row in catalog["representatives"]
    }
    require(
        set(catalog_representatives)
        == {row["factionId"] for row in economy["factions"]},
        "catalog representative coverage drifted",
    )
    require(
        sum(len(row["products"]) for row in catalog["representatives"]) == 26,
        "catalog product rows do not total 26",
    )
    require(
        sum(
            len(row["requestedItems"])
            for row in catalog["representatives"]
        )
        == 37,
        "catalog requested rows do not total 37",
    )

    for contract_key, table in TABLES.items():
        generated_path = GENERATED_ROOT / table["generated_json"]
        generated = read_json(generated_path)
        source = read_json(SOURCE_JSON_ROOT / table["source_json"])
        source_rows = table_rows(source)
        generated_rows = table_rows(generated)
        require(
            len(generated_rows) == len(source_rows) + 7 == 45,
            f"generated table must contain 45 rows: {contract_key}",
        )
        require(
            generated_rows[: len(source_rows)] == source_rows,
            f"native rows changed while appending shop rows: {contract_key}",
        )
        custom = {
            row["Name"]: row
            for row in generated_rows
            if row["Name"].startswith("PFT_Economy_")
        }
        require(
            len(custom) == 7,
            f"expected seven custom rows: {contract_key}",
        )

        for representative in catalog["representatives"]:
            if table["kind"] == "create":
                row_name = representative["productGroupRowName"]
                observed = decode_create_row(custom[row_name])
                expected = [
                    {
                        "itemId": item["itemId"],
                        "productType": "Normal",
                        "overridePrice": item["overridePrice"],
                        "productNum": item["productNum"],
                        "stock": item["stock"],
                    }
                    for item in representative["products"]
                ]
            else:
                row_name = representative["lotteryRowName"]
                observed = decode_lottery_row(custom[row_name])
                expected = [
                    {
                        "shopGroupName": representative[
                            "productGroupRowName"
                        ],
                        "weight": 100,
                    }
                ]
            require(
                observed == expected,
                f"custom row content drifted: {contract_key}/{row_name}",
            )

        roundtrip_path = (
            ROUNDTRIP_ROOT / f"{table['asset']}.roundtrip.json"
        )
        roundtrip_rows = table_rows(read_json(roundtrip_path))
        roundtrip_custom = [
            row
            for row in roundtrip_rows
            if row["Name"].startswith("PFT_Economy_")
        ]
        generated_custom = [
            row
            for row in generated_rows
            if row["Name"].startswith("PFT_Economy_")
        ]
        require(
            roundtrip_custom == generated_custom,
            f"compiled roundtrip custom rows differ: {contract_key}",
        )


def verify_compiled_assets_and_pak() -> None:
    expected_files = {
        f"{table['asset']}{extension}"
        for table in TABLES.values()
        for extension in (".uasset", ".uexp")
    }
    observed_files = {
        path.name for path in COMPILED_ROOT.iterdir() if path.is_file()
    }
    require(
        observed_files == expected_files,
        "compiled asset root must contain exactly eight asset files",
    )
    for filename in expected_files:
        require(
            (COMPILED_ROOT / filename).stat().st_size > 0,
            f"compiled asset is empty: {filename}",
        )

    require(PAK_PATH.is_file(), "economy shop PAK is missing")
    require(PAK_PATH.stat().st_size > 0, "economy shop PAK is empty")
    require(REPAK_PATH.is_file(), "repak v0.2.3 is missing")
    result = subprocess.run(
        [str(REPAK_PATH), "hash-list", str(PAK_PATH)],
        cwd=PROJECT_ROOT,
        check=True,
        capture_output=True,
        text=True,
        encoding="utf-8",
    )
    entries: dict[str, str] = {}
    for line in result.stdout.splitlines():
        digest, separator, entry = line.partition(" ")
        require(separator == " ", f"invalid repak hash-list line: {line}")
        entries[entry.replace("\\", "/")] = digest.upper()
    expected_entries = {
        f"Pal/Content/Pal/DataTable/ItemShop/{filename}"
        for filename in expected_files
    }
    require(
        set(entries) == expected_entries,
        "PAK must contain exactly the eight expected shop assets",
    )
    for filename in expected_files:
        entry = f"Pal/Content/Pal/DataTable/ItemShop/{filename}"
        require(
            entries[entry] == sha256(COMPILED_ROOT / filename),
            f"PAK content hash differs from compiled file: {filename}",
        )


def main() -> int:
    contract = read_json(CONTRACT_PATH)
    economy = read_json(ECONOMY_PATH)
    verify_contract(contract, economy)
    verify_sources(contract)
    verify_v10_native_asset()
    verify_catalog_and_json(contract, economy)
    verify_compiled_assets_and_pak()
    print(
        "PASS faction economy shops "
        "(7 representatives, 26 products, 37 requested items, "
        "63 signals, 4 roundtrips, 8 PAK entries, "
        "confirmed-sale reputation enabled)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
