from __future__ import annotations

from dataclasses import dataclass
from enum import Enum


class MapMode(str, Enum):
    ORIGINAL = "Original"
    TERRITORY = "Territory"


class RelationshipState(str, Enum):
    NEUTRAL = "Neutral"
    FRIENDLY = "Friendly"
    HOSTILE = "Hostile"


@dataclass(frozen=True)
class FactionDefinition:
    id: str
    display_name_zh_hans: str
    display_name_en: str
    source_text_key: str
    native_organization_type: str | None
    binding_status: str


@dataclass(frozen=True)
class FactionCatalog:
    schema_version: str
    game_build: str
    factions: tuple[FactionDefinition, ...]


@dataclass(frozen=True)
class TerritoryDefinition:
    id: str
    native_tower_id: str
    display_text_key: str
    display_name_zh_hans: str
    display_name_en: str
    owner_faction_id: str | None
    controller_id: str | None
    controller_display_name_zh_hans: str | None
    native_mask_asset_path: str | None
    binding_status: str
    evidence_refs: tuple[str, ...]


@dataclass(frozen=True)
class TerritoryCatalog:
    schema_version: str
    game_build: str
    territories: tuple[TerritoryDefinition, ...]


@dataclass(frozen=True)
class PlayerRelation:
    faction_id: str
    state: RelationshipState
    revision: int


@dataclass(frozen=True)
class RelationshipPalette:
    hostile: str = "#D34A4A"
    friendly: str = "#4FAF68"
    neutral: str = "#4D86D9"
    locked: str = "#6B7078"


@dataclass(frozen=True)
class TerritoryOverlay:
    territory_id: str
    visible: bool
    preserve_native_fog: bool
    relationship: RelationshipState | None
    color: str
    faction_id: str | None
    controller_id: str | None


@dataclass(frozen=True)
class TerritoryMapInfo:
    territory_id: str
    territory_name_zh_hans: str
    faction_id: str | None
    faction_name_zh_hans: str | None
    controller_id: str | None
    controller_name_zh_hans: str | None
    relationship: RelationshipState
    relationship_label_zh_hans: str


@dataclass(frozen=True)
class FastTravelDecision:
    allowed: bool
    reason_code: str
    territory_id: str
    faction_id: str | None
    relationship: RelationshipState | None


@dataclass(frozen=True)
class TerritoryEntryDecision:
    entered_new_territory: bool
    should_notify: bool
    territory_id: str
    faction_id: str | None
    relationship: RelationshipState | None
    suggested_text: str | None
