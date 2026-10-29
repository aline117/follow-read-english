#!/usr/bin/env python3
"""家园局域网内容服务（content-service 的 Python 版）。

- 学期包：扫描 `packs/*.meta.json` 生成 `/manifest.json`，提供 `/packs/*.zip`
- 媒体库：提供 `/media.json` 与 `/media/files/*`（支持 HTTP Range）
- 只读、只绑内网、不做端口映射；iPad 只需要 HTTP GET

目录约定（content-service 根目录）：
    packs/            学期包 zip + meta
    media/media.json  媒体清单
    media/files/...   儿歌 / 绘本 mp4

用法：
    python3 content-service/serve/serve.py
    python3 content-service/serve/serve.py --port 9000
    python3 content-service/serve/serve.py --root /path/to/content-service

Windows 上如果装了 Node，用 serve.js + serve.bat；两者协议一致。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import mimetypes
import os
import re
import socket
import sys
import threading
from typing import Optional
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlparse

SERVICE_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# App 支持的内容结构版本上限（与 App 内 ContentSchema.supported 对齐）
CONTENT_SCHEMA_VERSION = 2

_sha_cache: dict[str, tuple[float, int, str]] = {}
_cache_lock = threading.Lock()

_RANGE_RE = re.compile(r"^bytes=(\d*)-(\d*)$")


def sha256_of(path: str) -> str:
    stat = os.stat(path)
    with _cache_lock:
        cached = _sha_cache.get(path)
        if cached and cached[0] == stat.st_mtime and cached[1] == stat.st_size:
            return cached[2]
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            digest.update(chunk)
    value = digest.hexdigest()
    with _cache_lock:
        _sha_cache[path] = (stat.st_mtime, stat.st_size, value)
    return value


def build_manifest(packs_dir: str) -> dict:
    metas = []
    if os.path.isdir(packs_dir):
        for name in sorted(os.listdir(packs_dir)):
            if not name.endswith(".meta.json"):
                continue
            meta_path = os.path.join(packs_dir, name)
            zip_path = meta_path[: -len(".meta.json")] + ".zip"
            if not os.path.isfile(zip_path):
                print(f"⚠ 跳过 {name}：找不到同名 zip", file=sys.stderr)
                continue
            with open(meta_path, encoding="utf-8") as fh:
                meta = json.load(fh)
            metas.append((meta, zip_path))

    # 同一学期保留多版本：最高版本作为主包，次高作为 previous（回退用）
    by_id: dict[str, list[tuple[dict, str]]] = {}
    for meta, zip_path in metas:
        by_id.setdefault(meta["id"], []).append((meta, zip_path))
    for versions in by_id.values():
        versions.sort(key=lambda item: item[0].get("contentVersion", 1), reverse=True)

    packs = []
    for pack_id, versions in sorted(by_id.items()):
        primary_meta, primary_zip = versions[0]
        entry = {
            "id": pack_id,
            "grade": primary_meta.get("grade", 0),
            "title": primary_meta.get("title", pack_id),
            "contentVersion": primary_meta.get("contentVersion", 1),
            "schemaVersion": primary_meta.get("schemaVersion", CONTENT_SCHEMA_VERSION),
            "sizeBytes": os.path.getsize(primary_zip),
            "sha256": sha256_of(primary_zip),
            "url": "/packs/" + os.path.basename(primary_zip),
        }
        if len(versions) > 1:
            previous_meta, previous_zip = versions[1]
            entry["previous"] = {
                "contentVersion": previous_meta.get("contentVersion", 1),
                "sha256": sha256_of(previous_zip),
                "url": "/packs/" + os.path.basename(previous_zip),
            }
        packs.append(entry)

    return {"contentSchemaVersion": CONTENT_SCHEMA_VERSION, "packs": packs}


def safe_join(root: str, relative: str) -> Optional[str]:
    """把 URL 相对路径限制在 root 下，挡住 ../ 穿越。"""
    root_real = os.path.realpath(root)
    target = os.path.realpath(os.path.join(root_real, relative.lstrip("/")))
    if target != root_real and not target.startswith(root_real + os.sep):
        return None
    return target


class Handler(BaseHTTPRequestHandler):
    server_version = "FollowReadContent/2.0"

    @property
    def packs_dir(self) -> str:
        return self.server.packs_dir  # type: ignore[attr-defined]

    @property
    def media_dir(self) -> str:
        return self.server.media_dir  # type: ignore[attr-defined]

    def log_message(self, fmt: str, *args) -> None:  # noqa: A003
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _send(self, status: int, body: bytes, content_type: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _send_json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self._send(status, body, "application/json; charset=utf-8")

    def _not_found(self) -> None:
        self._send_json(404, {"error": "not found"})

    def _send_file(self, target: str, content_type: Optional[str] = None) -> None:
        size = os.path.getsize(target)
        content_type = content_type or mimetypes.guess_type(target)[0] or "application/octet-stream"
        start, end = 0, size - 1
        status = 200
        range_header = self.headers.get("Range")

        if range_header:
            match = _RANGE_RE.match(range_header.strip())
            if not match:
                self._send_range_error(size)
                return
            raw_start, raw_end = match.groups()
            if raw_start == "" and raw_end == "":
                self._send_range_error(size)
                return
            if raw_start == "":
                # bytes=-N：最后 N 字节
                length = int(raw_end)
                start = max(0, size - length)
                end = size - 1
            else:
                start = int(raw_start)
                end = int(raw_end) if raw_end else size - 1
            if start >= size or end < start:
                self._send_range_error(size)
                return
            end = min(end, size - 1)
            status = 206

        length = end - start + 1
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(length))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Cache-Control", "no-store")
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        if self.command == "HEAD":
            return
        with open(target, "rb") as fh:
            fh.seek(start)
            remaining = length
            while remaining > 0:
                chunk = fh.read(min(1 << 20, remaining))
                if not chunk:
                    break
                self.wfile.write(chunk)
                remaining -= len(chunk)

    def _send_range_error(self, size: int) -> None:
        self.send_response(416)
        self.send_header("Content-Range", f"bytes */{size}")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_HEAD(self) -> None:  # noqa: N802
        self.do_GET()

    def do_GET(self) -> None:  # noqa: N802
        path = unquote(urlparse(self.path).path)

        if path in ("/", "/index.html"):
            manifest = build_manifest(self.packs_dir)
            media_path = os.path.join(self.media_dir, "media.json")
            media_count = "—"
            if os.path.isfile(media_path):
                try:
                    with open(media_path, encoding="utf-8") as fh:
                        media_count = str(len(json.load(fh).get("items", [])))
                except (OSError, ValueError):
                    media_count = "损坏"
            rows = "".join(
                f"<tr><td>{p['id']}</td><td>{p['title']}</td><td>v{p['contentVersion']}</td>"
                f"<td>{p['sizeBytes'] / 1_048_576:.1f} MiB</td><td><a href='{p['url']}'>{p['url']}</a></td></tr>"
                for p in manifest["packs"]
            )
            html = (
                "<!doctype html><meta charset='utf-8'><title>内容服务</title>"
                "<h1>家园内容服务已启动</h1>"
                f"<p><a href='/manifest.json'>/manifest.json</a> · "
                f"<a href='/media.json'>/media.json</a>（媒体 {media_count} 项）</p>"
                "<table border='1' cellpadding='6' style='border-collapse:collapse'>"
                "<tr><th>id</th><th>title</th><th>版本</th><th>大小</th><th>包</th></tr>"
                f"{rows}</table>"
            )
            self._send(200, html.encode("utf-8"), "text/html; charset=utf-8")
            return

        if path == "/manifest.json":
            body = json.dumps(build_manifest(self.packs_dir), ensure_ascii=False, indent=2).encode("utf-8")
            self._send(200, body, "application/json; charset=utf-8")
            return

        if path == "/media.json":
            target = os.path.join(self.media_dir, "media.json")
            if not os.path.isfile(target):
                self._send_json(404, {"error": "media.json not found"})
                return
            self._send_file(target, "application/json; charset=utf-8")
            return

        if path.startswith("/packs/"):
            target = safe_join(self.packs_dir, path[len("/packs/"):])
            if not target or not os.path.isfile(target):
                self._not_found()
                return
            self._send_file(target, "application/zip")
            return

        if path.startswith("/media/files/"):
            target = safe_join(os.path.join(self.media_dir, "files"), path[len("/media/files/"):])
            if not target or not os.path.isfile(target):
                self._not_found()
                return
            self._send_file(target)
            return

        self._not_found()


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address: tuple[str, int], packs_dir: str, media_dir: str):
        super().__init__(address, Handler)
        self.packs_dir = packs_dir
        self.media_dir = media_dir


def local_hints(port: int) -> list[str]:
    hints = [f"http://127.0.0.1:{port}"]
    host = socket.gethostname().split(".")[0]
    hints.append(f"http://{host}.local:{port}")
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            ip = info[4][0]
            if ip.startswith("127."):
                continue
            hints.append(f"http://{ip}:{port}")
    except socket.gaierror:
        pass
    return list(dict.fromkeys(hints))


def main() -> int:
    parser = argparse.ArgumentParser(description="家园局域网内容服务")
    parser.add_argument("--root", default=SERVICE_ROOT, help="content-service 根目录（含 packs/ 与 media/）")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8080)
    args = parser.parse_args()

    root = os.path.abspath(args.root)
    packs_dir = os.path.join(root, "packs")
    media_dir = os.path.join(root, "media")
    if not os.path.isdir(packs_dir):
        print(f"⚠ 学期包目录不存在：{packs_dir}（只提供媒体也能跑）", file=sys.stderr)

    server = Server((args.host, args.port), packs_dir, media_dir)
    print(f"内容服务已启动：{root}")
    print(f"  学期包：{packs_dir}")
    print(f"  媒体库：{media_dir}")
    for hint in local_hints(args.port):
        print(f"  {hint}")
    print("Ctrl+C 停止；App 里填上面的地址（推荐 <host>.local）")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n已停止")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
