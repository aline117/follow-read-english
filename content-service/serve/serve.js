#!/usr/bin/env node
/**
 * 家园局域网内容服务（content-service 的 Node 版，Windows 也可用）。
 *
 * - 学期包：扫描 `packs/*.meta.json` 生成 `/manifest.json`，提供 `/packs/*.zip`
 * - 媒体库：提供 `/media.json` 与 `/media/files/*`（支持 HTTP Range）
 * - 学习备份：`PUT /backup/<deviceID>/<name>.json` 上传、`GET /backup/index.json` 索引、
 *   `GET /backup/file/<deviceID>/<name>` 下载（每设备滚动保留 30 份）
 * - 只绑内网、不做端口映射（备份写入只发生在局域网内）
 *
 * 目录约定（content-service 根目录）：
 *   packs/            学期包 zip + meta
 *   media/media.json  媒体清单
 *   media/files/...   儿歌 / 绘本 mp4
 *   backups/<deviceID>/*.json   App 上传的学习备份（不进 git）
 *
 * 用法：
 *   node content-service/serve/serve.js
 *   node content-service/serve/serve.js --port 9000
 *   node content-service/serve/serve.js --root /path/to/content-service
 */

const http = require('node:http');
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const path = require('node:path');
const crypto = require('node:crypto');
const os = require('node:os');

const SERVICE_ROOT = path.dirname(__dirname);
const CONTENT_SCHEMA_VERSION = 2; // 与 App 内 ContentSchema.supported 对齐

const BACKUP_KEEP_PER_DEVICE = 30;
const BACKUP_MAX_BYTES = 64 * 1024 * 1024; // 学习备份正常 <2 MB，64 MB 只是防呆上限
// 路径参数白名单：deviceID 与文件名都不含 `/`、`.`（扩展名单独拼接）
const SEGMENT_RE = /^[A-Za-z0-9-]{1,64}$/;
const BACKUP_NAME_RE = /^[A-Za-z0-9-]{1,64}$/;

const MIME = {
  '.json': 'application/json; charset=utf-8',
  '.zip': 'application/zip',
  '.mp4': 'video/mp4',
  '.mov': 'video/quicktime',
  '.m4a': 'audio/mp4',
  '.mp3': 'audio/mpeg',
};

function parseArgs(argv) {
  const args = { root: SERVICE_ROOT, host: '0.0.0.0', port: 8080 };
  for (let i = 0; i < argv.length; i += 1) {
    const key = argv[i];
    if (key === '--root') args.root = path.resolve(argv[++i]);
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
  if (!fs.existsSync(packsDir)) return { contentSchemaVersion: CONTENT_SCHEMA_VERSION, packs: [] };
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
    const versions = byId
      .get(packId)
      .sort((a, b) => (b.meta.contentVersion || 1) - (a.meta.contentVersion || 1));
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
    if (primary.meta.changelog) entry.changelog = String(primary.meta.changelog);
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

function mediaCount(mediaDir) {
  const file = path.join(mediaDir, 'media.json');
  if (!fs.existsSync(file)) return '—';
  try {
    return String((JSON.parse(fs.readFileSync(file, 'utf8')).items || []).length);
  } catch {
    return '损坏';
  }
}

function indexHtml(manifest, media) {
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
    "<p><a href='/manifest.json'>/manifest.json</a> · " +
    `<a href='/media.json'>/media.json</a>（媒体 ${media} 项）` +
    "<p><a href='/backup/index.json'>/backup/index.json</a>（学习备份索引）</p>" +
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

function sendJson(res, status, payload) {
  send(res, status, JSON.stringify(payload), 'application/json; charset=utf-8');
}

function safeJoin(root, relative) {
  const rootReal = fs.realpathSync(root);
  const target = path.resolve(rootReal, relative.replace(/^\/+/, ''));
  if (target !== rootReal && !target.startsWith(rootReal + path.sep)) return null;
  return target;
}

function parseRange(header, size) {
  const match = /^bytes=(\d*)-(\d*)$/.exec(header.trim());
  if (!match || (!match[1] && !match[2])) return null;
  let start;
  let end;
  if (!match[1]) {
    const suffix = Number(match[2]);
    start = Math.max(0, size - suffix);
    end = size - 1;
  } else {
    start = Number(match[1]);
    end = match[2] ? Number(match[2]) : size - 1;
  }
  if (start >= size || end < start) return null;
  return { start, end: Math.min(end, size - 1) };
}

function sendFile(req, res, target, contentType) {
  const stat = fs.statSync(target);
  const type = contentType || MIME[path.extname(target).toLowerCase()] || 'application/octet-stream';
  const range = req.headers.range ? parseRange(req.headers.range, stat.size) : null;

  if (req.headers.range && !range) {
    res.writeHead(416, {
      'Content-Range': `bytes */${stat.size}`,
      'Content-Length': '0',
    });
    res.end();
    return;
  }

  const start = range ? range.start : 0;
  const end = range ? range.end : stat.size - 1;
  const headers = {
    'Content-Type': type,
    'Content-Length': String(end - start + 1),
    'Accept-Ranges': 'bytes',
    'Cache-Control': 'no-store',
  };
  if (range) headers['Content-Range'] = `bytes ${start}-${end}/${stat.size}`;
  res.writeHead(range ? 206 : 200, headers);
  if (req.method === 'HEAD') {
    res.end();
    return;
  }
  fs.createReadStream(target, { start, end })
    .on('error', () => res.destroy())
    .pipe(res);
}

// —— 学习备份 ——

function backupsRoot(root) {
  return path.join(root, 'backups');
}

function deviceDirOf(root, deviceID) {
  if (!SEGMENT_RE.test(deviceID)) return null;
  const dir = path.join(backupsRoot(root), deviceID);
  const rootReal = fs.existsSync(backupsRoot(root))
    ? fs.realpathSync(backupsRoot(root))
    : backupsRoot(root);
  const resolved = path.resolve(dir);
  if (resolved !== path.join(rootReal, deviceID)) return null;
  return resolved;
}

function backupFileName(name) {
  const base = name.endsWith('.json') ? name.slice(0, -'.json'.length) : name;
  if (!BACKUP_NAME_RE.test(base)) return null;
  return base + '.json';
}

function readBody(req, limit) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > limit) {
        reject(Object.assign(new Error('payload too large'), { status: 413 }));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('error', reject);
    req.on('end', () => resolve(Buffer.concat(chunks)));
  });
}

async function listBackups(root) {
  const dir = backupsRoot(root);
  if (!fs.existsSync(dir)) return [];
  const devices = (await fsp.readdir(dir, { withFileTypes: true }))
    .filter((entry) => entry.isDirectory() && SEGMENT_RE.test(entry.name))
    .map((entry) => entry.name)
    .sort();

  const out = [];
  for (const deviceID of devices) {
    const deviceDir = path.join(dir, deviceID);
    const names = (await fsp.readdir(deviceDir))
      .filter((name) => name.endsWith('.json') && backupFileName(name) === name)
      .sort()
      .reverse(); // 文件名以时间戳开头，倒序即最新在前
    for (const name of names) {
      const file = path.join(deviceDir, name);
      const stat = await fsp.stat(file);
      if (!stat.isFile()) continue;
      out.push({
        deviceID,
        name,
        bytes: stat.size,
        modifiedAt: new Date(stat.mtimeMs).toISOString(),
        sha256: await sha256Of(file),
      });
    }
  }
  return out;
}

/** 超出保留份数时按文件名（时间戳）删最旧；返回删掉的文件名 */
async function pruneBackups(deviceDir) {
  const names = (await fsp.readdir(deviceDir))
    .filter((name) => name.endsWith('.json') && backupFileName(name) === name)
    .sort()
    .reverse();
  const removed = [];
  for (const name of names.slice(BACKUP_KEEP_PER_DEVICE)) {
    await fsp.unlink(path.join(deviceDir, name)).catch(() => {});
    shaCache.delete(path.join(deviceDir, name));
    removed.push(name);
  }
  return removed;
}

async function saveBackup(root, deviceID, name, body, declaredSha) {
  const deviceDir = deviceDirOf(root, deviceID);
  const fileName = backupFileName(name);
  if (!deviceDir || !fileName) {
    throw Object.assign(new Error('bad path'), { status: 400 });
  }

  const actual = crypto.createHash('sha256').update(body).digest('hex');
  const declared = String(declaredSha || '').trim().toLowerCase();
  // 校验和不符说明传输中出了问题，宁可让 App 重传也不要落一份坏备份
  if (declared && declared !== actual) {
    throw Object.assign(new Error('sha256 mismatch'), {
      status: 400,
      detail: { declared, actual },
    });
  }

  try {
    JSON.parse(body.toString('utf8'));
  } catch {
    throw Object.assign(new Error('body is not valid JSON'), { status: 400 });
  }

  await fsp.mkdir(deviceDir, { recursive: true });
  // 临时文件放同目录，rename 才是原子的（跨盘 rename 会退化成拷贝）
  const temp = path.join(deviceDir, `.${fileName}.${process.pid}-${Date.now()}.tmp`);
  await fsp.writeFile(temp, body);
  await fsp.rename(temp, path.join(deviceDir, fileName));
  shaCache.delete(path.join(deviceDir, fileName));

  const removed = await pruneBackups(deviceDir);
  return { deviceID, name: fileName, bytes: body.length, sha256: actual, removed };
}

async function handleBackup(req, res, root, pathname) {
  if (pathname === '/backup/index.json') {
    if (req.method !== 'GET' && req.method !== 'HEAD') {
      sendJson(res, 405, { error: 'method not allowed' });
      return;
    }
    const items = await listBackups(root);
    sendJson(res, 200, {
      backupFormatVersion: 1,
      keepPerDevice: BACKUP_KEEP_PER_DEVICE,
      items,
    });
    return;
  }

  if (pathname.startsWith('/backup/file/')) {
    const rest = pathname.slice('/backup/file/'.length).split('/');
    if (rest.length !== 2) {
      sendJson(res, 400, { error: 'bad path' });
      return;
    }
    const [deviceID, rawName] = rest;
    const deviceDir = deviceDirOf(root, deviceID);
    const fileName = backupFileName(rawName);
    if (!deviceDir || !fileName) {
      sendJson(res, 400, { error: 'bad path' });
      return;
    }
    const target = path.join(deviceDir, fileName);
    if (!fs.existsSync(target) || !fs.statSync(target).isFile()) {
      sendJson(res, 404, { error: 'not found' });
      return;
    }
    sendFile(req, res, target, 'application/json; charset=utf-8');
    return;
  }

  // PUT /backup/<deviceID>/<name>.json
  if (pathname.startsWith('/backup/')) {
    if (req.method !== 'PUT') {
      sendJson(res, 405, { error: 'method not allowed' });
      return;
    }
    const rest = pathname.slice('/backup/'.length).split('/');
    if (rest.length !== 2) {
      sendJson(res, 400, { error: 'bad path' });
      return;
    }
    const [deviceID, name] = rest;
    let body;
    try {
      body = await readBody(req, BACKUP_MAX_BYTES);
    } catch (error) {
      sendJson(res, error.status || 400, { error: String(error.message || error) });
      return;
    }
    try {
      const result = await saveBackup(root, deviceID, name, body, req.headers['x-backup-sha256']);
      sendJson(res, 200, { ok: true, ...result });
    } catch (error) {
      sendJson(res, error.status || 500, { error: String(error.message || error), ...(error.detail || {}) });
    }
    return;
  }

  sendJson(res, 404, { error: 'not found' });
}

async function handle(req, res, root) {
  const packsDir = path.join(root, 'packs');
  const mediaDir = path.join(root, 'media');
  const url = new URL(req.url, 'http://localhost');
  const pathname = decodeURIComponent(url.pathname);

  // 备份三件套（PUT 上传 / index / 下载）：独立处理，写完即返回
  if (pathname === '/backup' || pathname === '/backup/' || pathname.startsWith('/backup/')) {
    await handleBackup(req, res, root, pathname);
    return;
  }

  // 内容分发是只读语义，其余路径一律只允许读
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    res.writeHead(405, { Allow: 'GET, HEAD' });
    res.end();
    return;
  }

  if (pathname === '/' || pathname === '/index.html') {
    const manifest = await buildManifest(packsDir);
    send(res, 200, indexHtml(manifest, mediaCount(mediaDir)), 'text/html; charset=utf-8');
    return;
  }

  if (pathname === '/manifest.json') {
    const manifest = await buildManifest(packsDir);
    send(res, 200, JSON.stringify(manifest, null, 2), 'application/json; charset=utf-8');
    return;
  }

  if (pathname === '/media.json') {
    const target = path.join(mediaDir, 'media.json');
    if (!fs.existsSync(target)) {
      sendJson(res, 404, { error: 'media.json not found' });
      return;
    }
    sendFile(req, res, target, 'application/json; charset=utf-8');
    return;
  }

  if (pathname.startsWith('/packs/')) {
    if (!fs.existsSync(packsDir)) {
      sendJson(res, 404, { error: 'not found' });
      return;
    }
    const target = safeJoin(packsDir, pathname.slice('/packs/'.length));
    if (!target || !fs.existsSync(target) || !fs.statSync(target).isFile()) {
      sendJson(res, 404, { error: 'not found' });
      return;
    }
    sendFile(req, res, target, 'application/zip');
    return;
  }

  if (pathname.startsWith('/media/files/')) {
    const filesDir = path.join(mediaDir, 'files');
    if (!fs.existsSync(filesDir)) {
      sendJson(res, 404, { error: 'not found' });
      return;
    }
    const target = safeJoin(filesDir, pathname.slice('/media/files/'.length));
    if (!target || !fs.existsSync(target) || !fs.statSync(target).isFile()) {
      sendJson(res, 404, { error: 'not found' });
      return;
    }
    sendFile(req, res, target);
    return;
  }

  sendJson(res, 404, { error: 'not found' });
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const packsDir = path.join(args.root, 'packs');
  if (!fs.existsSync(packsDir)) {
    console.warn(`⚠ 学期包目录不存在：${packsDir}（只提供媒体也能跑）`);
  }

  const server = http.createServer((req, res) => {
    handle(req, res, args.root).catch((error) => {
      console.error(error);
      sendJson(res, 500, { error: String(error) });
    });
  });

  server.listen(args.port, args.host, () => {
    console.log(`内容服务已启动：${args.root}`);
    console.log(`  学期包：${packsDir}`);
    console.log(`  媒体库：${path.join(args.root, 'media')}`);
    console.log(`  学习备份：${path.join(args.root, 'backups')}（每设备保留 ${BACKUP_KEEP_PER_DEVICE} 份）`);
    console.log(`  http://127.0.0.1:${args.port}`);
    console.log(`  http://${os.hostname().split('.')[0]}.local:${args.port}`);
    console.log('Ctrl+C 停止；App 里填上面的地址（推荐 <host>.local）');
  });
}

main();
