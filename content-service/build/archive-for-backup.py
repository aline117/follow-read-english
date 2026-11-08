#!/usr/bin/env python3
"""把学期包与媒体包整理成一份「可直接拷去云盘/移动硬盘」的备份归档，并支持事后校验。

为什么需要它（tasks 7.9 / 7.11）：

- 学期包（`packs/`）与媒体包（`media/`）是**家里电脑上唯一的一份**，原始素材来源已不稳定，
  丢了无法重做。但直接拷目录有三个坑：
  1. 6.3 GB 中途断开，第二天不知道哪些拷完了、哪些是半截文件；
  2. `media.json` 与 `media/files/` 一旦错位（少拷一个文件、清单是旧版），
     App 侧会把它当成「内容损坏」——比没备份更糟，因为你会以为已经备好了；
  3. 半年后翻出来，不记得这份备份对应哪个内容版本。

所以这里产出的不是裸目录，而是一份**自描述 + 可校验**的归档：

    <out>/MANIFEST.json      每文件 sha256 / 字节数 / 内容版本 / 生成时间
    <out>/CHECKSUMS.sha256   标准 sha256sum 格式，任何工具都能独立核（含 Windows certutil）
    <out>/packs/...          学期包 zip + meta
    <out>/media/...          media.json + files/（清单与文件始终同目录）

用法：

    # 生成归档（断点续传：已拷过且大小一致的文件会跳过）
    python content-service/build/archive-for-backup.py --out E:/backup/english-20261108

    # 只想备学期包（41 MB，秒级）
    python content-service/build/archive-for-backup.py --out E:/backup/packs-only --no-media

    # 校验（换机后、或半年后想确认没坏）：逐个文件比 sha256，并核对 media.json 与文件成对
    python content-service/build/archive-for-backup.py --verify E:/backup/english-20261108

退出码：0 = 全部通过；1 = 有问题（会逐条列出）；2 = 参数/环境错误。
"""

from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
import os
import shutil
import sys
import time
from datetime import datetime, timezone

ARCHIVE_VERSION = 1
BLOCK = 1024 * 1024


# ---------------------------------------------------------------- 基础工具


def sha256_of(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        while True:
            chunk = handle.read(BLOCK)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def human(bytes_count: int) -> str:
    value = float(bytes_count)
    for unit in ("B", "KB", "MB", "GB"):
        if value < 1024 or unit == "GB":
            return f"{value:.1f} {unit}" if unit != "B" else f"{int(value)} B"
        value /= 1024
    return f"{value:.1f} GB"


def load_json(path: str) -> dict:
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def now_iso() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


# ---------------------------------------------------------------- 收集源文件


def collect_sources(root: str, include_media: bool) -> tuple[list[tuple[str, str]], dict]:
    """返回（相对路径, 绝对路径）列表 + 内容版本信息。相对路径以 content-service 为根。"""
    files: list[tuple[str, str]] = []
    info: dict = {}

    packs_dir = os.path.join(root, "packs")
    if os.path.isdir(packs_dir):
        for name in sorted(os.listdir(packs_dir)):
            if not name.endswith((".zip", ".meta.json")):
                continue
            absolute = os.path.join(packs_dir, name)
            if os.path.isfile(absolute):
                files.append((f"packs/{name}", absolute))

    if not include_media:
        info["media"] = None
        return files, info

    media_dir = os.path.join(root, "media")
    manifest_path = os.path.join(media_dir, "media.json")
    if not os.path.isfile(manifest_path):
        info["media"] = None
        return files, info

    manifest = load_json(manifest_path)
    files.append(("media/media.json", manifest_path))

    items = manifest.get("items") or []
    missing: list[str] = []
    for item in items:
        rel = item.get("relPath") or ""
        if not rel:
            continue
        absolute = os.path.join(media_dir, rel.replace("/", os.sep))
        if not os.path.isfile(absolute):
            missing.append(rel)
            continue
        files.append((f"media/{rel}", absolute))

    info["media"] = {
        "items": len(items),
        "mediaSchemaVersion": manifest.get("mediaSchemaVersion"),
        "contentVersion": manifest.get("contentVersion"),
        "generatedAt": manifest.get("generatedAt"),
        "missingOnDisk": missing,
    }
    return files, info


# ---------------------------------------------------------------- 拷贝模式


def copy_one(src: str, dst: str) -> tuple[int, str]:
    """拷一个文件并顺便算 sha256（只读一遍源文件）。返回（字节数, sha256）。"""
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    temp = dst + ".part"
    digest = hashlib.sha256()
    size = 0
    with open(src, "rb") as reader, open(temp, "wb") as writer:
        while True:
            chunk = reader.read(BLOCK)
            if not chunk:
                break
            digest.update(chunk)
            writer.write(chunk)
            size += len(chunk)
    # 先写 .part 再改名：断电不会留下「大小对但内容是半截」的文件
    os.replace(temp, dst)
    shutil.copystat(src, dst)
    return size, digest.hexdigest()


def build_archive(root: str, out: str, include_media: bool, quiet: bool) -> int:
    files, info = collect_sources(root, include_media)
    if not files:
        print("没有找到可备份的内容：packs/ 与 media/ 都为空？", file=sys.stderr)
        return 2

    if info.get("media") and info["media"]["missingOnDisk"]:
        print(f"注意：清单里有 {len(info['media']['missingOnDisk'])} 项在磁盘上不存在，"
              f"这份备份不完整（先跑 build-media-pack.py 重导）", file=sys.stderr)
        for rel in info["media"]["missingOnDisk"][:5]:
            print(f"  缺：{rel}", file=sys.stderr)

    os.makedirs(out, exist_ok=True)
    started = time.time()
    entries: list[dict] = []
    copied = skipped = 0
    total_bytes = 0

    for index, (rel, src) in enumerate(files, start=1):
        dst = os.path.join(out, rel.replace("/", os.sep))
        src_size = os.path.getsize(src)

        # 断点续传：目标已有且大小一致就当拷过了（内容对不对由 --verify 兜底）
        if os.path.isfile(dst) and os.path.getsize(dst) == src_size:
            entries.append({"path": rel, "bytes": src_size, "sha256": None})
            skipped += 1
        else:
            size, digest = copy_one(src, dst)
            entries.append({"path": rel, "bytes": size, "sha256": digest})
            copied += 1
            total_bytes += size

        if not quiet and index % 20 == 0:
            print(f"  {index}/{len(files)} 个文件…", flush=True)

    manifest = {
        "archiveVersion": ARCHIVE_VERSION,
        "createdAt": now_iso(),
        "sourceRoot": os.path.abspath(root),
        "packs": sorted({e["path"].split("/")[-1].replace(".zip", "").replace(".meta.json", "")
                         for e in entries if e["path"].startswith("packs/")}),
        "media": info.get("media"),
        "totals": {"files": len(entries), "bytes": sum(e["bytes"] for e in entries)},
        "files": entries,
    }
    with open(os.path.join(out, "MANIFEST.json"), "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, ensure_ascii=False, indent=2)

    # 占位 sha：新拷的已有值；跳过的是空值 → 统一补算一遍（这一步也顺便验证了源文件没坏）
    if any(e["sha256"] is None for e in entries):
        if not quiet:
            print("  补算跳过文件的 sha256…", flush=True)
        for entry in entries:
            if entry["sha256"] is None:
                entry["sha256"] = sha256_of(os.path.join(out, entry["path"].replace("/", os.sep)))
        with open(os.path.join(out, "MANIFEST.json"), "w", encoding="utf-8") as handle:
            json.dump(manifest, handle, ensure_ascii=False, indent=2)

    with open(os.path.join(out, "CHECKSUMS.sha256"), "w", encoding="utf-8") as handle:
        for entry in entries:
            handle.write(f"{entry['sha256']}  {entry['path']}\n")

    elapsed = time.time() - started
    print(f"\n归档完成：{out}")
    print(f"  新拷 {copied} 个 / 跳过 {skipped} 个，共 {human(manifest['totals']['bytes'])}，"
          f"耗时 {elapsed:.0f}s")
    if info.get("media"):
        media = info["media"]
        print(f"  媒体清单：{media['items']} 项 · mediaSchemaVersion {media['mediaSchemaVersion']} "
              f"· contentVersion {media['contentVersion']}")
    if info.get("media") and info["media"]["missingOnDisk"]:
        # 备份不完整**不能**当成功：宁可让脚本报错，也别让人以为已经备好了
        print(f"✗ 归档不完整：清单里 {len(info['media']['missingOnDisk'])} 项文件不在磁盘上，"
              f"这份备份不能用（先重导媒体包再跑一次）", file=sys.stderr)
        return 3
    print("  下一步：整份目录拷到云盘/移动硬盘，之后随时可用 --verify 校验")
    return 0


# ---------------------------------------------------------------- 校验模式


def verify_archive(out: str, workers: int, quiet: bool) -> int:
    manifest_path = os.path.join(out, "MANIFEST.json")
    if not os.path.isfile(manifest_path):
        print(f"找不到 {manifest_path}：这不是本工具生成的归档", file=sys.stderr)
        return 2

    manifest = load_json(manifest_path)
    entries = manifest.get("files") or []
    if not entries:
        print("MANIFEST.json 里没有文件清单", file=sys.stderr)
        return 2

    problems: list[str] = []

    def check(entry: dict) -> str | None:
        absolute = os.path.join(out, entry["path"].replace("/", os.sep))
        if not os.path.isfile(absolute):
            return f"缺失：{entry['path']}"
        size = os.path.getsize(absolute)
        if size != entry["bytes"]:
            return f"大小不符：{entry['path']}（清单 {entry['bytes']}，实际 {size}）"
        digest = sha256_of(absolute)
        if digest != entry["sha256"]:
            return f"内容损坏：{entry['path']}（清单 {entry['sha256'][:12]}…，实际 {digest[:12]}…）"
        return None

    started = time.time()
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        for index, result in enumerate(pool.map(check, entries), start=1):
            if result:
                problems.append(result)
            if not quiet and index % 20 == 0:
                print(f"  校验 {index}/{len(entries)}…", flush=True)

    # 清单 ↔ 文件成对：media.json 里声明的每一项都要在归档里，且大小一致
    media_manifest = os.path.join(out, "media", "media.json")
    if os.path.isfile(media_manifest):
        declared = load_json(media_manifest)
        present = {e["path"]: e for e in entries}
        for item in declared.get("items") or []:
            rel = item.get("relPath") or ""
            key = f"media/{rel}"
            if key not in present:
                problems.append(f"清单有、文件没有：{rel}")
            elif present[key]["bytes"] != item.get("bytes"):
                problems.append(f"清单与文件大小不一致：{rel}")
        extra = [p for p in present if p.startswith("media/") and p != "media/media.json"]
        if len(extra) > len(declared.get("items") or []):
            problems.append(f"归档里的媒体文件比清单多 {len(extra) - len(declared.get('items') or [])} 个"
                            f"（可能是旧版残留）")

    elapsed = time.time() - started
    total = human(sum(e["bytes"] for e in entries))
    print()
    if problems:
        print(f"校验未通过：{len(problems)} 处问题（共 {len(entries)} 个文件 / {total}，{elapsed:.0f}s）")
        for line in problems[:40]:
            print(f"  ✗ {line}")
        if len(problems) > 40:
            print(f"  …还有 {len(problems) - 40} 条")
        return 1

    print(f"校验通过：{len(entries)} 个文件 / {total}，逐个 sha256 一致，"
          f"media.json 与文件成对（{elapsed:.0f}s）")
    return 0


# ---------------------------------------------------------------- 入口


def main() -> int:
    default_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    parser = argparse.ArgumentParser(
        description="把 content-service 的学期包与媒体包整理成可校验的异地备份归档")
    parser.add_argument("--root", default=default_root, help="content-service 根目录")
    parser.add_argument("--out", help="归档输出目录（应为云盘/移动硬盘上的路径）")
    parser.add_argument("--verify", metavar="DIR", help="校验已生成的归档")
    parser.add_argument("--no-media", action="store_true", help="只备学期包，跳过 6 GB 媒体")
    parser.add_argument("--jobs", type=int, default=min(4, (os.cpu_count() or 2)),
                        help="校验时的并发线程数（默认 4）")
    parser.add_argument("--quiet", action="store_true", help="少打印进度")
    args = parser.parse_args()

    if args.verify:
        return verify_archive(args.verify, max(1, args.jobs), args.quiet)
    if not args.out:
        parser.error("要么给 --out 生成归档，要么给 --verify DIR 校验")
    return build_archive(args.root, args.out, not args.no_media, args.quiet)


if __name__ == "__main__":
    sys.exit(main())
