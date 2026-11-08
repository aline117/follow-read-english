#!/usr/bin/env python3
"""儿歌「可跟读句」的标注工作表、校验与合并（tasks 10.7）。

为什么需要它：

- 82 首儿歌要各标 2–3 句（文本 + 起止秒）。这件事只能人来听——机器切不出「这一句孩子跟得上」，
  但机器能守住四条硬线：**句数、时段合法、不重叠、不把 `la la la` 当句子**。
- 标错了 App 侧不会报错，只会让孩子跟着一段哼唱或半句话读，评测一路挂——所以宁可在入库前拦住。
- 手改 `media.json` 风险高：文件 246 项、几千行，改坏一个逗号整包内容就「损坏」。

所以拆成三件小事：

    # 1) 生成工作表（82 首，边听边记）
    python content-service/build/song-lines.py --worksheet docs/song-lines-worksheet.md

    # 2) 生成待填 JSON 骨架（想直接填 JSON 就用这个，比 md 好合并）
    python content-service/build/song-lines.py --draft song-lines-draft.json

    # 3) 填完合并回 media.json（先校验，全过才写；写前自动备份 + 原子替换）
    python content-service/build/song-lines.py --apply song-lines-draft.json

    # 随时看进度
    python content-service/build/song-lines.py --status

    # 只校验现有 media.json 的标注质量（入库前 / 改完再跑一次）
    python content-service/build/song-lines.py --check

判定规则（`--check` 与 `--apply` 共用同一套）：

- 每首儿歌 2–3 句，`index` 从 0 连续；
- 文本 2–80 字符、1–10 个词、至少含 2 个字母，去重后不得重复；
- 起止秒齐全，单句 1.0–8.0 秒（太短跟不完、太长记不住）；
- 按开始时间升序、彼此不重叠；`durationSec > 0` 时不得超出结尾；
- 整句都是拟声/哼唱词（la / na / oh / yeah / hmm…）判不合格；
- 同一个词连着出现 3 次以上（疑似 `la la la` 段）判不合格。

退出码：0 = 通过；1 = 有不合格项（逐条列出）；2 = 参数/环境错误。
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
import tempfile
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_MEDIA = ROOT / "content-service" / "media" / "media.json"

MIN_LINES = 2
MAX_LINES = 3
MIN_SEC = 1.0
MAX_SEC = 8.0
MAX_WORDS = 10

# 整句都是这些词 → 是哼唱/语气词，不是可跟读的句子
FILLER_TOKENS = {
    "la", "laa", "na", "da", "doo", "dum", "boom", "oh", "ooh", "ah", "aah",
    "yeah", "yea", "hmm", "mmm", "mm", "hey", "shh", "wo", "woo", "ha", "haha",
    "sha", "bop", "beep", "wow", "yay", "uh", "eh",
}

WORD_RE = re.compile(r"[A-Za-z][A-Za-z'’\-]*")


# ---------------------------------------------------------------- 读取与定位


def load_media(path: Path) -> dict:
    try:
        with path.open(encoding="utf-8") as fh:
            data = json.load(fh)
    except FileNotFoundError:
        print(f"找不到媒体清单：{path}", file=sys.stderr)
        raise SystemExit(2)
    except json.JSONDecodeError as exc:
        print(f"媒体清单不是合法 JSON：{path}\n  {exc}", file=sys.stderr)
        raise SystemExit(2)
    if not isinstance(data.get("items"), list):
        print(f"媒体清单缺少 items 数组：{path}", file=sys.stderr)
        raise SystemExit(2)
    return data


def songs(data: dict) -> list[dict]:
    return [item for item in data["items"] if item.get("kind") == "song"]


# ---------------------------------------------------------------- 校验


def validate_lines(lines) -> list[str]:
    """返回问题列表（空 = 合格）。纯函数，`--check` 与 `--apply` 共用。"""
    problems: list[str] = []
    if not isinstance(lines, list):
        return ["lines 不是数组"]
    if not (MIN_LINES <= len(lines) <= MAX_LINES):
        problems.append(f"需要 {MIN_LINES}–{MAX_LINES} 句，实际 {len(lines)} 句")

    previous_end = -1.0
    seen_texts: set[str] = set()
    for position, line in enumerate(lines):
        tag = f"第 {position + 1} 句"
        if not isinstance(line, dict):
            problems.append(f"{tag}：不是对象")
            continue

        index = line.get("index")
        if index != position:
            problems.append(f"{tag}：index 应为 {position}，实际 {index}")

        text = (line.get("text") or "").strip()
        if not text:
            problems.append(f"{tag}：文本为空")
        else:
            words = WORD_RE.findall(text)
            if len(words) < 2:
                problems.append(f"{tag}：至少要 2 个词（现在是「{text}」）")
            if len(words) > MAX_WORDS:
                problems.append(f"{tag}：超过 {MAX_WORDS} 个词，孩子记不住")
            if len(text) > 80:
                problems.append(f"{tag}：超过 80 字符")
            lowered = [w.lower() for w in words]
            if lowered and all(w in FILLER_TOKENS for w in lowered):
                problems.append(f"{tag}：整句是哼唱/语气词（「{text}」），不能当跟读句")
            run = 1
            for prev, cur in zip(lowered, lowered[1:]):
                run = run + 1 if cur == prev else 1
                if run >= 3:
                    problems.append(f"{tag}：疑似 `la la la` 段（「{text}」）")
                    break
            normalized = " ".join(lowered)
            if normalized in seen_texts:
                problems.append(f"{tag}：与前面的句子重复")
            seen_texts.add(normalized)

        start, end = line.get("startSec"), line.get("endSec")
        if not isinstance(start, (int, float)) or not isinstance(end, (int, float)):
            problems.append(f"{tag}：起止秒必须是数字")
            continue
        if start < 0 or end < 0:
            problems.append(f"{tag}：起止秒不能为负")
            continue
        if end <= start:
            problems.append(f"{tag}：结束时间要大于开始时间")
            continue
        length = end - start
        if length < MIN_SEC:
            problems.append(f"{tag}：只 {length:.1f} 秒，短于 {MIN_SEC} 秒跟不完")
        if length > MAX_SEC:
            problems.append(f"{tag}：{length:.1f} 秒，长于 {MAX_SEC} 秒记不住")
        if start < previous_end - 0.05:
            problems.append(f"{tag}：与上一句时间重叠")
        previous_end = max(previous_end, end)

    return problems


def check_duration(item: dict, problems: list[str]) -> None:
    duration = item.get("durationSec") or 0
    if duration <= 0:
        return
    for line in item.get("lines") or []:
        end = line.get("endSec")
        if isinstance(end, (int, float)) and end > duration + 0.5:
            problems.append(
                f"第 {(line.get('index') or 0) + 1} 句：结束 {end:.1f}s 超出时长 {duration:.1f}s"
            )


def check_all(data: dict, only: list[str] | None = None) -> int:
    """校验所有（或指定）儿歌，返回不合格首数。"""
    bad = 0
    for item in songs(data):
        if only is not None and item["id"] not in only:
            continue
        problems = validate_lines(item.get("lines") or [])
        check_duration(item, problems)
        if problems:
            bad += 1
            print(f"✗ {item['id']}  {item.get('title', '')}")
            for problem in problems:
                print(f"    - {problem}")
    return bad


# ---------------------------------------------------------------- 工作表 / 骨架


def write_worksheet(data: dict, out: Path) -> None:
    items = songs(data)
    done = sum(1 for item in items if len(item.get("lines") or []) >= MIN_LINES)
    lines = [
        "# 儿歌跟读句标注工作表",
        "",
        f"> 由 `content-service/build/song-lines.py --worksheet` 从 `media.json` 生成（{datetime.now():%Y-%m-%d %H:%M}）。",
        "> **重新生成会覆盖本文件**：填写结果请另存为 `song-lines-draft.json`，再用 `--apply` 合并。",
        "",
        f"进度：已标注 **{done} / {len(items)}** 首。",
        "",
        "标注口径（tasks 10.7）：",
        "",
        "- 每首 2–3 句，选副歌里**完整、说得清**的句子；避开 `la la la`、拟声词、说唱段；",
        "- 一句 1–8 秒：太短孩子跟不上，太长记不住；",
        "- 起止秒记 **开始** 与 **结束**（秒，可带一位小数），句与句不要重叠；",
        "- 判断标准是「孩子听完能重复出来」，不是「唱得好听」。",
        "",
        "---",
        "",
    ]
    for number, item in enumerate(items, start=1):
        lines.append(f"## {number}. {item.get('title', '')}")
        lines.append("")
        lines.append(f"- id：`{item['id']}`")
        lines.append(f"- 文件：`{item.get('relPath', '')}`")
        for slot in range(MAX_LINES):
            lines.append(f"- 第 {slot + 1} 句：____________________ ｜ 起 ____ ｜ 止 ____")
        lines.append("")
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"工作表已写入：{out}（{len(items)} 首，已标注 {done} 首）")


def write_draft(data: dict, out: Path) -> None:
    draft = {}
    for item in songs(data):
        existing = item.get("lines") or []
        slots = existing if existing else [
            {"index": slot, "text": "", "startSec": None, "endSec": None}
            for slot in range(MAX_LINES)
        ]
        draft[item["id"]] = [
            {
                "index": line.get("index", slot),
                "text": line.get("text", ""),
                "startSec": line.get("startSec"),
                "endSec": line.get("endSec"),
            }
            for slot, line in enumerate(slots)
        ]
    out.write_text(json.dumps(draft, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"待填骨架已写入：{out}。填完 text / startSec / endSec 后跑 --apply。")


# ---------------------------------------------------------------- 合并


def is_filled(line: dict) -> bool:
    return bool((line.get("text") or "").strip()) and isinstance(
        line.get("startSec"), (int, float)
    ) and isinstance(line.get("endSec"), (int, float))


def atomic_write_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    handle, temp_name = tempfile.mkstemp(prefix=path.name + ".", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as fh:
            json.dump(data, fh, ensure_ascii=False, indent=2)
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(temp_name, path)
    except BaseException:
        Path(temp_name).unlink(missing_ok=True)
        raise


def apply_draft(data: dict, draft_path: Path, media_path: Path) -> int:
    try:
        draft = json.loads(draft_path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        print(f"找不到填写结果：{draft_path}", file=sys.stderr)
        return 2
    except json.JSONDecodeError as exc:
        print(f"填写结果不是合法 JSON：{draft_path}\n  {exc}", file=sys.stderr)
        return 2
    if not isinstance(draft, dict):
        print("填写结果应是 { \"m:song-xxx\": [ ... ] } 形式", file=sys.stderr)
        return 2

    by_id = {item["id"]: item for item in songs(data)}
    unknown = [key for key in draft if key not in by_id]
    if unknown:
        print(f"这些 id 在媒体清单里不存在：{', '.join(unknown[:5])}", file=sys.stderr)
        return 2

    accepted, skipped, rejected = [], [], []
    for item_id, raw_lines in draft.items():
        if not isinstance(raw_lines, list):
            rejected.append((item_id, ["不是数组"]))
            continue
        filled = [line for line in raw_lines if isinstance(line, dict) and is_filled(line)]
        if not filled:
            skipped.append(item_id)
            continue
        normalized = [
            {
                "index": position,
                "text": line["text"].strip(),
                "startSec": round(float(line["startSec"]), 1),
                "endSec": round(float(line["endSec"]), 1),
            }
            for position, line in enumerate(filled)
        ]
        problems = validate_lines(normalized)
        if problems:
            rejected.append((item_id, problems))
            continue
        accepted.append((item_id, normalized))

    if rejected:
        print(f"有 {len(rejected)} 首不合格，本次不写入（改完再跑）：")
        for item_id, problems in rejected:
            print(f"✗ {item_id}")
            for problem in problems:
                print(f"    - {problem}")
        return 1

    if not accepted:
        print(f"没有可写入的条目（未填写 {len(skipped)} 首）。先填 text 与起止秒。")
        return 0

    backup = media_path.with_suffix(
        media_path.suffix + f".bak-{datetime.now():%Y%m%d-%H%M%S}"
    )
    shutil.copy2(media_path, backup)

    for item_id, normalized in accepted:
        by_id[item_id]["lines"] = normalized

    atomic_write_json(media_path, data)

    remaining = [item for item in by_id.values() if len(item.get("lines") or []) < MIN_LINES]
    print(f"已写入 {len(accepted)} 首；仍待标注 {len(remaining)} 首；未填写跳过 {len(skipped)} 首。")
    print(f"原清单备份：{backup.name}")
    if remaining:
        print("待标注：" + "、".join(item["id"] for item in remaining[:8]) +
              (" …" if len(remaining) > 8 else ""))
    print("提示：`media.json` 变了，App 侧要重新生成媒体包索引（见 content-service/README.md）。")
    return 0


def print_status(data: dict) -> int:
    items = songs(data)
    done = [item for item in items if len(item.get("lines") or []) >= MIN_LINES]
    partial = [
        item for item in items
        if 0 < len(item.get("lines") or []) < MIN_LINES
    ]
    print(f"儿歌 {len(items)} 首：已标注 {len(done)} 首，只标了一半 {len(partial)} 首，未标注 {len(items) - len(done) - len(partial)} 首。")
    if partial:
        print("只标了一半：" + "、".join(item["id"] for item in partial))
    return 0


# ---------------------------------------------------------------- 入口


def main() -> int:
    parser = argparse.ArgumentParser(
        description="儿歌跟读句的标注工作表 / 校验 / 合并（tasks 10.7）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--media", default=str(DEFAULT_MEDIA), help="媒体清单路径")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--worksheet", metavar="OUT", help="生成 Markdown 工作表")
    group.add_argument("--draft", metavar="OUT", help="生成待填 JSON 骨架")
    group.add_argument("--apply", metavar="DRAFT", help="把填写结果合并回 media.json")
    group.add_argument("--check", action="store_true", help="校验现有标注")
    group.add_argument("--status", action="store_true", help="只看进度")
    args = parser.parse_args()

    media_path = Path(args.media)
    data = load_media(media_path)

    if args.worksheet:
        write_worksheet(data, Path(args.worksheet))
        return 0
    if args.draft:
        write_draft(data, Path(args.draft))
        return 0
    if args.apply:
        return apply_draft(data, Path(args.apply), media_path)
    if args.status:
        return print_status(data)

    bad = check_all(data)
    total = len(songs(data))
    if bad:
        print(f"\n不合格 {bad} / {total} 首。")
        return 1
    print(f"全部 {total} 首儿歌标注合格。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
