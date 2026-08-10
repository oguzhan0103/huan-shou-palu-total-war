from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
MOD_ROOT = PROJECT_ROOT / "mod0" / "ue4ss" / "PalFactionTerritory0"
SCRIPTS_ROOT = MOD_ROOT / "Scripts"
NATIVE_MERCHANT_EVIDENCE = (
    PROJECT_ROOT / "evidence" / "native-merchant-assets-20260728"
)
HUMAN_PARAMETER_ASSET = (
    NATIVE_MERCHANT_EVIDENCE
    / "Pal"
    / "Content"
    / "Pal"
    / "DataTable"
    / "Character"
    / "DT_PalHumanParameter.uasset"
)
ITEM_PARAMETER_ASSET = (
    PROJECT_ROOT
    / "evidence"
    / "shop-assets-20260723"
    / "Pal"
    / "Content"
    / "Pal"
    / "DataAsset"
    / "Item"
    / "DA_StaticItemDataAsset.uasset"
)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def contains_ascii_asset_name(asset_bytes: bytes, value: str) -> bool:
    encoded = value.encode("ascii")
    return (
        re.search(
            rb"(?<![A-Za-z0-9_])" + re.escape(encoded) + rb"\x00",
            asset_bytes,
        )
        is not None
    )


def evidence_uasset_for_class_path(class_path: str) -> Path:
    package_path, separator, _ = class_path.partition(".")
    require(
        separator == "."
        and package_path.startswith("/Game/")
        and package_path.count("/") >= 2,
        f"invalid native class path: {class_path}",
    )
    return (
        NATIVE_MERCHANT_EVIDENCE
        / "Pal"
        / "Content"
        / (package_path.removeprefix("/Game/") + ".uasset")
    )


def main() -> int:
    required = [
        MOD_ROOT / "enabled.txt",
        MOD_ROOT / "State" / "README.txt",
        SCRIPTS_ROOT / "main.lua",
        SCRIPTS_ROOT / "pwft" / "config.lua",
        SCRIPTS_ROOT / "pwft" / "content_pack_registry.lua",
        SCRIPTS_ROOT / "pwft" / "content_runtime.lua",
        SCRIPTS_ROOT / "pwft" / "ending_runtime.lua",
        SCRIPTS_ROOT / "pwft" / "commerce_bridge.lua",
        SCRIPTS_ROOT / "pwft" / "faction_api.lua",
        SCRIPTS_ROOT / "pwft" / "faction_commerce.lua",
        SCRIPTS_ROOT / "pwft" / "faction_defense.lua",
        SCRIPTS_ROOT / "pwft" / "faction_economy.lua",
        SCRIPTS_ROOT / "pwft" / "faction_economy_merchant_runtime.lua",
        SCRIPTS_ROOT / "pwft" / "faction_economy_shop_catalog.lua",
        SCRIPTS_ROOT / "pwft" / "faction_guard.lua",
        SCRIPTS_ROOT / "pwft" / "faction_join.lua",
        SCRIPTS_ROOT / "pwft" / "faction_merchant_runtime.lua",
        SCRIPTS_ROOT / "pwft" / "faction_progression.lua",
        SCRIPTS_ROOT / "pwft" / "faction_ui_model.lua",
        SCRIPTS_ROOT / "pwft" / "faction_ui_presenter.lua",
        SCRIPTS_ROOT / "pwft" / "json.lua",
        SCRIPTS_ROOT / "pwft" / "native_character_adapter.lua",
        SCRIPTS_ROOT / "pwft" / "pal_reconciliation.lua",
        SCRIPTS_ROOT / "pwft" / "pal_raid_result_adapter.lua",
        SCRIPTS_ROOT / "pwft" / "pal_discourse_runtime.lua",
        SCRIPTS_ROOT / "pwft" / "pal_dialogue_controller.lua",
        SCRIPTS_ROOT / "pwft" / "pal_dialogue_presenter.lua",
        SCRIPTS_ROOT / "pwft" / "pal_representative_interaction.lua",
        SCRIPTS_ROOT / "pwft" / "registry.lua",
        SCRIPTS_ROOT / "pwft" / "policy.lua",
        SCRIPTS_ROOT / "pwft" / "progression_identity.lua",
        SCRIPTS_ROOT / "pwft" / "progression_store.lua",
        SCRIPTS_ROOT / "pwft" / "quest_runtime.lua",
        SCRIPTS_ROOT / "pwft" / "strategic_world.lua",
        SCRIPTS_ROOT / "pwft" / "runtime.lua",
        SCRIPTS_ROOT / "pwft" / "settlement_raid.lua",
        SCRIPTS_ROOT / "pwft" / "world_balance.lua",
        SCRIPTS_ROOT / "pwft" / "pal_faction_island_mask.lua",
        PROJECT_ROOT / "mod0" / "tests" / "policy_spec.lua",
        PROJECT_ROOT / "mod0" / "tests" / "faction_api_spec.lua",
        PROJECT_ROOT / "mod0" / "tests" / "commerce_bridge_spec.lua",
        PROJECT_ROOT / "mod0" / "tests" / "faction_commerce_spec.lua",
        PROJECT_ROOT / "mod0" / "tests" / "faction_economy_spec.lua",
        PROJECT_ROOT / "mod0" / "tests" / "faction_economy_merchant_runtime_spec.lua",
        PROJECT_ROOT / "mod0" / "tests" / "faction_economy_shop_catalog_spec.lua",
        PROJECT_ROOT / "mod0" / "tests" / "faction_services_spec.lua",
        PROJECT_ROOT / "mod0" / "tests" / "faction_ui_presenter_spec.lua",
        PROJECT_ROOT / "mod0" / "tests" / "faction_merchant_runtime_spec.lua",
        PROJECT_ROOT / "mod0" / "tests" / "faction_join_spec.lua",
        PROJECT_ROOT / "mod0" / "tests" / "faction_progression_spec.lua",
        PROJECT_ROOT / "mod0" / "tests" / "pal_reconciliation_spec.lua",
        PROJECT_ROOT / "mod0" / "tests" / "pal_raid_result_adapter_spec.lua",
        PROJECT_ROOT / "mod0" / "tests" / "pal_discourse_runtime_spec.lua",
        PROJECT_ROOT / "mod0" / "tests" / "pal_dialogue_controller_spec.lua",
        PROJECT_ROOT / "mod0" / "tests" / "pal_dialogue_presenter_spec.lua",
        PROJECT_ROOT / "mod0" / "tests" / "pal_representative_interaction_spec.lua",
        PROJECT_ROOT / "mod0" / "tests" / "content_pack_registry_spec.lua",
        PROJECT_ROOT / "mod0" / "tests" / "content_runtime_spec.lua",
        PROJECT_ROOT / "mod0" / "tests" / "quest_runtime_spec.lua",
        PROJECT_ROOT / "mod0" / "tests" / "strategic_world_spec.lua",
        PROJECT_ROOT / "mod0" / "tests" / "ending_runtime_spec.lua",
        PROJECT_ROOT / "mod0" / "tests" / "content_pack_author_sdk_e2e_spec.lua",
        PROJECT_ROOT / "examples" / "minimal-content-pack" / "README.md",
        PROJECT_ROOT / "examples" / "minimal-content-pack" / "pack.lua",
        PROJECT_ROOT / "examples" / "minimal-content-pack" / "manifest.lua",
        PROJECT_ROOT / "examples" / "minimal-content-pack" / "localization_keys.lua",
        PROJECT_ROOT / "examples" / "minimal-content-pack" / "quest_template.lua",
        PROJECT_ROOT / "examples" / "minimal-content-pack" / "strategic_world.lua",
        PROJECT_ROOT / "examples" / "minimal-content-pack" / "ending_routes.lua",
        PROJECT_ROOT / "examples" / "minimal-content-pack" / "pal_discourse.lua",
        PROJECT_ROOT / "mod0" / "tests" / "json_spec.lua",
        PROJECT_ROOT / "mod0" / "tests" / "native_character_adapter_spec.lua",
        PROJECT_ROOT / "mod0" / "tests" / "progression_identity_spec.lua",
        PROJECT_ROOT / "mod0" / "tests" / "progression_store_spec.lua",
        PROJECT_ROOT / "mod0" / "tests" / "runtime_smoke.lua",
        PROJECT_ROOT / "mod0" / "tests" / "world_balance_spec.lua",
        PROJECT_ROOT / "mod0" / "tests" / "settlement_raid_spec.lua",
        PROJECT_ROOT / "contracts" / "fast_travel_territories.v1.json",
        PROJECT_ROOT / "contracts" / "faction_progression.v1.json",
        PROJECT_ROOT / "contracts" / "pal_reconciliation.v1.json",
        PROJECT_ROOT / "contracts" / "content_pack.v1.json",
        PROJECT_ROOT / "contracts" / "content_bundle.v1.json",
        PROJECT_ROOT / "contracts" / "strategic_world.v1.json",
        PROJECT_ROOT / "contracts" / "ending_routes.v1.json",
        PROJECT_ROOT
        / "evidence"
        / "contracts"
        / "pal-raid-result-adapter-build24467282.json",
        PROJECT_ROOT / "contracts" / "faction_commerce.v1.json",
        PROJECT_ROOT / "contracts" / "faction_economy.v1.json",
        PROJECT_ROOT / "contracts" / "faction_economy_shops.v1.json",
        PROJECT_ROOT / "tools" / "build_faction_economy_shops.mjs",
        PROJECT_ROOT / "tools" / "verify_faction_economy_shops.py",
        PROJECT_ROOT / "tools" / "verify_pal_raid_result_adapter_contract.py",
        PROJECT_ROOT / "scripts" / "build-faction-economy-shops.ps1",
        PROJECT_ROOT / "evidence" / "asset_json" / "DT_PalMonsterParameter.mapped.json",
        HUMAN_PARAMETER_ASSET,
        ITEM_PARAMETER_ASSET,
    ]
    for path in required:
        require(path.exists(), f"missing Mod 0 file: {path}")

    subprocess.run(
        [sys.executable, str(PROJECT_ROOT / "tools" / "generate_mod0_registry.py"), "--check"],
        cwd=PROJECT_ROOT,
        check=True,
    )
    subprocess.run(
        [
            sys.executable,
            str(PROJECT_ROOT / "tools" / "generate_pal_faction_mask.py"),
            "--check",
        ],
        cwd=PROJECT_ROOT,
        check=True,
    )
    subprocess.run(
        [
            sys.executable,
            str(PROJECT_ROOT / "tools" / "verify_faction_economy_contract.py"),
        ],
        cwd=PROJECT_ROOT,
        check=True,
    )
    subprocess.run(
        [
            sys.executable,
            str(PROJECT_ROOT / "tools" / "verify_faction_economy_shops.py"),
        ],
        cwd=PROJECT_ROOT,
        check=True,
    )

    assignments = json.loads(
        (PROJECT_ROOT / "contracts" / "territory_assignments.v1.json").read_text(encoding="utf-8")
    )
    factions = json.loads(
        (PROJECT_ROOT / "contracts" / "factions.v1.json").read_text(encoding="utf-8")
    )
    progression = json.loads(
        (PROJECT_ROOT / "contracts" / "faction_progression.v1.json").read_text(encoding="utf-8")
    )
    pal_reconciliation = json.loads(
        (PROJECT_ROOT / "contracts" / "pal_reconciliation.v1.json").read_text(encoding="utf-8")
    )
    commerce = json.loads(
        (PROJECT_ROOT / "contracts" / "faction_commerce.v1.json").read_text(encoding="utf-8")
    )
    tower_contract = json.loads(
        (PROJECT_ROOT / "contracts" / "tower_territories.v1.json").read_text(encoding="utf-8")
    )
    island_contract = json.loads(
        (PROJECT_ROOT / "contracts" / "island_territories.v2.json").read_text(encoding="utf-8")
    )
    fast_travel_contract = json.loads(
        (PROJECT_ROOT / "contracts" / "fast_travel_territories.v1.json").read_text(encoding="utf-8")
    )
    monster_parameter = json.loads(
        (
            PROJECT_ROOT
            / "evidence"
            / "asset_json"
            / "DT_PalMonsterParameter.mapped.json"
        ).read_text(encoding="utf-8-sig")
    )
    require(assignments["baselineStatus"] == "user_approved_frozen_baseline", "baseline not frozen")
    require(len(assignments["assignments"]) == 22, "expected 22 map regions")
    require(len(factions["factions"]) == 12, "expected 12 stable factions")
    require(
        progression["baselineStatus"] == "user_confirmed_mechanics_baseline_2026-07-28",
        "faction progression baseline not active",
    )
    require(len(progression["humanFactionIds"]) == 7, "expected 7 human progression factions")
    require(len(progression["palFactionIds"]) == 5, "expected 5 Pal progression factions")
    join_interaction = progression["membershipPolicy"]["joinInteraction"]
    require(join_interaction["enabled"] is True, "join interaction adapter must remain enabled")
    require(
        join_interaction["requiresRegisteredSource"] is True,
        "join interaction must require a registered source",
    )
    require(
        join_interaction["requiresExplicitConfirmation"] is True,
        "join interaction must require explicit confirmation",
    )
    require(
        join_interaction["dialogueContentIncluded"] is False,
        "join interaction adapter cannot contain authored dialogue",
    )
    diplomacy_recovery = progression["reputationSources"]["commerce"]["diplomacyRecovery"]
    require(diplomacy_recovery["enabled"] is True, "commerce diplomacy recovery must remain enabled")
    require(
        diplomacy_recovery["automaticClear"] is True,
        "commerce diplomacy recovery must clear completed hostility sources",
    )
    require(
        diplomacy_recovery["requiresNonNegativeReputation"] is True,
        "commerce diplomacy recovery cannot start below zero reputation",
    )
    require(
        diplomacy_recovery["pointsSource"]
        == "applied_non_negative_commerce_reputation",
        "commerce diplomacy recovery must use applied non-negative commerce reputation",
    )
    require(
        diplomacy_recovery["requiredPointsPerHostilitySource"] == 60,
        "commerce diplomacy recovery threshold drifted from 60",
    )
    require(
        diplomacy_recovery["capPerWindow"] == 20,
        "commerce diplomacy recovery window cap drifted from 20",
    )
    require(
        diplomacy_recovery["sourceOrder"] == "sorted_faction_id",
        "commerce diplomacy recovery source order must remain deterministic",
    )
    require(
        diplomacy_recovery["carryRemainderAcrossSources"] is False,
        "commerce diplomacy recovery cannot carry remainder across hostility sources",
    )
    require(
        diplomacy_recovery["fixedMarketCommercialTruceRequired"] is True,
        "commerce diplomacy recovery must require a fixed-market commercial truce",
    )
    require(
        diplomacy_recovery["visitingCaravansWhileHostileAllowed"] is False,
        "hostile visiting caravans cannot provide diplomacy recovery",
    )
    require(len(commerce["factions"]) == 7, "expected 7 human commerce merchants")
    require(
        {item["factionId"] for item in commerce["factions"]}
        == set(progression["humanFactionIds"]),
        "commerce merchants must cover all human factions",
    )
    merchant_island = commerce["merchantIsland"]
    require(
        merchant_island["placementStatus"]
        == "user_selected_ftpoint90_island_live_ground_validation_pending",
        "merchant-island selection status is not locked",
    )
    merchant_island_selection = merchant_island["selectionDecision"]
    require(
        merchant_island_selection["referenceFastTravelPointId"]
        == "FTPoint90",
        "merchant island must remain anchored to FTPoint90",
    )
    require(
        merchant_island_selection["factionTerritoryPolicy"]
        == "neutral_commercial_public_zone",
        "merchant island must remain a neutral public commercial zone",
    )
    require(
        merchant_island_selection["publicFastTravelPolicy"]
        == "preserve_native_unrestricted",
        "merchant-island fast travel must remain unrestricted",
    )
    human_parameter_bytes = HUMAN_PARAMETER_ASSET.read_bytes()
    item_parameter_bytes = ITEM_PARAMETER_ASSET.read_bytes()
    commerce_item_ids: set[str] = set()
    commerce_character_ids: set[str] = set()
    verified_native_variants = 0
    verified_guard_variants = 0
    for merchant in commerce["factions"]:
        commerce_character_ids.add(merchant["nativeCharacterId"])
        commerce_character_ids.update(merchant["guardCharacterIds"])
        commerce_item_ids.update(merchant["stockItemIds"])
        commerce_item_ids.update(merchant["requestedItemIds"])
        require(
            len(merchant["guardCharacterIds"])
            == len(merchant["guardCharacterClassPaths"]),
            f"guard ID/class path mismatch for {merchant['factionId']}",
        )
        for guard_id, guard_class_path in zip(
            merchant["guardCharacterIds"],
            merchant["guardCharacterClassPaths"],
        ):
            guard_asset = evidence_uasset_for_class_path(
                guard_class_path
            )
            require(
                guard_asset.exists(),
                f"native guard blueprint is missing: {guard_asset}",
            )
            guard_bytes = guard_asset.read_bytes()
            guard_class_token = guard_class_path.rsplit(".", 1)[1]
            require(
                guard_class_token.encode("ascii") in guard_bytes,
                f"native guard blueprint class mismatch: "
                f"{guard_id} -> {guard_class_path}",
            )
            verified_guard_variants += 1
        if merchant["existingRuntimeBinding"] is None:
            blueprint_asset = evidence_uasset_for_class_path(
                merchant["nativeCharacterClassPath"]
            )
            require(
                blueprint_asset.exists(),
                f"native merchant blueprint is missing: {blueprint_asset}",
            )
            blueprint_bytes = blueprint_asset.read_bytes()
            require(
                merchant["nativeShopRowName"].encode("ascii") in blueprint_bytes,
                f"{merchant['nativeCharacterId']} does not bind "
                f"{merchant['nativeShopRowName']}",
            )
            require(
                merchant["nativeCharacterId"].encode("ascii") in blueprint_bytes,
                f"native merchant blueprint identity mismatch: "
                f"{merchant['nativeCharacterId']}",
            )
            verified_native_variants += 1
    missing_character_ids = sorted(
        character_id
        for character_id in commerce_character_ids
        if not contains_ascii_asset_name(
            human_parameter_bytes,
            character_id,
        )
    )
    require(
        not missing_character_ids,
        "commerce character IDs missing from DT_PalHumanParameter: "
        + ", ".join(missing_character_ids),
    )
    missing_item_ids = sorted(
        item_id
        for item_id in commerce_item_ids
        if not contains_ascii_asset_name(
            item_parameter_bytes,
            item_id,
        )
    )
    require(
        not missing_item_ids,
        "commerce item IDs missing from DA_StaticItemDataAsset: "
        + ", ".join(missing_item_ids),
    )
    require(
        verified_native_variants == 6,
        "expected six non-Rayne native merchant variants",
    )
    require(
        verified_guard_variants == 7,
        "expected seven faction guard blueprints",
    )
    require(
        set(progression["humanFactionIds"]) | set(progression["palFactionIds"])
        == {item["id"] for item in factions["factions"]},
        "progression classification does not cover all factions",
    )
    require(
        not (set(progression["humanFactionIds"]) & set(progression["palFactionIds"])),
        "human and Pal progression classifications overlap",
    )
    require(
        [rank["id"] for rank in progression["rankPolicy"]["ranks"]]
        == ["Member", "CoreMember", "Leader", "Lord"],
        "human rank order mismatch",
    )
    require(
        progression["rankPolicy"]["ranks"][2]["guardAccess"] is True,
        "Leader must unlock player guards",
    )
    require(
        progression["designPolicy"]["reputationDecreaseEnabled"] is False,
        "reputation decrease must remain outside the current phase",
    )
    require(
        progression["designPolicy"]["palworldSaveMutationAllowed"] is False,
        "Palworld save mutation must remain disabled",
    )
    require(len(tower_contract["territories"]) == 24, "expected 24 native watchtowers")
    require(island_contract["baselineStatus"] == "user_approved_active_baseline", "island baseline not active")
    require(len(island_contract["islands"]) == 7, "expected 7 whole-island geometry units")
    mapped_fast_travel_ids = [
        fast_travel_id
        for territory in fast_travel_contract["territories"]
        for fast_travel_id in territory["fastTravelPointIds"]
    ]
    require(len(mapped_fast_travel_ids) == 109, "expected 109 faction-mapped public fast-travel destinations")
    require(len(set(mapped_fast_travel_ids)) == 109, "faction-mapped public fast-travel destinations must map uniquely")
    require("FTPoint90" not in mapped_fast_travel_ids, "merchant-island fast travel must remain neutral and unrestricted")
    classification = fast_travel_contract["classificationPolicy"]
    require(
        classification["sourcePointCount"]
        == classification["mappedPointCount"]
        + classification["neutralOverridePointCount"]
        + classification["unmappedPointCount"],
        "fast-travel classification counts must include the neutral override",
    )
    require(
        classification["manualNeutralOverrides"]
        == [
            {
                "fastTravelPointId": "FTPoint90",
                "displayNameZhHans": "泰拉瑞亚密域",
                "reason": "user_selected_merchant_island_public_access_2026-07-29",
            }
        ],
        "FTPoint90 neutral override contract drifted",
    )
    neutral_exclusions = island_contract["neutralGeometryExclusions"]
    require(
        len(neutral_exclusions) == 1
        and neutral_exclusions[0]["id"] == "pwft.neutral.market_island"
        and neutral_exclusions[0]["seedFastTravelPointId"] == "FTPoint90",
        "merchant-island neutral geometry exclusion is missing",
    )
    require(
        island_contract["designPolicy"]["relationshipColors"]
        == {"Hostile": "#D34A4A", "Friendly": "#4D86D9", "Player": "#4FAF68"},
        "relationship palette does not match the approved red/blue/green contract",
    )
    require(
        island_contract["designPolicy"]["unownedIslandVisual"] == "transparent",
        "unowned islands must stay transparent",
    )
    fast_travel_ids = [
        item["runtimeFastTravelPointId"]
        for item in tower_contract["territories"]
        if item.get("runtimeFastTravelPointId") is not None
    ]
    require(len(fast_travel_ids) == 22, "expected 22 runtime-confirmed fast-travel IDs")
    require(all(isinstance(item, str) and item for item in fast_travel_ids), "invalid runtime fast-travel ID")
    require(len(set(fast_travel_ids)) == 22, "runtime fast-travel IDs must be unique")

    selected_raid_ids = {
        "LizardMan",
        "Baphomet_Dark",
        "PinkLizard",
        "DarkCrow",
        "NightFox",
        "HadesBird",
    }
    monster_rows = {
        row["Name"]: {
            field["Name"]: field.get("Value")
            for field in row["Value"]
        }
        for row in monster_parameter["Exports"][0]["Table"]["Data"]
        if row.get("Name") in selected_raid_ids
    }
    require(
        set(monster_rows) == selected_raid_ids,
        "one or more selected settlement-raid Pal rows are missing",
    )
    for character_id, row in monster_rows.items():
        require(row.get("IsPal") is True, f"{character_id} is not a Pal")
        require(row.get("BPClass") == character_id, f"{character_id} BP class mismatch")
        require(
            isinstance(row.get("ZukanIndex"), int)
            and row["ZukanIndex"] >= 0,
            f"{character_id} is not a released Paldex row",
        )
        require(
            row.get("ElementType1") == "Dark"
            or row.get("ElementType2") == "Dark",
            f"{character_id} is outside the dark tribe roster",
        )
        require(
            row.get("Nocturnal") is True,
            f"{character_id} is not nocturnal",
        )
        require(
            row.get("IsBoss") is False
            and row.get("IsRaidBoss") is False
            and row.get("IsTowerBoss") is False,
            f"{character_id} is a boss-only row",
        )

    main_text = (SCRIPTS_ROOT / "main.lua").read_text(encoding="utf-8")
    config_text = (SCRIPTS_ROOT / "pwft" / "config.lua").read_text(encoding="utf-8")
    content_pack_registry_text = (
        SCRIPTS_ROOT / "pwft" / "content_pack_registry.lua"
    ).read_text(encoding="utf-8")
    registry_text = (SCRIPTS_ROOT / "pwft" / "registry.lua").read_text(encoding="utf-8")
    runtime_text = (SCRIPTS_ROOT / "pwft" / "runtime.lua").read_text(encoding="utf-8")
    policy_text = (SCRIPTS_ROOT / "pwft" / "policy.lua").read_text(encoding="utf-8")
    progression_text = (SCRIPTS_ROOT / "pwft" / "faction_progression.lua").read_text(encoding="utf-8")
    faction_api_text = (SCRIPTS_ROOT / "pwft" / "faction_api.lua").read_text(encoding="utf-8")
    faction_commerce_text = (SCRIPTS_ROOT / "pwft" / "faction_commerce.lua").read_text(encoding="utf-8")
    faction_economy_shop_text = (
        SCRIPTS_ROOT / "pwft" / "faction_economy_shop_catalog.lua"
    ).read_text(encoding="utf-8")
    faction_economy_merchant_runtime_text = (
        SCRIPTS_ROOT / "pwft" / "faction_economy_merchant_runtime.lua"
    ).read_text(encoding="utf-8")
    faction_defense_text = (SCRIPTS_ROOT / "pwft" / "faction_defense.lua").read_text(encoding="utf-8")
    faction_guard_text = (SCRIPTS_ROOT / "pwft" / "faction_guard.lua").read_text(encoding="utf-8")
    faction_join_text = (SCRIPTS_ROOT / "pwft" / "faction_join.lua").read_text(encoding="utf-8")
    faction_merchant_runtime_text = (SCRIPTS_ROOT / "pwft" / "faction_merchant_runtime.lua").read_text(encoding="utf-8")
    faction_ui_text = (SCRIPTS_ROOT / "pwft" / "faction_ui_model.lua").read_text(encoding="utf-8")
    faction_ui_presenter_text = (
        SCRIPTS_ROOT / "pwft" / "faction_ui_presenter.lua"
    ).read_text(encoding="utf-8")
    native_character_adapter_text = (
        SCRIPTS_ROOT / "pwft" / "native_character_adapter.lua"
    ).read_text(encoding="utf-8")
    pal_reconciliation_text = (
        SCRIPTS_ROOT / "pwft" / "pal_reconciliation.lua"
    ).read_text(encoding="utf-8")
    pal_raid_result_adapter_text = (
        SCRIPTS_ROOT / "pwft" / "pal_raid_result_adapter.lua"
    ).read_text(encoding="utf-8")
    pal_discourse_runtime_text = (
        SCRIPTS_ROOT / "pwft" / "pal_discourse_runtime.lua"
    ).read_text(encoding="utf-8")
    pal_dialogue_controller_text = (
        SCRIPTS_ROOT / "pwft" / "pal_dialogue_controller.lua"
    ).read_text(encoding="utf-8")
    pal_dialogue_presenter_text = (
        SCRIPTS_ROOT / "pwft" / "pal_dialogue_presenter.lua"
    ).read_text(encoding="utf-8")
    pal_representative_interaction_text = (
        SCRIPTS_ROOT / "pwft" / "pal_representative_interaction.lua"
    ).read_text(encoding="utf-8")
    progression_identity_text = (
        SCRIPTS_ROOT / "pwft" / "progression_identity.lua"
    ).read_text(encoding="utf-8")
    quest_runtime_text = (
        SCRIPTS_ROOT / "pwft" / "quest_runtime.lua"
    ).read_text(encoding="utf-8")
    commerce_bridge_text = (SCRIPTS_ROOT / "pwft" / "commerce_bridge.lua").read_text(encoding="utf-8")
    world_balance_text = (SCRIPTS_ROOT / "pwft" / "world_balance.lua").read_text(encoding="utf-8")
    settlement_raid_text = (SCRIPTS_ROOT / "pwft" / "settlement_raid.lua").read_text(encoding="utf-8")
    pal_mask_text = (SCRIPTS_ROOT / "pwft" / "pal_faction_island_mask.lua").read_text(encoding="utf-8")

    require(
        'expectedSteamBuildId = "24467282"' in config_text,
        "runtime host build must match the current Steam appmanifest",
    )
    require(
        "sourceContractBuild=%s" in runtime_text,
        "runtime logs must distinguish current host build from source-contract provenance",
    )
    require("enableMapOverlayMutation = true" in config_text, "native faction overlay must be explicitly enabled")
    require("enableNativeTerritoryMaterialOverlay = true" in config_text, "native faction material must be enabled")
    require("enableNativePlaceNamePresentation = true" in config_text, "native place-name presentation must be enabled")
    require('["mappedNativePlaceNames"] = 82' in registry_text, "native place-name index must include the 82 extracted owned-area rows")
    require('["mappedFastTravelPoints"] = 109' in registry_text, "all faction-owned public fast-travel destinations must be indexed")
    require(
        '["FTPoint90"] = "pwft.island.' not in registry_text,
        "merchant-island fast travel must not inherit a faction territory",
    )
    require("enableDangerAreaWarningUi = true" in config_text, "native danger warning must be enabled")
    require("enableMapFastTravelSelectionWarning = true" in config_text, "pre-confirmation danger warning must be enabled")
    require("enableFastTravelEnforcement = true" in config_text, "hostile availability gate must be enabled")
    require("enableSaveWrites = false" in config_text, "save writes must remain disabled")
    require(
        "nativeSaleReplicationProbeEnabled = true" in config_text,
        "read-only native sale replication probe must be enabled",
    )
    require("factionProgression = {" in config_text, "faction progression runtime configuration missing")
    require("palReconciliation = {" in config_text, "Pal reconciliation runtime configuration missing")
    require("factionUi = {" in config_text, "faction UI runtime configuration missing")
    require('key = "F5"' in config_text, "faction UI explicit toggle key missing")
    require(
        "keepMapBackdrop" not in config_text,
        "dedicated faction UI must not expose a legacy-map backdrop option",
    )
    require('mode = "mod-sidecar-json"' in config_text, "progression sidecar mode missing")
    require(
        "enabled = true" in config_text
        and "deferredIdentity = true" in config_text
        and "companionLedgerEnabled = true" in config_text,
        "identity-deferred external progression ledger must be enabled",
    )
    require(
        "identityProbe = {" in config_text
        and "readOnly = true" in config_text,
        "read-only progression identity probe configuration missing",
    )
    require(
        "Config.factionProgression.persistence.rootPath" in main_text
        and 'ModDirectory .. "/State"' in main_text,
        "portable Mod-owned sidecar root derivation is missing",
    )
    require(
        "GetWorldSaveDirectoryName" in progression_identity_text
        and "GetPlayerUId" in progression_identity_text
        and "GetLocalPlayerUID" in progression_identity_text,
        "stable world/player identity routes are incomplete",
    )
    require(
        "string.rep(\"0\", 32)" in progression_identity_text,
        "zero GUID rejection is missing",
    )
    require("ProgressionStore.create(" in runtime_text, "progression sidecar store is not wired")
    require(
        "ProgressionIdentity.resolve_native()" in runtime_text
        and "sidecarWrites=%s" in runtime_text,
        "read-only identity capture and sidecar activation log are not wired",
    )
    require(
        "config.factionProgression.persistence.enabled == true" in runtime_text
        and "native-world-player-identity-pending" in runtime_text
        and "state.onProgressionIdentityReady" in runtime_text,
        "runtime must defer external writes until stable identity is ready",
    )
    require(
        "CompanionLedger.create(" in runtime_text
        and "_G.PWFT_COMPANION_LEDGER_V1" in runtime_text,
        "external companion ledger runtime is not wired",
    )
    require(
        "PalItemSlot:OnRep_StackCount" in commerce_bridge_text
        and "PalItemSlot:OnRep_ItemId" in commerce_bridge_text
        and "NATIVE_SELL_REPLICATION_CONFIRMED" in commerce_bridge_text,
        "server-authoritative item-sale replication adapter is incomplete",
    )
    require(
        "nativeSaleReputationSettlementEnabled" in commerce_bridge_text
        and "live-acceptance-pending" in commerce_bridge_text,
        "native sale replication must remain probe-only pending acceptance",
    )
    require("progression sidecar recovery failed" in runtime_text, "corrupt sidecar fail-closed guard missing")
    require("FactionProgression.create(" in runtime_text, "progression runtime is not started")
    require("PalReconciliation.create(" in runtime_text, "finite Pal reconciliation runtime is not started")
    require("PalRaidResultAdapter.create(" in runtime_text, "Pal raid-result adapter runtime is not started")
    require("PalDiscourseRuntime.create(" in runtime_text, "offline Pal discourse runtime is not started")
    require("PalDialogueController.create(" in runtime_text, "Pal Agent dialogue controller is not started")
    require("PalDialoguePresenter.create(" in runtime_text, "Pal dialogue presenter router is not started")
    require("PalRepresentativeInteraction.create(" in runtime_text, "Pal representative interaction router is not started")
    require("_G.PWFT_FACTION_API_V1" in runtime_text, "versioned public faction API is not exported")
    require("_G.PWFT_PAL_RECONCILIATION_API_V1" in runtime_text, "versioned public Pal reconciliation API is not exported")
    require("_G.PWFT_PAL_RAID_RESULT_ADAPTER_V1" in runtime_text, "versioned Pal raid-result adapter is not exported")
    require("_G.PWFT_PAL_DISCOURSE_API_V1" in runtime_text, "versioned Pal discourse API is not exported")
    require("_G.PWFT_PAL_DIALOGUE_CONTROLLER_V1" in runtime_text, "versioned Pal dialogue controller is not exported")
    require("_G.PWFT_PAL_DIALOGUE_PRESENTER_V1" in runtime_text, "versioned Pal dialogue presenter is not exported")
    require("_G.PWFT_PAL_REPRESENTATIVE_INTERACTION_V1" in runtime_text, "versioned Pal representative interaction API is not exported")
    require("_G.PWFT_COMMERCE_API_V1" in runtime_text, "versioned public commerce API is not exported")
    require("_G.PWFT_ECONOMY_SHOP_API_V1" in runtime_text, "versioned economy shop API is not exported")
    require("_G.PWFT_COMMERCE_BRIDGE_V1" in runtime_text, "versioned commerce bridge is not exported")
    require("_G.PWFT_DEFENSE_API_V1" in runtime_text, "versioned public defense API is not exported")
    require("_G.PWFT_GUARD_API_V1" in runtime_text, "versioned public guard API is not exported")
    require("_G.PWFT_JOIN_API_V1" in runtime_text, "versioned public join API is not exported")
    require("_G.PWFT_MERCHANT_RUNTIME_V1" in runtime_text, "versioned merchant runtime is not exported")
    require("_G.PWFT_FACTION_UI_MODEL_V1" in runtime_text, "versioned faction UI model is not exported")
    require("_G.PWFT_FACTION_UI_V1" in runtime_text, "versioned faction UI presenter is not exported")
    require("temporary-defense-truce" in faction_defense_text, "hostile defense truce route missing")
    require("defense-failed-no-reputation-decrease" in faction_defense_text, "defense no-decrease guard missing")
    require("leader-rank-required" in faction_guard_text, "Leader guard eligibility gate missing")
    require("explicitConfirmation" in faction_join_text, "explicit join confirmation capability missing")
    require("join-offer-stale" in faction_join_text, "stale join offer guard missing")
    require("dialogueContentIncluded = false" in faction_join_text, "join adapter must remain dialogue-free")
    require("FACTION_JOIN_READY" in runtime_text, "join interaction readiness log missing")
    require("FactionEconomyShopCatalog.create(" in runtime_text, "economy shop catalog is not started")
    require("FACTION_ECONOMY_SHOPS_READY" in runtime_text, "economy shop readiness log missing")
    require("pwft.economy shop" in runtime_text, "economy shop console diagnostics missing")
    require("settlementReady = false" in faction_economy_shop_text, "procurement quote must remain non-settling")
    require("procurementMoneyBonusEnabled" in faction_economy_shop_text, "economy shop money activation binding missing")
    require("procurementCommerceReputationEnabled" in faction_economy_shop_text, "economy shop reputation activation binding missing")
    require("io." not in faction_economy_shop_text, "economy shop catalog cannot write files")
    require("FactionEconomyMerchantRuntime.create(" in runtime_text, "Merchant Guild economy runtime is not wired")
    require("_G.PWFT_ECONOMY_MERCHANT_RUNTIME_V1" in runtime_text, "versioned Merchant Guild economy runtime is not exported")
    require("PFT_Economy_" not in faction_economy_merchant_runtime_text, "economy runtime must consume generated catalog rows instead of hardcoding row names")
    require("economyCatalogBinding = true" in faction_economy_merchant_runtime_text, "represented-faction economy settlement metadata missing")
    require("economy-market-runtime-disabled" in faction_economy_merchant_runtime_text, "economy market activation safety gate missing")
    require("economy-market-activation-rollback" in faction_economy_merchant_runtime_text, "economy market transactional rollback missing")
    require("raynePalMerchantExcluded = true" in faction_economy_merchant_runtime_text, "Rayne Pal merchant exclusion missing")
    require("io." not in faction_economy_merchant_runtime_text, "economy merchant runtime cannot write files")
    require("native-guard-provider-pending" in faction_guard_text, "guard provider safety boundary missing")
    require("fixed-market" in faction_merchant_runtime_text, "fixed faction market plan missing")
    require("visiting-caravan" in faction_merchant_runtime_text, "visiting faction caravan plan missing")
    require("hostile-faction-caravan-unavailable" in faction_merchant_runtime_text, "hostile caravan gate missing")
    require("commercialTruce = true" in faction_merchant_runtime_text, "hostile recovery market truce missing")
    require(
        "dedicated-faction-panel-ready-live-acceptance-pending" in faction_ui_text,
        "UI live-acceptance boundary missing",
    )
    require(
        "WBP_PFT_FactionStatus" in faction_ui_presenter_text,
        "dedicated Mod-owned faction widget route missing",
    )
    require(
        "WBP_PFT_TerritoryMap" not in faction_ui_presenter_text
        and "IMG_Map" not in faction_ui_presenter_text
        and "CKB_MapMode" not in faction_ui_presenter_text
        and "BTN_TerritoryMap" not in faction_ui_presenter_text,
        "faction presenter must not reference the legacy territory-map widget",
    )
    require(
        "TXT_FactionSummary" in faction_ui_presenter_text,
        "faction summary text binding missing",
    )
    require(
        "RegisterKeyBind" in faction_ui_presenter_text,
        "explicit faction UI toggle missing",
    )
    require(
        "StaticConstructObject" not in faction_ui_presenter_text
        and "WidgetTree" not in faction_ui_presenter_text,
        "faction UI cannot construct a dynamic widget tree",
    )
    require("NativeCharacterAdapter.create(" in runtime_text, "native character adapter is not wired")
    require("BeginDeferredActorSpawnFromClass" in native_character_adapter_text, "native blueprint spawn route missing")
    require("itemShopSimpleLotteryTableName" in native_character_adapter_text, "native item-shop binding missing")
    require("palShopSimpleLotteryTableName" in native_character_adapter_text, "native Pal-shop binding missing")
    require("K2_DestroyActor" in native_character_adapter_text, "native character cleanup route missing")
    require("create_guard_provider" in native_character_adapter_text, "native guard provider factory missing")
    require("native-follow-controller-pending-live-validation" in native_character_adapter_text, "guard follow-validation boundary missing")
    require("RegisterLoop" not in native_character_adapter_text, "native character adapter cannot use a permanent loop")
    require("io." not in native_character_adapter_text, "native character adapter cannot write files")
    require("negativeRecoveryRemaining" in faction_ui_text, "UI commerce-cap model missing")
    require("CommerceBridge.create(" in runtime_text, "native commerce bridge is not started")
    require("nativeSuccessfulTransactionsOnly" in faction_commerce_text, "native-success commerce guard missing")
    require("no-requested-items" in faction_commerce_text, "requested-item sale filter missing")
    require("requestedItemResolver" in faction_commerce_text, "economy-driven requested-item resolver missing")
    require("faction-economy-commodity-signals-v1" in runtime_text, "economy procurement signals are not wired to commerce settlement")
    require("RecieveBuyResult_ToClient" in commerce_bridge_text, "native buy result hook missing")
    require("Successed" in commerce_bridge_text, "native successful-buy enum route missing")
    require("confirm_item_sale" in commerce_bridge_text, "confirmed native sale adapter missing")
    require("unregister_vendor_actor" in commerce_bridge_text, "native vendor lifecycle cleanup missing")
    require("PalUIItemShopBase:TrySell" in commerce_bridge_text, "item-shop sale slot capture hook missing")
    require("ItemId" in commerce_bridge_text and "StaticId" in commerce_bridge_text, "sold item ID extraction missing")
    require("StackCount" in commerce_bridge_text, "sold item count extraction missing")
    require("item-shop-ui-sale-not-accepted" in commerce_bridge_text, "item-shop acceptance gate missing")
    require("pwft.commerce" in runtime_text, "commerce console diagnostics missing")
    require("FACTION_MERCHANT_RUNTIME_READY" in runtime_text, "merchant runtime readiness log missing")
    require("pwft.progress" in runtime_text, "progression console diagnostics missing")
    require("grant_reputation" in progression_text, "reputation award API missing")
    require("negativeRecoveryCapPerWindow" in progression_text, "commerce recovery cap missing")
    require("nonNegativeCapPerWindow" in progression_text, "friendly commerce cap missing")
    require("apply_commerce_diplomacy_recovery" in progression_text, "automatic commerce diplomacy recovery missing")
    require("diplomacyRecoveryEligible" in progression_text, "commerce diplomacy venue eligibility gate missing")
    require("commercialTruce = true" in faction_merchant_runtime_text, "fixed-market commercial truce metadata missing")
    require("bind_existing_fixed" in faction_merchant_runtime_text, "existing Rayne merchant lifecycle binding missing")
    require("on_relation_changed" in faction_merchant_runtime_text, "relation-driven caravan recall missing")
    require("deactivate_market" in faction_merchant_runtime_text, "fixed market deactivation lifecycle missing")
    require("pal-faction-membership-forbidden" in progression_text, "Pal membership guard missing")
    require("pal-discourse-service-required" in progression_text, "direct Pal reconciliation bypass must be blocked")
    require("award_pal_reconciliation" in progression_text, "authorized finite Pal affinity award route missing")
    require("ending3Unlocked" in progression_text, "ending 3 gate missing")
    require("export_snapshot" in progression_text, "versioned progression snapshot export missing")
    require("io." not in progression_text, "progression core must not write files before profile identity is verified")
    require("award_task" in faction_api_text, "task content API missing")
    require("award_defense" in faction_api_text, "defense content API missing")
    require("award_commerce" in faction_api_text, "commerce content API missing")
    require("reconcile_pal" in faction_api_text, "Pal reconciliation content API missing")
    require("eventId" in progression_text, "idempotent reputation event IDs missing")
    require(
        pal_reconciliation["baselineStatus"]
        == "user_confirmed_token_discourse_mechanics_2026-08-05",
        "Pal reconciliation baseline is not user-confirmed",
    )
    require(
        len(pal_reconciliation["humanCityStateIds"]) == 7
        and len(pal_reconciliation["palFactionIds"]) == 5,
        "Pal reconciliation faction sets are incomplete",
    )
    require(
        pal_reconciliation["raidEligibility"]["playerSideMustWin"] is True
        and pal_reconciliation["raidEligibility"]["participationRule"]
        == "authoritative_raid_leader_kill_credit"
        and pal_reconciliation["raidEligibility"]["duplicateCityStateResultsAllowed"] is True,
        "Pal raid token eligibility policy drifted",
    )
    raid_adapter_policy = pal_reconciliation["raidResultAdapterPolicy"]
    require(
        raid_adapter_policy["normalizedAdapterEnabled"] is True
        and raid_adapter_policy["nativeBindingEnabled"] is False
        and raid_adapter_policy["leaderDesignation"]
        == "first-spawn-of-final-wave"
        and raid_adapter_policy["timerCleanupMaySettleRaid"] is False
        and raid_adapter_policy["remoteOrUnresolvedAttributionAwardsToken"]
        is False,
        "Pal raid-result adapter activation or fail-closed policy drifted",
    )
    require(
        pal_reconciliation["tokenPolicy"]["quotaSource"]
        == "content_pack_per_pal_faction"
        and pal_reconciliation["tokenPolicy"]["eachDropCreatesIndependentInstance"] is True,
        "Pal token quota or instance policy drifted",
    )
    require(
        pal_reconciliation["discoursePolicy"]["technicalFailureConsumesToken"] is False
        and pal_reconciliation["discoursePolicy"]["playerAbortAfterConfirmationConsumesToken"] is True
        and pal_reconciliation["discoursePolicy"]["exhaustedBeforeTargetPermanentlyLocksFaction"] is True,
        "Pal discourse consumption or exhaustion policy drifted",
    )
    dialogue_policy = pal_reconciliation["offlineDialogueTreePolicy"]
    require(
        dialogue_policy["runtimeEnabled"] is True
        and dialogue_policy["nativePresenterEnabled"] is False
        and dialogue_policy["baseStoryContentIncluded"] is False
        and dialogue_policy["inlineTextAllowed"] is False
        and dialogue_policy["deterministicRuleEngineOwnsOutcome"] is True
        and dialogue_policy["agentMayMutateState"] is False,
        "offline Pal dialogue-tree content or authority policy drifted",
    )
    require(
        pal_reconciliation["runtimeActivation"]["nativeRaidResultBindingEnabled"] is False
        and pal_reconciliation["runtimeActivation"]["dialoguePresenterRouterEnabled"] is True
        and pal_reconciliation["runtimeActivation"]["representativeInteractionRouterEnabled"] is True
        and pal_reconciliation["runtimeActivation"]["representativeInteractionDistance"] == 500
        and pal_reconciliation["runtimeActivation"]["nativeDialoguePresenterEnabled"] is False
        and pal_reconciliation["runtimeActivation"]["agentAdapterEnabled"] is True,
        "dialogue routing and Agent adapter must stay active while the native Pal presenter remains disabled",
    )
    require("record_raid_result" in pal_reconciliation_text, "Pal raid-result adapter is missing")
    require("first-spawn-of-final-wave" in pal_raid_result_adapter_text, "deterministic Pal raid leader rule is missing")
    require("authoritative-native-end-required" in pal_raid_result_adapter_text, "native raid-end settlement gate is missing")
    require("local-player-owned-pal" in pal_raid_result_adapter_text, "owned-Pal kill attribution is missing")
    require("raid-member-observation-conflict" in pal_raid_result_adapter_text, "conflicting raid evidence fail-closed route is missing")
    require("io." not in pal_raid_result_adapter_text, "Pal raid-result adapter cannot write files directly")
    require("invalid-pal-discourse-content-pack" in pal_discourse_runtime_text, "Pal dialogue content validation is missing")
    require("pal-discourse-declined-token-preserved" in pal_discourse_runtime_text, "pre-confirmation token preservation is missing")
    require("pal-discourse-player-abort-consumed" in pal_discourse_runtime_text, "confirmed player-abort consumption is missing")
    require("pal-discourse-technical-failure-refunded" in pal_discourse_runtime_text, "technical failure refund is missing")
    require("localizationKeysOnly = true" in pal_discourse_runtime_text, "localization-key-only dialogue boundary is missing")
    require("io." not in pal_discourse_runtime_text, "Pal discourse runtime cannot write files directly")
    require("response-fields-not-allowed" in pal_dialogue_controller_text, "Pal Agent response authority-field rejection is missing")
    require("agent-proposal-committed-by-player" in pal_dialogue_controller_text, "Pal Agent player-confirmation route is missing")
    require("technical_failure" in pal_dialogue_controller_text, "Pal Agent presentation technical-refund route is missing")
    require("io." not in pal_dialogue_controller_text, "Pal dialogue controller cannot write files directly")
    require("explicit-player-abort-required-active-token-would-be-consumed" in pal_dialogue_presenter_text, "Pal dialogue UI explicit-abort guard is missing")
    require("deterministicRuleEngineOwnsOutcome = true" in pal_dialogue_presenter_text, "Pal dialogue presenter authority boundary is missing")
    require("io." not in pal_dialogue_presenter_text, "Pal dialogue presenter cannot write files directly")
    require("player-not-near-pal-representative" in pal_representative_interaction_text, "Pal representative proximity gate is missing")
    require("dialogue-presenter-backend-unavailable-token-preserved" in pal_representative_interaction_text, "Pal representative pre-confirmation presenter gate is missing")
    require("pal-representative-presentation-failed" in pal_representative_interaction_text, "Pal representative presentation refund route is missing")
    require("nativeDelegateBinding = false" in pal_representative_interaction_text, "Pal representative native-delegate boundary is missing")
    require("io." not in pal_representative_interaction_text, "Pal representative interaction router cannot write files directly")
    require("complete_token_quest" in pal_reconciliation_text, "Pal token quest adapter is missing")
    require("preview_discourse" in pal_reconciliation_text, "irreversible discourse preview is missing")
    require("begin_discourse" in pal_reconciliation_text, "Pal discourse reservation route is missing")
    require("resolve_discourse" in pal_reconciliation_text, "Pal discourse settlement route is missing")
    require("technical-failure-refunded" in pal_reconciliation_text, "technical token refund route is missing")
    require("player-abort-token-consumed" in pal_reconciliation_text, "confirmed abort token consumption route is missing")
    require("reconciliation-locked-attempts-exhausted" in pal_reconciliation_text, "permanent Pal reconciliation lock route is missing")
    require("io." not in pal_reconciliation_text, "Pal reconciliation core cannot write files directly")
    require("content-pack-load-order-cycle" in content_pack_registry_text, "content-pack dependency/load-order cycle gate missing")
    require("content-pack-conflict" in content_pack_registry_text, "content-pack conflict gate missing")
    require("invalid-content-pack-manifest" in content_pack_registry_text, "content-pack manifest validation missing")
    require("manifestMayExecuteCode = false" in content_pack_registry_text, "content-pack manifests must remain data-only")
    require("io." not in content_pack_registry_text, "content-pack registry cannot write files directly")
    require("quest-event-id-conflict" in quest_runtime_text, "quest event idempotency conflict gate missing")
    require("quest-template-migration-required" in quest_runtime_text, "quest template migration gate missing")
    require("snapshotOwnedByProgression" in quest_runtime_text, "quest state must remain attached to progression snapshot")
    require("INLINE_TEXT_FIELDS" in quest_runtime_text, "quest inline narrative rejection missing")
    require("io." not in quest_runtime_text, "quest runtime cannot write files directly")
    require("PAL_RECONCILIATION_READY" in runtime_text, "Pal reconciliation readiness log missing")
    require("PAL_RAID_RESULT_ADAPTER_READY" in runtime_text, "Pal raid-result adapter readiness log missing")
    require("PAL_DISCOURSE_RUNTIME_READY" in runtime_text, "Pal discourse runtime readiness log missing")
    require("assert(config.enableMapOverlayMutation == true" in runtime_text, "missing explicit map overlay guard")
    require("assert(type(config.enableFastTravelEnforcement) == \"boolean\"" in runtime_text, "missing travel configuration guard")
    require("assert(type(config.enableNativePlaceNamePresentation) == \"boolean\"" in runtime_text, "missing place-name configuration guard")
    require("assert(config.enableSaveWrites == false" in runtime_text, "missing save safety guard")
    require("hostile_territory" in policy_text, "hostile travel policy missing")
    require("preserveNativeFog = true" in policy_text, "native fog preservation missing")
    require("pwft.status" in runtime_text, "status command missing")
    require("TOWER_BINDING" in runtime_text, "tower binding probe missing")
    require("register_map_toggle_key(config" not in runtime_text, "failed Lua UMG path must not be activated")
    require("NATIVE_FACTION_MAP_APPLIED" in runtime_text, "native faction map implementation missing")
    require("PLACE_NAME_PRESENTED" in runtime_text, "native place-name presentation implementation missing")
    require("WBP_IngamePlaceName.WBP_IngamePlaceName_C:Display Region" in runtime_text, "native place-name display route missing")
    require("resolve_region_name_presentation" in runtime_text, "place-name must use the shared presentation resolver")
    require("NATIVE_FACTION_PACKED_MASKS_READY" in runtime_text, "packed native mask loading contract missing")
    require("M_PFT_IslandGeometryOverlay" in runtime_text, "whole-island material is not active")
    require("Color_\" .. suffix" in runtime_text, "per-island colour/visibility parameters missing")
    require("Visibility_\" .. suffix" in runtime_text, "independent per-island visibility parameters missing")
    require("BorderOpacity\"), 0.0" in runtime_text, "global border must stay hidden for unowned islands")
    require("ShowCommonWarning" in runtime_text, "native generic warning route missing")
    require("Conv_StringToText(message)" in runtime_text, "danger warning must construct an FText payload through Unreal")
    require("Conv_SoftObjectReferenceToString(value)" in runtime_text, "live tower-to-mask path conversion missing")
    require("Message = warning_text" in runtime_text, "danger warning must not pass a raw Lua string to FText")
    require("WBP_Map_Base.WBP_Map_Base_C:On Icon Clicked" in runtime_text, "pre-confirmation native map selection route missing")
    require("WBP_Map_IconFTTower.WBP_Map_IconFTTower_C:ClickEvent" in runtime_text, "concrete native tower-icon selection route missing")
    require("PalLocationPoint:IsEnableFastTravel" in runtime_text, "native fast-travel availability gate missing")
    require("RegisterHook(path, callback, post_callback)" in runtime_text, "native post callback registration missing")
    require("return override" in runtime_text, "native availability result must be returned to UE4SS")
    require("FAST_TRAVEL_AVAILABILITY_DENIED" in runtime_text, "native availability-denial evidence missing")
    require("route=IsEnableFastTravel:return-false" in runtime_text, "native return-false route missing")
    require("ui=false" in runtime_text, "high-frequency availability gate must remain UI-free")
    require("FAST_TRAVEL_BLOCK_APPLIED" in runtime_text, "hostile travel block evidence missing")
    require('message = "\u65e0\u6cd5\u4f20\u9001\u5230\u654c\u65b9\u9635\u8425\u3002"' in runtime_text, "blocked hostile destination UI text missing")
    require("FAST_TRAVEL_REPLY_FORCED_FALSE" not in runtime_text, "late Blueprint reply mutation must stay disabled")
    require("FindAllOf(\"WBP_Crime" not in runtime_text, "danger warning must not reuse crime UI")
    require("Image_MapBody" in runtime_text, "native map body preservation contract missing")
    require("targetLevel = 80" in config_text, "world level target must be 80")
    require(
        'levelOverride = {' in config_text
        and 'mode = "native-character-initialization-events-only"' in config_text,
        "event-driven level override must have an independent gate",
    )
    require(
        "loadedActorReconcile = {" in config_text
        and 'reason = "disabled-after-bulk-world-scan-instability"' in config_text,
        "loaded-actor reconciliation must have an independent fail-closed gate",
    )
    require("hpMultiplier = 2.0" in config_text, "Pal-faction HP multiplier must be 2.0")
    require("damageMultiplier = 2.0" in config_text, "Pal-faction damage multiplier must be 2.0")
    require("makeUncapturable = true" in config_text, "Predator Pals must remain uncapturable")
    require(
        "WorldBalance.has_enabled_feature(world_balance_config)" in runtime_text
        and "WorldBalance.start(world_balance_config)" in runtime_text,
        "independently gated world balance runtime is not started",
    )
    require("SettlementRaid.start(" in runtime_text, "small settlement raid runtime is not started")
    require(
        'executionMode = "native-negotiator"' in config_text,
        "settlement raid must select exactly one execution route",
    )
    require("Grass_Village_001" in config_text, "small settlement native region binding missing")
    require("FTPoint24" in config_text, "small settlement fast-travel binding missing")
    require("pwft.faction.dark_nocturnal_pal_tribe" in config_text, "nearest Pal tribe binding missing")
    require("replaceNativePlayerBaseInvasion = true" in config_text, "native player-base invasion replacement missing")
    require("countdownSeconds = 15 * 60" in config_text, "small settlement raid must keep the fifteen-minute warning")
    require("Invader_Group_Monster_Grade5_Basic" in config_text, "native Grade 5 Pal invasion group missing")
    require(
        "setting.bInvaderDisable = disabled == true" in settlement_raid_text,
        "runtime-only native invasion gate missing",
    )
    require("GetOptionWorldSettings" not in settlement_raid_text, "settlement raid must not read or mutate saved world options")
    require(".bEnableInvaderEnemy" not in settlement_raid_text, "settlement raid must not mutate the saved invasion option")
    require("SpawnMonster" not in settlement_raid_text, "dead PalCheatManager spawn route must stay removed")
    require("BP_PalSpawner_DebugSpawn" not in settlement_raid_text, "custom debug spawner must stay removed")
    require("CreateDebugSpawnerGroupInfo" not in settlement_raid_text, "custom SpawnGroup injection must stay removed")
    require("SpawnRequest_ByOutside" not in settlement_raid_text, "custom outside spawn request must stay removed")
    require("GetInvaderManager" in settlement_raid_text, "world-owned invader manager accessor missing")
    require("StartInvaderMarchForBaseCamp" in settlement_raid_text, "native base-camp invasion lifecycle entry missing")
    require("PalInvaderIncidentBase:SelectInvaders" in settlement_raid_text, "native Grade 80 Meadow selection adapter missing")
    require("RequestIncidentInvaderEnemy_BP" not in settlement_raid_text, "unsafe internal incident request must stay removed")
    require("RequestIncidentInvaderEnemy(" not in settlement_raid_text, "unsafe native incident request must stay removed")
    require("Debug_InvaderMarchForNearCamp" not in settlement_raid_text, "silent player-controller debug route must stay removed")
    require("InvaderMarchForNearestCamp" not in settlement_raid_text, "cheat-manager invasion route must stay removed")
    require("StaticConstructObject" not in settlement_raid_text, "settlement raid must not construct lifecycle objects manually")
    require("PalCheatManager" not in settlement_raid_text, "settlement raid must not depend on cheat-manager lifecycle")
    require("PalInvaderIncidentBase:GetInvaderStartPoint" in settlement_raid_text, "native invasion start-point adapter missing")
    require(
        "BP_PalIncidentInvaderVisitorNPC" in settlement_raid_text
        and "OnAllCharacterSpawned" in settlement_raid_text,
        "native negotiator lifecycle adapter missing",
    )
    require(
        'safe_hook_param_set(\n                return_parameter,\n                true' in settlement_raid_text,
        "native start-point success flag override missing",
    )
    require(
        "nativeFallbackLaunchEnabled = false" in config_text,
        "duplicate native fallback launches must stay disabled",
    )
    require(
        "nativeNegotiatorTimeoutMs = 180000" in config_text,
        "bounded native negotiator timeout missing",
    )
    require(
        "rampagingPalFallback = {" in config_text
        and "native-predator-spawner-provider-required" in config_text
        and "liveValidated = false" in config_text,
        "fail-closed rampaging-Pal fallback contract missing",
    )
    require(
        "attendanceSimulation = {" in config_text
        and "noActorSpawnWhenAbsent = true" in config_text
        and "targetPlayerHate = 125000.0" in config_text,
        "player-attendance raid simulation contract missing",
    )
    require(
        "BACKGROUND_RAID_RESOLVED" in settlement_raid_text
        and "actorSpawns=0 worldCombat=false" in settlement_raid_text,
        "absent-player background-only raid settlement missing",
    )
    require(
        "ATTENDANCE_RAID_STARTED" in settlement_raid_text
        and "AddTargetPlayer_ForEnemy" in settlement_raid_text,
        "present-player expanded hate route missing",
    )
    require(
        "PWFT_SETTLEMENT_RAID_API_V1" in settlement_raid_text,
        "settlement raid background status API missing",
    )
    require("GetTargetBaseCampPosition" in settlement_raid_text, "native invasion target adapter missing")
    require("OnCharacterSpawned" in settlement_raid_text, "native invasion spawned-character callback missing")
    require(
        "local function safe_hook_param_get" in settlement_raid_text
        and "local function unwrap(value)" not in settlement_raid_text,
        "settlement raid must only unwrap known RegisterHook parameters",
    )
    require("AddTargetNPC" in settlement_raid_text, "native settlement-NPC targeting route missing")
    require("ChangeHate" in settlement_raid_text, "native target-priority route missing")
    require("FindMostHateTarget" in settlement_raid_text, "native hate-target diagnostic missing")
    require("K2_TeleportTo" not in settlement_raid_text, "raid must not teleport existing characters")
    require("IsNight" in settlement_raid_text, "dark/nocturnal raid time gate missing")
    require(
        "local function destroy_attendance_attackers" in settlement_raid_text
        and 'TRANSIENT_ATTACKER_DESTROY_METHOD = "K2_DestroyActor"'
        in settlement_raid_text
        and "attendanceSpawnedActorNames" in settlement_raid_text
        and "attendanceNativeSpawnHandles" in settlement_raid_text,
        "transient attendance attackers must have explicit bounded cleanup",
    )
    require("WBP_WarningEvent_NoticeTimer" in settlement_raid_text, "native warning-event countdown widget missing")
    require("SetRemainTime" in settlement_raid_text, "native countdown update route missing")
    require("nativeLifecycle=true" in settlement_raid_text, "native incident lifecycle contract missing")
    require("customSpawner=false" in settlement_raid_text, "custom-spawner removal evidence missing")
    require("RegisterLoop" not in settlement_raid_text, "settlement raid must not use a permanent loop")
    require("io." not in settlement_raid_text, "settlement raid must not write files")
    require("SetOverrideLevel" in world_balance_text, "native level override route missing")
    require("SetSpawnedCharacterType" in world_balance_text, "native Predator route missing")
    require("PREDATOR_SPAWNED_CHARACTER_TYPE = 8" in world_balance_text, "Predator enum must be 8")
    require("AdditionalEnemyMaxHPRate" in world_balance_text, "native enemy HP rate missing")
    require("AdditionalEnemyInflictDamageRate" in world_balance_text, "native enemy damage rate missing")
    require("SetUncapturable" in world_balance_text, "native uncapturable route missing")
    require("IsPlayersOtomo" in world_balance_text, "player Pal exclusion missing")
    require("IsAssignedToAnyWork" in world_balance_text, "base worker exclusion missing")
    require(
        "local function unwrap_hook_param" in world_balance_text
        and "local function unwrap(value)" not in world_balance_text,
        "world balance must only unwrap known RegisterHook parameters",
    )
    require("RegisterLoadMapPostHook" in world_balance_text, "bounded world-load reconciliation missing")
    require(
        "if instance.config.levelOverride.enabled ~= true then" in world_balance_text,
        "level override must be independently gated",
    )
    require(
        "if reconcile.enabled == true then" in world_balance_text,
        "loaded-actor reconciliation must be independently gated",
    )
    require(
        "WorldBalance.has_enabled_feature" in world_balance_text,
        "world-balance feature gate helper missing",
    )
    require("RegisterLoop" not in world_balance_text, "world balance must not use a permanent loop")
    require("RegisterHook" in world_balance_text, "character initialization hook missing")
    require('Mask.textureSize = 1024' in pal_mask_text, "Pal-faction mask projection size mismatch")
    require(pal_mask_text.count("pixelCount = ") == 5, "expected exactly five Pal-faction island masks")

    print(
        "PASS commerce native assets "
        f"({len(commerce_character_ids)} character IDs, "
        f"{len(commerce_item_ids)} item IDs, "
        f"{verified_native_variants} merchant variants, "
        f"{verified_guard_variants} guard variants)"
    )
    print("PASS faction map, safety gates, level-80 world, and five-island Predator balance")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
