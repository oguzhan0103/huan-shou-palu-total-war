from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[1]
CONTRACTS_DIR = PROJECT_ROOT / "contracts"
OUTPUT_PATH = (
    PROJECT_ROOT
    / "mod0"
    / "ue4ss"
    / "PalFactionTerritory0"
    / "Scripts"
    / "pwft"
    / "registry.lua"
)


def _read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _lua_string(value: str) -> str:
    escaped = (
        value.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
        .replace("\r", "\\r")
        .replace("\t", "\\t")
    )
    return f'"{escaped}"'


def _lua_value(value: Any, indent: int = 0) -> str:
    if value is None:
        return "nil"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, str):
        return _lua_string(value)
    if isinstance(value, (int, float)):
        return repr(value)
    if isinstance(value, list):
        if not value:
            return "{}"
        pad = " " * indent
        child_pad = " " * (indent + 4)
        body = ",\n".join(
            f"{child_pad}{_lua_value(item, indent + 4)}" for item in value
        )
        return "{\n" + body + f"\n{pad}}}"
    if isinstance(value, dict):
        if not value:
            return "{}"
        pad = " " * indent
        child_pad = " " * (indent + 4)
        rows: list[str] = []
        for key, item in value.items():
            rows.append(
                f"{child_pad}[{_lua_string(str(key))}] = "
                f"{_lua_value(item, indent + 4)}"
            )
        return "{\n" + ",\n".join(rows) + f"\n{pad}}}"
    raise TypeError(f"unsupported Lua value: {type(value).__name__}")


def _build_registry() -> dict[str, Any]:
    factions_path = CONTRACTS_DIR / "factions.v1.json"
    commerce_path = CONTRACTS_DIR / "faction_commerce.v1.json"
    economy_path = CONTRACTS_DIR / "faction_economy.v1.json"
    economy_shops_path = CONTRACTS_DIR / "faction_economy_shops.v1.json"
    pal_reconciliation_path = CONTRACTS_DIR / "pal_reconciliation.v1.json"
    progression_path = CONTRACTS_DIR / "faction_progression.v1.json"
    multiplayer_authority_path = (
        CONTRACTS_DIR / "multiplayer_authority.v1.json"
    )
    assignments_path = CONTRACTS_DIR / "territory_assignments.v1.json"
    fast_travel_path = CONTRACTS_DIR / "fast_travel_territories.v1.json"
    islands_path = CONTRACTS_DIR / "island_territories.v2.json"
    tower_path = CONTRACTS_DIR / "tower_territories.v1.json"

    factions_contract = _read_json(factions_path)
    commerce_contract = _read_json(commerce_path)
    economy_contract = _read_json(economy_path)
    economy_shops_contract = _read_json(economy_shops_path)
    pal_reconciliation_contract = _read_json(pal_reconciliation_path)
    progression_contract = _read_json(progression_path)
    multiplayer_authority_contract = _read_json(
        multiplayer_authority_path
    )
    assignments_contract = _read_json(assignments_path)
    fast_travel_contract = _read_json(fast_travel_path)
    islands_contract = _read_json(islands_path)
    tower_contract = _read_json(tower_path)

    if assignments_contract.get("baselineStatus") != "user_approved_frozen_baseline":
        raise ValueError("territory partition is not the user-approved frozen baseline")
    if progression_contract.get("baselineStatus") != "user_confirmed_mechanics_baseline_2026-07-28":
        raise ValueError("faction progression is not the user-confirmed mechanics baseline")
    if (
        multiplayer_authority_contract.get("workPackage")
        != "technical-multiplayer-authority-foundation"
    ):
        raise ValueError("multiplayer authority contract is not active")
    if commerce_contract.get("baselineStatus") != "mechanics_complete_balance_provisional_2026-07-28":
        raise ValueError("faction commerce mechanics baseline is not active")
    if (
        economy_contract.get("baselineStatus")
        != "user_confirmed_trade_direction_resource_and_recipe_baseline_complete_balance_pending_2026-07-29"
    ):
        raise ValueError("faction economy resource and recipe baseline is not active")
    if (
        economy_shops_contract.get("baselineStatus")
        != "offline_shop_asset_and_catalog_ready_runtime_disabled_2026-07-29"
    ):
        raise ValueError("faction economy shop asset baseline is not active")
    if (
        pal_reconciliation_contract.get("baselineStatus")
        != "user_confirmed_token_discourse_mechanics_2026-08-05"
    ):
        raise ValueError("Pal reconciliation mechanics baseline is not active")
    if factions_contract["gameBuild"] != assignments_contract["gameBuild"]:
        raise ValueError("faction and assignment contracts target different game builds")
    if progression_contract["gameBuild"] != assignments_contract["gameBuild"]:
        raise ValueError("faction progression and assignment contracts target different game builds")
    if commerce_contract["gameBuild"] != assignments_contract["gameBuild"]:
        raise ValueError("faction commerce and assignment contracts target different game builds")
    if economy_contract["gameBuild"] != assignments_contract["gameBuild"]:
        raise ValueError("faction economy and assignment contracts target different game builds")
    if economy_shops_contract["gameBuild"] != assignments_contract["gameBuild"]:
        raise ValueError(
            "faction economy shops and assignment contracts target different game builds"
        )
    if pal_reconciliation_contract["gameBuild"] != assignments_contract["gameBuild"]:
        raise ValueError(
            "Pal reconciliation and assignment contracts target different game builds"
        )
    if tower_contract["gameBuild"] != assignments_contract["gameBuild"]:
        raise ValueError("tower and assignment contracts target different game builds")
    if islands_contract["gameBuild"] != assignments_contract["gameBuild"]:
        raise ValueError("island and assignment contracts target different game builds")
    if fast_travel_contract["gameBuild"] != assignments_contract["gameBuild"]:
        raise ValueError("fast-travel and assignment contracts target different game builds")
    if islands_contract.get("baselineStatus") != "user_approved_active_baseline":
        raise ValueError("island territory layers are not the active user-approved baseline")

    factions: dict[str, dict[str, Any]] = {}
    for item in factions_contract["factions"]:
        faction_id = item["id"]
        if faction_id in factions:
            raise ValueError(f"duplicate faction ID: {faction_id}")
        factions[faction_id] = {
            "id": faction_id,
            "displayNameZhHans": item["displayNameZhHans"],
            "displayNameEn": item["displayNameEn"],
            "sourceTextKey": item.get("sourceTextKey"),
            "bindingStatus": item.get("bindingStatus"),
        }

    human_faction_ids = progression_contract["humanFactionIds"]
    pal_faction_ids = progression_contract["palFactionIds"]
    human_faction_set = set(human_faction_ids)
    pal_faction_set = set(pal_faction_ids)
    if human_faction_set & pal_faction_set:
        raise ValueError("human and Pal faction classifications overlap")
    if human_faction_set | pal_faction_set != set(factions):
        raise ValueError("faction progression classification must cover every stable faction")
    if len(human_faction_ids) != len(human_faction_set):
        raise ValueError("duplicate human faction progression ID")
    if len(pal_faction_ids) != len(pal_faction_set):
        raise ValueError("duplicate Pal faction progression ID")
    if set(pal_reconciliation_contract["humanCityStateIds"]) != human_faction_set:
        raise ValueError(
            "Pal reconciliation city-state pool must cover every human faction"
        )
    if set(pal_reconciliation_contract["palFactionIds"]) != pal_faction_set:
        raise ValueError(
            "Pal reconciliation contract must cover every Pal faction"
        )
    raid_eligibility = pal_reconciliation_contract["raidEligibility"]
    if (
        raid_eligibility.get("playerSideMustWin") is not True
        or raid_eligibility.get("participationRule")
        != "authoritative_raid_leader_kill_credit"
        or raid_eligibility.get("duplicateCityStateResultsAllowed") is not True
    ):
        raise ValueError("Pal reconciliation raid eligibility rules drifted")
    discourse_policy = pal_reconciliation_contract["discoursePolicy"]
    if (
        discourse_policy.get("technicalFailureConsumesToken") is not False
        or discourse_policy.get("playerAbortAfterConfirmationConsumesToken") is not True
        or discourse_policy.get("exhaustedBeforeTargetPermanentlyLocksFaction") is not True
    ):
        raise ValueError("Pal reconciliation finite-attempt policy drifted")
    for faction_id, faction in factions.items():
        faction["kind"] = "Human" if faction_id in human_faction_set else "Pal"
        faction["membershipAllowed"] = faction_id in human_faction_set

    commerce_faction_ids: set[str] = set()
    merchant_ids: set[str] = set()
    for merchant in commerce_contract["factions"]:
        faction_id = merchant["factionId"]
        merchant_id = merchant["merchantId"]
        if faction_id not in human_faction_set:
            raise ValueError(f"commerce merchant is not a human faction: {faction_id}")
        if faction_id in commerce_faction_ids:
            raise ValueError(f"duplicate commerce faction: {faction_id}")
        if merchant_id in merchant_ids:
            raise ValueError(f"duplicate commerce merchant ID: {merchant_id}")
        commerce_faction_ids.add(faction_id)
        merchant_ids.add(merchant_id)
    if commerce_faction_ids != human_faction_set:
        raise ValueError("commerce contract must define exactly one merchant for every human faction")
    if commerce_contract["merchantIsland"]["merchantCount"] != len(human_faction_set):
        raise ValueError("commerce merchant-island count does not match human factions")

    territories: dict[str, dict[str, Any]] = {}
    mask_to_region: dict[str, str] = {}
    region_name_id_to_region: dict[str, str] = {}
    for item in assignments_contract["assignments"]:
        region_id = item["regionId"]
        if region_id in territories:
            raise ValueError(f"duplicate region ID: {region_id}")
        owner_id = item.get("ownerFactionId")
        if owner_id is not None and owner_id not in factions:
            raise ValueError(f"region {region_id} references unknown faction {owner_id}")

        mask_asset = item["nativeMaskAsset"]
        if mask_asset in mask_to_region:
            raise ValueError(f"duplicate native mask asset: {mask_asset}")
        mask_to_region[mask_asset] = region_id

        native_region_name_ids = item.get("nativeRegionNameIds", [])
        if not isinstance(native_region_name_ids, list) or not all(
            isinstance(value, str) and value for value in native_region_name_ids
        ):
            raise ValueError(
                f"region {region_id} nativeRegionNameIds must be a list of non-empty strings"
            )
        for native_region_name_id in native_region_name_ids:
            existing_region_id = region_name_id_to_region.get(native_region_name_id)
            if existing_region_id is not None:
                raise ValueError(
                    "native RegionNameID is assigned more than once: "
                    f"{native_region_name_id} ({existing_region_id}, {region_id})"
                )
            region_name_id_to_region[native_region_name_id] = region_id

        temporal = item.get("temporalControlPolicy") or {}
        territories[region_id] = {
            "id": region_id,
            "mapId": item.get("mapId", "main"),
            "nativeMaskAsset": mask_asset,
            "nativeRegionNameIds": native_region_name_ids,
            "ownerFactionId": owner_id,
            "ownerDisplayNameZhHans": item.get("ownerDisplayNameZhHans", "中立区"),
            "ownerShortNameZhHans": item.get("ownerShortNameZhHans", "中立区"),
            "controllerNameZhHans": item.get("includedTowerLeaderZhHans"),
            "towerDisplayNameZhHans": item.get("includedTowerDisplayNameZhHans"),
            "fixedRelationState": item.get("relationState"),
            "dayRelationOverride": temporal.get("dayRelationOverride"),
            "nightRelationPolicy": temporal.get("nightRelationPolicy"),
            "assignmentStatus": item.get("assignmentStatus"),
        }

    tower_ids: list[str] = []
    watchtower_by_fast_travel_id: dict[str, str] = {}
    for item in tower_contract["territories"]:
        tower_id = item["nativeTowerId"]
        if tower_id in tower_ids:
            raise ValueError(f"duplicate native tower ID: {tower_id}")
        tower_ids.append(tower_id)
        fast_travel_id = item.get("runtimeFastTravelPointId")
        if fast_travel_id is not None:
            if not isinstance(fast_travel_id, str) or not fast_travel_id:
                raise ValueError(f"tower {tower_id} has an invalid runtime fast-travel ID")
            if fast_travel_id in watchtower_by_fast_travel_id:
                raise ValueError(f"duplicate runtime fast-travel ID: {fast_travel_id}")
            watchtower_by_fast_travel_id[fast_travel_id] = tower_id

    observed_tower_count = tower_contract.get("runtimeEvidence", {}).get("observedTowerCount")
    if observed_tower_count != len(watchtower_by_fast_travel_id):
        raise ValueError(
            "runtime evidence count does not match confirmed fast-travel IDs: "
            f"expected {observed_tower_count}, found {len(watchtower_by_fast_travel_id)}"
        )

    if len(territories) != 22:
        raise ValueError(f"expected 22 frozen map regions, found {len(territories)}")
    if len(tower_ids) != 24:
        raise ValueError(f"expected 24 native watchtowers, found {len(tower_ids)}")

    islands: dict[str, dict[str, Any]] = {}
    island_order: list[str] = []
    region_to_island: dict[str, str] = {}
    region_name_id_to_island: dict[str, str] = {}
    for item in islands_contract["islands"]:
        island_id = item["id"]
        if island_id in islands:
            raise ValueError(f"duplicate island ID: {island_id}")
        human_owner_id = item.get("humanOwnerFactionId")
        pal_owner_id = item.get("palOwnerFactionId")
        for owner_id in (human_owner_id, pal_owner_id):
            if owner_id is not None and owner_id not in factions:
                raise ValueError(f"island {island_id} references unknown faction {owner_id}")

        source_region_ids = item.get("geometrySourceRegionIds") or []
        if not source_region_ids:
            raise ValueError(f"island {island_id} has no source regions")
        for region_id in source_region_ids:
            if region_id not in territories:
                raise ValueError(f"island {island_id} references unknown region {region_id}")
            existing_island_id = region_to_island.get(region_id)
            if existing_island_id is not None:
                raise ValueError(
                    f"legacy region {region_id} maps to multiple islands: "
                    f"{existing_island_id}, {island_id}"
                )
            region_to_island[region_id] = island_id

        native_region_name_ids = item.get("nativeRegionNameIds", [])
        for native_region_name_id in native_region_name_ids:
            existing_island_id = region_name_id_to_island.get(native_region_name_id)
            if existing_island_id is not None:
                raise ValueError(
                    "native RegionNameID maps to multiple islands: "
                    f"{native_region_name_id} ({existing_island_id}, {island_id})"
                )
            region_name_id_to_island[native_region_name_id] = island_id

        islands[island_id] = {
            "id": island_id,
            "mapId": "main",
            "displayNameZhHans": item["displayNameZhHans"],
            "geometrySourceRegionIds": source_region_ids,
            "humanOwnerFactionId": human_owner_id,
            "palOwnerFactionId": pal_owner_id,
            # Human ownership is the gameplay/entry default.  The Pal owner is
            # selected only while rendering the separate Pal map layer.
            "ownerFactionId": human_owner_id,
            "ownerDisplayNameZhHans": (
                factions[human_owner_id]["displayNameZhHans"]
                if human_owner_id is not None
                else "无主人类势力"
            ),
            "palOwnerDisplayNameZhHans": (
                factions[pal_owner_id]["displayNameZhHans"]
                if pal_owner_id is not None
                else "无主帕鲁势力"
            ),
            "nativeRegionNameIds": native_region_name_ids,
            "fixedRelationState": None,
            "dayRelationOverride": None,
            "nightRelationPolicy": None,
        }
        island_order.append(island_id)

    if len(islands) != 7:
        raise ValueError(f"expected 7 approved whole-island units, found {len(islands)}")

    fast_travel_point_to_island: dict[str, str] = {}
    for item in fast_travel_contract["territories"]:
        island_id = item["islandId"]
        if island_id not in islands:
            raise ValueError(f"fast-travel contract references unknown island {island_id}")
        for fast_travel_id in item.get("fastTravelPointIds", []):
            if not isinstance(fast_travel_id, str) or not fast_travel_id:
                raise ValueError(f"invalid fast-travel ID for island {island_id}")
            existing_island_id = fast_travel_point_to_island.get(fast_travel_id)
            if existing_island_id is not None:
                raise ValueError(
                    f"fast-travel ID maps to multiple islands: {fast_travel_id} "
                    f"({existing_island_id}, {island_id})"
                )
            fast_travel_point_to_island[fast_travel_id] = island_id

    expected_fast_travel_count = fast_travel_contract["classificationPolicy"]["mappedPointCount"]
    if len(fast_travel_point_to_island) != expected_fast_travel_count:
        raise ValueError(
            "fast-travel mapping count mismatch: "
            f"expected {expected_fast_travel_count}, found {len(fast_travel_point_to_island)}"
        )

    return {
        "schemaVersion": "1.0.0",
        "baselineId": islands_contract["baselineId"],
        "baselineStatus": islands_contract["baselineStatus"],
        "gameBuild": assignments_contract["gameBuild"],
        "contractHashes": {
            "factions.v1.json": _sha256(factions_path),
            "faction_commerce.v1.json": _sha256(commerce_path),
            "faction_economy.v1.json": _sha256(economy_path),
            "faction_economy_shops.v1.json": _sha256(economy_shops_path),
            "pal_reconciliation.v1.json": _sha256(pal_reconciliation_path),
            "faction_progression.v1.json": _sha256(progression_path),
            "multiplayer_authority.v1.json": _sha256(
                multiplayer_authority_path
            ),
            "territory_assignments.v1.json": _sha256(assignments_path),
            "fast_travel_territories.v1.json": _sha256(fast_travel_path),
            "island_territories.v2.json": _sha256(islands_path),
            "tower_territories.v1.json": _sha256(tower_path),
        },
        "counts": {
            "factions": len(factions),
            "regions": len(territories),
            "islands": len(islands),
            "nativeWatchtowers": len(tower_ids),
            "runtimeConfirmedWatchtowers": len(watchtower_by_fast_travel_id),
            "mappedNativePlaceNames": len(region_name_id_to_island),
            "mappedFastTravelPoints": len(fast_travel_point_to_island),
        },
        "palette": {
            "Hostile": "#D34A4A",
            "Friendly": "#4D86D9",
            "Player": "#4FAF68",
            "Neutral": "#6B7078",
            "Locked": "#6B7078",
        },
        "factions": factions,
        "commerce": commerce_contract,
        "economy": economy_contract,
        "economyShops": economy_shops_contract,
        "palReconciliation": pal_reconciliation_contract,
        "progression": progression_contract,
        "multiplayerAuthority": multiplayer_authority_contract,
        "mapModes": islands_contract["designPolicy"]["mapModes"],
        "islandOrder": island_order,
        "islands": islands,
        "regionToIsland": region_to_island,
        "regionNameIdToIsland": region_name_id_to_island,
        "territories": territories,
        "maskToRegion": mask_to_region,
        "regionNameIdToRegion": region_name_id_to_region,
        "nativeTowerIds": tower_ids,
        "watchtowerByFastTravelId": watchtower_by_fast_travel_id,
        "fastTravelPointToIsland": fast_travel_point_to_island,
    }


def _render(registry: dict[str, Any]) -> str:
    header = (
        "-- Generated by tools/generate_mod0_registry.py.\n"
        "-- Do not edit this file by hand; edit the versioned contracts instead.\n"
    )
    return header + "return " + _lua_value(registry) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--check",
        action="store_true",
        help="fail if the generated registry is missing or stale",
    )
    args = parser.parse_args()

    rendered = _render(_build_registry())
    if args.check:
        if not OUTPUT_PATH.exists():
            print(f"MISSING {OUTPUT_PATH}")
            return 1
        if OUTPUT_PATH.read_text(encoding="utf-8") != rendered:
            print(f"STALE {OUTPUT_PATH}")
            return 1
        print(f"PASS generated registry: {OUTPUT_PATH}")
        return 0

    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT_PATH.write_text(rendered, encoding="utf-8", newline="\n")
    print(f"WROTE {OUTPUT_PATH}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
