"""Pack Palworld's native region masks into five RGBA data textures.

This creates only transparent overlay data.  It never copies terrain, map
labels, icons, player data, or any save file.  Each source channel comes from
the alpha channel of a shipped ``T_MapMask_*`` asset, preserving Palworld's
own region contours exactly.

The source directory must contain the *extracted* .uexp files.  Extract just
those files from Pal-Windows.pak with UnrealPak before running this tool:

  UnrealPak Pal-Windows.pak -Extract <dir>
    -Filter=Pal/Content/Pal/Texture/UI/UnlockMapAreaMask/T_MapMask_*.uexp
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

from PIL import Image


WIDTH = 256
HEIGHT = 256
PIXEL_BYTES = WIDTH * HEIGHT * 4

# The ordering is deliberately identical to runtime.lua MAIN_REGION_IDS.
# T_MapMask_g/h do not exist in the game package; i/v are the actual next
# native assets in the main-world unlock-mask series.
PACKS = (
    ("T_MapMask_a", "T_MapMask_b", "T_MapMask_c", "T_MapMask_d"),
    ("T_MapMask_e", "T_MapMask_f", "T_MapMask_i", "T_MapMask_j"),
    ("T_MapMask_k", "T_MapMask_l", "T_MapMask_m", "T_MapMask_n"),
    ("T_MapMask_o", "T_MapMask_p", "T_MapMask_q", "T_MapMask_r"),
    ("T_MapMask_s", "T_MapMask_t", "T_MapMask_u", "T_MapMask_v"),
)


def read_native_alpha(path: Path) -> Image.Image:
    payload = path.read_bytes()
    if len(payload) < PIXEL_BYTES:
        raise ValueError(f"{path} is too short for a {WIDTH}x{HEIGHT} BGRA mip")
    # UnrealPak has already decompressed the stored Oodle block.  The last
    # mip is a directly addressable 256x256 PF_B8G8R8A8 image.
    texture = Image.frombytes("RGBA", (WIDTH, HEIGHT), payload[-PIXEL_BYTES:], "raw", "BGRA")
    return texture.getchannel("A")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()

    args.output_dir.mkdir(parents=True, exist_ok=True)
    manifest: dict[str, object] = {
        "schemaVersion": "1.0.0",
        "purpose": "native Palworld region-mask channel packs; no terrain or map art",
        "resolution": [WIDTH, HEIGHT],
        "packs": [],
    }

    for pack_index, asset_names in enumerate(PACKS, start=1):
        channels = []
        source_entries = []
        for channel_name, asset_name in zip(("R", "G", "B", "A"), asset_names):
            source = args.source_dir / f"{asset_name}.uexp"
            alpha = read_native_alpha(source)
            channels.append(alpha)
            source_entries.append(
                {
                    "channel": channel_name,
                    "asset": asset_name,
                    "uexpSha256": hashlib.sha256(source.read_bytes()).hexdigest(),
                }
            )

        output = args.output_dir / f"T_PFT_NativeMaskPack_{pack_index:02d}.png"
        Image.merge("RGBA", tuple(channels)).save(output)
        manifest["packs"].append(
            {
                "name": output.stem,
                "sha256": hashlib.sha256(output.read_bytes()).hexdigest(),
                "sources": source_entries,
            }
        )
        print(f"PACKED {output}")

    manifest_path = args.output_dir / "native_mask_pack_manifest.json"
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"MANIFEST {manifest_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
