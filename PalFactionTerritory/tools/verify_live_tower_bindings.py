"""Validate the runtime-confirmed watchtower FastTravelPointID evidence.

This intentionally validates only IDs observed in the listed UE4SS log.  It does
not infer missing IDs from matching editor names, because the remaining two
watchtowers have not yet appeared in the loaded world.
"""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
CONTRACT_PATH = PROJECT_ROOT / "contracts" / "tower_territories.v1.json"
DEFAULT_LOG_PATH = Path(
    r"E:\SteamLibrary\steamapps\common\Palworld\Pal\Binaries\Win64\ue4ss\UE4SS.log"
)
TOWER_BINDING_PATTERN = re.compile(
    r"TOWER_BINDING .*?fastTravelId=(WatchTower_(?:WorldTree_)?\d+) "
    r"nativeTowerId=(\S+)"
)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", type=Path, default=DEFAULT_LOG_PATH)
    args = parser.parse_args()

    contract = json.loads(CONTRACT_PATH.read_text(encoding="utf-8"))
    evidence = contract["runtimeEvidence"]
    expected = {
        item["runtimeFastTravelPointId"]: item["nativeTowerId"]
        for item in contract["territories"]
        if item.get("runtimeFastTravelPointId") is not None
    }
    pending = [
        item["nativeTowerId"]
        for item in contract["territories"]
        if item.get("runtimeFastTravelPointId") is None
    ]

    require(args.log.is_file(), f"missing UE4SS log: {args.log}")
    observed_pairs = TOWER_BINDING_PATTERN.findall(
        args.log.read_text(encoding="utf-8", errors="replace")
    )
    observed_by_fast_travel_id: dict[str, set[str]] = {}
    for fast_travel_id, native_tower_id in observed_pairs:
        observed_by_fast_travel_id.setdefault(fast_travel_id, set()).add(native_tower_id)

    require(len(expected) == evidence["observedTowerCount"], "contract runtime evidence count is stale")
    require(
        set(expected).issubset(observed_by_fast_travel_id),
        "UE4SS log is missing confirmed watchtower IDs",
    )
    unexpected = set(observed_by_fast_travel_id) - set(expected)
    require(
        not unexpected,
        "UE4SS log contains new watchtower IDs that require a reviewed contract update: "
        + ", ".join(sorted(unexpected)),
    )
    for fast_travel_id, expected_native_tower_id in expected.items():
        actual_native_tower_ids = observed_by_fast_travel_id[fast_travel_id]
        require(
            actual_native_tower_ids == {expected_native_tower_id},
            "runtime/native tower mismatch for "
            f"{fast_travel_id}: expected {expected_native_tower_id}, "
            f"observed {', '.join(sorted(actual_native_tower_ids))}",
        )
    require(len(pending) == 2, "expected exactly two still-unobserved watchtowers")

    print(
        "PASS live tower binding evidence "
        f"({len(expected)} confirmed FastTravelPointID/native tower pairs; "
        f"pending: {', '.join(pending)})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
