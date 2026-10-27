#!/usr/bin/env node
/**
 * 家园局域网内容服务（tasks 7.5）——Node 版，给家里装 Node 的电脑（含 Windows）用。
 *
 * - 静态服务 `packs/` 下的学期包
 * - 扫描 `packs/*.meta.json`（由 build_resources.py / build_resources.js 产出）生成 `manifest.json`
 * - 只读、只绑内网、不做端口映射
 *
 * 用法：
 *   node serve.js              # 0.0.0.0:8080
 *   node serve.js --port 9000
 *
 * manifest 结构与 serve.py 完全一致，客户端只认结构。
 */

const http = require('node:http');
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const path = require('node:path');
const crypto = require('node:crypto');
const os = require('node:os');

const REPO = path.dirname(__dirname);
const CONTENT_SCHEMA_VERSION = 2; // 与 App 内 ContentSchema.supported 对齐

function parseArgs(argv) {
  const args = { root: path.join(REPO, '_download', 'packs'), host: '0.0.0.0', port: 8080 };
  for (let i = 0; i < argv.length; i += 1) {
    const key = argv[i];
    if (key === '--root') args.root = argv[++i];
    else if (key === '--host') args.host = argv[++i];
    else if (key === '--port') args.port = Number(argv[++i]);
  }
  return args;
}

const shaCache = new Map();

async function sha256Of(file) {
  const stat = await fsp.stat(file);
  const cached = shaCache.get(file);
  if (cached && cached.mtimeMs === stat.mtimeMs && cached.size === stat.size) return cached.value;
  const value = await new Promise((resolve, reject) => {
    const hash = crypto.createHash('sha256');
    const stream = fs.createReadStream(file);
    stream.on('data', (chunk) => hash.update(chunk));
    stream.on('error', reject);
    stream.on('end', () => resolve(hash.digest('hex')));
  });
  shaCache.set(file, { mtimeMs: stat.mtimeMs, size: stat.size, value });
  return value;
}

async function buildManifest(packsDir) {
  const names = (await fsp.readdir(packsDir)).filter((n) => n.endsWith('.meta.json')).sort();
  const entries = [];
  for (const name of names) {
    const metaPath = path.join(packsDir, name);
    const zipPath = metaPath.slice(0, -'.meta.json'.length) + '.zip';
    if (!fs.existsSync(zipPath)) {
      console.warn(`⚠ 跳过 ${name}：找不到同名 zip`);
      continue;
    }
    const meta = JSON.parse(await fsp.readFile(metaPath, 'utf8'));
    entries.push({ meta, zipPath });
  }

  const byId = new Map();
  for (const entry of entries) {
    const list = byId.get(entry.meta.id) || [];
    list.push(entry);
    byId.set(entry.meta.id, list);
  }

  const packs = [];
  for (const packId of [...byId.keys()].sort()) {
    const versions = byId.get(packId).sort((a, b) => (b.meta.contentVersion || 1) - (a.meta.contentVersion || 1));
    const primary = versions[0];
    const stat = await fsp.stat(primary.zipPath);
    const entry = {
      id: packId,
      grade: primary.meta.grade || 0,
      title: primary.meta.title || packId,
      contentVersion: primary.meta.contentVersion || 1,
      schemaVersion: primary.meta.schemaVersion || CONTENT_SCHEMA_VERSION,
      sizeBytes: stat.size,
      sha256: await sha256Of(primary.zipPath),
      url: '/packs/' + path.basename(primary.zipPath),
    };
    if (versions.length > 1) {
      const previous = versions[1];
      entry.previous = {
        contentVersion: previous.meta.contentVersion || 1,
        sha256: await sha256Of(previous.zipPath),
        url: '/packs/' + path.basename(previous.zipPath),
      };
    }
    packs.push(entry);
  }

  return { contentSchemaVersion: CONTENT_SCHEMA_VERSION, packs };
}

function indexHtml(manifest) {
  const rows = manifest.packs
    .map(
      (p) =>
        `<tr><td>${p.id}</td><td>${p.title}</td><td>v${p.contentVersion}</td>` +
        `<td>${(p.sizeBytes / 1048576).toFixed(1)} MiB</td><td><a href="${p.url}">${p.url}</a></td></tr>`,
    )
    .join('');
  return (
    "<!doctype html><meta charset='utf-8'><title>内容服务</title>" +
    '<h1>家园内容服务已启动</h1>' +
    "<p><a href='/manifest.json'>/manifest.json</a></p>" +
    "<table border='1' cellpadding='6' style='border-collapse:collapse'>" +
    '<tr><th>id</th><th>title</th><th>版本</th><th>大小</th><th>包</th></tr>' +
    rows +
    '</table>'
  );
}

function send(res, status, body, contentType) {
  res.writeHead(status, {
    'Content-Type': contentType,
    'Content-Length': Buffer.byteLength(body),
    'Cache-Control': 'no-store',
  });
  res.end(body);
}

async function handle(req, res, packsDir) {
  const url = new URL(req.url, 'http://localhost');
  const pathname = decodeURIComponent(url.pathname);

  if (pathname === '/' || pathname === '/index.html') {
    const manifest = await buildManifest(packsDir);
    send(res, 200, indexHtml(manifest), 'text/html; charset=utf-8');
    return;
  }

  if (pathname === '/manifest.json') {
    const manifest = await buildManifest(packsDir);
    send(res, 200, JSON.stringify(manifest, null, 2), 'application/json; charset=utf-8');
    return;
  }

  if (pathname.startsWith('/packs/')) {
    const name = path.basename(pathname);
    const target = path.join(packsDir, name);
    if (!name || !fs.existsSync(target)) {
      send(res, 404, JSON.stringify({ error: 'not found' }), 'application/json; charset=utf-8');
      return;
    }
    const stat = await fsp.stat(target);
    res.writeHead(200, {
      'Content-Type': 'application/zip',
      'Content-Length': stat.size,
      'Cache-Control': 'no-store',
    });
    if (req.method === 'HEAD') {
      res.end();
      return;
    }
    fs.createReadStream(target)
      .on('error', () => res.destroy())
      .pipe(res);
    return;
  }

  send(res, 404, JSON.stringify({ error: 'not found' }), 'application/json; charset=utf-8');
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!fs.existsSync(args.root)) {
    console.error(`✗ 学期包目录不存在：${args.root}（先跑 build_resources.py）`);
    process.exit(2);
  }

  const server = http.createServer((req, res) => {
    handle(req, res, args.root).catch((error) => {
      console.error(error);
      send(res, 500, JSON.stringify({ error: String(error) }), 'application/json; charset=utf-8');
    });
  });

  server.listen(args.port, args.host, () => {
    console.log(`内容服务已启动，包目录：${args.root}`);
    console.log(`  http://127.0.0.1:${args.port}`);
    console.log(`  http://${os.hostname().split('.')[0]}.local:${args.port}`);
    console.log('Ctrl+C 停止；App 里填上面的地址（推荐 <host>.local）');
  });
}

main();
