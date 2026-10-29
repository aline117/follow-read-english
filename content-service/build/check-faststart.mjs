#!/usr/bin/env node
// 判断 mp4 的 moov box 是否在文件头部（在头部才能"边下边播/秒开"）。
// 只读文件头 1 MB，不需要 ffprobe。
//
// 用法：
//   node content-service/build/check-faststart.mjs <file> [more files...]
//   import { isStreamable } from './check-faststart.mjs'

import fs from 'node:fs';

const HEAD_BYTES = 1024 * 1024;

/**
 * @param {string} filePath
 * @returns {{ streamable: boolean, found: string[], offset: number }}
 */
export function isStreamable(filePath) {
  const fd = fs.openSync(filePath, 'r');
  try {
    const buffer = Buffer.alloc(HEAD_BYTES);
    const read = fs.readSync(fd, buffer, 0, HEAD_BYTES, 0);
    const head = buffer.subarray(0, read);
    // 顶层 box 结构：4 字节 size + 4 字节 type；先在头部里找 moov / mdat 谁在前
    const boxes = [];
    let offset = 0;
    while (offset + 8 <= head.length) {
      const size = head.readUInt32BE(offset);
      const type = head.toString('ascii', offset + 4, offset + 8);
      if (!/^[a-zA-Z0-9 ]{4}$/.test(type)) break;
      boxes.push({ type, offset, size });
      if (type === 'moov' || type === 'mdat') break;
      if (size < 8) break;
      offset += size;
    }
    const moov = boxes.find((b) => b.type === 'moov');
    const mdat = boxes.find((b) => b.type === 'mdat');
    const streamable = Boolean(moov) && (!mdat || moov.offset < mdat.offset);
    return {
      streamable,
      found: boxes.map((b) => b.type),
      offset: moov ? moov.offset : -1,
    };
  } finally {
    fs.closeSync(fd);
  }
}

if (import.meta.url === `file://${process.argv[1]?.replace(/\\/g, '/')}` ||
    process.argv[1]?.endsWith('check-faststart.mjs')) {
  const files = process.argv.slice(2);
  if (files.length === 0) {
    console.error('用法: node content-service/build/check-faststart.mjs <file> [more files...]');
    process.exit(1);
  }
  let bad = 0;
  for (const file of files) {
    const result = isStreamable(file);
    if (!result.streamable) bad += 1;
    console.log(`${result.streamable ? '✓' : '✗'} ${file}  顶层 boxes=${result.found.join(',')} moov@${result.offset}`);
  }
  console.log(`\n合计 ${files.length} 个，不能秒开 ${bad} 个`);
  process.exit(bad === 0 ? 0 : 2);
}
