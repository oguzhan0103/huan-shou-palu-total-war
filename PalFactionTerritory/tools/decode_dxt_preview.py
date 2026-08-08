from __future__ import annotations

import argparse
import struct
import zlib
from pathlib import Path


PACKAGE_MAGIC = b"\xC1\x83\x2A\x9E"
PACKAGE_TRAILER_BYTES = 28


def rgb565(value: int) -> tuple[int, int, int]:
    red = ((value >> 11) & 0x1F) * 255 // 31
    green = ((value >> 5) & 0x3F) * 255 // 63
    blue = (value & 0x1F) * 255 // 31
    return red, green, blue


def mix(a: tuple[int, int, int], b: tuple[int, int, int], wa: int, wb: int) -> tuple[int, int, int]:
    divisor = wa + wb
    return tuple((a[index] * wa + b[index] * wb) // divisor for index in range(3))


def color_palette(block: bytes, dxt1: bool) -> tuple[tuple[int, int, int, int], ...]:
    color0, color1 = struct.unpack_from("<HH", block)
    first = rgb565(color0)
    second = rgb565(color1)
    if dxt1 and color0 <= color1:
        return (
            (*first, 255),
            (*second, 255),
            (*mix(first, second, 1, 1), 255),
            (0, 0, 0, 0),
        )
    return (
        (*first, 255),
        (*second, 255),
        (*mix(first, second, 2, 1), 255),
        (*mix(first, second, 1, 2), 255),
    )


def alpha_palette(alpha0: int, alpha1: int) -> tuple[int, ...]:
    if alpha0 > alpha1:
        return (
            alpha0,
            alpha1,
            (6 * alpha0 + alpha1) // 7,
            (5 * alpha0 + 2 * alpha1) // 7,
            (4 * alpha0 + 3 * alpha1) // 7,
            (3 * alpha0 + 4 * alpha1) // 7,
            (2 * alpha0 + 5 * alpha1) // 7,
            (alpha0 + 6 * alpha1) // 7,
        )
    return (
        alpha0,
        alpha1,
        (4 * alpha0 + alpha1) // 5,
        (3 * alpha0 + 2 * alpha1) // 5,
        (2 * alpha0 + 3 * alpha1) // 5,
        (alpha0 + 4 * alpha1) // 5,
        0,
        255,
    )


def decode_dxt1_pixel(block: bytes, x: int, y: int) -> tuple[int, int, int, int]:
    palette = color_palette(block[:4], dxt1=True)
    indices = int.from_bytes(block[4:8], "little")
    return palette[(indices >> (2 * (y * 4 + x))) & 0x03]


def decode_dxt5_pixel(block: bytes, x: int, y: int) -> tuple[int, int, int, int]:
    pixel_index = y * 4 + x
    alphas = alpha_palette(block[0], block[1])
    alpha_indices = int.from_bytes(block[2:8], "little")
    alpha = alphas[(alpha_indices >> (3 * pixel_index)) & 0x07]
    colors = color_palette(block[8:12], dxt1=False)
    color_indices = int.from_bytes(block[12:16], "little")
    red, green, blue, _ = colors[(color_indices >> (2 * pixel_index)) & 0x03]
    return red, green, blue, alpha


def png_chunk(kind: bytes, payload: bytes) -> bytes:
    return (
        struct.pack(">I", len(payload))
        + kind
        + payload
        + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)
    )


def write_png(path: Path, width: int, height: int, rgba: bytes) -> None:
    rows = bytearray()
    stride = width * 4
    for row in range(height):
        rows.append(0)
        start = row * stride
        rows.extend(rgba[start : start + stride])
    payload = bytearray(b"\x89PNG\r\n\x1a\n")
    payload.extend(
        png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
    )
    payload.extend(png_chunk(b"IDAT", zlib.compress(bytes(rows), level=9)))
    payload.extend(png_chunk(b"IEND", b""))
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(payload)


def decode(
    source: Path,
    destination: Path,
    width: int,
    height: int,
    pixel_format: str,
    output_width: int,
) -> None:
    package = source.read_bytes()
    if package[-4:] != PACKAGE_MAGIC:
        raise ValueError("unexpected Unreal package footer")
    block_bytes = 8 if pixel_format == "DXT1" else 16
    compressed_bytes = (width // 4) * (height // 4) * block_bytes
    payload_offset = len(package) - PACKAGE_TRAILER_BYTES - compressed_bytes
    if not 64 <= payload_offset <= 256:
        raise ValueError(f"unexpected texture payload offset: {payload_offset}")
    payload = package[payload_offset : payload_offset + compressed_bytes]

    output_height = max(1, round(height * output_width / width))
    rgba = bytearray(output_width * output_height * 4)
    blocks_per_row = width // 4
    decoder = decode_dxt1_pixel if pixel_format == "DXT1" else decode_dxt5_pixel

    for out_y in range(output_height):
        source_y = min(height - 1, ((out_y * 2 + 1) * height) // (output_height * 2))
        block_y, pixel_y = divmod(source_y, 4)
        for out_x in range(output_width):
            source_x = min(width - 1, ((out_x * 2 + 1) * width) // (output_width * 2))
            block_x, pixel_x = divmod(source_x, 4)
            offset = (block_y * blocks_per_row + block_x) * block_bytes
            pixel = decoder(payload[offset : offset + block_bytes], pixel_x, pixel_y)
            target = (out_y * output_width + out_x) * 4
            rgba[target : target + 4] = bytes(pixel)

    write_png(destination, output_width, output_height, bytes(rgba))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--width", type=int, required=True)
    parser.add_argument("--height", type=int, required=True)
    parser.add_argument("--format", choices=("DXT1", "DXT5"), required=True)
    parser.add_argument("--output-width", type=int, required=True)
    args = parser.parse_args()
    decode(
        args.source,
        args.destination,
        args.width,
        args.height,
        args.format,
        args.output_width,
    )
    print(args.destination)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
