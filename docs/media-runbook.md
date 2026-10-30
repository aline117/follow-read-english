# 媒体素材 runbook（听和看）

> 对应任务 10.6。只写流程与命令，不写本机绝对路径——这台电脑上素材放哪、盘符叫什么，都不进仓库。
> 学期包（课本内容）的流程见 [content-service/README.md](../content-service/README.md)。

## 0. 这套流程在做什么

```
素材目录（仓库外）
   │  ① 挑出要用的儿歌 / 绘本，重命名成稳定文件名
   ▼
content-service/media/files/{songs,picture}/*.mp4
   │  ② faststart 体检（moov 在前才能秒开）→ 需要时 remux
   │  ③ build-media-manifest.mjs 扫描 → media/media.json
   ▼
content-service/serve/{serve.py|serve.js}   （iPad 同 Wi-Fi 访问）
   │  ④ curl 自检：media.json / Range 206
   ▼
App「听和看」：入口出现 → 串流播放 → 跟读发星 → 家长端明细
```

约定：

- 逐项串流见上面 ①～④；素材成批导入 + 生成清单可以一条命令跑完（见 §8）。
- `media/` 与 `packs/` 都不进 git（`.gitignore` 已覆盖），要单独备份。
- `media.json` 由脚本生成，**不要手改**；要改标题/id 用 `media/ids.json` 覆盖。
- 素材只放本机；仓库里不出现任何绝对路径。

## 1. 前置条件（本机）

```bash
node --version          # 生成清单、体检 faststart 都用 Node
python3 --version        # 或者用 Node 版服务起服务，二选一
ffmpeg -version          # 只在需要 remux 时用到；不在 PATH 就加 --ffmpeg
```

服务与构建脚本都支持 Python / Node 两条路，选一条即可。

## 2. 放素材

```bash
# 儿歌
content-service/media/files/songs/<id>.mp4
# 绘本（按部/册建子目录）
content-service/media/files/picture/<part>/<id>.mp4
```

命名建议：

- 只用小写字母、数字、短横线；不要空格、中文、括号。
- 同一部绘本的段落用固定前缀 + 两位序号：`part01-01.mp4`、`part01-02.mp4`。
- 文件名就是 App 里的稳定 id 来源（`m:` 由脚本加），改名 = 换 id，旧缓存与观看记录不会跟过去。

## 3. 体检 + 生成清单

```bash
# ① 先看能不能秒开（只读文件头 1 MB，不需要 ffprobe；有不能秒开的返回 2）
node content-service/build/check-faststart.mjs content-service/media/files/songs/*.mp4

# ② 不能秒开的再 remux（无损，-c copy；输出到另一个目录比原地改更安全）
node content-service/build/remux-faststart.mjs \
  --in  content-service/media/files/songs \
  --out content-service/media-remuxed/songs

# ③ 扫描生成 media.json
node content-service/build/build-media-manifest.mjs \
  --media content-service/media \
  --out   content-service/media/media.json \
  --version 1
```

要点：

- `--out` 只能放 `content-service/media/` 或仓库外；仓库内其它位置会被拒绝（退出码 3，任务 10.5 的守卫）。
- `--version` 每次加一；App 按 `mediaSchemaVersion` / 版本判断要不要重拉清单。
- `durationSec` 默认写 0，App 首次播放会回填实测时长（显示优先级：清单 > 回填 > 「未看过」）。
- `lines[]`（可跟读句）留空时，跟读入口会提示「这段还没有可跟读的句子」；补句属于任务 10.7。

## 4. 起服务并自检

```bash
# 任选其一
python3 content-service/serve/serve.py --port 8080
node    content-service/serve/serve.js  --port 8080
./content-service/serve/serve.sh --runtime auto --port 8080
```

启动日志会打印 `http://127.0.0.1:8080`、`http://<host>.local:8080`、`http://192.168.x.x:8080` 三个地址；iPad 用 `<host>.local` 那个。

自检（把 `<host>` 换成日志里的主机名或 IP）：

```bash
# 清单能拉到，且条目数对得上
curl -s http://<host>:8080/media.json | head -c 300
curl -s http://<host>:8080/manifest.json | head -c 300

# 支持 Range：应返回 206 + Content-Range + Accept-Ranges
curl -I http://<host>:8080/media/files/songs/<id>.mp4
curl -H 'Range: bytes=0-1023' -i http://<host>:8080/media/files/songs/<id>.mp4 | head -12

# 越界 Range 应返回 416（App 依赖它判断文件长度不一致）
curl -H 'Range: bytes=99999999999-' -i http://<host>:8080/media/files/songs/<id>.mp4 | head -5
```

## 5. App 侧验收

1. 家长模式 → 内容管理：地址填 `http://<host>.local:8080`，点「连接内容服务」，确认 `media.json` 拉到（条目数 = 本地清单条数）。
2. 孩子端「学习 → 课程列表」底部出现「听和看 · 儿歌与绘本」入口；**没有 `media.json` 时该入口不显示**（这是回滚验证点 17.2）。
3. 打开第一条：应在 8 秒内起播；播放后 5 秒内状态落盘（退出重进位置偏差 ≤ 3 秒）。
4. 家长模式 → 媒体设置 → 「今天看了什么」：今天的条目、累计时长、跟读通过句数都对得上。
5. 断网（保留局域网）再播一次同一段：应走本地缓存，不报外网错误。

## 6. 出问题怎么查

| 现象 | 先看什么 |
|---|---|
| App 里没有「听和看」入口 | `media.json` 是否存在、`mediaSchemaVersion` 是否高于 App 支持上限（会整包置灰并提示更新） |
| 点开一直转圈 | 服务是否在跑；`curl -I` 该文件是否 200；`streamable:false` 的项会先下载再播，看下载进度 |
| 起播要等很久、暂停才出画面 | 该文件 moov 不在头部 → 第 3 步体检 + remux |
| 明明有文件却 404 | 清单里的 `relPath` 与实际目录不一致（多半是改了文件名后没重跑清单） |
| 播放被拦 | 家长端「每日观看上限」（0 = 关闭该区；到上限后当前条可播完，不能开新条目） |
| 家长端看不到明细 | 家长端只展示事实（时长 / 通过 / 一次通过 / 复读），没有分数与排名，属预期 |

## 7. 回滚

- 清单坏了：把上一次的 `media/media.json` 复制回来（建议每次生成前先 `cp media.json media.json.bak-<version>`）。
- 服务端想退回旧清单：`media.json` 里把 `mediaSchemaVersion` 保持不高于 App 上限即可；App 不删本地缓存。
- 素材被替换：`--version` 加一后重新生成，App 会按新清单重新拉；旧缓存由 LRU 自然淘汰。

## 8. 一条命令生成媒体包（素材 → media/files + media.json）

§2～§3 是手工流程（放素材 → 体检 → remux → 生成清单）。素材成批来自某个课程包时，
用 `build-media-pack.py` 一次跑完，它按 design Decision 7 只产出**清单 + 原始文件**，不打包 zip：

```bash
python3 content-service/build/build-media-pack.py \
  --songs   "/素材盘/…/赠品英文儿歌" \
  --picture "/素材盘/…/6.绘本口语跟读6部164节" \
  --version 1
```

产出（默认落在 `content-service/media/`，与 §2～§3 的目录约定完全一致）：

```
media/media.json                     # mediaSchemaVersion / contentVersion / 逐项 sha256 / streamable
media/files/songs/<slug>.mp4         # 儿歌
media/files/picture/b1/<slug>.mp4    # 绘本（每部一个 b1…b6 子目录）
```

要点：

- 递归识别「赠课1 / 赠课2」这类子目录：儿歌铺平（`part` 恒为 0），绘本按子目录分部（`b1…b6`）
- 文件名转 slug（`1.At the Market.mp4` → `files/picture/b1/1-at-the-market.mp4`），`title` 保留原名
- id：儿歌 `m:song-<slug>`、绘本 `m:pb-b1-<slug>`；要自定义就加 `--ids ids.json`
- 复制时就地算 `sha256` 与 faststart（不用再跑一遍 `build-media-manifest.mjs`）；
  已在位的同名同大小文件跳过复制，`--dry-run` 只列计划
- 副本落在 `media/files/`（6.3 GB），源素材可以留在素材盘当原始备份
- 日志会报「不能秒开 N 项」：这批雪梨素材 moov 基本都在文件尾，串流会走「先下后播」；
  要秒开就先按 §3 ② 用 `remux-faststart.mjs` 重排，再指定重排后的目录跑本脚本

自检：

```bash
# 清单能拉到，条目数对得上
curl -s http://<host>:8080/media.json | python -c "import json,sys;m=json.load(sys.stdin);print(len(m['items']),m['mediaSchemaVersion'],m['contentVersion'])"

# 单项可播：200 + Range 206 + 越界 416
curl -sI http://<host>:8080/media/files/songs/baby-shark.mp4 | head -5
curl -H 'Range: bytes=0-1023' -i http://<host>:8080/media/files/songs/baby-shark.mp4 | head -5
```

- 打完后把 `media.json` 和 `media/files/` 一起备份（清单与文件必须成对，单独一份没用）
- 换素材：改完素材再跑一次（`--version` 加一），App 按新清单重拉，旧缓存由 LRU 淘汰
