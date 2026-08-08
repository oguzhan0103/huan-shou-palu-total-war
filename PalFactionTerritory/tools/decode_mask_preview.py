from __future__ import annotations

import argparse
import struct
import zlib
from pathlib import Path


WIDTH = 256
HEIGHT = 256
PIXEL_OFFSET = 0x83
PIXEL_FORMAT = b"PF_B8G8R8A8\x00"
PACKAGE_MAGIC = b"\xC1\x83\x2A\x9E"


def png_chunk(kind: bytes, payload: bytes) -> bytes:
    return (
        struct.pack(">I", len(payload))
        + kind
        + payload
        + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)
    )


def decode(source: Path, destination: Path) -> None:
    package = source.read_bytes()
    pixel_count = WIDTH * HEIGHT
    pixel_bytes = pixel_count * 4
    end = PIXEL_OFFSET + pixel_bytes

    if PIXEL_FORMAT not in package[:PIXEL_OFFSET]:
        raise ValueError("unsupported texture pixel format")
    if package[-4:] != PACKAGE_MAGIC:
        raise ValueError("unexpected Unreal package footer")
    if end > len(package) - 4:
        raise ValueError("texture payload is shorter than the expected BGRA mip")

    bgra = package[PIXEL_OFFSET:end]
    rgba = bytearray(pixel_bytes)
    for offset in range(0, pixel_bytes, 4):
        blue, green, red, alpha = bgra[offset : offset + 4]
        rgba[offset : offset + 4] = bytes((red, green, blue, alpha))

    rows = bytearray()
    stride = WIDTH * 4
    for row in range(HEIGHT):
        rows.append(0)
        start = row * stride
        rows.extend(rgba[start : start + stride])

    png = bytearray(b"\x89PNG\r\n\x1a\n")
    png.extend(
        png_chunk(
            b"IHDR",
            struct.pack(">IIBBBBB", WIDTH, HEIGHT, 8, 6, 0, 0, 0),
        )
    )
    png.extend(png_chunk(b"IDAT", zlib.compress(bytes(rows), level=9)))
    png.extend(png_chunk(b"IEND", b""))
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(png)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    decode(args.source, args.destination)
    print(args.destination)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
