#!/usr/bin/env python3
"""把某学期的资源目录打成学期包（tasks 7.4）。

输入：app/Resources/Curriculum/（grade2.json + audio/ words/ img/）
输出：content-service/packs/<id>.zip + <id>.meta.json

包内结构（design「内容分发：家园局域网」）：
    <id>/curriculum.json      = 原 grade2.json + 顶层 schemaVersion
    <id>/audio/  <id>/words/  <id>/img/

用法：
    python3 content-service/build/build_resources.py                    # 默认二上、版本 1
    python3 content-service/build/build_resources.py --version 2        # 产出 g2s1-v2.zip（给 previous 回退用）

只依赖标准库；Node 版（build_resources.js）等家里电脑装 Node 后再补，两边产物要一致。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import time
import zipfile

SERVICE_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = os.path.dirname(SERVICE_ROOT)

# 内容结构版本：JSON 结构变了才 +1（design「版本兼容」）
SCHEMA_VERSION = 2


def read_source_json(src: str) -> tuple[dict, str]:
    path = os.path.join(src, "grade2.json")
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    return data, path


def referenced_assets(curriculum: dict) -> list[str]:
    """JSON 里引用到的全部相对路径（img/u1/x.png 这种）。"""
    paths: list[str] = []
    for volume in curriculum.get("volumes", []):
        for unit in volume.get("units", []):
            for word in unit.get("words", []):
                paths.append(word["image"])
                paths.append(word["audio"])
            for listening in unit.get("listenings", []):
                paths.append(listening["audio"])
            for sentence in unit.get("sentences", []):
                audio = sentence.get("audio") or ""
                if audio:
                    paths.append(audio)
    return paths


def sha256_of(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description="打学期包")
    parser.add_argument("--id", default="g2s1", help="学期包 id，如 g2s1")
    parser.add_argument("--grade", type=int, default=2)
    parser.add_argument("--title", default="二年级上")
    parser.add_argument("--version", type=int, default=1, help="内容版本；>1 时文件名带 -vN")
    parser.add_argument("--src", default=os.path.join(REPO, "app", "Resources", "Curriculum"))
    parser.add_argument("--out", default=os.path.join(SERVICE_ROOT, "packs"))
    args = parser.parse_args()

    src = args.src
    if not os.path.isdir(src):
        print(f"✗ 找不到资源目录：{src}", file=sys.stderr)
        return 2

    curriculum, source_json = read_source_json(src)
    curriculum["schemaVersion"] = SCHEMA_VERSION

    # 1) 校验 JSON 引用的资产齐全
    missing = [p for p in referenced_assets(curriculum) if not os.path.isfile(os.path.join(src, p))]
    if missing:
        print("✗ 以下资产在源目录里缺失，打包中止：", file=sys.stderr)
        for path in missing:
            print(f"  - {path}", file=sys.stderr)
        return 1

    # 2) 落盘
    os.makedirs(args.out, exist_ok=True)
    suffix = "" if args.version <= 1 else f"-v{args.version}"
    zip_name = f"{args.id}{suffix}.zip"
    zip_path = os.path.join(args.out, zip_name)

    file_count = 0
    with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as zf:
        zf.writestr(f"{args.id}/curriculum.json", json.dumps(curriculum, ensure_ascii=False, indent=2))
        file_count += 1
        for root, _dirs, files in os.walk(src):
            for name in files:
                if name == "grade2.json":
                    continue  # 已作为 curriculum.json 写入
                absolute = os.path.join(root, name)
                relative = os.path.relpath(absolute, src).replace(os.sep, "/")
                zf.write(absolute, f"{args.id}/{relative}")
                file_count += 1

    # 3) 生成 meta（serve 脚本据此产出 manifest）
    meta = {
        "id": args.id,
        "grade": args.grade,
        "title": args.title,
        "contentVersion": args.version,
        "schemaVersion": SCHEMA_VERSION,
        "fileCount": file_count,
        "sourceJson": os.path.relpath(source_json, REPO),
        "builtAt": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    }
    meta_path = os.path.join(args.out, f"{args.id}{suffix}.meta.json")
    with open(meta_path, "w", encoding="utf-8") as fh:
        json.dump(meta, fh, ensure_ascii=False, indent=2)

    size = os.path.getsize(zip_path)
    print(f"✓ {zip_name}  {size / 1_048_576:.1f} MiB  {file_count} 个文件")
    print(f"✓ {os.path.basename(meta_path)}")
    print(f"  sha256 = {sha256_of(zip_path)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
