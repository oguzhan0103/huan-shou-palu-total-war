from __future__ import annotations

from collections.abc import Iterable, Mapping, Set

from .models import (
    FactionCatalog,
    FactionDefinition,
    FastTravelDecision,
    MapMode,
    PlayerRelation,
    RelationshipPalette,
    RelationshipState,
    TerritoryCatalog,
    TerritoryDefinition,
    TerritoryEntryDecision,
    TerritoryMapInfo,
    TerritoryOverlay,
)


class TerritoryPolicyEngine:
    def __init__(
        self,
        factions: FactionCatalog,
        territories: TerritoryCatalog,
        palette: RelationshipPalette | None = None,
    ) -> None:
        self._factions = self._unique_by_id(factions.factions, "faction")
        self._territories = self._unique_by_id(territories.territories, "territory")
        self._palette = palette or RelationshipPalette()
        self._validate(factions, territories)

    def resolve_overlay(
        self,
        mode: MapMode,
        territory_id: str,
        unlocked_tower_ids: Set[str],
        relations: Mapping[str, PlayerRelation],
    ) -> TerritoryOverlay:
        territory = self._require_territory(territory_id)
        if mode is MapMode.ORIGINAL:
            return TerritoryOverlay(
                territory.id,
                False,
                True,
                None,
                self._palette.locked,
                territory.owner_faction_id,
                territory.controller_id,
            )
        if territory.native_tower_id not in unlocked_tower_ids:
            return TerritoryOverlay(
                territory.id,
                False,
                True,
                None,
                self._palette.locked,
                territory.owner_faction_id,
                territory.controller_id,
            )
        relation = self._resolve_relation(territory, relations)
        return TerritoryOverlay(
            territory.id,
            territory.native_mask_asset_path is not None,
            True,
            relation,
            self._color_for(relation),
            territory.owner_faction_id,
            territory.controller_id,
        )

    def can_use_public_fast_travel(
        self,
        fast_travel_point_territory_id: str,
        unlocked_tower_ids: Set[str],
        relations: Mapping[str, PlayerRelation],
    ) -> FastTravelDecision:
        territory = self._require_territory(fast_travel_point_territory_id)
        if territory.native_tower_id not in unlocked_tower_ids:
            return FastTravelDecision(
                False,
                "native_region_locked",
                territory.id,
                territory.owner_faction_id,
                None,
            )
        relation = self._resolve_relation(territory, relations)
        if relation is RelationshipState.HOSTILE:
            return FastTravelDecision(
                False,
                "hostile_territory",
                territory.id,
                territory.owner_faction_id,
                relation,
            )
        return FastTravelDecision(
            True,
            "allowed",
            territory.id,
            territory.owner_faction_id,
            relation,
        )

    def resolve_map_info(
        self,
        territory_id: str,
        relations: Mapping[str, PlayerRelation],
    ) -> TerritoryMapInfo:
        territory = self._require_territory(territory_id)
        relation = self._resolve_relation(territory, relations)
        faction = self._get_faction(territory.owner_faction_id)
        return TerritoryMapInfo(
            territory.id,
            territory.display_name_zh_hans,
            faction.id if faction else None,
            faction.display_name_zh_hans if faction else None,
            territory.controller_id,
            territory.controller_display_name_zh_hans,
            relation,
            self._relation_label_zh_hans(relation),
        )

    def evaluate_entry(
        self,
        previous_territory_id: str | None,
        current_territory_id: str,
        relations: Mapping[str, PlayerRelation],
    ) -> TerritoryEntryDecision:
        territory = self._require_territory(current_territory_id)
        changed = previous_territory_id != current_territory_id
        relation = self._resolve_relation(territory, relations)
        should_notify = changed and relation is RelationshipState.HOSTILE
        return TerritoryEntryDecision(
            changed,
            should_notify,
            territory.id,
            territory.owner_faction_id,
            relation,
            "已进入敌对势力领地" if should_notify else None,
        )

    @staticmethod
    def latest_relations(events: Iterable[PlayerRelation]) -> dict[str, PlayerRelation]:
        latest: dict[str, PlayerRelation] = {}
        for event in events:
            current = latest.get(event.faction_id)
            if current is None or event.revision > current.revision:
                latest[event.faction_id] = event
        return latest

    def _resolve_relation(
        self,
        territory: TerritoryDefinition,
        relations: Mapping[str, PlayerRelation],
    ) -> RelationshipState:
        if territory.owner_faction_id is None:
            return RelationshipState.NEUTRAL
        event = relations.get(territory.owner_faction_id)
        return event.state if event else RelationshipState.NEUTRAL

    def _color_for(self, relation: RelationshipState) -> str:
        if relation is RelationshipState.HOSTILE:
            return self._palette.hostile
        if relation is RelationshipState.FRIENDLY:
            return self._palette.friendly
        return self._palette.neutral

    @staticmethod
    def _relation_label_zh_hans(relation: RelationshipState) -> str:
        if relation is RelationshipState.HOSTILE:
            return "敌对"
        if relation is RelationshipState.FRIENDLY:
            return "和平／友好"
        return "中立"

    def _get_faction(self, faction_id: str | None) -> FactionDefinition | None:
        if faction_id is None:
            return None
        value = self._factions[faction_id]
        if not isinstance(value, FactionDefinition):
            raise TypeError(f"invalid faction definition: {faction_id}")
        return value

    def _require_territory(self, territory_id: str) -> TerritoryDefinition:
        try:
            value = self._territories[territory_id]
        except KeyError as exc:
            raise KeyError(f"unknown territory: {territory_id}") from exc
        if not isinstance(value, TerritoryDefinition):
            raise TypeError(f"invalid territory definition: {territory_id}")
        return value

    @staticmethod
    def _unique_by_id(values: Iterable[object], label: str) -> dict[str, object]:
        result: dict[str, object] = {}
        for value in values:
            identifier = getattr(value, "id")
            if identifier in result:
                raise ValueError(f"duplicate {label} ID: {identifier}")
            result[identifier] = value
        return result

    def _validate(self, factions: FactionCatalog, territories: TerritoryCatalog) -> None:
        if factions.game_build != territories.game_build:
            raise ValueError("faction and territory contracts target different game builds")
        if len(territories.territories) != 24:
            raise ValueError(
                f"expected 24 native watchtowers, found {len(territories.territories)}"
            )
        native_ids: set[str] = set()
        for territory in territories.territories:
            if territory.native_tower_id in native_ids:
                raise ValueError(f"duplicate native tower ID: {territory.native_tower_id}")
            native_ids.add(territory.native_tower_id)
            owner = territory.owner_faction_id
            if owner is not None and owner not in self._factions:
                raise ValueError(
                    f"territory {territory.id} references unknown faction {owner}"
                )
            if owner is not None and not territory.evidence_refs:
                raise ValueError(
                    f"territory {territory.id} has an owner but no evidence reference"
                )
