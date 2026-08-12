from __future__ import annotations

import json
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
CONTRACTS = PROJECT_ROOT / "contracts"
EVIDENCE_ITEM_ROOT = (
    PROJECT_ROOT
    / "evidence"
    / "faction-economy-assets-20260729"
    / "Pal"
    / "Content"
    / "Pal"
    / "DataTable"
    / "Item"
)


class Check:
    def __init__(self) -> None:
        self.count = 0

    def require(self, condition: bool, message: str) -> None:
        self.count += 1
        if not condition:
            raise AssertionError(message)


def load(name: str) -> dict:
    return json.loads((CONTRACTS / name).read_text(encoding="utf-8"))


def load_data_table(name: str) -> dict[str, dict]:
    payload = json.loads(
        (EVIDENCE_ITEM_ROOT / name).read_text(encoding="utf-8")
    )
    return {
        row["Name"]: {
            property_data["Name"]: property_data.get("Value")
            for property_data in row["Value"]
        }
        for row in payload["Exports"][0]["Table"]["Data"]
    }


def recipe_materials(recipe: dict) -> list[dict]:
    materials = []
    for index in range(1, 6):
        item_id = recipe.get(f"Material{index}_Id")
        count = recipe.get(f"Material{index}_Count")
        if item_id:
            materials.append({"itemId": item_id, "count": count})
    return materials


def main() -> int:
    check = Check()
    economy = load("faction_economy.v1.json")
    islands = load("island_territories.v2.json")
    progression = load("faction_progression.v1.json")
    commerce = load("faction_commerce.v1.json")

    policy = economy["designPolicy"]
    check.require(
        economy["baselineStatus"]
        == "user_confirmed_trade_direction_resource_and_recipe_baseline_complete_balance_pending_2026-07-29",
        "faction economy is not marked as a user-confirmed direction baseline",
    )
    check.require(
        policy["merchantOrganisationFactionId"] is None,
        "Merchant Guild must remain independent from every faction",
    )
    check.require(
        policy["merchantOrganisationDisplayNameZhHans"] == "商人商会",
        "Merchant Guild display name drifted",
    )
    for key in (
        "factionsAreSuppliersAndCustomers",
        "merchantGuildIsTradeChannel",
        "sellsProcessedGoodsFromLocalResources",
        "procuresGoodsMissingFromLocalSupply",
        "sameProcessedGoodMayAppearForMultipleFactions",
        "greaterLocalSupplyMeansMoreStock",
        "greaterLocalSupplyMeansLowerSellPrice",
        "greaterLocalScarcityMeansStrongerProcurementDemand",
        "existingVanillaMerchantInputsAreExternalSupply",
        "externalMerchantInputsAffectCostButNotRegionalSupplyBand",
        "purchasedFactionGoodsGrantCommerceReputation",
        "sellingRequestedGoodsGrantsCommerceReputation",
    ):
        check.require(policy[key] is True, f"required economy policy disabled: {key}")
    check.require(
        policy["sellingUnrequestedGoodsGrantsCommerceReputation"] is False,
        "unrequested goods must not grant commerce reputation",
    )
    check.require(
        policy["commerceReputationCapsOwnedBy"] == "faction_progression.v1.json",
        "commerce reputation caps must remain owned by faction progression",
    )
    merchant_inputs = economy["merchantInputPolicy"]
    check.require(
        merchant_inputs["regionalEndowmentAuditRequired"] is False,
        "existing merchant inputs must not require regional endowment audits",
    )
    check.require(
        merchant_inputs["countsTowardEffectiveSupplyBand"] is False,
        "existing merchant inputs must not reduce territorial supply bands",
    )
    check.require(
        merchant_inputs["countsTowardProductCostFloor"] is True,
        "existing merchant inputs must remain part of the product cost floor",
    )
    check.require(
        merchant_inputs["source"]
        == "existing_vanilla_merchants_user_confirmed_2026-07-29",
        "existing merchant input decision source drifted",
    )
    check.require(
        {entry["itemId"] for entry in merchant_inputs["inputs"]}
        == {
            "Pal_crystal_S",
            "FireOrgan",
            "Charcoal",
            "PalOil",
            "Polymer",
        },
        "existing merchant input list drifted",
    )

    resource_ids = [entry["resourceId"] for entry in economy["resources"]]
    check.require(len(resource_ids) == 8, "expected eight mineral resource channels")
    check.require(
        len(resource_ids) == len(set(resource_ids)),
        "resource IDs must be unique",
    )
    check.require(
        all(
            entry["recipeAuditStatus"].startswith("audited_")
            for entry in economy["resources"]
        ),
        "every mineral channel must carry a completed local recipe audit status",
    )

    recipes = load_data_table("DT_ItemRecipeDataTable.json")
    recipes_common = load_data_table("DT_ItemRecipeDataTable_Common.json")
    items = load_data_table("DT_ItemDataTable.json")
    items_common = load_data_table("DT_ItemDataTable_Common.json")
    check.require(len(recipes) == 1414, "unexpected recipe row count")
    check.require(len(items) == 2466, "unexpected item row count")
    check.require(
        recipes == recipes_common,
        "recipe Common and non-Common tables must remain identical",
    )
    check.require(
        items == items_common,
        "item Common and non-Common tables must remain identical",
    )
    for resource in economy["resources"]:
        check.require(
            resource["nativeBasePrice"]
            == items[resource["nativeItemId"]]["Price"],
            f"{resource['nativeItemId']} territorial resource price drifted",
        )
    for merchant_input in merchant_inputs["inputs"]:
        check.require(
            merchant_input["nativeBasePrice"]
            == items[merchant_input["itemId"]]["Price"],
            f"{merchant_input['itemId']} merchant input price drifted",
        )

    expected_products = {
        "CopperIngot": {
            "displayNameZhHans": "金属锭",
            "productCount": 1,
            "nativeBasePrice": 240,
            "materials": [{"itemId": "CopperOre", "count": 2}],
        },
        "IronIngot": {
            "displayNameZhHans": "精炼金属锭",
            "productCount": 1,
            "nativeBasePrice": 720,
            "materials": [
                {"itemId": "CopperOre", "count": 2},
                {"itemId": "Coal", "count": 2},
            ],
        },
        "StealIngot": {
            "displayNameZhHans": "帕鲁金属锭",
            "productCount": 1,
            "nativeBasePrice": 1250,
            "materials": [
                {"itemId": "CopperOre", "count": 4},
                {"itemId": "Quartz", "count": 1},
                {"itemId": "Pal_crystal_S", "count": 2},
            ],
        },
        "CarbonFiber": {
            "displayNameZhHans": "碳纤维",
            "productCount": 1,
            "nativeBasePrice": 840,
            "materials": [
                {"itemId": "Coal", "count": 2},
                {"itemId": "FireOrgan", "count": 1},
            ],
        },
        "Gunpowder2": {
            "displayNameZhHans": "火药",
            "productCount": 1,
            "nativeBasePrice": 430,
            "materials": [
                {"itemId": "Charcoal", "count": 2},
                {"itemId": "Sulfur", "count": 1},
            ],
        },
        "Polymer": {
            "displayNameZhHans": "聚合物",
            "productCount": 1,
            "nativeBasePrice": 1080,
            "materials": [
                {"itemId": "PalOil", "count": 2},
                {"itemId": "Sulfur", "count": 1},
            ],
        },
        "MachineParts2": {
            "displayNameZhHans": "电路板",
            "productCount": 1,
            "nativeBasePrice": 2500,
            "materials": [
                {"itemId": "Quartz", "count": 2},
                {"itemId": "Polymer", "count": 1},
            ],
        },
        "Plastic": {
            "displayNameZhHans": "塑钢",
            "productCount": 1,
            "nativeBasePrice": 2520,
            "materials": [
                {"itemId": "CrudeOil", "count": 2},
                {"itemId": "CopperOre", "count": 5},
            ],
        },
        "StainlessSteel": {
            "displayNameZhHans": "六棱晶锭",
            "productCount": 1,
            "nativeBasePrice": 3000,
            "materials": [
                {"itemId": "Chromium", "count": 1},
                {"itemId": "RainbowCrystal", "count": 1},
            ],
        },
    }
    contract_products = {
        entry["productItemId"]: entry for entry in economy["auditedProducts"]
    }
    check.require(
        set(contract_products) == set(expected_products),
        "audited product candidates drifted",
    )
    for product_id, expected in expected_products.items():
        contract_product = contract_products[product_id]
        source_recipe = recipes[product_id]
        source_item = items[product_id]
        for field in ("displayNameZhHans", "productCount", "nativeBasePrice"):
            check.require(
                contract_product[field] == expected[field],
                f"{product_id} contract {field} drifted",
            )
        check.require(
            source_recipe["Product_Id"] == product_id,
            f"{product_id} source recipe product ID drifted",
        )
        check.require(
            source_recipe["Product_Count"] == expected["productCount"],
            f"{product_id} source recipe count drifted",
        )
        check.require(
            source_item["Price"] == expected["nativeBasePrice"],
            f"{product_id} native base price drifted",
        )
        check.require(
            recipe_materials(source_recipe) == expected["materials"],
            f"{product_id} source recipe materials drifted",
        )
        check.require(
            contract_product["materials"] == expected["materials"],
            f"{product_id} contract materials drifted",
        )

    check.require(
        recipe_materials(recipes["ManganeseIngot"])
        == [
            {"itemId": "ManganeseOre", "count": 2},
            {"itemId": "Coal", "count": 5},
        ],
        "ManganeseIngot must remain Coralum Ingot, not Hexolite",
    )
    check.require(
        recipe_materials(recipes["SkyislandIngot"])
        == [
            {"itemId": "SkyIslandOre", "count": 2},
            {"itemId": "Quartz", "count": 2},
        ],
        "Soralite Ingot recipe drifted",
    )

    island_owner_map = {
        island["humanOwnerFactionId"]: island["id"]
        for island in islands["islands"]
    }
    expected_factions = set(progression["humanFactionIds"])
    economy_factions = {
        entry["factionId"]: entry for entry in economy["factions"]
    }
    check.require(
        set(economy_factions) == expected_factions,
        "economy factions must exactly match the seven human progression factions",
    )
    check.require(
        set(island_owner_map) == expected_factions,
        "active whole-island ownership must exactly match the economy factions",
    )

    valid_bands = set(economy["supplyBands"]["orderedLowToHigh"])
    for faction_id, entry in economy_factions.items():
        check.require(
            entry["territoryId"] == island_owner_map[faction_id],
            f"territory owner mismatch for {faction_id}",
        )
        baseline = entry["resourceBaseline"]
        check.require(
            set(baseline) == set(resource_ids),
            f"resource baseline is incomplete for {faction_id}",
        )
        for resource_id, observation in baseline.items():
            ordinary = observation["ordinaryNodes"]
            veins = observation["veins"]
            band = observation["supplyBand"]
            check.require(
                isinstance(ordinary, int) and ordinary >= 0,
                f"invalid ordinary-node count for {faction_id}/{resource_id}",
            )
            check.require(
                isinstance(veins, int) and veins >= 0,
                f"invalid vein count for {faction_id}/{resource_id}",
            )
            check.require(
                band in valid_bands,
                f"invalid supply band for {faction_id}/{resource_id}",
            )
            if ordinary == 0 and veins == 0:
                check.require(
                    band == "absent",
                    f"zero local supply must be absent for {faction_id}/{resource_id}",
                )
            else:
                check.require(
                    band != "absent",
                    f"positive local supply cannot be absent for {faction_id}/{resource_id}",
                )

    market = economy["marketRules"]
    check.require(
        market["crossFactionTradeRoutesAreIntentional"] is True,
        "cross-faction buy-low/sell-needed trade routes are part of the design",
    )
    check.require(
        market["merchantInputRule"]
        == "existing merchant supplied inputs contribute to product cost but never reduce the faction territorial supply band",
        "merchant-supplied input cost and supply-band rule drifted",
    )
    balance = market["balanceProfile"]
    check.require(
        balance["profileId"] == "pwft.economy.balance.supply_band_v1",
        "balance profile ID drifted",
    )
    check.require(
        balance["status"]
        == "offline_first_pass_complete_user_confirmation_and_live_calibration_pending",
        "balance profile status drifted",
    )
    check.require(
        balance["runtimeAuthority"] is False,
        "offline balance profile cannot mutate runtime shops",
    )
    check.require(
        balance["supplyIndexMode"]
        == "audited_supply_band_only_no_numeric_vein_weight",
        "balance profile must not fabricate a vein production weight",
    )
    check.require(
        balance["refreshWindowIdProvider"] == "external-world-day-adapter"
        and balance["refreshDurationMinutes"] is None,
        "refresh duration must remain pending live calibration",
    )
    check.require(
        balance["priceRoundingStep"] == 10
        and balance["merchantInputCostFloorMultiplier"] == 1.2,
        "price rounding or merchant-input cost floor drifted",
    )
    check.require(
        balance["minimumUnitsPerActiveLine"] == 1
        and balance["maximumUnitsPerActiveLine"] == 99,
        "active market-line unit caps drifted",
    )
    expected_bands = {
        "absent": {
            "direction": "procure",
            "procurementPriceMultiplier": 1.4,
            "procurementValueBudget": 30000,
        },
        "scarce": {
            "direction": "procure",
            "procurementPriceMultiplier": 1.2,
            "procurementValueBudget": 18000,
        },
        "limited": {
            "direction": "sell",
            "sellPriceMultiplier": 1.15,
            "stockValueBudget": 8000,
        },
        "established": {
            "direction": "sell",
            "sellPriceMultiplier": 1.0,
            "stockValueBudget": 16000,
        },
        "strong": {
            "direction": "sell",
            "sellPriceMultiplier": 0.9,
            "stockValueBudget": 28000,
        },
        "abundant": {
            "direction": "sell",
            "sellPriceMultiplier": 0.82,
            "stockValueBudget": 40000,
        },
        "dominant": {
            "direction": "sell",
            "sellPriceMultiplier": 0.75,
            "stockValueBudget": 60000,
        },
        "exclusive": {
            "direction": "sell",
            "sellPriceMultiplier": 0.7,
            "stockValueBudget": 80000,
        },
    }
    check.require(
        balance["bands"] == expected_bands,
        "supply-band balance parameters drifted",
    )
    sell_bands = [
        expected_bands[band]
        for band in economy["supplyBands"]["orderedLowToHigh"]
        if expected_bands[band]["direction"] == "sell"
    ]
    for previous, current in zip(sell_bands, sell_bands[1:]):
        check.require(
            current["sellPriceMultiplier"]
            <= previous["sellPriceMultiplier"],
            "sell multiplier rises with supply",
        )
        check.require(
            current["stockValueBudget"] >= previous["stockValueBudget"],
            "stock value budget falls with supply",
        )
    check.require(
        expected_bands["absent"]["procurementPriceMultiplier"]
        >= expected_bands["scarce"]["procurementPriceMultiplier"]
        and expected_bands["absent"]["procurementValueBudget"]
        >= expected_bands["scarce"]["procurementValueBudget"],
        "more severe scarcity must not weaken procurement",
    )
    check.require(
        market["exactSellPriceMultipliers"]
        == "marketRules.balanceProfile.bands[*].sellPriceMultiplier"
        and market["exactStockCounts"] == "derived_by_stockCountFormula"
        and market["exactProcurementPrices"]
        == "nativeBasePrice_x_band_procurementPriceMultiplier"
        and market["exactProcurementQuotas"]
        == "derived_by_procurementQuotaFormula",
        "balance formula bindings drifted",
    )
    check.require(
        market["balanceStatus"]
        == "offline_first_pass_complete_user_confirmation_and_live_calibration_pending",
        "market balance status drifted",
    )
    check.require(
        commerce["transactionPolicy"]["requestedSaleAward"]["unrequestedItemAward"]
        == 0,
        "commerce adapter must not reward unrequested sales",
    )
    progression_commerce = progression["reputationSources"]["commerce"]
    check.require(
        progression_commerce["primarySource"] is False,
        "commerce must remain a capped secondary reputation source",
    )
    check.require(
        progression_commerce["canReachLordAlone"] is False,
        "commerce cannot reach Lord without task/defense progression",
    )
    check.require(
        progression_commerce["negativeRecoveryCapPerWindow"] > 0
        and progression_commerce["nonNegativeCapPerWindow"] > 0,
        "commerce recovery and friendly caps must remain positive",
    )

    activation = economy["runtimeActivation"]
    for key in (
        "nativeMerchantSpawnEnabled",
        "customProductRowsEnabled",
        "dynamicPriceRuntimeEnabled",
    ):
        check.require(
            activation[key] is False,
            f"economy runtime feature must remain disabled before validation: {key}",
        )
    check.require(
        activation["requestedSaleReputationSettlementEnabled"] is True,
        "requested-sale reputation must use the confirmed native-sale gate",
    )

    print(
        "PASS faction economy contract "
        f"({check.count} assertions, {len(economy_factions)} factions, "
        f"{len(resource_ids)} resources)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
