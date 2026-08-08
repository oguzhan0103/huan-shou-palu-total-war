from __future__ import annotations

import json
from pathlib import Path

from .models import (
    FactionCatalog,
    FactionDefinition,
    PlayerRelation,
    RelationshipState,
    TerritoryCatalog,
    TerritoryDefinition,
)


def _read_json(path: str | Path) -> object:
    with Path(path).open("r", encoding="utf-8") as handle:
        return json.load(handle)


def load_factions(path: str | Path) -> FactionCatalog:
    raw = _require_dict(_read_json(path), "faction catalog")
    definitions = tuple(
        FactionDefinition(
            id=_string(item, "id"),
            display_name_zh_hans=_string(item, "displayNameZhHans"),
            display_name_en=_string(item, "displayNameEn"),
            source_text_key=_string(item, "sourceTextKey"),
            native_organization_type=_optional_string(item, "nativeOrganizationType"),
            binding_status=_string(item, "bindingStatus"),
        )
        for item in _dict_list(raw, "factions")
    )
    return FactionCatalog(
        schema_version=_string(raw, "schemaVersion"),
        game_build=_string(raw, "gameBuild"),
        factions=definitions,
    )


def load_territories(path: str | Path) -> TerritoryCatalog:
    raw = _require_dict(_read_json(path), "territory catalog")
    definitions = tuple(
        TerritoryDefinition(
            id=_string(item, "id"),
            native_tower_id=_string(item, "nativeTowerId"),
            display_text_key=_string(item, "displayTextKey"),
            display_name_zh_hans=_string(item, "displayNameZhHans"),
            display_name_en=_string(item, "displayNameEn"),
            owner_faction_id=_optional_string(item, "ownerFactionId"),
            controller_id=_optional_string(item, "controllerId"),
            controller_display_name_zh_hans=_optional_string(
                item, "controllerDisplayNameZhHans"
            ),
            native_mask_asset_path=_optional_string(item, "nativeMaskAssetPath"),
            binding_status=_string(item, "bindingStatus"),
            evidence_refs=tuple(_string_list(item, "evidenceRefs")),
        )
        for item in _dict_list(raw, "territories")
    )
    return TerritoryCatalog(
        schema_version=_string(raw, "schemaVersion"),
        game_build=_string(raw, "gameBuild"),
        territories=definitions,
    )


def load_relations(path: str | Path) -> tuple[PlayerRelation, ...]:
    raw = _read_json(path)
    if not isinstance(raw, list):
        raise ValueError("relation events must be a list")
    result: list[PlayerRelation] = []
    for index, value in enumerate(raw):
        item = _require_dict(value, f"relation[{index}]")
        try:
            state = RelationshipState(_string(item, "state"))
        except ValueError as exc:
            raise ValueError(f"relation[{index}] has an invalid state") from exc
        revision = item.get("revision")
        if not isinstance(revision, int) or isinstance(revision, bool) or revision < 0:
            raise ValueError(f"relation[{index}].revision must be a non-negative integer")
        result.append(PlayerRelation(_string(item, "factionId"), state, revision))
    return tuple(result)


def _require_dict(value: object, label: str) -> dict[str, object]:
    if not isinstance(value, dict):
        raise ValueError(f"{label} must be an object")
    return value


def _string(item: dict[str, object], key: str) -> str:
    value = item.get(key)
    if not isinstance(value, str) or not value:
        raise ValueError(f"{key} must be a non-empty string")
    return value


def _optional_string(item: dict[str, object], key: str) -> str | None:
    value = item.get(key)
    if value is None:
        return None
    if not isinstance(value, str) or not value:
        raise ValueError(f"{key} must be null or a non-empty string")
    return value


def _dict_list(item: dict[str, object], key: str) -> list[dict[str, object]]:
    value = item.get(key)
    if not isinstance(value, list):
        raise ValueError(f"{key} must be a list")
    return [_require_dict(entry, f"{key} entry") for entry in value]


def _string_list(item: dict[str, object], key: str) -> list[str]:
    value = item.get(key)
    if not isinstance(value, list) or not all(isinstance(entry, str) for entry in value):
        raise ValueError(f"{key} must be a list of strings")
    return value

