# 内容服务（家园局域网）

App 里**不带任何课文内容**，学期包由这台电脑提供。三件事：打包 → 起服务 → App 里下载。

> 只绑内网、只读、不做端口映射；iPad 与电脑要在同一个 Wi-Fi。

## 1. 打学期包

```bash
python3 _download/build_resources.py           # 产出 _download/packs/g2s1.zip + g2s1.meta.json
python3 _download/build_resources.py --version 2   # 改内容后出 g2s1-v2.zip，供 manifest 的 previous 回退
```

- 源目录：`app/Resources/Curriculum/`（`grade2.json` + `audio/ words/ img/`）
- 包内结构：`g2s1/{curriculum.json,audio,words,img}`，`curriculum.json` = 原 `grade2.json` + 顶层 `schemaVersion`
- 脚本会先校验 JSON 引用的每个资产都在，缺一个就非 0 退出并列清单
- `packs/` 至少保留最近 2 个版本，`previous` 才有东西可回退
- **学期包必须异地备份**（云盘或移动硬盘）：原始素材来自第三方站点，可能已无法重爬

## 2. 起服务

```bash
python3 _download/serve.py            # 本机/Mac：0.0.0.0:8080
node _download/serve.js               # 装了 Node 的电脑（含 Windows）
_download\serve.bat                   # Windows 双击（内部调 serve.js）
```

启动后会打印可用地址，例如：

```
http://127.0.0.1:8080
http://my-mac.local:8080
http://192.168.1.23:8080
```

iPad 上填 `<host>.local` 那个（DHCP 换 IP 也不失效）。浏览器打开根路径能看到包列表，`/manifest.json` 能看到协议内容。

## 3. App 里下载

家长模式 → 内容管理：

1. 确认地址框里是 `http://<host>.local:8080`，点「连接」
2. 首次会弹**本地网络权限**（在点下载/连接时才申请，不在启动时）
3. 列表里选学期 → 下载 → 进度 → 校验 sha256 → 解压 → 安装完成
4. 之后断网也能学；只有「下载新学期」需要局域网

## manifest 协议

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

## 常见问题

| 现象 | 原因 |
|---|---|
| iPad 连不上 `xxx.local` | 电脑防火墙只放行了「公共」网络；改为允许「专用网络」，或先用 IP 试通 |
| App 提示「需要更新 App」 | 包里的 `schemaVersion` 比 App 支持的高：更新 App，或用旧版本包 |
| 下载完提示「内容不兼容」 | `curriculum.json` 解码失败或资产缺失：重跑 `build_resources.py` 检查 |
| 想删掉重下 | 家长模式 → 内容管理 → 删除该学期；学习进度按 `itemCode` 保留，重下即恢复 |
