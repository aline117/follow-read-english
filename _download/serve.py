#!/usr/bin/env python3
"""家园局域网内容服务（tasks 7.5 的 Python 版，本机可直接跑）。

- 静态服务 `packs/` 下的学期包
- 扫描 `packs/*.meta.json`（由 build_resources.py 产出）生成 `manifest.json`
- 只绑内网、只读、不做端口映射；iPad 侧只需要 HTTP GET

用法：
    python3 _download/serve.py                 # 0.0.0.0:8080
    python3 _download/serve.py --port 9000

Windows 上如果装了 Node，用 serve.js + serve.bat；两者 manifest 结构一致。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import socket
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlparse

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# App 支持的内容结构版本上限（与 App 内 ContentSchema.supported 对齐）
CONTENT_SCHEMA_VERSION = 2

_sha_cache: dict[str, tuple[float, int, str]] = {}
_cache_lock = threading.Lock()


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


class Handler(BaseHTTPRequestHandler):
    server_version = "FollowReadContent/1.0"

    @property
    def packs_dir(self) -> str:
        return self.server.packs_dir  # type: ignore[attr-defined]

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

    def do_HEAD(self) -> None:  # noqa: N802
        self.do_GET()

    def do_GET(self) -> None:  # noqa: N802
        path = unquote(urlparse(self.path).path)

        if path in ("/", "/index.html"):
            manifest = build_manifest(self.packs_dir)
            rows = "".join(
                f"<tr><td>{p['id']}</td><td>{p['title']}</td><td>v{p['contentVersion']}</td>"
                f"<td>{p['sizeBytes'] / 1_048_576:.1f} MiB</td><td><a href='{p['url']}'>{p['url']}</a></td></tr>"
                for p in manifest["packs"]
            )
            html = (
                "<!doctype html><meta charset='utf-8'><title>内容服务</title>"
                "<h1>家园内容服务已启动</h1>"
                "<p><a href='/manifest.json'>/manifest.json</a></p>"
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

        if path.startswith("/packs/"):
            name = os.path.basename(path)
            target = os.path.join(self.packs_dir, name)
            if not name or not os.path.isfile(target):
                self._send(404, b'{"error":"not found"}', "application/json; charset=utf-8")
                return
            size = os.path.getsize(target)
            self.send_response(200)
            self.send_header("Content-Type", "application/zip")
            self.send_header("Content-Length", str(size))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            if self.command == "HEAD":
                return
            with open(target, "rb") as fh:
                for chunk in iter(lambda: fh.read(1 << 20), b""):
                    self.wfile.write(chunk)
            return

        self._send(404, b'{"error":"not found"}', "application/json; charset=utf-8")


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address: tuple[str, int], packs_dir: str):
        super().__init__(address, Handler)
        self.packs_dir = packs_dir


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
    parser.add_argument("--root", default=os.path.join(REPO, "_download", "packs"))
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8080)
    args = parser.parse_args()

    if not os.path.isdir(args.root):
        print(f"✗ 学期包目录不存在：{args.root}（先跑 build_resources.py）", file=sys.stderr)
        return 2

    server = Server((args.host, args.port), args.root)
    print(f"内容服务已启动，包目录：{args.root}")
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
