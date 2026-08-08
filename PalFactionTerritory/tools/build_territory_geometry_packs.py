"""Build a clean, Mod-owned territory geometry baseline from the recovered v1 plan.

The game supplied ``T_MapMask_*`` textures are exploration/reveal masks.  They
have soft, overlapping alpha edges, which is useful for fog but makes a poor
political map.  This tool uses them only as the recovered 2026-07-21 planning
reference, resolves their overlaps deterministically, and writes a new set of
hard-edged territory stencil packs.  The generated packs contain no terrain,
map labels, icons, fog state, player data, or save data.

It deliberately writes to the project artifacts directory, not to the game or
PMK source-art folders.  Importing these packs into the cooked UI material is a
separate, reviewable step.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from collections import Counter
from pathlib import Path
from typing import Final

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont


ROOT: Final = Path(__file__).resolve().parents[1]
ASSIGNMENTS_PATH: Final = ROOT / "contracts" / "territory_assignments.v1.json"
SOURCE_MASK_DIR: Final = ROOT / "artifacts" / "map-assets" / "masks"
SOURCE_MAP: Final = ROOT / "artifacts" / "map-assets" / "native-world-map.jpg"

# This order is deliberately the same as runtime.lua MAIN_REGION_IDS and the
# 20 Color_01...Color_20 material parameters.
MAIN_REGION_IDS: Final = tuple(f"M-{letter}" for letter in "ABCDEFGHIJKLMNOPQRST")
CHANNEL_NAMES: Final = ("R", "G", "B", "A")
PACK_SIZE: Final = (256, 256)
PREVIEW_SIZE: Final = (1024, 1024)
LABEL_POSITIONS: Final = {
    "M-A": (66.05, 50.45), "M-B": (76.59, 42.26), "M-C": (84.29, 27.13),
    "M-D": (72.80, 15.03), "M-E": (52.88, 15.18), "M-F": (41.15, 26.08),
    "M-G": (39.19, 50.01), "M-H": (44.22, 42.30), "M-I": (56.50, 54.78),
    "M-J": (53.48, 41.82), "M-K": (48.57, 32.66), "M-L": (60.14, 38.11),
    "M-M": (68.06, 33.35), "M-N": (59.35, 24.96), "M-O": (36.28, 63.53),
    "M-P": (24.09, 59.39), "M-Q": (17.29, 67.59), "M-R": (20.56, 84.59),
    "M-S": (33.35, 75.49), "M-T": (47.48, 78.78),
}


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


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_assignments() -> dict[str, dict]:
    document = json.loads(ASSIGNMENTS_PATH.read_text(encoding="utf-8"))
    assignments = {item["regionId"]: item for item in document["assignments"]}
    missing = [region_id for region_id in MAIN_REGION_IDS if region_id not in assignments]
    if missing:
        raise RuntimeError(f"Missing main-world assignments: {missing}")
    return assignments


def load_source_alphas(assignments: dict[str, dict]) -> tuple[list[Image.Image], list[dict]]:
    channels: list[Image.Image] = []
    evidence: list[dict] = []
    for region_id in MAIN_REGION_IDS:
        asset_name = assignments[region_id]["nativeMaskAsset"]
        source = SOURCE_MASK_DIR / f"{asset_name}.png"
        if not source.exists():
            raise RuntimeError(f"Recovered mask source is missing: {source}")
        alpha = Image.open(source).convert("RGBA").getchannel("A")
        if alpha.size != PACK_SIZE:
            raise RuntimeError(f"Expected {PACK_SIZE} for {source}, got {alpha.size}")
        channels.append(alpha)
        evidence.append({
            "regionId": region_id,
            "nativeMaskAsset": asset_name,
            "source": str(source.relative_to(ROOT)).replace("\\", "/"),
            "sha256": sha256(source),
        })
    return channels, evidence


def resolve_exclusive_geometry(source_channels: list[Image.Image], threshold: int, border_gap: int) -> tuple[list[Image.Image], Image.Image, dict]:
    """Choose one owner per pixel, then reserve a transparent border gap.

    Selecting the strongest source alpha is deterministic, keeps the recovered
    visual boundary reference, and removes the semi-transparent multi-owner
    areas which make the fog-derived implementation look muddy.
    """
    width, height = PACK_SIZE
    source_pixels = [list(channel.get_flattened_data()) for channel in source_channels]
    winners: list[int | None] = []
    overlap_count = 0
    for pixel_index in range(width * height):
        candidates = [index for index, pixels in enumerate(source_pixels) if pixels[pixel_index] >= threshold]
        if len(candidates) > 1:
            overlap_count += 1
        if not candidates:
            winners.append(None)
            continue
        # tuple ordering makes the earlier Color_XX channel the stable tiebreak.
        winners.append(max(candidates, key=lambda index: (source_pixels[index][pixel_index], -index)))

    final_winners = winners[:]
    if border_gap > 0:
        for y in range(height):
            for x in range(width):
                pixel_index = y * width + x
                owner = winners[pixel_index]
                if owner is None:
                    continue
                for dy in range(-border_gap, border_gap + 1):
                    for dx in range(-border_gap, border_gap + 1):
                        if dx == 0 and dy == 0:
                            continue
                        nx, ny = x + dx, y + dy
                        if nx < 0 or nx >= width or ny < 0 or ny >= height:
                            final_winners[pixel_index] = None
                            break
                        if winners[ny * width + nx] != owner:
                            final_winners[pixel_index] = None
                            break
                    if final_winners[pixel_index] is None:
                        break

    output_channels: list[Image.Image] = []
    final_counts: Counter[int] = Counter(index for index in final_winners if index is not None)
    for region_index in range(len(MAIN_REGION_IDS)):
        alpha = Image.new("L", PACK_SIZE, 0)
        alpha.putdata([255 if owner == region_index else 0 for owner in final_winners])
        output_channels.append(alpha)

    union = Image.new("L", PACK_SIZE, 0)
    union.putdata([255 if owner is not None else 0 for owner in final_winners])
    # The transparent one-pixel political gaps remain part of the outline, so
    # this produces both the outside contour and clean internal borders.
    expanded = union.filter(ImageFilter.MaxFilter(3))
    contracted = union.filter(ImageFilter.MinFilter(3))
    edge = ImageChops.subtract(expanded, contracted).point(lambda value: 255 if value else 0)

    stats = {
        "sourcePixelsAtOrAboveThreshold": sum(
            1 for pixel_index in range(width * height)
            if any(pixels[pixel_index] >= threshold for pixels in source_pixels)
        ),
        "sourceOverlapPixelsAtOrAboveThreshold": overlap_count,
        "exclusivePixelsBeforeBorderGap": sum(owner is not None for owner in winners),
        "exclusivePixelsAfterBorderGap": sum(owner is not None for owner in final_winners),
        "regionPixelsAfterBorderGap": {
            MAIN_REGION_IDS[index]: final_counts[index] for index in range(len(MAIN_REGION_IDS))
        },
    }
    return output_channels, edge, stats


def write_packs(output_dir: Path, channels: list[Image.Image]) -> list[dict]:
    pack_manifest: list[dict] = []
    for pack_number, start in enumerate(range(0, len(channels), 4), start=1):
        pack = Image.merge("RGBA", tuple(channels[start:start + 4]))
        output = output_dir / f"T_PFT_TerritoryGeometryPack_{pack_number:02d}.png"
        pack.save(output, optimize=True)
        region_ids = list(MAIN_REGION_IDS[start:start + 4])
        pack_manifest.append({
            "file": output.name,
            "sha256": sha256(output),
            "channels": {channel: region_id for channel, region_id in zip(CHANNEL_NAMES, region_ids)},
        })
    return pack_manifest


def draw_label(draw: ImageDraw.ImageDraw, x: int, y: int, text: str) -> None:
    bbox = draw.multiline_textbbox((0, 0), text, font=FONT_LABEL, align="center", spacing=1)
    width, height = bbox[2] - bbox[0], bbox[3] - bbox[1]
    left, top = x - width // 2 - 5, y - height // 2 - 3
    draw.rounded_rectangle((left, top, left + width + 10, top + height + 6), radius=5, fill=(3, 17, 28, 210), outline=(80, 229, 245, 210), width=1)
    draw.multiline_text((x - width // 2, y - height // 2), text, font=FONT_LABEL, fill=(227, 249, 255, 255), align="center", spacing=1)


def write_review_preview(output_dir: Path, channels: list[Image.Image], edge: Image.Image, assignments: dict[str, dict]) -> Path:
    base = Image.open(SOURCE_MAP).convert("RGBA").resize(PREVIEW_SIZE, Image.Resampling.LANCZOS)
    combined = Image.new("L", PACK_SIZE, 0)
    for channel in channels:
        combined = ImageChops.lighter(combined, channel)
    # The actual UI sampler filters these 256px data packs.  Use the same kind
    # of resampling in the review preview so it shows a boundary, not enlarged
    # data-texture pixels.
    fill_alpha = combined.resize(PREVIEW_SIZE, Image.Resampling.LANCZOS).point(lambda value: 43 if value >= 128 else 0)
    fill = Image.new("RGBA", PREVIEW_SIZE, (35, 135, 190, 0))
    fill.putalpha(fill_alpha)
    preview = Image.alpha_composite(base, fill)

    edge_alpha = edge.resize(PREVIEW_SIZE, Image.Resampling.LANCZOS).point(lambda value: 205 if value >= 96 else 0)
    border = Image.new("RGBA", PREVIEW_SIZE, (74, 233, 248, 0))
    border.putalpha(edge_alpha)
    preview = Image.alpha_composite(preview, border)

    draw = ImageDraw.Draw(preview, "RGBA")
    draw.rounded_rectangle((24, 24, 690, 104), radius=10, fill=(4, 17, 29, 218), outline=(78, 230, 246, 220), width=2)
    draw.text((44, 38), "势力领地分区 · 找回基线", font=FONT_TITLE, fill=(238, 250, 255, 255))
    draw.text((45, 74), "用户确认的 v1 归属；青线为独立政治边界，不是游戏迷雾。", font=FONT_SUBTITLE, fill=(170, 218, 232, 255))
    draw.rounded_rectangle((712, 28, 998, 104), radius=10, fill=(4, 17, 29, 218), outline=(78, 230, 246, 220), width=2)
    draw.text((732, 42), "审阅图说明", font=FONT_SUBTITLE, fill=(170, 218, 232, 255))
    draw.text((732, 68), "实际游戏仍只用红 / 绿 / 蓝关系色", font=FONT_SUBTITLE, fill=(238, 250, 255, 255))

    for region_id, (x_percent, y_percent) in LABEL_POSITIONS.items():
        entry = assignments[region_id]
        label = f"{region_id}\n{entry['ownerShortNameZhHans']}"
        draw_label(draw, round(x_percent * PREVIEW_SIZE[0] / 100), round(y_percent * PREVIEW_SIZE[1] / 100), label)

    output = output_dir / "territory_partition_review.png"
    preview.save(output, optimize=True)
    return output


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, default=ROOT / "artifacts" / "recovered-territory-geometry-v1")
    parser.add_argument("--threshold", type=int, default=128, choices=range(1, 256), metavar="1..255")
    parser.add_argument("--border-gap", type=int, default=1, choices=range(0, 4), metavar="0..3")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    assignments = load_assignments()
    source_channels, source_evidence = load_source_alphas(assignments)
    channels, edge, stats = resolve_exclusive_geometry(source_channels, args.threshold, args.border_gap)

    args.output_dir.mkdir(parents=True, exist_ok=True)
    packs = write_packs(args.output_dir, channels)
    border_path = args.output_dir / "T_PFT_TerritoryGeometryBorder.png"
    # Save normally so the generated image remains standard PNG source art.
    Image.merge("RGBA", (edge, edge, edge, edge)).save(border_path, optimize=True)
    preview_path = write_review_preview(args.output_dir, channels, edge, assignments)

    manifest = {
        "schemaVersion": "1.0.0",
        "baselineId": "pwft.territory_partition.v1",
        "baselineStatus": "user_approved_frozen_baseline",
        "purpose": "Mod-owned political territory geometry; separate from Palworld exploration fog",
        "generation": {
            "source": "recovered 2026-07-21 native-mask planning reference",
            "threshold": args.threshold,
            "borderGapPixels": args.border_gap,
            "overlapRule": "highest source alpha; Color_01..Color_20 order breaks ties",
            "mapRuntimePolicy": "bind only to the existing Image_MapMask transform; never alter Image_MapBody or RT_WorldMapMask",
            "deploymentStatus": "artifact_only_not_imported_or_deployed",
        },
        "sources": source_evidence,
        "packs": packs,
        "border": {"file": border_path.name, "sha256": sha256(border_path)},
        "reviewPreview": {"file": preview_path.name, "sha256": sha256(preview_path)},
        "stats": stats,
        "knownManualBorderExceptions": [
            "M-N / M-E: user baseline requires the snow-mountain tower to be included in M-N during final border drawing.",
            "M-C / M-D: the desert-town political enclave belongs to M-C while its native reveal mask lies in M-D.",
        ],
    }
    manifest_path = args.output_dir / "territory_geometry_manifest.v1.json"
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"WROTE {args.output_dir}")
    print(f"PACKS {len(packs)} PREVIEW {preview_path.name} MANIFEST {manifest_path.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
