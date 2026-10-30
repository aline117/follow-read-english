#!/usr/bin/env python3
"""生成媒体包：把儿歌 / 绘本素材导入 `content-service/media/`，并写出 `media/media.json`。

按 design「Decision 7：媒体包只发清单，逐项下载，不打包 zip」——
媒体包就是一件事：`media/media.json`（清单）+ `media/files/...`（原始 mp4）。
iPad 只先拉清单，播哪条下哪条；没有「下载整个媒体包」这个动作，也没有 zip。

素材目录（仓库外，通常是 G:/…/雪梨课程精讲视频 下的
`赠品英文儿歌` 与 `6.绘本口语跟读6部164节`）→ 落成：

    media/media.json                      ← 清单：mediaSchemaVersion / contentVersion / 逐项 sha256
    media/files/songs/<slug>.mp4          ← 儿歌
    media/files/picture/b1/<slug>.mp4     ← 绘本（每部一个 b1…b6 子目录）

没有这套导入脚本时，等价的手工流程是「把素材按命名规范放进 media/files/，
再跑 build-media-manifest.mjs」；本脚本额外做三件事：递归识别「赠课1/赠课2」这类子目录、
把文件名规范化成 url 安全 slug、复制时顺带算 sha256 与 faststart 判定。

用法：

    python3 content-service/build/build-media-pack.py \\
        --songs   G:/…/赠品英文儿歌 \\
        --picture G:/…/6.绘本口语跟读6部164节 \\
        --version 1

    python3 content-service/build/build-media-pack.py --help

只依赖标准库。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import sys
import time
import unicodedata

SERVICE_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MEDIA_SCHEMA_VERSION = 1  # 与 App 的 MediaManifest.supportedSchemaVersion 对齐
VIDEO_EXTS = (".mp4", ".m4v")


# --------------------------------------------------------------------------- 工具

def slug(name: str, fallback: str = "item") -> str:
    """文件名 → 稳定的 url 片段：非 ascii 字母数字一律折成短横线。

    `1.At the Market` → `1-at-the-market`（保留排序前缀，标题另外去掉）
    """
    text = unicodedata.normalize("NFKD", name)
    text = text.encode("ascii", "ignore").decode("ascii")
    text = re.sub(r"[^0-9A-Za-z]+", "-", text).strip("-").lower()
    text = re.sub(r"^(\d+)([a-z])", r"\1-\2", text)  # `01abc` → `01-abc`
    return text or fallback


def display_title(stem: str, fallback: str) -> str:
    """`19.On the... School` → `On the... School`（去掉排序用的数字前缀）。"""
    text = re.sub(r"^\s*\d+\s*[.、\-_ ]\s*", "", stem).strip()
    return text or stem.strip() or fallback


def is_streamable(path: str) -> bool:
    """moov 在文件头（且在 mdat 之前）才算能秒开；只读头部 1 MiB。"""
    head_size = 1024 * 1024
    try:
        with open(path, "rb") as fh:
            head = fh.read(head_size)
    except OSError:
        return False

    offset = 0
    moov_at = -1
    mdat_at = -1
    while offset + 8 <= len(head):
        size = int.from_bytes(head[offset:offset + 4], "big")
        box_type = head[offset + 4:offset + 8].decode("ascii", "replace")
        if not re.fullmatch(r"[A-Za-z0-9 ]{4}", box_type):
            break
        if box_type == "moov":
            moov_at = offset
            break
        if box_type == "mdat":
            mdat_at = offset
            break
        if size < 8:
            break
        offset += size
    return moov_at >= 0 and (mdat_at < 0 or moov_at < mdat_at)


def sha256_of(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


class HashingWriter:
    """复制的同时算 sha256，免得为 6 GB 素材再读一遍。"""

    def __init__(self, handle):
        self._handle = handle
        self.digest = hashlib.sha256()
        self.written = 0

    def write(self, chunk: bytes) -> int:
        self.digest.update(chunk)
        self.written += len(chunk)
        return self._handle.write(chunk)

    def sha256(self) -> str:
        return self.digest.hexdigest()


def copy_hashing(src: str, dst: str) -> tuple[str, int]:
    """把 src 复制成 dst，返回 (sha256, 字节数)。"""
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    tmp = dst + ".part"
    with open(src, "rb") as source, open(tmp, "wb") as target:
        writer = HashingWriter(target)
        shutil.copyfileobj(source, writer, 1 << 20)
    os.replace(tmp, dst)  # 原子落地：半截文件不会留在 media/files 里
    return writer.sha256(), writer.written


# --------------------------------------------------------------------------- 扫描

def list_videos(directory: str) -> list[str]:
    """递归收集一个目录下的视频（素材常按「赠课1 / 赠课2」这类子目录分包）。"""
    found: list[str] = []
    for current, dirs, files in os.walk(directory):
        dirs.sort()
        for name in sorted(files):
            if name.lower().endswith(VIDEO_EXTS) and not name.startswith("."):
                found.append(os.path.join(current, name))
    return found


def scan_group(root: str, kind: str, split_parts: bool) -> list[dict]:
    """扫一个素材目录；`split_parts=True` 表示每个子目录算一「部」。"""
    found: list[dict] = []
    if not os.path.isdir(root):
        return found

    if not split_parts:
        # 儿歌：扁平化，part 恒为 0（子目录只用来分组文件，不参与 id）
        for absolute in list_videos(root):
            found.append({"file": absolute, "kind": kind, "part": 0, "part_dir": ""})
        return found

    # 绘本：每个子目录是一「部」；没有子目录时当作第 1 部
    subs = [d for d in sorted(os.listdir(root))
            if os.path.isdir(os.path.join(root, d))]
    if not subs:
        subs = [""]
    for index, sub in enumerate(subs, start=1):
        directory = os.path.join(root, sub) if sub else root
        tail = re.search(r"(\d+)\s*$", sub)
        token = f"b{tail.group(1)}" if tail else f"b{index}"
        part = int(tail.group(1)) if tail else index
        for absolute in list_videos(directory):
            found.append({"file": absolute, "kind": kind, "part": part, "part_dir": token})
    return found


# --------------------------------------------------------------------------- 主流程

def main() -> int:
    parser = argparse.ArgumentParser(description="生成媒体包（素材 → media/files + media/media.json）")
    parser.add_argument("--songs", default="", help="儿歌素材目录（可省略）")
    parser.add_argument("--picture", default="", help="绘本素材目录（每部一个子目录；可省略）")
    parser.add_argument("--media", default=os.path.join(SERVICE_ROOT, "media"),
                        help="媒体包目录，默认 content-service/media")
    parser.add_argument("--version", type=int, default=1, help="内容版本（内容变了 +1）")
    parser.add_argument("--ids", default="", help="可选 ids.json：{ \"<相对路径>\": \"m:自定义id\" }")
    parser.add_argument("--dry-run", action="store_true", help="只列计划，不复制、不写清单")
    args = parser.parse_args()

    if not args.songs and not args.picture:
        parser.error("至少要给 --songs 或 --picture 之一")

    # 产物只许落在 content-service/media 或仓库外（见 design「版权」：素材不进 git）
    repo = os.path.dirname(SERVICE_ROOT)
    media_dir = os.path.abspath(args.media)
    allowed = os.path.join(SERVICE_ROOT, "media")
    inside_repo = media_dir == repo or media_dir.startswith(repo + os.sep)
    inside_allowed = media_dir == allowed or media_dir.startswith(allowed + os.sep)
    if inside_repo and not inside_allowed:
        print(f"✗ 拒绝写入仓库内的路径：{media_dir}\n  请用 content-service/media（默认），或换到仓库外。",
              file=sys.stderr)
        return 3

    overrides: dict[str, str] = {}
    if args.ids and os.path.isfile(args.ids):
        with open(args.ids, encoding="utf-8") as fh:
            overrides = json.load(fh)

    entries: list[dict] = []
    entries += scan_group(args.songs, "song", split_parts=False)
    entries += scan_group(args.picture, "picture", split_parts=True)
    if not entries:
        print("✗ 两个素材目录里都没有 mp4，生成中止", file=sys.stderr)
        return 2

    # 定 id / 相对路径（同一目录下 slug 撞车时才加 -2、-3，并跳过已被真实文件名占用的名字）
    used_names: dict[str, set[str]] = {}
    used_ids: set[str] = set()
    plan: list[dict] = []
    for entry in entries:
        stem = os.path.splitext(os.path.basename(entry["file"]))[0]
        base_slug = slug(stem)
        bucket = f"{entry['kind']}/{entry['part_dir']}"
        taken = used_names.setdefault(bucket, set())
        final_slug = base_slug
        suffix = 1
        while final_slug in taken:
            suffix += 1
            final_slug = f"{base_slug}-{suffix}"
        taken.add(final_slug)

        if entry["kind"] == "song":
            rel_path = f"files/songs/{final_slug}.mp4"
            default_id = f"m:song-{final_slug}"
        else:
            rel_path = f"files/picture/{entry['part_dir']}/{final_slug}.mp4"
            default_id = f"m:pb-{entry['part_dir']}-{final_slug}"

        item_id = overrides.get(rel_path, default_id)
        if not item_id.startswith("m:"):
            print(f"✗ id 必须以 m: 开头：{item_id}", file=sys.stderr)
            return 4
        if item_id in used_ids:
            print(f"✗ id 重复：{item_id}（用 --ids 覆盖）", file=sys.stderr)
            return 4
        used_ids.add(item_id)

        plan.append({
            "file": entry["file"],
            "kind": entry["kind"],
            "part": entry["part"],
            "title": display_title(stem, final_slug),
            "id": item_id,
            "relPath": rel_path,
        })

    if args.dry_run:
        for index, entry in enumerate(plan, start=1):
            print(f"{index:3d}. {entry['relPath']}  ←  {entry['file']}")
        print(f"\n共 {len(plan)} 项（dry-run，未复制、未写清单）")
        return 0

    # 复制 + 逐项算 sha256 / faststart
    items: list[dict] = []
    raw_bytes = 0
    not_streamable = 0
    reused = 0
    started = time.time()

    for index, entry in enumerate(plan, start=1):
        source = entry["file"]
        target = os.path.join(media_dir, entry["relPath"].replace("/", os.sep))
        size = os.path.getsize(source)

        if os.path.isfile(target) and os.path.getsize(target) == size:
            digest = sha256_of(target)  # 已经在位就不重复拷 6 GB
            reused += 1
        else:
            digest, written = copy_hashing(source, target)
            if written != size:
                print(f"✗ {source} 复制字节数不对：{written} != {size}", file=sys.stderr)
                return 5

        streamable = is_streamable(target)
        if not streamable:
            not_streamable += 1
        raw_bytes += size
        items.append({
            "id": entry["id"],
            "title": entry["title"],
            "kind": entry["kind"],
            "part": entry["part"],
            "durationSec": 0,
            "bytes": size,
            "sha256": digest,
            "relPath": entry["relPath"],
            "streamable": streamable,
            "lines": [],
        })
        if index % 20 == 0 or index == len(plan):
            print(f"  {index}/{len(plan)}  {raw_bytes / 1073741824:.2f} GiB  {time.time() - started:.0f}s")

    manifest = {
        "mediaSchemaVersion": MEDIA_SCHEMA_VERSION,
        "contentVersion": args.version,
        "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "items": items,
    }
    manifest_path = os.path.join(media_dir, "media.json")
    os.makedirs(media_dir, exist_ok=True)
    with open(manifest_path, "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, ensure_ascii=False, indent=2)
        fh.write("\n")

    songs = sum(1 for item in items if item["kind"] == "song")
    pictures = len(items) - songs
    print()
    print(f"✓ media.json  {len(items)} 项（儿歌 {songs} · 绘本 {pictures}）")
    print(f"  素材 {raw_bytes / 1073741824:.2f} GiB → {media_dir}")
    if reused:
        print(f"  已在位跳过复制 {reused} 项")
    print(f"  不能秒开 {not_streamable} 项（逐项串流会走「先下后播」；要秒开先 remux）")
    print(f"  用时 {time.time() - started:.0f}s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
