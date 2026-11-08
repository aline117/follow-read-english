#!/usr/bin/env python3
"""家园局域网内容服务（content-service 的 Python 版）。

- 学期包：扫描 `packs/*.meta.json` 生成 `/manifest.json`，提供 `/packs/*.zip`
- 媒体库：提供 `/media.json` 与 `/media/files/*`（支持 HTTP Range）
- 学习备份：`PUT /backup/<deviceID>/<name>.json`、`GET /backup/index.json`、
  `GET /backup/file/<deviceID>/<name>`（每设备滚动保留 30 份）
- 只绑内网、不做端口映射；内容分发只读，备份是唯一的写入口

目录约定（content-service 根目录）：
    packs/            学期包 zip + meta
    media/media.json  媒体清单
    media/files/...   儿歌 / 绘本 mp4
    backups/<deviceID>/*.json   App 上传的学习备份（不进 git）

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
import time
from typing import Optional
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlparse

SERVICE_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# App 支持的内容结构版本上限（与 App 内 ContentSchema.supported 对齐）
CONTENT_SCHEMA_VERSION = 2

# 备份：每设备滚动保留份数与单次请求上限（正常备份 <2 MB，64 MB 只是防呆）
BACKUP_KEEP_PER_DEVICE = 30
BACKUP_MAX_BYTES = 64 * 1024 * 1024
_SEGMENT_RE = re.compile(r"^[A-Za-z0-9-]{1,64}$")

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
        if primary_meta.get("changelog"):
            entry["changelog"] = str(primary_meta["changelog"])
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


# —— 学习备份 ——


def backup_file_name(raw: str) -> Optional[str]:
    """文件名只允许 [A-Za-z0-9-] + 固定 .json 扩展名。"""
    base = raw[: -len(".json")] if raw.endswith(".json") else raw
    if not _SEGMENT_RE.match(base):
        return None
    return base + ".json"


def device_dir_of(backups_dir: str, device_id: str) -> Optional[str]:
    if not _SEGMENT_RE.match(device_id):
        return None
    return os.path.join(backups_dir, device_id)


def list_backups(backups_dir: str) -> list[dict]:
    if not os.path.isdir(backups_dir):
        return []
    items = []
    for device_id in sorted(os.listdir(backups_dir)):
        device_dir = os.path.join(backups_dir, device_id)
        if not os.path.isdir(device_dir) or not _SEGMENT_RE.match(device_id):
            continue
        names = [n for n in os.listdir(device_dir) if backup_file_name(n) == n]
        # 文件名以时间戳开头，倒序即最新在前
        for name in sorted(names, reverse=True):
            path = os.path.join(device_dir, name)
            if not os.path.isfile(path):
                continue
            stat = os.stat(path)
            items.append(
                {
                    "deviceID": device_id,
                    "name": name,
                    "bytes": stat.st_size,
                    "modifiedAt": time.strftime("%Y-%m-%dT%H:%M:%S.", time.gmtime(stat.st_mtime))
                    + f"{int(stat.st_mtime % 1 * 1000):03d}Z",
                    "sha256": sha256_of(path),
                }
            )
    return items


def prune_backups(device_dir: str) -> list[str]:
    names = sorted((n for n in os.listdir(device_dir) if backup_file_name(n) == n), reverse=True)
    removed = []
    for name in names[BACKUP_KEEP_PER_DEVICE:]:
        path = os.path.join(device_dir, name)
        try:
            os.unlink(path)
            removed.append(name)
            with _cache_lock:
                _sha_cache.pop(path, None)
        except OSError:
            pass
    return removed


def save_backup(backups_dir: str, device_id: str, raw_name: str, body: bytes, declared_sha: str):
    """校验 → 临时文件 → 原子 rename。返回 (payload, 状态码)。"""
    device_dir = device_dir_of(backups_dir, device_id)
    file_name = backup_file_name(raw_name)
    if not device_dir or not file_name:
        return {"error": "bad path"}, 400

    actual = hashlib.sha256(body).hexdigest()
    if declared_sha and declared_sha.strip().lower() != actual:
        return {"error": "sha256 mismatch", "declared": declared_sha.strip().lower(), "actual": actual}, 400

    try:
        json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        return {"error": "body is not valid JSON"}, 400

    os.makedirs(device_dir, exist_ok=True)
    # 临时文件放同目录，os.replace 才是原子的
    temp = os.path.join(device_dir, f".{file_name}.{os.getpid()}-{int(time.time() * 1000)}.tmp")
    with open(temp, "wb") as fh:
        fh.write(body)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(temp, os.path.join(device_dir, file_name))
    with _cache_lock:
        _sha_cache.pop(os.path.join(device_dir, file_name), None)

    removed = prune_backups(device_dir)
    return {
        "ok": True,
        "deviceID": device_id,
        "name": file_name,
        "bytes": len(body),
        "sha256": actual,
        "removed": removed,
    }, 200


class Handler(BaseHTTPRequestHandler):
    server_version = "FollowReadContent/2.0"

    @property
    def packs_dir(self) -> str:
        return self.server.packs_dir  # type: ignore[attr-defined]

    @property
    def media_dir(self) -> str:
        return self.server.media_dir  # type: ignore[attr-defined]

    @property
    def backups_dir(self) -> str:
        return self.server.backups_dir  # type: ignore[attr-defined]

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

        if path == "/backup/index.json":
            self._send_json(
                200,
                {
                    "backupFormatVersion": 1,
                    "keepPerDevice": BACKUP_KEEP_PER_DEVICE,
                    "items": list_backups(self.backups_dir),
                },
            )
            return

        if path.startswith("/backup/file/"):
            rest = path[len("/backup/file/"):].split("/")
            if len(rest) != 2:
                self._send_json(400, {"error": "bad path"})
                return
            device_id, raw_name = rest
            file_name = backup_file_name(raw_name)
            device_dir = device_dir_of(self.backups_dir, device_id)
            if not device_dir or not file_name:
                self._send_json(400, {"error": "bad path"})
                return
            target = os.path.join(device_dir, file_name)
            if not os.path.isfile(target):
                self._not_found()
                return
            self._send_file(target, "application/json; charset=utf-8")
            return

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
                "<p><a href='/backup/index.json'>/backup/index.json</a>（学习备份索引）</p>"
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

    def do_PUT(self) -> None:  # noqa: N802
        """唯一写入口：App 上传学习备份（`PUT /backup/<deviceID>/<name>.json`）。"""
        path = unquote(urlparse(self.path).path)
        if not path.startswith("/backup/") or path == "/backup/index.json":
            # 内容分发保持只读语义，别的路径一律不接写
            self._send_json(405, {"error": "method not allowed"})
            return

        rest = path[len("/backup/"):].split("/")
        if len(rest) != 2:
            self._send_json(400, {"error": "bad path"})
            return
        device_id, raw_name = rest

        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            self._send_json(400, {"error": "bad content-length"})
            return
        if length < 0:
            self._send_json(400, {"error": "bad content-length"})
            return
        if length > BACKUP_MAX_BYTES:
            self.close_connection = True
            self._send_json(413, {"error": "payload too large"})
            return

        body = self.rfile.read(length) if length else b""
        payload, status = save_backup(
            self.backups_dir, device_id, raw_name, body, self.headers.get("X-Backup-Sha256", "")
        )
        self._send_json(status, payload)


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address: tuple[str, int], packs_dir: str, media_dir: str, backups_dir: str):
        super().__init__(address, Handler)
        self.packs_dir = packs_dir
        self.media_dir = media_dir
        self.backups_dir = backups_dir


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

    server = Server((args.host, args.port), packs_dir, media_dir, os.path.join(root, "backups"))
    print(f"内容服务已启动：{root}")
    print(f"  学期包：{packs_dir}")
    print(f"  媒体库：{media_dir}")
    print(f"  学习备份：{os.path.join(root, 'backups')}（每设备保留 {BACKUP_KEEP_PER_DEVICE} 份）")
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
