#!/usr/bin/env node
// 扫描媒体目录，产出 media.json（媒体清单）。
//
// 目录约定（媒体素材不进仓库，放在仓库外或 gitignore 的目录）：
//   <media>/files/songs/<any>.mp4      儿歌
//   <media>/files/picture/<any>.mp4    绘本跟读
//   <media>/ids.json                   可选：{ "<相对路径>": "m:自定义id" } 覆盖自动 id
//
// 用法：
//   node content-service/build/build-media-manifest.mjs --media content-service/media --out content-service/media/media.json --version 1
//
// 说明：
// - durationSec 默认写 0（App 首次播放会回填实测时长，见 services/MediaStateStore）
// - streamable 由同目录的 check-faststart.mjs 判定
// - lines 默认空；重扫时**保留**已有清单里同 id、同 sha256 的跟读句（10.7 的 82 首标注不能因为
//   重扫一次就全丢）。文件内容变了（sha256 不同）才丢弃那一条，并在输出里点名，提醒重新标注。

import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { isStreamable } from './check-faststart.mjs';

function parseArgs(argv) {
  const args = { media: '', out: '', version: 1, part: 0 };
  for (let i = 2; i < argv.length; i += 1) {
    const key = argv[i];
    const value = argv[i + 1];
    if (key === '--media') { args.media = value; i += 1; }
    else if (key === '--out') { args.out = value; i += 1; }
    else if (key === '--version') { args.version = Number(value); i += 1; }
    else if (key === '--part') { args.part = Number(value); i += 1; }
  }
  return args;
}

function slug(name) {
  const cleaned = name
    .normalize('NFKD')
    .replace(/[^\w\s-]/g, '')
    .trim()
    .replace(/\s+/g, '-')
    .toLowerCase();
  return cleaned || 'item';
}

function sha256File(file) {
  return new Promise((resolve, reject) => {
    const hash = crypto.createHash('sha256');
    const stream = fs.createReadStream(file);
    stream.on('data', (chunk) => hash.update(chunk));
    stream.on('end', () => resolve(hash.digest('hex')));
    stream.on('error', reject);
  });
}

function listVideos(dir) {
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir, { withFileTypes: true })
    .filter((entry) => entry.isFile() && /\.(mp4|m4v)$/i.test(entry.name))
    .map((entry) => path.join(dir, entry.name));
}

const args = parseArgs(process.argv);
if (!args.media || !args.out) {
  console.error('用法: node content-service/build/build-media-manifest.mjs --media <媒体目录> --out <media.json> [--version N] [--part N]');
  process.exit(1);
}

// 目标路径落在仓库内就报错退出（素材与产物都不进 git）
const scriptDir = path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1'));
const repoRoot = path.resolve(scriptDir, '..', '..');
const allowedRoot = path.resolve(scriptDir, '..', 'media');
const outResolved = path.resolve(args.out);
const insideRepo = outResolved === repoRoot || outResolved.startsWith(repoRoot + path.sep);
const insideMediaDir = outResolved === allowedRoot || outResolved.startsWith(allowedRoot + path.sep);
if (insideRepo && !insideMediaDir) {
  console.error(`拒绝写入仓库内的路径：${outResolved}\n请放到 content-service/media/ 下，或换到仓库外。`);
  process.exit(3);
}

const overridesPath = path.join(args.media, 'ids.json');
const overrides = fs.existsSync(overridesPath)
  ? JSON.parse(fs.readFileSync(overridesPath, 'utf8'))
  : {};

// 上一次的清单：用来保住已标注的跟读句（lines）
function loadPrevious(file) {
  try {
    const parsed = JSON.parse(fs.readFileSync(file, 'utf8'));
    const map = new Map();
    for (const item of parsed.items ?? []) map.set(item.id, item);
    return map;
  } catch {
    return new Map();
  }
}

const previousItems = loadPrevious(outResolved);
let keptLineCount = 0;
const droppedLines = [];

const items = [];
const groups = [
  { dir: path.join(args.media, 'files', 'songs'), kind: 'song', prefix: 'm:song-' },
  { dir: path.join(args.media, 'files', 'picture'), kind: 'picture', prefix: 'm:pb-' },
];

for (const group of groups) {
  for (const file of listVideos(group.dir)) {
    const relToMedia = path.relative(args.media, file).split(path.sep).join('/');
    const base = path.basename(file, path.extname(file));
    const id = overrides[relToMedia] ?? `${group.prefix}${slug(base)}`;
    const stat = fs.statSync(file);
    const digest = await sha256File(file);
    const { streamable } = isStreamable(file);
    const previous = previousItems.get(id);
    const previousLines = previous?.lines ?? [];
    // 文件换了，旧的时间轴就不可信了：宁可空着让孩子端显示「待标注」，也别对着错位的秒数跟读
    const keepLines = previous?.sha256 === digest ? previousLines : [];
    if (keepLines.length > 0) keptLineCount += keepLines.length;
    if (previous && previousLines.length > 0 && previous.sha256 !== digest) {
      droppedLines.push(id);
    }
    items.push({
      id,
      title: base,
      kind: group.kind,
      part: Number(overrides[`${relToMedia}#part`] ?? args.part ?? 0),
      durationSec: 0,
      bytes: stat.size,
      sha256: digest,
      relPath: relToMedia,
      streamable,
      lines: keepLines,
    });
    console.log(`${streamable ? '✓' : '✗'} ${id}  ${(stat.size / 1048576).toFixed(1)} MB`);
  }
}

const seen = new Set();
for (const item of items) {
  if (seen.has(item.id)) {
    console.error(`id 重复：${item.id}（用 ${overridesPath} 覆盖）`);
    process.exit(4);
  }
  seen.add(item.id);
}

const manifest = {
  mediaSchemaVersion: 1,
  contentVersion: args.version,
  generatedAt: new Date().toISOString(),
  items,
};

fs.mkdirSync(path.dirname(outResolved), { recursive: true });
fs.writeFileSync(outResolved, `${JSON.stringify(manifest, null, 2)}\n`, 'utf8');

const totalBytes = items.reduce((sum, item) => sum + item.bytes, 0);
const notStreamable = items.filter((item) => !item.streamable).length;
console.log(`\n共 ${items.length} 项 · ${(totalBytes / 1073741824).toFixed(2)} GB · 不能秒开 ${notStreamable} 项`);
if (keptLineCount > 0) console.log(`保留已标注的跟读句 ${keptLineCount} 条`);
if (droppedLines.length > 0) {
  console.warn(`这些文件内容变了，旧跟读句已丢弃，需要重新标注：${droppedLines.join('、')}`);
}
console.log(`已写入 ${outResolved}`);
