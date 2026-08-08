from __future__ import annotations

import argparse
import subprocess
from pathlib import Path, PurePosixPath


DEFAULT_REPAK = (
    Path(__file__).resolve().parents[2]
    / "1.0文本资料库"
    / "_tools"
    / "repak-v0.2.3"
    / "repak.exe"
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Read selected files from an Unreal .pak without unpacking it."
    )
    parser.add_argument("pak", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("entries", nargs="+")
    parser.add_argument("--repak", type=Path, default=DEFAULT_REPAK)
    return parser.parse_args()


def validated_relative_entry(value: str) -> PurePosixPath:
    entry = PurePosixPath(value.replace("\\", "/"))
    if entry.is_absolute() or ".." in entry.parts or not entry.parts:
        raise ValueError(f"unsafe pak entry path: {value}")
    return entry


def main() -> int:
    args = parse_args()
    pak = args.pak.resolve(strict=True)
    repak = args.repak.resolve(strict=True)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)

    for raw_entry in args.entries:
        entry = validated_relative_entry(raw_entry)
        destination = output.joinpath(*entry.parts)
        destination.parent.mkdir(parents=True, exist_ok=True)
        completed = subprocess.run(
            [str(repak), "get", str(pak), entry.as_posix()],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if not completed.stdout:
            raise RuntimeError(f"empty pak entry: {entry.as_posix()}")
        destination.write_bytes(completed.stdout)
        print(f"EXTRACTED {entry.as_posix()} ({destination.stat().st_size} bytes)")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
