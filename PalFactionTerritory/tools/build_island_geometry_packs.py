"""Build whole-island faction geometry aligned to Palworld's native map.

The native watchtower masks are used only as broad selectors for the islands
that were approved in the previous planning baseline.  The visible coastline
comes from the extracted ``T_WorldMap`` image: sea pixels are removed and no
watchtower boundary is rendered.  The resulting packed textures are Mod-owned
UI masks and never alter Palworld's exploration render target or save data.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from collections import deque
from pathlib import Path
from typing import Final

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont


ROOT: Final = Path(__file__).resolve().parents[1]
ISLANDS_PATH: Final = ROOT / "contracts" / "island_territories.v2.json"
ASSIGNMENTS_PATH: Final = ROOT / "contracts" / "territory_assignments.v1.json"
FAST_TRAVEL_PATH: Final = ROOT / "contracts" / "fast_travel_territories.v1.json"
SOURCE_MAP: Final = ROOT / "artifacts" / "map-assets" / "native-world-map.jpg"
SOURCE_MASK_DIR: Final = ROOT / "artifacts" / "map-assets" / "masks"
OUTPUT_SIZE: Final = (1024, 1024)
PACK_COUNT: Final = 5
CHANNELS: Final = ("R", "G", "B", "A")

LABEL_POSITIONS: Final = {
    "pwft.island.central_southeast_archipelago": (676, 517),
    "pwft.island.central_forest_archipelago": (616, 390),
    "pwft.island.desert": (780, 205),
    "pwft.island.snow": (560, 180),
    "pwft.island.sakurajima": (420, 270),
    "pwft.island.volcano": (405, 500),
    "pwft.island.feybreak": (270, 735),
}

HUMAN_DEFAULT_RELATIONS: Final = {
    "pwft.faction.free_pal_alliance": "Friendly",
}

PALETTE: Final = {
    "Hostile": (211, 74, 74),
    "Friendly": (77, 134, 217),
    "Player": (79, 175, 104),
}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    for candidate in (
        Path("C:/Windows/Fonts/msyhbd.ttc" if bold else "C:/Windows/Fonts/msyh.ttc"),
        Path("C:/Windows/Fonts/simhei.ttf"),
    ):
        if candidate.exists():
            return ImageFont.truetype(str(candidate), size=size)
    return ImageFont.load_default()


FONT_TITLE = font(28, bold=True)
FONT_SUBTITLE = font(15)
FONT_LABEL = font(14, bold=True)


def load_contracts() -> tuple[dict, list[dict], dict[str, dict], dict]:
    contract = json.loads(ISLANDS_PATH.read_text(encoding="utf-8"))
    assignments_document = json.loads(ASSIGNMENTS_PATH.read_text(encoding="utf-8"))
    fast_travel_contract = json.loads(FAST_TRAVEL_PATH.read_text(encoding="utf-8"))
    assignments = {item["regionId"]: item for item in assignments_document["assignments"]}
    islands = contract["islands"]
    if len(islands) > PACK_COUNT * len(CHANNELS):
        raise RuntimeError("island count exceeds the five RGBA material packs")
    seen: set[str] = set()
    for island in islands:
        island_id = island["id"]
        if island_id in seen:
            raise RuntimeError(f"duplicate island id: {island_id}")
        seen.add(island_id)
        source_regions = island.get("geometrySourceRegionIds") or []
        if not source_regions:
            raise RuntimeError(f"island has no geometry selectors: {island_id}")
        missing = [region_id for region_id in source_regions if region_id not in assignments]
        if missing:
            raise RuntimeError(f"unknown selector regions for {island_id}: {missing}")
    island_ids = {island["id"] for island in islands}
    for exclusion in contract.get("neutralGeometryExclusions", []):
        if exclusion["sourceIslandId"] not in island_ids:
            raise RuntimeError(
                "neutral geometry exclusion references unknown island: "
                f"{exclusion['sourceIslandId']}"
            )
        if exclusion.get("policy") != (
            "remove_connected_land_component_from_all_faction_overlays"
        ):
            raise RuntimeError(
                f"unsupported neutral geometry exclusion policy: {exclusion.get('policy')}"
            )
    return contract, islands, assignments, fast_travel_contract


def connected_components(mask: np.ndarray) -> list[list[tuple[int, int]]]:
    height, width = mask.shape
    seen = np.zeros_like(mask, dtype=bool)
    components: list[list[tuple[int, int]]] = []
    for y in range(height):
        for x in range(width):
            if not mask[y, x] or seen[y, x]:
                continue
            points: list[tuple[int, int]] = [(x, y)]
            seen[y, x] = True
            for px, py in points:
                for dy in (-1, 0, 1):
                    for dx in (-1, 0, 1):
                        if dx == 0 and dy == 0:
                            continue
                        nx, ny = px + dx, py + dy
                        if (
                            0 <= nx < width
                            and 0 <= ny < height
                            and mask[ny, nx]
                            and not seen[ny, nx]
                        ):
                            seen[ny, nx] = True
                            points.append((nx, ny))
            components.append(points)
    return components


def derive_land_mask(source: Image.Image) -> tuple[Image.Image, dict]:
    """Classify textured terrain while rejecting Palworld's smooth sea.

    T_WorldMap has no separate island-alpha layer.  Terrain is strongly
    textured and colour-diverse while the sea is a smooth blue field, so a
    local RGB range plus obvious land-colour rules provides a stable coastline
    selector.  Components touching the outer map frame are discarded.
    """
    rgb = np.asarray(source.convert("RGB"), dtype=np.int16)
    local_ranges: list[np.ndarray] = []
    for channel_index in range(3):
        channel = Image.fromarray(rgb[:, :, channel_index].astype(np.uint8), mode="L")
        high = np.asarray(channel.filter(ImageFilter.MaxFilter(7)), dtype=np.int16)
        low = np.asarray(channel.filter(ImageFilter.MinFilter(7)), dtype=np.int16)
        local_ranges.append(high - low)
    texture_range = np.maximum.reduce(local_ranges)
    red, green, blue = (rgb[:, :, index] for index in range(3))
    brightness = np.maximum.reduce((red, green, blue))
    yy, xx = np.mgrid[: rgb.shape[0], : rgb.shape[1]]
    candidate = (
        (texture_range > 28)
        | ((red > blue + 10) & (red > green - 8) & (brightness > 35))
        | ((green > red + 12) & (green > blue - 5) & (brightness > 38))
        | ((brightness > 145) & (red > 100))
    )
    candidate &= (xx > 20) & (xx < 1000) & (yy > 20) & (yy < 1000)
    closed = (
        Image.fromarray((candidate * 255).astype(np.uint8), mode="L")
        .filter(ImageFilter.MaxFilter(7))
        .filter(ImageFilter.MinFilter(7))
        .filter(ImageFilter.MedianFilter(5))
    )
    closed_pixels = np.asarray(closed, dtype=np.uint8) > 0
    retained = np.zeros_like(closed_pixels, dtype=bool)
    removed_frame_pixels = 0
    component_count = 0
    for component in connected_components(closed_pixels):
        if len(component) < 30:
            continue
        xs = [point[0] for point in component]
        ys = [point[1] for point in component]
        touches_frame = min(xs) < 40 or min(ys) < 40 or max(xs) > 984 or max(ys) > 984
        if touches_frame:
            removed_frame_pixels += len(component)
            continue
        component_count += 1
        for x, y in component:
            retained[y, x] = True
    mask = Image.fromarray((retained * 255).astype(np.uint8), mode="L")
    return mask, {
        "classifiedLandPixels": int(np.count_nonzero(retained)),
        "retainedLandComponents": component_count,
        "removedOuterFramePixels": removed_frame_pixels,
        "classifier": "T_WorldMap local RGB range and land-colour rules",
    }


def load_selector(
    island: dict,
    assignments: dict[str, dict],
) -> tuple[Image.Image, list[dict]]:
    selector = Image.new("L", OUTPUT_SIZE, 0)
    evidence: list[dict] = []
    for region_id in island["geometrySourceRegionIds"]:
        asset_name = assignments[region_id]["nativeMaskAsset"]
        source_path = SOURCE_MASK_DIR / f"{asset_name}.png"
        if not source_path.exists():
            raise RuntimeError(f"missing recovered selector mask: {source_path}")
        source_alpha = Image.open(source_path).convert("RGBA").getchannel("A")
        resized = source_alpha.resize(OUTPUT_SIZE, Image.Resampling.BICUBIC)
        selector = ImageChops.lighter(selector, resized)
        evidence.append(
            {
                "regionId": region_id,
                "nativeMaskAsset": asset_name,
                "source": str(source_path.relative_to(ROOT)).replace("\\", "/"),
                "sha256": sha256(source_path),
            }
        )
    return selector.filter(ImageFilter.MaxFilter(11)), evidence


def resolve_island_masks(
    islands: list[dict],
    assignments: dict[str, dict],
    land_mask: Image.Image,
    selector_threshold: int,
) -> tuple[list[Image.Image], list[dict], dict]:
    selectors: list[np.ndarray] = []
    evidence: list[dict] = []
    for island in islands:
        selector, sources = load_selector(island, assignments)
        selectors.append(np.asarray(selector, dtype=np.uint8))
        evidence.append({"islandId": island["id"], "selectors": sources})

    stack = np.stack(selectors, axis=0)
    best_index = np.argmax(stack, axis=0)
    best_value = np.max(stack, axis=0)
    land = np.asarray(land_mask, dtype=np.uint8) > 0
    assigned = land & (best_value >= selector_threshold)
    masks: list[Image.Image] = []
    pixel_counts: dict[str, int] = {}
    for index, island in enumerate(islands):
        pixels = assigned & (best_index == index)
        pixel_counts[island["id"]] = int(np.count_nonzero(pixels))
        masks.append(Image.fromarray((pixels * 255).astype(np.uint8), mode="L"))
    return masks, evidence, {
        "selectorThreshold": selector_threshold,
        "ownedIslandPixels": int(np.count_nonzero(assigned)),
        "unassignedLandPixels": int(np.count_nonzero(land & ~assigned)),
        "islandPixels": pixel_counts,
    }


def inset_island_masks(
    masks: list[Image.Image],
    geometry_stats: dict,
    inset_pixels: int,
) -> tuple[list[Image.Image], dict]:
    """Contract the binary coastline by a deliberately small pixel radius.

    The source map's antialiased coast can classify a one-pixel sea fringe as
    land.  A one-pixel MinFilter contraction removes that fringe without
    changing the island/archipelago ownership model.
    """
    if inset_pixels < 0:
        raise ValueError("coast inset must be zero or greater")
    if inset_pixels == 0:
        geometry_stats["coastInsetPixels"] = 0
        geometry_stats["removedBoundaryPixels"] = 0
        return masks, geometry_stats

    kernel_size = inset_pixels * 2 + 1
    inset_masks = [mask.filter(ImageFilter.MinFilter(kernel_size)) for mask in masks]
    before = sum(int(np.count_nonzero(np.asarray(mask, dtype=np.uint8))) for mask in masks)
    after_counts = [int(np.count_nonzero(np.asarray(mask, dtype=np.uint8))) for mask in inset_masks]
    after = sum(after_counts)
    geometry_stats["preInsetOwnedIslandPixels"] = before
    geometry_stats["ownedIslandPixels"] = after
    geometry_stats["coastInsetPixels"] = inset_pixels
    geometry_stats["removedBoundaryPixels"] = before - after
    for island_id, pixel_count in zip(geometry_stats["islandPixels"], after_counts):
        geometry_stats["islandPixels"][island_id] = pixel_count
    return inset_masks, geometry_stats


def apply_neutral_geometry_exclusions(
    masks: list[Image.Image],
    islands: list[dict],
    exclusions: list[dict],
    projection: dict,
    geometry_stats: dict,
) -> tuple[list[Image.Image], dict]:
    """Remove a selected whole land component from faction ownership.

    A commercial public island must remain transparent on both faction layers
    and its native fast-travel point must not inherit the surrounding faction.
    The exclusion is seeded by the pinned world location of the island's
    native travel point, then removes only that connected land component.
    """
    if not exclusions:
        geometry_stats["neutralGeometryExclusions"] = []
        return masks, geometry_stats

    width, height = OUTPUT_SIZE
    min_x = float(projection["minX"])
    min_y = float(projection["minY"])
    max_x = float(projection["maxX"])
    max_y = float(projection["maxY"])
    island_index = {island["id"]: index for index, island in enumerate(islands)}
    records: list[dict] = []
    removed_total = 0

    for exclusion in exclusions:
        source_island_id = exclusion["sourceIslandId"]
        index = island_index[source_island_id]
        seed = exclusion["seedWorldLocation"]
        pixel_x = round(
            (float(seed["Y"]) - min_y) / (max_y - min_y) * width
        )
        pixel_y = round(
            (max_x - float(seed["X"])) / (max_x - min_x) * height
        )
        pixels = np.asarray(masks[index], dtype=np.uint8) > 0
        components = connected_components(pixels)
        selected = next(
            (
                component
                for component in components
                if (pixel_x, pixel_y) in component
            ),
            None,
        )
        if selected is None:
            raise RuntimeError(
                "neutral geometry seed did not land on the selected island "
                f"component: {exclusion['id']} at ({pixel_x}, {pixel_y})"
            )

        mutable = pixels.copy()
        for x, y in selected:
            mutable[y, x] = False
        masks[index] = Image.fromarray(
            (mutable * 255).astype(np.uint8),
            mode="L",
        )
        removed = len(selected)
        removed_total += removed
        geometry_stats["islandPixels"][source_island_id] -= removed
        xs = [point[0] for point in selected]
        ys = [point[1] for point in selected]
        records.append(
            {
                "id": exclusion["id"],
                "displayNameZhHans": exclusion["displayNameZhHans"],
                "sourceIslandId": source_island_id,
                "seedFastTravelPointId": exclusion["seedFastTravelPointId"],
                "seedPixel": {"x": pixel_x, "y": pixel_y},
                "removedPixels": removed,
                "bounds": {
                    "minX": min(xs),
                    "minY": min(ys),
                    "maxX": max(xs),
                    "maxY": max(ys),
                },
                "policy": exclusion["policy"],
                "decisionSource": exclusion["decisionSource"],
            }
        )

    geometry_stats["ownedIslandPixels"] -= removed_total
    geometry_stats["neutralGeometryExclusions"] = records
    return masks, geometry_stats


def write_packs(output_dir: Path, masks: list[Image.Image], islands: list[dict]) -> list[dict]:
    padded = masks + [Image.new("L", OUTPUT_SIZE, 0) for _ in range(PACK_COUNT * 4 - len(masks))]
    records: list[dict] = []
    for pack_index in range(PACK_COUNT):
        channels = padded[pack_index * 4 : pack_index * 4 + 4]
        output = output_dir / f"T_PFT_IslandGeometryPack_{pack_index + 1:02d}.png"
        Image.merge("RGBA", tuple(channels)).save(output, optimize=True)
        channel_map: dict[str, str | None] = {}
        for channel_index, channel_name in enumerate(CHANNELS):
            island_index = pack_index * 4 + channel_index
            channel_map[channel_name] = islands[island_index]["id"] if island_index < len(islands) else None
        records.append({"file": output.name, "sha256": sha256(output), "channels": channel_map})
    return records


def draw_label(draw: ImageDraw.ImageDraw, x: int, y: int, lines: str) -> None:
    bbox = draw.multiline_textbbox((0, 0), lines, font=FONT_LABEL, align="center", spacing=1)
    width, height = bbox[2] - bbox[0], bbox[3] - bbox[1]
    left, top = x - width // 2 - 5, y - height // 2 - 3
    draw.rounded_rectangle(
        (left, top, left + width + 10, top + height + 6),
        radius=5,
        fill=(3, 17, 28, 210),
        outline=(210, 232, 240, 190),
        width=1,
    )
    draw.multiline_text(
        (x - width // 2, y - height // 2),
        lines,
        font=FONT_LABEL,
        fill=(238, 250, 255, 255),
        align="center",
        spacing=1,
    )


def relation_for_owner(owner_id: str | None, layer: str) -> str | None:
    if owner_id is None:
        return None
    if layer == "Human":
        return HUMAN_DEFAULT_RELATIONS.get(owner_id, "Hostile")
    return "Hostile"


def write_review(
    output_dir: Path,
    source_map: Image.Image,
    islands: list[dict],
    masks: list[Image.Image],
    layer: str,
) -> Path:
    preview = source_map.convert("RGBA")
    owner_key = "humanOwnerFactionId" if layer == "Human" else "palOwnerFactionId"
    for island, mask in zip(islands, masks):
        relation = relation_for_owner(island.get(owner_key), layer)
        if relation is None:
            continue
        red, green, blue = PALETTE[relation]
        fill = Image.new("RGBA", OUTPUT_SIZE, (red, green, blue, 0))
        fill.putalpha(mask.point(lambda value: 102 if value else 0))
        preview = Image.alpha_composite(preview, fill)
        expanded = mask.filter(ImageFilter.MaxFilter(3))
        contracted = mask.filter(ImageFilter.MinFilter(3))
        edge = ImageChops.subtract(expanded, contracted)
        edge_layer = Image.new("RGBA", OUTPUT_SIZE, (red, green, blue, 0))
        edge_layer.putalpha(edge.point(lambda value: 205 if value else 0))
        preview = Image.alpha_composite(preview, edge_layer)

    draw = ImageDraw.Draw(preview, "RGBA")
    title = "人类势力图" if layer == "Human" else "帕鲁势力图"
    draw.rounded_rectangle((24, 24, 520, 104), radius=10, fill=(4, 17, 29, 224), outline=(184, 220, 233, 220), width=2)
    draw.text((44, 38), title, font=FONT_TITLE, fill=(238, 250, 255, 255))
    draw.text((45, 76), "整岛着色；海洋与无主岛屿完全透明", font=FONT_SUBTITLE, fill=(180, 222, 235, 255))

    for island in islands:
        owner_id = island.get(owner_key)
        if owner_id is None:
            continue
        x, y = LABEL_POSITIONS[island["id"]]
        short_owner = owner_id.rsplit(".", 1)[-1]
        draw_label(draw, x, y, f"{island['displayNameZhHans']}\n{short_owner}")

    output = output_dir / ("human_factions_review.png" if layer == "Human" else "pal_factions_review.png")
    preview.save(output, optimize=True)
    return output


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=ROOT / "artifacts" / "island-territory-v2",
    )
    parser.add_argument("--selector-threshold", type=int, default=48)
    parser.add_argument(
        "--coast-inset-pixels",
        type=int,
        default=1,
        help="contract each 1024px island mask to remove a sea-edge fringe",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    contract, islands, assignments, fast_travel_contract = load_contracts()
    source_map = Image.open(SOURCE_MAP).convert("RGB").resize(OUTPUT_SIZE, Image.Resampling.LANCZOS)
    land_mask, land_stats = derive_land_mask(source_map)
    masks, selector_evidence, geometry_stats = resolve_island_masks(
        islands,
        assignments,
        land_mask,
        args.selector_threshold,
    )
    masks, geometry_stats = inset_island_masks(masks, geometry_stats, args.coast_inset_pixels)
    masks, geometry_stats = apply_neutral_geometry_exclusions(
        masks,
        islands,
        contract.get("neutralGeometryExclusions", []),
        fast_travel_contract["classificationPolicy"]["projection"],
        geometry_stats,
    )

    args.output_dir.mkdir(parents=True, exist_ok=True)
    land_mask_path = args.output_dir / "T_PFT_IslandLandMask.png"
    land_mask.save(land_mask_path, optimize=True)
    packs = write_packs(args.output_dir, masks, islands)
    human_review = write_review(args.output_dir, source_map, islands, masks, "Human")
    pal_review = write_review(args.output_dir, source_map, islands, masks, "Pal")

    union = Image.new("L", OUTPUT_SIZE, 0)
    for mask in masks:
        union = ImageChops.lighter(union, mask)
    border = ImageChops.subtract(
        union.filter(ImageFilter.MaxFilter(3)),
        union.filter(ImageFilter.MinFilter(3)),
    )
    border_path = args.output_dir / "T_PFT_IslandGeometryBorder.png"
    Image.merge("RGBA", (border, border, border, border)).save(border_path, optimize=True)

    manifest = {
        "schemaVersion": "2.0.0",
        "baselineId": contract["baselineId"],
        "purpose": "whole-island faction overlay aligned to Palworld T_WorldMap",
        "runtimePolicy": {
            "mapModes": contract["designPolicy"]["mapModes"],
            "sea": "transparent",
            "unownedIslands": "transparent",
            "neutralUtilityAreas": "transparent",
            "entryPresentationLayer": "Human",
            "nativeFogOrSaveMutation": False,
        },
        "sourceMap": {
            "file": str(SOURCE_MAP.relative_to(ROOT)).replace("\\", "/"),
            "sha256": sha256(SOURCE_MAP),
        },
        "selectorEvidence": selector_evidence,
        "landMask": {"file": land_mask_path.name, "sha256": sha256(land_mask_path), **land_stats},
        "geometry": {**geometry_stats, "islandOrder": [island["id"] for island in islands]},
        "packs": packs,
        "border": {"file": border_path.name, "sha256": sha256(border_path)},
        "reviews": [
            {"layer": "Human", "file": human_review.name, "sha256": sha256(human_review)},
            {"layer": "Pal", "file": pal_review.name, "sha256": sha256(pal_review)},
        ],
    }
    manifest_path = args.output_dir / "island_geometry_manifest.v2.json"
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"WROTE {args.output_dir}")
    print(f"ISLANDS {len(islands)} PACKS {len(packs)}")
    print(f"HUMAN_REVIEW {human_review.name}")
    print(f"PAL_REVIEW {pal_review.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
