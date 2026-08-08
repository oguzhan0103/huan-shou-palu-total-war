from __future__ import annotations

import csv
import json
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
WORKSPACE_ROOT = PROJECT_ROOT.parent


def main() -> int:
    corpus_roots = [
        path
        for path in WORKSPACE_ROOT.iterdir()
        if path.is_dir()
        and (path / "raw_extracted" / "local_text_pairs.csv").is_file()
    ]
    if len(corpus_roots) != 1:
        raise RuntimeError(
            "Expected exactly one local text corpus containing "
            "raw_extracted/local_text_pairs.csv"
        )

    text_pairs_path = corpus_roots[0] / "raw_extracted" / "local_text_pairs.csv"
    with text_pairs_path.open(encoding="utf-8-sig", newline="") as handle:
        text_rows = {row["source_key"]: row for row in csv.DictReader(handle)}

    territories = json.loads(
        (PROJECT_ROOT / "contracts" / "tower_territories.v1.json").read_text(
            encoding="utf-8"
        )
    )["territories"]
    factions = json.loads(
        (PROJECT_ROOT / "contracts" / "factions.v1.json").read_text(
            encoding="utf-8"
        )
    )["factions"]

    checked_towers = 0
    for territory in territories:
        row = text_rows.get(territory["displayTextKey"])
        if row is None:
            raise AssertionError(
                f"Missing native tower text row: {territory['displayTextKey']}"
            )
        if row["zh_hans"] != territory["displayNameZhHans"]:
            raise AssertionError(
                f"Chinese tower text mismatch: {territory['nativeTowerId']}"
            )
        if row["en"] != territory["displayNameEn"]:
            raise AssertionError(
                f"English tower text mismatch: {territory['nativeTowerId']}"
            )
        checked_towers += 1

    checked_factions = 0
    skipped_user_defined_factions = 0
    for faction in factions:
        if faction["bindingStatus"] == "user_defined_no_native_binding":
            skipped_user_defined_factions += 1
            continue
        row = text_rows.get(faction["sourceTextKey"])
        if row is None:
            raise AssertionError(
                f"Missing native faction text row: {faction['sourceTextKey']}"
            )
        if faction["displayNameZhHans"] not in row["zh_hans"]:
            raise AssertionError(f"Chinese faction text mismatch: {faction['id']}")
        if faction["displayNameEn"] not in row["en"]:
            raise AssertionError(f"English faction text mismatch: {faction['id']}")
        checked_factions += 1

    print(
        "PASS native text bindings "
        f"({checked_towers} towers, {checked_factions} native factions; "
        f"{skipped_user_defined_factions} user-defined factions skipped)"
    )
    print(f"- source: {text_pairs_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
