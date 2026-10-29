# 内容备注：句型（sentences）与音频

## 数据来源

18 条核心句型（6 单元 × 3 条）取自**沪教牛津（2024 新教材）二年级上册**各单元 Period 1 的教案页文本（原始暂存于旧 `_download/jx/`，现不入库；来源站点：教习网），
与 `grade2.json` 里的单词、单元标题同源，可按单元号对应：

| 单元 | 教案页 | 选用的句型 |
|---|---|---|
| u1 What can you do with your five senses? | `d17635230` | I can see/hear/smell with my … |
| u2 What do you like about your family? | `d17404353` | This is my aunt. / She's young. / They are my cousins. |
| u3 What is your favourite toy? | `d17404356` | This is a robot. / These are balls. / What's your favourite toy? |
| u4 What is around your home? | `d17531571` | This is a pet shop. / We can … in the … |
| u5 What do you like about farms? | `d17531574` | I like cows/sheep. / They all live on the farm. |
| u6 How do people celebrate the Mid-Autumn Festival? | `d17635233` | We eat mooncakes … / I look at the moon … / My cousin and I … |

字段：`id`（`s1`…，与单元 id 拼成 `itemCode = s:u1-s1`）、`en`、`zh`、`pattern`（句型框架，用于「认」环节提示）、`chunks`（词块，用于拖拽排序）、`audio`。

## ⚠️ 音频是 TTS 占位，不是课本原声

`app/Resources/Curriculum/sentences/uN/sM.wav` 由 Windows 本机语音合成（Microsoft Zira, en-US, 22.05 kHz 16-bit mono）生成，
作用是**先让「听整句 / 跟读整句」跑起来**，避免句子环节无音可放。

**换成课本原声时只需替换文件**，文件名和路径保持不变即可，JSON 不用改：

```
sentences/u1/s1.wav   ← 换成 s1.mp3 时，把 grade2.json 里 audio 后缀一起改掉
```

课时原声（原始暂存于旧 `_download/jx_audio/`，即 `listenings`）里包含这些句子，但目前没有按句切分——要切成单句需要 ffmpeg（本机未安装）。
所以优先级建议：**先跑通流程 → 有 ffmpeg 后再批量切句替换**。

## 改内容后要做的两件事

1. `python3 content-service/build/build_resources.py --version <n+1>` 重新出学期包（脚本会校验每个 `audio` 路径都存在）
2. App 里「内容管理」重新下载该学期
