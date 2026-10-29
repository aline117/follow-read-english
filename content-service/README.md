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
│   ├── build-media-manifest.mjs      # 媒体目录 → media/media.json
│   ├── check-faststart.mjs           # 判断 mp4 能否秒开
│   └── remux-faststart.mjs           # 可选：moov 后置的视频重排
├── packs/              # 学期包 zip + meta（不进 git，需备份）
├── media/
│   ├── media.json      # 媒体清单（App 通过 /media.json 拉取）
│   └── files/          # 儿歌 / 绘本 mp4（不进 git，需备份）
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

启动后会打印可用地址：

```
http://127.0.0.1:8080
http://my-mac.local:8080
http://192.168.1.23:8080
```

iPad 上填 `<host>.local` 那个（DHCP 换 IP 也不失效）。

## 2. 打开与验证

- `/`：包列表 + 媒体项数
- `/manifest.json`：学期包清单
- `/media.json`：媒体清单
- `/packs/g2s1.zip`：学期包（支持 Range）
- `/media/files/songs/xxx.mp4`：媒体（支持 Range / 206）

自检：

```bash
curl -I http://127.0.0.1:8080/media/files/songs/<file>.mp4
curl -H "Range: bytes=0-1023" -i http://127.0.0.1:8080/media/files/songs/<file>.mp4
# 期望 206 + Content-Range: bytes 0-1023/<size>
```

## 3. 打学期包

```bash
python3 build/build_resources.py                 # 产出 packs/g2s1.zip + g2s1.meta.json
python3 build/build_resources.py --version 2     # 改内容后出 g2s1-v2.zip，供 previous 回退
```

- 源目录：`../app/Resources/Curriculum/`（`grade2.json` + `audio/ words/ img/`）
- 脚本会先校验 JSON 引用的每个资产都在，缺一个就非 0 退出并列清单
- `packs/` 至少保留最近 2 个版本，manifest 的 `previous` 才有东西可回退
- **学期包必须异地备份**（云盘或移动硬盘）：原始素材来自第三方站点，可能已无法重爬

## 4. 生成媒体清单

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
没标注时 App 的跟读入口会显示「待标注」。

## 5. manifest 协议

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

## 6. App 里下载

家长模式 → 内容管理：

1. 确认地址框里是 `http://<host>.local:8080`，点「连接」
2. 首次会弹**本地网络权限**（在点下载/连接时才申请，不在启动时）
3. 列表里选学期 → 下载 → 进度 → 校验 sha256 → 解压 → 安装完成
4. 之后断网也能学；只有「下载新学期」需要局域网

## 7. 常见问题

| 现象 | 原因 |
|---|---|
| iPad 连不上 `xxx.local` | 电脑防火墙只放行了「公共」网络；改为允许「专用网络」，或先用 IP 试通 |
| App 提示「需要更新 App」 | 包里的 `schemaVersion` 比 App 支持的高：更新 App，或用旧版本包 |
| 下载完提示「内容不兼容」 | `curriculum.json` 解码失败或资产缺失：重跑 `build_resources.py` 检查 |
| 媒体列表不出现 | 还没有 `media/media.json`，或内容服务没提供 `/media.json` |
| 媒体能播但不能拖 | 服务端没返回 206/Range；确认用的是本目录新版 `serve.py` / `serve.js` |
| 想删掉重下 | 家长模式 → 内容管理 → 删除该学期；学习进度按 `itemCode` 保留，重下即恢复 |

## 8. 备份

必须异地备份：

- `packs/*.zip` + `*.meta.json`
- `media/media.json`
- `media/files/`（6.3 GB，可按需压缩/分盘）

原始素材来源已不稳定，丢了可能无法重爬。

## 9. 注意

- 不要把 `packs/`、`media/` 提交进 git；根目录 `.gitignore` 已忽略
- 不要做端口映射到公网；这是纯家庭局域网服务
- Windows 防火墙只需放行「专用网络」的 8080
