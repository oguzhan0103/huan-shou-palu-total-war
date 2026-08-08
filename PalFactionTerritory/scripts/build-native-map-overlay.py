#!/usr/bin/env python3
"""Extract a transparent territory-only layer from prior PFT source art.

The generated image intentionally contains no base-map pixels, labels, title,
or legend.  It is meant to replace only Palworld's existing Image_MapMask
brush, so the game continues to draw the map art, icons, pan and zoom itself.
"""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image


DEFAULT_SOURCE_ROOT = Path(r"E:\mod\PalworldModdingKit\Content\Mods\PalFactionTerritory0\SourceArt")


def is_ui_chrome(x: int, y: int, width: int, height: int) -> bool:
    """Exclude only the prior standalone widget's title/legend/footer boxes."""
    return (
        (24 <= x <= width - 25 and 28 <= y <= 108)
        or (30 <= x <= width - 31 and height - 118 <= y <= height - 25)
    )


def make_overlay(original: Image.Image, neutral: Image.Image) -> Image.Image:
    if original.size != neutral.size:
        raise ValueError(f"source dimensions differ: {original.size} vs {neutral.size}")

    base = original.convert("RGBA")
    territory = neutral.convert("RGBA")
    result = Image.new("RGBA", base.size, (0, 0, 0, 0))

    base_pixels = base.load()
    territory_pixels = territory.load()
    output_pixels = result.load()
    width, height = base.size

    for y in range(height):
        for x in range(width):
            if is_ui_chrome(x, y, width, height):
                continue

            br, bg, bb, ba = base_pixels[x, y]
            tr, tg, tb, ta = territory_pixels[x, y]
            if ba == 0 or ta == 0:
                continue

            delta = max(abs(tr - br), abs(tg - bg), abs(tb - bb))
            # Neon cyan is the prior overlay's boundary color.  Preserve it
            # as a line, but reject white labels and yellow tower markers.
            is_cyan_boundary = tg > 135 and tb > 165 and tr < 120 and tb - tr > 80
            # The neutral territory fills are blue-shifted from the base map.
            # A low alpha keeps the original Palworld art legible beneath it.
            is_blue_fill = delta >= 12 and tb > tr + 14 and tb > 60

            if is_cyan_boundary:
                alpha = min(218, max(132, delta * 2))
                output_pixels[x, y] = (67, 222, 242, alpha)
            elif is_blue_fill:
                alpha = min(72, max(16, delta * 2))
                output_pixels[x, y] = (49, 143, 232, alpha)

    return result


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--original",
        type=Path,
        default=DEFAULT_SOURCE_ROOT / "PFT_Main_Original.png",
        help="Original-map source image.",
    )
    parser.add_argument(
        "--territory",
        type=Path,
        default=DEFAULT_SOURCE_ROOT / "PFT_Main_Territory_Neutral.png",
        help="Prior neutral-territory source image.",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=DEFAULT_SOURCE_ROOT / "PFT_Main_Territory_Overlay.png",
        help="Transparent territory-only output PNG.",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    output = make_overlay(Image.open(args.original), Image.open(args.territory))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    output.save(args.output)
    alpha_count = sum(1 for _, _, _, alpha in output.getdata() if alpha > 0)
    print(f"WROTE {args.output} size={output.size[0]}x{output.size[1]} visiblePixels={alpha_count}")


if __name__ == "__main__":
    main()
