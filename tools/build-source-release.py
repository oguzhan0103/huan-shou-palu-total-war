#!/usr/bin/env python3
"""Build deterministic, source-only Palworld Total War v1 release archives.

This publisher intentionally uses explicit allowlists. It never reads a game
installation, a save directory, local evidence, build output, or art assets.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import sys
import tempfile
import zipfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Iterable


VERSION = "1.0.2"
TARGET_STEAM_BUILD_ID = "24467282"
FIXED_ZIP_TIME = (1980, 1, 1, 0, 0, 0)
ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUTPUT = ROOT / "release" / f"v{VERSION}"

FORBIDDEN_EXTENSIONS = {
    ".7z",
    ".dll",
    ".dmp",
    ".exe",
    ".fbx",
    ".log",
    ".obj",
    ".pak",
    ".pdb",
    ".rar",
    ".sav",
    ".uasset",
    ".ubulk",
    ".uexp",
    ".usmap",
    ".zip",
}
FORBIDDEN_PATH_PARTS = {
    ".codex_tmp",
    "artifacts",
    "build",
    "bridge-data",
    "evidence",
    "logs",
    "node_modules",
    "outputs",
    "palblackfurdragonrevival",
    "saved",
    "savegames",
    "target",
    "vendor",
}
FORBIDDEN_TEXT = {
    "24370881": "retired Steam Build ID",
    "appmanifest_1623730": "local Steam manifest",
    "幻兽帕鲁_mod项目交付与接手说明": "private handoff title",
    "幻兽帕鲁全面战争_mod目标清单": "private planning title",
}

COMMON_FILES = (
    "LICENSE",
    "SECURITY.md",
    "THIRD_PARTY_NOTICES.md",
    "幻兽帕鲁全面战争_已完成内容.md",
)

CORE_CONTRACTS = (
    "content_bundle.v1.json",
    "content_pack.v1.json",
    "ending_routes.v1.json",
    "factions.v1.json",
    "faction_commerce.v1.json",
    "faction_economy.v1.json",
    "faction_economy_shops.v1.json",
    "faction_progression.v1.json",
    "fast_travel_territories.v1.json",
    "island_territories.v2.json",
    "pal_reconciliation.v1.json",
    "player_relations.sample.json",
    "strategic_world.v1.json",
    "territory_assignments.v1.json",
    "tower_territories.v1.json",
)


CORE_README = """# 幻兽帕鲁全面战争 Core Foundation v1.0.2

这是《幻兽帕鲁全面战争》的 source-only 机制底座，目标 Steam Build 为 24467282。

包含势力进度、商业与商会、任务状态机、护卫与保卫战、帕鲁有限和解、
战略世界/结局接口、内容包契约和作者示例。它不包含正式剧情文本、游戏资产、
存档、日志、安装产物或玄绒龙美术资源。

状态：小型聚落攻城与商人商会七柜台已在 Build 24467282 实机通过；其他规则层
通过离线回归。NPC/帕鲁的 Core 对话控制器、通用呈现路由和代表距离门闩已经
离线完成；原生聊天 Widget/Delegate、真实交易好感度闭环和最终场景落位未完成。

本包不含地图、UMG 或商店 DataTable 的 Cooked PAK，因此是开发者基座，不是
一键安装的完整玩家版。UE4SS 源码位于
`PalFactionTerritory/mod0/ue4ss/PalFactionTerritory0/`。
"""

ADDONS_README = """# 幻兽帕鲁全面战争 Official Add-ons v1.0.2

本 source-only 包包含官方多帕鲁协同作战扩展 PalMultiOtomo0。
目标 Steam Build 为 24467282；不包含游戏资产、存档、日志或已部署文件。

状态：源码、Lua 语法和离线烟测已通过；当前 Build 的重新实机确认仍待完成。
将 `PalMultiOtomo0` 目录复制到 UE4SS 的 `Mods` 目录后，从 Steam 启动游戏验证。
"""

AI_README = """# 幻兽帕鲁全面战争 AI Dialogue Experimental v1.0.2

这是独立的 Rust 源码实验包，支持本地 Ollama 和 OpenAI-compatible 接口。
模型只能提出对白、白名单选择和白名单标签；任务、好感、物品和世界状态仍由
确定性的 Core 裁决。

状态：Rust 外部运行时和 UE4SS 文件桥源码均已包含并通过离线测试。Mod Core
已经具备提交、轮询、再次校验、离线回退和玩家确认控制器，以及后端无关的呈现
与代表距离门闩。原生 NPC Delegate、玩家可见 Widget 与 Build 24467282 实机验收
仍未完成，因此本包明确标记为 Experimental。
"""


@dataclass(frozen=True)
class PackageSpec:
    key: str
    archive_stem: str
    status: str
    live_validation_scope: str
    readme: str
    source_files: tuple[tuple[str, str], ...]


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def json_bytes(value: object) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")


def iter_files(directory: Path, suffixes: set[str] | None = None) -> Iterable[Path]:
    if not directory.is_dir():
        raise FileNotFoundError(f"Required source directory is missing: {directory}")
    for path in sorted(directory.rglob("*"), key=lambda item: item.as_posix().lower()):
        if not path.is_file():
            continue
        if suffixes is not None and path.suffix.lower() not in suffixes:
            continue
        yield path


def add_tree(
    entries: dict[str, bytes],
    source_dir: str,
    archive_dir: str,
    suffixes: set[str] | None = None,
) -> None:
    base = ROOT / source_dir
    for source in iter_files(base, suffixes):
        relative = source.relative_to(base).as_posix()
        entries[f"{archive_dir}/{relative}"] = source.read_bytes()


def add_file(entries: dict[str, bytes], source: str, archive: str) -> None:
    path = ROOT / source
    if not path.is_file():
        raise FileNotFoundError(f"Required source file is missing: {path}")
    entries[archive] = path.read_bytes()


def validate_entries(package_key: str, entries: dict[str, bytes]) -> None:
    failures: list[str] = []
    for archive_path, data in sorted(entries.items()):
        pure = PurePosixPath(archive_path)
        lower_parts = {part.lower() for part in pure.parts}
        forbidden_parts = sorted(lower_parts & FORBIDDEN_PATH_PARTS)
        if forbidden_parts:
            failures.append(f"{archive_path}: forbidden path component {forbidden_parts}")
        if pure.suffix.lower() in FORBIDDEN_EXTENSIONS:
            failures.append(f"{archive_path}: forbidden extension {pure.suffix.lower()}")
        if ".." in pure.parts or pure.is_absolute():
            failures.append(f"{archive_path}: unsafe archive path")

        try:
            text = data.decode("utf-8").lower()
        except UnicodeDecodeError:
            failures.append(f"{archive_path}: non-UTF-8 payload in source-only package")
            continue
        for needle, label in FORBIDDEN_TEXT.items():
            if needle.lower() in text:
                failures.append(f"{archive_path}: contains {label}")
        if re.search(r"\b7656119\d{10}\b", text):
            failures.append(f"{archive_path}: contains a Steam account ID")
        if re.search(r"[a-z]:\\(?:users|steamlibrary)\\", text, flags=re.IGNORECASE):
            failures.append(f"{archive_path}: contains a local Windows user/game path")

    if failures:
        detail = "\n".join(f"  - {failure}" for failure in failures)
        raise RuntimeError(f"Release safety validation failed for {package_key}:\n{detail}")


def payload_manifest(spec: PackageSpec, entries: dict[str, bytes]) -> dict[str, object]:
    files = [
        {
            "path": path,
            "bytes": len(data),
            "sha256": sha256_bytes(data),
        }
        for path, data in sorted(entries.items())
    ]
    return {
        "schemaVersion": 1,
        "releaseVersion": VERSION,
        "package": spec.key,
        "status": spec.status,
        "liveValidationScope": spec.live_validation_scope,
        "targetSteamBuildId": TARGET_STEAM_BUILD_ID,
        "sourceOnly": True,
        "payloadFileCount": len(files),
        "payloadBytes": sum(item["bytes"] for item in files),
        "files": files,
    }


def write_deterministic_zip(path: Path, root_name: str, entries: dict[str, bytes]) -> None:
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for relative, data in sorted(entries.items()):
            member = f"{root_name}/{relative}"
            info = zipfile.ZipInfo(member, date_time=FIXED_ZIP_TIME)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            info.flag_bits = 0x800
            archive.writestr(info, data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)


def core_entries() -> dict[str, bytes]:
    entries: dict[str, bytes] = {"README.md": CORE_README.encode("utf-8")}
    for common in COMMON_FILES:
        add_file(entries, common, common)
    for contract in CORE_CONTRACTS:
        add_file(
            entries,
            f"PalFactionTerritory/contracts/{contract}",
            f"PalFactionTerritory/contracts/{contract}",
        )
    add_tree(
        entries,
        "PalFactionTerritory/mod0/ue4ss/PalFactionTerritory0",
        "PalFactionTerritory/mod0/ue4ss/PalFactionTerritory0",
        {".lua", ".txt"},
    )
    add_tree(entries, "PalFactionTerritory/mod0/tests", "PalFactionTerritory/mod0/tests", {".lua"})
    add_tree(
        entries,
        "PalFactionTerritory/examples/minimal-content-pack",
        "PalFactionTerritory/examples/minimal-content-pack",
        {".lua", ".md"},
    )
    add_tree(entries, "PalFactionTerritory/src", "PalFactionTerritory/src", {".py"})
    return entries


def addon_entries() -> dict[str, bytes]:
    entries: dict[str, bytes] = {"README.md": ADDONS_README.encode("utf-8")}
    for common in COMMON_FILES:
        add_file(entries, common, common)
    add_file(entries, "PalMultiOtomo/README.md", "PalMultiOtomo/README.md")
    add_tree(
        entries,
        "PalMultiOtomo/mod0/ue4ss/PalMultiOtomo0",
        "PalMultiOtomo/mod0/ue4ss/PalMultiOtomo0",
        {".lua", ".txt"},
    )
    add_tree(entries, "PalMultiOtomo/mod0/tests", "PalMultiOtomo/mod0/tests", {".lua"})
    add_file(entries, "PalMultiOtomo/scripts/verify.ps1", "PalMultiOtomo/scripts/verify.ps1")
    return entries


def ai_entries() -> dict[str, bytes]:
    entries: dict[str, bytes] = {"RELEASE-NOTES.md": AI_README.encode("utf-8")}
    for file_name in (
        ".env.example",
        ".gitattributes",
        ".gitignore",
        "Cargo.lock",
        "Cargo.toml",
        "CHANGELOG.md",
        "LICENSE",
        "PRIVACY.md",
        "README.md",
        "SECURITY.md",
        "THIRD_PARTY_NOTICES.md",
    ):
        add_file(entries, f"PalAgentDialogue/{file_name}", file_name)
    add_tree(entries, "PalAgentDialogue/src", "src", {".rs"})
    add_tree(entries, "PalAgentDialogue/tests", "tests", {".rs"})
    add_tree(entries, "PalAgentDialogue/contracts", "contracts", {".json", ".md"})
    add_tree(entries, "PalAgentDialogue/character-packs", "character-packs", {".json", ".md"})
    add_tree(entries, "PalAgentDialogue/scripts", "scripts", {".ps1"})
    add_tree(entries, "PalAgentDialogue/ue4ss", "ue4ss", {".lua", ".txt"})
    return entries


def build_release(output: Path) -> dict[str, object]:
    specs = (
        PackageSpec(
            "Core",
            f"PalworldTotalWar-v{VERSION}-Core-source",
            "mixed-live-accepted-and-offline-verified-source-only",
            "Build 24467282: settlement raid and seven-counter merchant guild accepted; other modules offline or pending",
            CORE_README,
            (),
        ),
        PackageSpec(
            "OfficialAddons",
            f"PalworldTotalWar-v{VERSION}-OfficialAddons-source",
            "offline-verified-current-build-live-recheck-pending",
            "current Build live recheck pending",
            ADDONS_README,
            (),
        ),
        PackageSpec(
            "AIExperimental",
            f"PalworldTotalWar-v{VERSION}-AIExperimental-source",
            "offline-tested-experimental-game-ui-integration-pending",
            "no in-game dialogue UI acceptance",
            AI_README,
            (),
        ),
    )
    factories = {
        "Core": core_entries,
        "OfficialAddons": addon_entries,
        "AIExperimental": ai_entries,
    }

    output_parent = output.parent.resolve()
    output_resolved = output.resolve()
    expected_parent = (ROOT / "release").resolve()
    if output_parent != expected_parent or output_resolved == expected_parent:
        raise RuntimeError(f"Output must be a direct child of {expected_parent}")

    temp_dir: Path | None = Path(
        tempfile.mkdtemp(prefix=f".{output.name}-", dir=expected_parent)
    )
    try:
        package_records: list[dict[str, object]] = []
        checksum_targets: list[Path] = []
        for spec in specs:
            entries = factories[spec.key]()
            validate_entries(spec.key, entries)
            manifest = payload_manifest(spec, entries)
            manifest_data = json_bytes(manifest)
            entries["PACKAGE-MANIFEST.json"] = manifest_data
            validate_entries(spec.key, entries)

            archive_name = f"{spec.archive_stem}.zip"
            manifest_name = f"{spec.archive_stem}.manifest.json"
            assert temp_dir is not None
            archive_path = temp_dir / archive_name
            manifest_path = temp_dir / manifest_name
            manifest_path.write_bytes(manifest_data)
            write_deterministic_zip(archive_path, spec.archive_stem, entries)
            checksum_targets.extend((archive_path, manifest_path))
            package_records.append(
                {
                    "package": spec.key,
                    "status": spec.status,
                    "liveValidationScope": spec.live_validation_scope,
                    "archive": archive_name,
                    "archiveBytes": archive_path.stat().st_size,
                    "archiveSha256": sha256_bytes(archive_path.read_bytes()),
                    "manifest": manifest_name,
                    "manifestSha256": sha256_bytes(manifest_data),
                    "payloadFileCount": manifest["payloadFileCount"],
                    "payloadBytes": manifest["payloadBytes"],
                }
            )

        release_manifest = {
            "schemaVersion": 1,
            "releaseVersion": VERSION,
            "targetSteamBuildId": TARGET_STEAM_BUILD_ID,
            "releaseType": "source-only",
            "liveValidationScope": "partial; see each package record and completion document",
            "packages": package_records,
            "excluded": [
                "PalBlackFurDragonRevival and all BlackFur art",
                "all game binaries and cooked assets",
                "save files and protected save identities",
                "logs, dumps, local evidence, build output, and deployment artifacts",
                "Steam account IDs and local installation paths",
                "private handoff/planning documents",
                "retired Steam Build 24370881 material",
            ],
        }
        assert temp_dir is not None
        release_manifest_path = temp_dir / "release-manifest.json"
        release_manifest_path.write_bytes(json_bytes(release_manifest))
        checksum_targets.append(release_manifest_path)

        checksums = "".join(
            f"{sha256_bytes(path.read_bytes())}  {path.name}\n"
            for path in sorted(checksum_targets, key=lambda item: item.name.lower())
        )
        (temp_dir / "SHA256SUMS.txt").write_text(checksums, encoding="ascii", newline="\n")

        if output.exists():
            if not output.is_dir():
                raise RuntimeError(f"Output exists and is not a directory: {output}")
            shutil.rmtree(output)
        os.replace(temp_dir, output)
        temp_dir = None
        return release_manifest
    finally:
        if temp_dir is not None and temp_dir.exists():
            resolved_temp = temp_dir.resolve()
            if resolved_temp.parent != expected_parent or not resolved_temp.name.startswith(
                f".{output.name}-"
            ):
                raise RuntimeError(
                    f"Refusing to clean an unexpected temporary path: {resolved_temp}"
                )
            shutil.rmtree(resolved_temp)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()

    if args.verify_only:
        for key, factory in (
            ("Core", core_entries),
            ("OfficialAddons", addon_entries),
            ("AIExperimental", ai_entries),
        ):
            entries = factory()
            validate_entries(key, entries)
            print(f"PASS {key}: {len(entries)} allowlisted UTF-8 source files")
        return 0

    DEFAULT_OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    manifest = build_release(args.output)
    print(json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # concise CLI failure, retaining a non-zero exit
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
