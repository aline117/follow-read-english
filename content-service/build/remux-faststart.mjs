#!/usr/bin/env node
// 批量把 mp4 的 moov 移到文件头（`-movflags +faststart`），让 App 能"边下边播/秒开"。
// 无损（-c copy），体积基本不变，几十秒可跑完上百个文件。
//
// 用法：
//   node content-service/build/remux-faststart.mjs --in <源目录> --out <目标目录> [--dry-run]
//
// 依赖本机 ffmpeg（默认 D:\bin\ffmpeg\bin\ffmpeg.exe，可用 --ffmpeg 覆盖）

import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { isStreamable } from './check-faststart.mjs';

function parseArgs(argv) {
  const args = { in: '', out: '', ffmpeg: 'D:\\bin\\ffmpeg\\bin\\ffmpeg.exe', dryRun: false };
  for (let i = 2; i < argv.length; i += 1) {
    const key = argv[i];
    if (key === '--in') { args.in = argv[i + 1]; i += 1; }
    else if (key === '--out') { args.out = argv[i + 1]; i += 1; }
    else if (key === '--ffmpeg') { args.ffmpeg = argv[i + 1]; i += 1; }
    else if (key === '--dry-run') { args.dryRun = true; }
  }
  return args;
}

function walk(dir) {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...walk(full));
    else if (/\.(mp4|m4v)$/i.test(entry.name)) out.push(full);
  }
  return out;
}

const args = parseArgs(process.argv);
if (!args.in || !args.out) {
  console.error('用法: node content-service/build/remux-faststart.mjs --in <源目录> --out <目标目录> [--dry-run]');
  process.exit(1);
}
if (!fs.existsSync(args.ffmpeg)) {
  console.error(`找不到 ffmpeg：${args.ffmpeg}\n用 --ffmpeg 指向实际路径。`);
  process.exit(2);
}

const files = walk(args.in);
let remuxed = 0;
let skipped = 0;
let failed = 0;

for (const file of files) {
  const rel = path.relative(args.in, file);
  const target = path.join(args.out, rel);
  if (isStreamable(file).streamable) {
    skipped += 1;
    console.log(`= 已是 faststart，跳过 ${rel}`);
    continue;
  }
  if (args.dryRun) {
    console.log(`→ 需要 remux ${rel}`);
    remuxed += 1;
    continue;
  }
  fs.mkdirSync(path.dirname(target), { recursive: true });
  try {
    execFileSync(args.ffmpeg, ['-y', '-v', 'error', '-i', file,
      '-c', 'copy', '-movflags', '+faststart', target]);
    if (!isStreamable(target).streamable) throw new Error('remux 后 moov 仍不在头部');
    remuxed += 1;
    console.log(`✓ ${rel}`);
  } catch (error) {
    failed += 1;
    console.error(`✗ ${rel}  ${error.message}`);
  }
}

console.log(`\nremux ${remuxed} 个 · 跳过 ${skipped} 个 · 失败 ${failed} 个`);
process.exit(failed === 0 ? 0 : 3);
