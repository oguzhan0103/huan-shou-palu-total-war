from __future__ import annotations

import sys
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT_ROOT / "src"))

from pal_faction_territory import (  # noqa: E402
    MapMode,
    PlayerRelation,
    RelationshipState,
    TerritoryPolicyEngine,
    load_factions,
    load_relations,
    load_territories,
)


def main() -> int:
    contracts = PROJECT_ROOT / "contracts"
    factions = load_factions(contracts / "factions.v1.json")
    territories = load_territories(contracts / "tower_territories.v1.json")
    relation_events = load_relations(contracts / "player_relations.sample.json")
    relations = TerritoryPolicyEngine.latest_relations(relation_events)
    engine = TerritoryPolicyEngine(factions, territories)
    passed: list[str] = []

    def check(condition: bool, name: str) -> None:
        if not condition:
            raise AssertionError(f"FAIL: {name}")
        passed.append(name)

    unlocked = {"WatchTower_1"}
    windswept = "pwft.territory.watchtower_1"

    check(len(territories.territories) == 24, "24 native watchtower IDs loaded")
    check(
        len({item.native_tower_id for item in territories.territories}) == 24,
        "native watchtower IDs are unique",
    )

    original = engine.resolve_overlay(MapMode.ORIGINAL, windswept, unlocked, relations)
    check(
        not original.visible and original.preserve_native_fog,
        "original-map mode does not paint an overlay",
    )

    hostile = engine.resolve_overlay(MapMode.TERRITORY, windswept, unlocked, relations)
    check(
        hostile.relationship is RelationshipState.HOSTILE
        and hostile.color == "#D34A4A",
        "hostile territory resolves to red",
    )

    blocked = engine.can_use_public_fast_travel(windswept, unlocked, relations)
    check(
        not blocked.allowed and blocked.reason_code == "hostile_territory",
        "hostile public fast travel is blocked",
    )

    hostile_info = engine.resolve_map_info(windswept, relations)
    check(
        hostile_info.territory_name_zh_hans == "风起之岛的瞭望塔"
        and hostile_info.faction_name_zh_hans == "雷恩盗猎团"
        and hostile_info.controller_name_zh_hans == "佐伊"
        and hostile_info.relationship_label_zh_hans == "敌对",
        "map info uses native territory, faction, and controller text",
    )

    entered = engine.evaluate_entry(None, windswept, relations)
    check(
        entered.should_notify and entered.suggested_text == "已进入敌对势力领地",
        "hostile territory entry raises one presentation event",
    )

    same = engine.evaluate_entry(windswept, windswept, relations)
    check(not same.should_notify, "remaining in a territory does not repeat the event")

    friendly_relations = TerritoryPolicyEngine.latest_relations(
        relation_events
        + (
            PlayerRelation(
                "pwft.faction.rayne_syndicate",
                RelationshipState.FRIENDLY,
                2,
            ),
        )
    )
    friendly = engine.resolve_overlay(
        MapMode.TERRITORY, windswept, unlocked, friendly_relations
    )
    check(
        friendly.relationship is RelationshipState.FRIENDLY
        and friendly.color == "#4FAF68",
        "latest relationship update resolves to green",
    )
    check(
        engine.resolve_map_info(
            windswept, friendly_relations
        ).relationship_label_zh_hans
        == "和平／友好",
        "map relationship label updates dynamically",
    )
    check(
        engine.can_use_public_fast_travel(
            windswept, unlocked, friendly_relations
        ).allowed,
        "friendly public fast travel is allowed",
    )

    neutral_relations = TerritoryPolicyEngine.latest_relations(
        relation_events
        + (
            PlayerRelation(
                "pwft.faction.rayne_syndicate",
                RelationshipState.NEUTRAL,
                3,
            ),
        )
    )
    neutral = engine.resolve_overlay(
        MapMode.TERRITORY, windswept, unlocked, neutral_relations
    )
    check(
        neutral.relationship is RelationshipState.NEUTRAL
        and neutral.color == "#4D86D9",
        "latest neutral relationship resolves to blue",
    )

    locked = engine.resolve_overlay(
        MapMode.TERRITORY,
        "pwft.territory.watchtower_2",
        unlocked,
        relations,
    )
    check(
        not locked.visible
        and locked.preserve_native_fog
        and locked.relationship is None,
        "locked territory preserves native fog and has no relation paint",
    )
    check(
        not engine.can_use_public_fast_travel(
            "pwft.territory.watchtower_2", unlocked, relations
        ).allowed,
        "native locked region cannot be a public fast-travel destination",
    )

    print(f"PASS ({len(passed)} assertions)")
    for item in passed:
        print(f"- {item}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
