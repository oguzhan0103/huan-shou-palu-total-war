"""Build native-asset-derived map textures for the first visible territory UI slice.

The source map and all 22 region masks were extracted from the installed game for
local modding research.  This script does not alter those source files or any
game package: it composites a territory-mode UI texture into a caller-supplied
PMK SourceArt folder.  Ownership comes solely from the frozen v1 contract.
"""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont


ROOT = Path(__file__).resolve().parents[1]
MAP_ASSETS = ROOT / "artifacts" / "map-assets"
ASSIGNMENTS_PATH = ROOT / "contracts" / "territory_assignments.v1.json"
PLANNER_PATH = ROOT / "artifacts" / "palworld-territory-planning-map.html"

CANVAS_SIZE = (1024, 1024)
RELATION_NEUTRAL = (38, 142, 232)
RELATION_NEUTRAL_ALPHA = 112
BORDER = (90, 230, 255, 210)
FRAME = (125, 241, 255, 230)
PANEL = (7, 18, 29, 210)
PANEL_BORDER = (53, 170, 210, 210)
TEXT = (235, 249, 255, 255)
MUTED_TEXT = (155, 204, 220, 255)
TOWER = (255, 198, 64, 255)
SETTLEMENT = (255, 141, 81, 255)
BOSS = (255, 222, 112, 255)


MAIN_REGIONS = {
    "M-A": (66.05, 50.45), "M-B": (76.59, 42.26), "M-C": (84.29, 27.13),
    "M-D": (72.80, 15.03), "M-E": (52.88, 15.18), "M-F": (41.15, 26.08),
    "M-G": (39.19, 50.01), "M-H": (44.22, 42.30), "M-I": (56.50, 54.78),
    "M-J": (53.48, 41.82), "M-K": (48.57, 32.66), "M-L": (60.14, 38.11),
    "M-M": (68.06, 33.35), "M-N": (59.35, 24.96), "M-O": (36.28, 63.53),
    "M-P": (24.09, 59.39), "M-Q": (17.29, 67.59), "M-R": (20.56, 84.59),
    "M-S": (33.35, 75.49), "M-T": (47.48, 78.78),
}

TREE_REGIONS = {"T-A": (66.96, 41.40), "T-B": (28.26, 49.53)}


def font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    candidates = [
        Path("C:/Windows/Fonts/msyhbd.ttc" if bold else "C:/Windows/Fonts/msyh.ttc"),
        Path("C:/Windows/Fonts/simhei.ttf"),
    ]
    for candidate in candidates:
        if candidate.exists():
            return ImageFont.truetype(str(candidate), size=size)
    return ImageFont.load_default()


FONT_TITLE = font(30, bold=True)
FONT_SUBTITLE = font(15)
FONT_LABEL = font(14, bold=True)
FONT_SMALL = font(12)
FONT_TOWER = font(12, bold=True)


def planner_dataset() -> dict:
    text = PLANNER_PATH.read_text(encoding="utf-8")
    match = re.search(r"const dataset = (\{.*?\});\s+const modes", text, re.S)
    if not match:
        raise RuntimeError("Could not locate planner dataset")
    return json.loads(match.group(1))


def load_contracts() -> dict[str, dict]:
    document = json.loads(ASSIGNMENTS_PATH.read_text(encoding="utf-8"))
    return {entry["regionId"]: entry for entry in document["assignments"]}


def alpha_mask(path: Path) -> Image.Image:
    source = Image.open(path).convert("RGBA").resize(CANVAS_SIZE, Image.Resampling.LANCZOS)
    return source.getchannel("A")


def rounded_panel(draw: ImageDraw.ImageDraw, box: tuple[int, int, int, int], radius: int = 8) -> None:
    draw.rounded_rectangle(box, radius=radius, fill=PANEL, outline=PANEL_BORDER, width=1)


def centered_label(draw: ImageDraw.ImageDraw, center: tuple[int, int], text: str, fill: tuple[int, int, int, int] = TEXT) -> None:
    bbox = draw.multiline_textbbox((0, 0), text, font=FONT_LABEL, align="center", spacing=1)
    width = bbox[2] - bbox[0]
    height = bbox[3] - bbox[1]
    x = int(center[0] - width / 2)
    y = int(center[1] - height / 2)
    pad_x, pad_y = 5, 3
    draw.rounded_rectangle((x - pad_x, y - pad_y, x + width + pad_x, y + height + pad_y), radius=5, fill=(3, 15, 24, 190), outline=(70, 210, 240, 160), width=1)
    draw.multiline_text((x, y), text, font=FONT_LABEL, fill=fill, align="center", spacing=1)


def marker(draw: ImageDraw.ImageDraw, x: float, y: float, text: str, color: tuple[int, int, int, int], square: bool = False) -> tuple[int, int]:
    px, py = int(x * CANVAS_SIZE[0] / 100), int(y * CANVAS_SIZE[1] / 100)
    radius = 8
    if square:
        draw.rounded_rectangle((px - radius, py - radius, px + radius, py + radius), radius=3, fill=color, outline=(8, 20, 28, 255), width=2)
    else:
        draw.ellipse((px - radius, py - radius, px + radius, py + radius), fill=color, outline=(8, 20, 28, 255), width=2)
    bbox = draw.textbbox((0, 0), text, font=FONT_TOWER)
    draw.text((px - (bbox[2] - bbox[0]) / 2, py - (bbox[3] - bbox[1]) / 2 - 1), text, font=FONT_TOWER, fill=(7, 18, 27, 255))
    return px, py


def decorate_frame(draw: ImageDraw.ImageDraw, title: str, subtitle: str) -> None:
    draw.rectangle((12, 12, 1012, 1012), outline=FRAME, width=2)
    for x, y, sx, sy in ((12, 12, 1, 1), (1012, 12, -1, 1), (12, 1012, 1, -1), (1012, 1012, -1, -1)):
        draw.line((x, y, x + sx * 32, y), fill=FRAME, width=5)
        draw.line((x, y, x, y + sy * 32), fill=FRAME, width=5)
    rounded_panel(draw, (32, 30, 574, 103), radius=10)
    draw.text((50, 42), title, font=FONT_TITLE, fill=TEXT)
    draw.text((51, 77), subtitle, font=FONT_SUBTITLE, fill=MUTED_TEXT)
    rounded_panel(draw, (708, 34, 992, 102), radius=10)
    draw.text((724, 45), "关系颜色", font=FONT_SMALL, fill=MUTED_TEXT)
    for x, color, label in ((724, (68, 196, 114), "友好"), (804, RELATION_NEUTRAL, "中立"), (884, (236, 79, 79), "敌对")):
        draw.ellipse((x, 70, x + 12, 82), fill=color)
        draw.text((x + 17, 67), label, font=FONT_SMALL, fill=TEXT)


def make_territory_map(base_path: Path, masks: list[tuple[str, Path]], label_positions: dict[str, tuple[float, float]], assignments: dict[str, dict], title: str, subtitle: str, out_path: Path, dataset: dict, is_tree: bool = False) -> None:
    base = Image.open(base_path).convert("RGBA").resize(CANVAS_SIZE, Image.Resampling.LANCZOS)
    dim = Image.new("RGBA", CANVAS_SIZE, (0, 9, 18, 58))
    canvas = Image.alpha_composite(base, dim)

    for _, path in masks:
        mask = alpha_mask(path)
        fill_alpha = mask.point(lambda value: int(value * RELATION_NEUTRAL_ALPHA / 255))
        fill = Image.new("RGBA", CANVAS_SIZE, (*RELATION_NEUTRAL, 0))
        fill.putalpha(fill_alpha)
        canvas = Image.alpha_composite(canvas, fill)

        outer = mask.filter(ImageFilter.MaxFilter(5))
        inner = mask.filter(ImageFilter.MinFilter(3))
        edge = ImageChops.subtract(outer, inner).point(lambda value: min(220, value * 2))
        border = Image.new("RGBA", CANVAS_SIZE, BORDER)
        border.putalpha(edge)
        canvas = Image.alpha_composite(canvas, border)

    draw = ImageDraw.Draw(canvas, "RGBA")
    decorate_frame(draw, title, subtitle)

    for region_id, (x, y) in label_positions.items():
        assignment = assignments[region_id]
        short_name = assignment["ownerShortNameZhHans"]
        if region_id == "M-I":
            short_name = "暗属部落\n昼·安全"
        elif short_name == "中立区":
            short_name = "中立（暂定）"
        line = f"{region_id}\n{short_name}"
        centered_label(draw, (int(x * 1024 / 100), int(y * 1024 / 100)), line)

    if not is_tree:
        tower_offsets = {
            "T1": (0, 0), "T2": (0, 0), "T3": (0, 0), "T4": (0, 0), "T5": (0, 0),
            "T6": (0, 0), "T7": (0, 0), "T8": (0, 0),
        }
        for tower in dataset["towers"]:
            if tower.get("mapId") != "main":
                continue
            px, py = marker(draw, tower["x"], tower["y"], tower["id"][1:], TOWER)
            offset = tower_offsets.get(tower["id"], (0, 0))
            draw.text((px + 12 + offset[0], py - 8 + offset[1]), tower["leader"], font=FONT_SMALL, fill=TEXT, stroke_width=2, stroke_fill=(6, 17, 24, 230))

        for settlement in dataset["settlements"]:
            px, py = marker(draw, settlement["x"], settlement["y"], "城", SETTLEMENT, square=True)
            draw.text((px + 12, py + 8), settlement["zh"], font=FONT_SMALL, fill=TEXT, stroke_width=2, stroke_fill=(6, 17, 24, 230))

        for region_id, assignment in assignments.items():
            boss = assignment.get("regionalBoss")
            if boss:
                x, y = boss.get("plannedMapX"), boss.get("plannedMapY")
                if x is not None and y is not None:
                    px, py = marker(draw, x, y, "首", BOSS)
                    draw.text((px + 12, py - 8), boss["displayNameZhHans"], font=FONT_SMALL, fill=(255, 239, 163, 255), stroke_width=2, stroke_fill=(6, 17, 24, 230))

        group = dataset.get("assignments", [])
        _ = group  # kept to make the planner dataset an explicit input to the render.
        rounded_panel(draw, (32, 908, 992, 990), radius=10)
        draw.text((52, 922), "势力版图模式 · 原始地图未替换", font=FONT_LABEL, fill=TEXT)
        draw.text((52, 951), "图层依据 22 个原生瞭望塔解锁遮罩；当前所有势力按中立关系显示为蓝色。", font=FONT_SUBTITLE, fill=MUTED_TEXT)
        draw.text((634, 922), "○ 塔主   ■ 城镇   ● 区域首领", font=FONT_SUBTITLE, fill=MUTED_TEXT)
    else:
        rounded_panel(draw, (32, 914, 992, 990), radius=10)
        draw.text((52, 928), "世界树地区暂定中立 · 未来由玩家推进后再划分", font=FONT_LABEL, fill=TEXT)
        draw.text((52, 957), "保留原始世界树地图；本版只显示原生两块解锁区域边界。", font=FONT_SUBTITLE, fill=MUTED_TEXT)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    canvas.convert("RGBA").save(out_path, "PNG", optimize=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dest", type=Path, required=True, help="PMK SourceArt output folder")
    args = parser.parse_args()

    assignments = load_contracts()
    dataset = planner_dataset()

    main_masks = [(region_id, MAP_ASSETS / "masks" / f"{assignments[region_id]['nativeMaskAsset']}.png") for region_id in MAIN_REGIONS]
    tree_masks = [
        ("T-A", MAP_ASSETS / "native-tree-mask-a.png"),
        ("T-B", MAP_ASSETS / "native-tree-mask-b.png"),
    ]

    make_territory_map(
        MAP_ASSETS / "native-world-map.jpg",
        main_masks,
        MAIN_REGIONS,
        assignments,
        "势力版图 · 主世界",
        "22 个原生瞭望塔区域｜原图独立保留｜蓝色：当前中立",
        args.dest / "PFT_Main_Territory_Neutral.png",
        dataset,
    )
    make_territory_map(
        MAP_ASSETS / "native-tree-map.jpg",
        tree_masks,
        TREE_REGIONS,
        assignments,
        "势力版图 · 世界树",
        "两块原生区域｜暂定中立｜后续由玩家推进后再划分",
        args.dest / "PFT_Tree_Territory_Neutral.png",
        dataset,
        is_tree=True,
    )

    # Original-mode copies are intentionally unmodified references to the extracted native maps.
    Image.open(MAP_ASSETS / "native-world-map.jpg").convert("RGBA").resize(CANVAS_SIZE, Image.Resampling.LANCZOS).save(args.dest / "PFT_Main_Original.png", "PNG", optimize=True)
    Image.open(MAP_ASSETS / "native-tree-map.jpg").convert("RGBA").resize(CANVAS_SIZE, Image.Resampling.LANCZOS).save(args.dest / "PFT_Tree_Original.png", "PNG", optimize=True)

    print(f"Generated territory UI textures in {args.dest}")


if __name__ == "__main__":
    main()
