# content-service（家园局域网内容服务）

App 里**不带任何课文内容与媒体**：学期包、儿歌、绘本都由这台电脑提供。
这个目录可以单独拷到家里电脑上部署，不依赖仓库里的其它代码（打包脚本除外，它们要读 `app/Resources/Curriculum`）。

```
content-service/
├── serve/
│   ├── serve.py        # Python 3 标准库，Mac/Linux 直接跑
│   ├── serve.js        # Node 版（Windows 也可用）
│   ├── serve.sh        # macOS / Linux 启动（默认 Node，--runtime 切换）
│   ├── serve.command   # macOS 双击入口（调用 serve.sh）
│   └── serve.bat       # Windows 启动（默认 Node，--runtime 切换）
├── build/
│   ├── build_resources.py            # 学期包 → packs/*.zip + meta
│   ├── build-media-pack.py           # 媒体包（儿歌+绘本）→ media/media.json + media/files/
│   ├── build-media-manifest.mjs      # 媒体目录 → media/media.json
│   ├── check-faststart.mjs           # 判断 mp4 能否秒开
│   └── remux-faststart.mjs           # 可选：moov 后置的视频重排
├── packs/              # 学期包 zip + meta（不进 git，需备份）
├── media/              # 媒体包：media.json + files/（不进 git，需备份）
│   ├── media.json      # 媒体清单（App 通过 /media.json 拉取）
│   └── files/          # 儿歌 / 绘本 mp4
└── README.md
```

> 只绑内网、只读、不做端口映射；iPad 与电脑要在同一个 Wi-Fi。

## 1. 部署到家里电脑

最简方式：把整个 `content-service/` 拷到家里电脑（U 盘 / 云盘都行），再准备 `packs/` 与 `media/` 数据。

```bash
# macOS / Linux：默认用 Node
./serve/serve.sh

# 想用 Python：
./serve/serve.sh --runtime python

# 不指定，按机器选择（有 python3 用 Python，否则 Node）
./serve/serve.sh --runtime auto

# macOS 也可以直接在 Finder 里双击 serve/serve.command（默认 Node）
# Linux 可加别名/软链到 ~/bin 之类

# Windows：默认 Node
serve\serve.bat
serve\serve.bat --runtime python
```

`--runtime` 只是启动器的参数，不会传给 `serve.py` / `serve.js`；其余参数原样透传：

```bash
./serve/serve.sh --runtime python --port 9000
./serve/serve.sh --runtime node --root /path/to/content-service
```

两种实现（Python / Node）提供完全相同的接口；默认选 Node 是为了和 Windows 侧、以及 `build/` 里的 Node 工具保持一致。

启动后会打印可用地址（Node 版与 Python 版完全一致）：

```
http://127.0.0.1:8080        ← 电脑本机自测
http://my-mac.local:8080     ← Bonjour 主机名（备选，不受 IP 变化影响）
http://192.168.1.11:8080     ← 局域网 IP，iPad 用这个
```

App 默认已填 `http://192.168.1.11:8080`（家里电脑的固定内网 IP）。**换路由器或 DHCP 重新分配后 IP 会变**：看启动日志里打印的局域网 IP，在 iPad「内容管理」改掉，或改回 `<host>.local`。

## 2. 打开与验证

- `/`：包列表 + 媒体项数
- `/manifest.json`：学期包清单
- `/media.json`：媒体清单
- `/packs/g2s1.zip`：学期包（支持 Range）
- `/media/files/songs/xxx.mp4`：媒体（支持 Range / 206）

自检：

```bash
curl -I http://192.168.1.11:8080/media/files/songs/<file>.mp4
curl -H "Range: bytes=0-1023" -i http://192.168.1.11:8080/media/files/songs/<file>.mp4
# 期望 206 + Content-Range: bytes 0-1023/<size>
```

> 在电脑上本机自测时，把 `192.168.1.11` 换成 `127.0.0.1` 也一样；iPad 上只能用局域网 IP（或 `<host>.local`）。

## 3. 打学期包

```bash
python3 build/build_resources.py                 # 产出 packs/g2s1.zip + g2s1.meta.json
python3 build/build_resources.py --version 2     # 改内容后出 g2s1-v2.zip，供 previous 回退
```

- 源目录：`../app/Resources/Curriculum/`（`grade2.json` + `audio/ words/ img/ sentences/`）
- 脚本会先校验 JSON 引用的每个资产都在，缺一个就非 0 退出并列清单
- `packs/` 至少保留最近 2 个版本，manifest 的 `previous` 才有东西可回退
- **学期包必须异地备份**（云盘或移动硬盘）：原始素材来自第三方站点，可能已无法重爬

## 4. 生成媒体包（儿歌 + 绘本）

媒体包**不含 zip**：按 design Decision 7 就是「清单 + 原始文件」，iPad 先拉 `media.json`，播哪条下哪条。
素材从任意素材目录导入（源素材不进仓库）：

```bash
python3 build/build-media-pack.py \
  --songs   "/path/to/赠品英文儿歌" \
  --picture "/path/to/6.绘本口语跟读6部164节" \
  --version 1
```

产出（默认落在 `content-service/media/`）：

```
media/media.json                        # 清单：mediaSchemaVersion / contentVersion / 逐项 sha256
media/files/songs/<slug>.mp4            # 儿歌
media/files/picture/b1/<slug>.mp4       # 绘本（每部一个 b1…b6 子目录）
```

- 脚本做三件事：递归识别「赠课1 / 赠课2」这类子目录、把文件名规范化成 url 安全 slug
  （`1.At the Market.mp4` → `files/picture/b1/1-at-the-market.mp4`，`title` 保留原名）、
  复制时顺带算逐项 `sha256` 与 `streamable`
- id 用 `m:` 命名空间：儿歌 `m:song-<slug>`、绘本 `m:pb-b1-<slug>`；要换 id 用 `--ids ids.json`
- 已经在位的同名同大小文件会跳过复制；换过素材（比如 remux 后）用 `--force` 强制重拷；
  `--dry-run` 只列计划，不落盘
- 想改成手工流程也行：按命名规范把素材放进 `media/files/`，再跑 `build-media-manifest.mjs`

> 「不能秒开 N 项」是 faststart 体检结果：`streamable: false` 的项串流时走「先下后播」。
> 修法是先 `remux-faststart.mjs` 重排（无损，`-c copy`）再用 `--force` 重新导入。
> 首批 246 项已全部重排（`streamable` 全 `true`，`contentVersion: 2`）。

## 5. 生成媒体清单

媒体素材更新频率低，但清单必须和文件一致。完整流程（挑选、命名、自检、回滚）见
[`docs/media-runbook.md`](../docs/media-runbook.md)，这里只列最小命令：

```bash
# ① 体检：不能秒开（moov 不在头部）的项会走「先下后播」，有不合格项时退出码 2
node build/check-faststart.mjs media/files/songs/*.mp4

# ② 需要时 remux（无损，-c copy，把 moov 移到文件头）；输出到别的目录再替换回来
#    ffmpeg 默认取 PATH 里的，不在 PATH 就用 --ffmpeg 指路
node build/remux-faststart.mjs --in media/files/songs --out /tmp/media-faststart

# ③ 生成 media/media.json
node build/build-media-manifest.mjs --media media --out media/media.json --version 1
```

- `--out` 只允许 `content-service/media/` 或仓库外；仓库内其它位置会被拒绝（退出码 3）
- 每条带 `sha256` / `bytes` / `streamable`，App 逐项校验后才启用
- `durationSec` 默认 0，App 首次播放会回填实测时长

目录约定：

```
media/files/songs/<any>.mp4      儿歌
media/files/picture/<any>.mp4    绘本跟读（可按部建子目录）
media/ids.json                   可选：{ "<相对路径>": "m:自定义id" }
```

可跟读句写在 `media.json` 的 `lines[]`（`text` + `startSec` + `endSec`）；
没标注时 App 的跟读入口会显示「待标注」并置灰。

### 儿歌跟读句标注（tasks 10.7）

82 首儿歌各要标 2–3 句，只能人听着标；脚本负责生成工作表、守住硬线、安全合并：

```bash
# ① 生成工作表：82 首各留 2–3 个空位，边听边记（起止秒 + 文本）
python build/song-lines.py --worksheet ../docs/song-lines-worksheet.md

# ② 更习惯填 JSON 就用这个骨架（结构同 media.json 的 lines[]）
python build/song-lines.py --draft song-lines-draft.json

# ③ 填完合并回去：校验全过才写；写前自动备份成 media.json.bak-<时间戳>，原子替换
python build/song-lines.py --apply song-lines-draft.json

# ④ 随时看进度 / 只校验不写
python build/song-lines.py --status
python build/song-lines.py --check
```

脚本会拦下这些（`--check` 与 `--apply` 同一套规则）：

- 句数不是 2–3 句、`index` 不连续；
- 文本空白、少于 2 个词、超过 10 个词或 80 字符、同首内重复；
- 整句都是拟声/语气词（`La la la`、`Oh yeah`、`Hmm mmm`），或某个词连续 ≥ 3 次（`doo doo doo`）；
- 单句短于 1 秒或长于 8 秒、起止时间为负、结束早于开始、与上一句重叠、超出 `durationSec`。

标注改完不用重扫：`--apply` 直接改 `media.json`。若之后因为换素材重跑第 5 节的 ③，
**同 id、同 sha256 的 `lines[]` 会被保留**；文件内容变了的那几条会打印出来并丢弃（时间轴已不可信），需要重新标。

## 6. manifest 协议

```json
{
  "contentSchemaVersion": 2,
  "packs": [
    { "id": "g2s1", "grade": 2, "title": "二年级上",
      "contentVersion": 1, "schemaVersion": 2,
      "sizeBytes": 42467328, "sha256": "…", "url": "/packs/g2s1.zip",
      "previous": { "contentVersion": 0, "sha256": "…", "url": "/packs/g2s1-v0.zip" } }
  ]
}
```

- `contentVersion`：内容版本（内容改了 +1）
- `schemaVersion`：内容结构版本（JSON 结构变了 +1）；大于 App 支持的上限时，App 置灰并标「需要更新 App」
- `previous`：上一版本包，设置页「回退到上一版本」用

App 下载后按 `sha256` 校验，失败可回退 `previous`；媒体按项校验，单项坏只影响该项。

## 7. App 里下载

家长模式 → 内容管理：

1. 地址框默认是 `http://192.168.1.11:8080`，点「连接」（电脑 IP 变了才需要手改）
2. 首次会弹**本地网络权限**（在点下载/连接时才申请，不在启动时）
3. 列表里选学期 → 下载 → 进度 → 校验 sha256 → 解压 → 安装完成
4. 之后断网也能学；只有「下载新学期」需要局域网

## 8. 学习备份（App 自动上传）

孩子 iPad 上的学习记录只存在设备里，卸载即清空。这里的备份接口让 App 顺手把整包备份传到家里电脑，数据不出家门：

| 方法与路径 | 作用 |
|---|---|
| `PUT /backup/<deviceID>/<name>.json` | App 上传；请求头 `X-Backup-Sha256` 必须与 body 一致，否则 400 拒收 |
| `GET /backup/index.json` | 扫描 `backups/` 生成索引（deviceID / 文件名 / 字节 / sha256 / 时间） |
| `GET /backup/file/<deviceID>/<name>` | 下载某一份（恢复用） |

约定：

- `deviceID` 与文件名只允许 `[A-Za-z0-9-]`，固定 `.json` 扩展名；越界路径直接 400（防穿越）
- 落盘是「同目录临时文件 + 原子 rename」，断电不会留半份文件
- 每设备滚动保留 **30 份**，超出按文件名时间戳删最旧
- body 上限 64 MB（正常备份 <2 MB），超了返回 413
- 除 `/backup/*` 之外，所有路径都只接 GET/HEAD——内容分发仍是只读语义

App 侧：家长模式 → 内容管理 → 「备份」卡片。连上家里 Wi-Fi 后每 24 小时自动传一次（内容摘要没变就跳过），也可以「立即备份」「从家里电脑恢复」。`serve.py` 与 `serve.js` 行为一致，自检：

```bash
# 传一份随手写的备份（sha 必须对得上）
SHA=$(shasum -a 256 /tmp/b.json | cut -d' ' -f1)
curl -X PUT --data-binary @/tmp/b.json \
  -H "X-Backup-Sha256: $SHA" \
  http://192.168.1.11:8080/backup/dev-test/20261107-220000.json

curl http://192.168.1.11:8080/backup/index.json
```

## 9. 常见问题

| 现象 | 原因 |
|---|---|
| iPad 连不上内容服务 | 先看启动日志里的局域网 IP 是不是还是 `192.168.1.11`（换路由器会变）；再查电脑防火墙只放行了「公共」网络，改为允许「专用网络」 |
| App 提示「需要更新 App」 | 包里的 `schemaVersion` 比 App 支持的高：更新 App，或用旧版本包 |
| 下载完提示「内容不兼容」 | `curriculum.json` 解码失败或资产缺失：重跑 `build_resources.py` 检查 |
| 媒体列表不出现 | 还没有 `media/media.json`，或内容服务没提供 `/media.json` |
| 媒体能播但不能拖 | 服务端没返回 206/Range；确认用的是本目录新版 `serve.py` / `serve.js` |
| 想删掉重下 | 家长模式 → 内容管理 → 删除该学期；学习进度按 `itemCode` 保留，重下即恢复 |

## 10. 学期包与媒体的异地备份

必须异地备份：

- `packs/*.zip` + `*.meta.json`（学期包）
- `media/media.json` + `media/files/`（媒体包，6.3 GB，可按需压缩/分盘）
- `backups/`（孩子的学习备份，体积小、价值最高；含姓名与学习记录，只往自己家的盘上备份）

原始素材来源已不稳定，丢了可能无法重爬。

### 用脚本生成可校验的归档（tasks 7.9 / 7.11）

直接拷目录有三个坑：传到一半断了不知道哪几个是半截文件；`media.json` 与 `files/` 错位会被 App 当成
「内容损坏」（比没备份更糟，因为你会以为已经备好了）；半年后翻出来不记得对应哪个内容版本。
所以用脚本产出自描述归档：

```bash
# 学期包 + 媒体（6.3 GB，断点续传：已拷过且大小一致的文件会跳过）
python content-service/build/archive-for-backup.py --out E:/backup/english-20261108

# 只备学期包（41 MB，秒级）
python content-service/build/archive-for-backup.py --out E:/backup/packs-only --no-media

# 校验：逐个文件比 sha256，并核对 media.json 与文件成对
python content-service/build/archive-for-backup.py --verify E:/backup/english-20261108
```

归档里除了原目录结构，还会多两个文件：

- `MANIFEST.json` —— 每个文件的 sha256 / 字节数，加上 `mediaSchemaVersion`、`contentVersion`、生成时间（换机时能确认版本对得上）
- `CHECKSUMS.sha256` —— 标准 `sha256sum` 格式，任何工具都能独立核（Windows 可 `certutil -hashfile`）

退出码：`0` 通过；`1` 校验有问题（逐条列出）；`3` 归档不完整（清单里有文件不在磁盘上，这份备份不能用）。
清单缺项时脚本不会假装成功——宁可报错，也别让人以为已经备好了。

## 11. 注意

- 不要把 `packs/`、`media/` 提交进 git；根目录 `.gitignore` 已忽略
- 不要做端口映射到公网；这是纯家庭局域网服务
- Windows 防火墙只需放行「专用网络」的 8080
