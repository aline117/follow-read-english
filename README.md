# 跟着课本学英语 · follow-read-english

> 给自家二年级孩子做的 iPad 英语学习 App：跟着沪教版课本，以「听 → 说 → 认 → 游戏 → 句型 → 复习」为核心，每天 20 分钟，配虚拟星星与真实奖励兑换。

**个人自用项目，不上架 App Store。** 通过 Mac + Xcode 侧载安装到自家 iPad。

---

## 当前状态

| 阶段 | 状态 |
|---|---|
| 需求与设计 | ✅ 完成（proposal / design / 4 份 spec / 61 项任务） |
| 交互原型 | ✅ 32 屏可点击原型（见 [prototype/](openspec/changes/ipad-elementary-english-learning/prototype/index.html)） |
| 内容素材 | ✅ 二年级上（沪教版）6 单元 / 33 词 / 18 句型 / 129 条课文原声 |
| 代码实现 | 🟡 **刚开始：9 / 61 任务**（仅模型骨架与内容加载器，**当前无法编译**） |

> ⚠️ `app/` 目前只有数据模型和内容加载器；`RootView` 引用的 4 个视图还没写，`Package.swift` 仍是 iOS 16（计划改 iOS 18）。现在编译会失败，这是预期状态。

进度可用 OpenSpec 查看：

```bash
openspec list                     # 9/61 tasks
openspec status --change ipad-elementary-english-learning --json
```

---

## 设计要点

### 1. 两种模式，而不是一个 Tab 里的三页

```
孩子模式（默认打开就是这个）            家长模式（验证后全屏覆盖）
├── 学习  今日任务卡 / 课程列表 / 6 环节   ├── 学习报告
└── 奖励  星星 / 徽章墙 / 兑换商店        ├── 兑换审核（记录是谁审的）
                                          ├── 奖励库 / 兑换限制
   顶栏右上角 🔒 ──验证──▶                ├── 练习强度（6 项可调）
                                          ├── 解锁单元 / 内容管理
                                          ├── 孩子档案（最多 4 个）
                                          └── 设置与安全
```

孩子界面上没有"家长"字样，避免天天看到一个点不进去的入口。

### 2. App 内零课程内容，内容按学期从家里电脑下载

```
iPad 主包（约 10MB）                     家里的电脑（同一 Wi-Fi）
├── catalog.json（几 KB 学期目录）        ├── serve.js（Node 静态服务）
└── Application Support/Curriculum/      └── packs/g2s1.zip + manifest.json
    └── g2s1/  ← 下载解压后落这里
```

- 下载后**完全离线**可学，学习过程不依赖网络
- 加新学期只需在家中电脑放新包，**不用重新构建 App**
- 包带 `sha256` + `schemaVersion` 校验，失败可回退上一版

### 3. 数据分三层，只读内容不进数据库

| 层 | 存放 | 内容 |
|---|---|---|
| 只读内容 | JSON（内置 catalog + 下载的学期包） | `Volume` / `Unit` / `UnitWord` / `Sentence` |
| 学习状态 | SwiftData | `Profile` / `LearningSession` / `Attempt` / `ItemProgress` / `ReviewSchedule` / `StarLedger` / `Badge` / `Redemption` |
| 家长配置 | SwiftData + Keychain | `RedemptionRule` / `LearningSettings` / `ParentProfile`；PIN 与恢复码只存 salt + 哈希 |

单词与句型统一用业务码关联：`w:758201`、`s:u1-s1`。

### 4. 关键机制

- **正确率存明细不存聚合**：每次交互写一条 `Attempt`，报告按 `AccuracyRule` 实时聚合，改口径不用重算历史
- **星星流水制**：`StarLedger` 带唯一 `grantKey`，重复发星自动幂等
- **今日任务**：复习优先（上限可调）→ 只有时长预算还有剩才推新词
- **间隔重复**：1 → 3 → 7 → 14 → 30 天，答错回退一级
- **卡住可跳过**：同一环节连续失败 N 次（家长可调）出现「先跳过」，不计星但记入薄弱项
- **防沉迷底线不开放**：每日 20 分钟预算、每日发星上限、星星余额上限 500

---

## 目录结构

```
.
├── app/                        # SwiftUI App（SwiftPM 包，待转 Xcode App 工程）
│   ├── Package.swift
│   ├── Sources/EnglishLearning/
│   │   ├── App/                # EnglishLearningApp.swift（SwiftData 容器）、RootView
│   │   ├── Models/             # 8 个 @Model
│   │   └── Services/           # CurriculumLoader（JSON 解析 + 资产校验）
│   └── Resources/Curriculum/   # 二上素材（196 文件：195 媒体 + grade2.json，53MB，走 Git LFS；后续迁出为 packs/）
│
├── openspec/                   # 设计与任务（唯一事实来源）
│   ├── config.yaml             # 项目上下文 + 各产物写作规则
│   └── changes/ipad-elementary-english-learning/
│       ├── proposal.md
│       ├── design.md           # 决策、参数表、奖励体系、健壮性、合规
│       ├── tasks.md            # 61 项任务
│       ├── specs/              # curriculum-sync / learning-cycle / parent-panel / reward-system
│       └── prototype/          # 32 屏可点击原型（index.html 为入口）
│
├── .acecode/skills/            # 12 个 OpenSpec 工作流技能
```

---

## 环境要求

| 项 | 要求 |
|---|---|
| 构建 | **macOS + Xcode**（iOS App 只能在 Mac 上编译） |
| 设备 | iPad，iPadOS 18 及以上（开发机实测 iPadOS 26.2） |
| 签名 | 免费 Apple ID 即可，**7 天有效期**，每 7 天在 Xcode 里重签一次 |
| 内容服务 | 任意一台与 iPad 同 Wi-Fi 的电脑 + Node.js（Windows 也可） |
| OpenSpec CLI | 可选，装了就可用 `openspec` 命令；本项目用 1.15.0 |

```bash
npm i -g @fission-ai/openspec      # 可选（注意别装同名的 0.0.0 占位包）
```

---

## 上手步骤（当前可做 / 待做）

### 现在就能看：原型

双击打开 `openspec/changes/ipad-elementary-english-learning/prototype/index.html`，按 A / B / C 三组点进去，屏与屏之间的按钮已经连好跳转。

### 待实现后再做：装到 iPad

1. 在 Mac 上用 Xcode 打开 `app/`（后续会转成 Xcode App 工程）
2. 选中 iPad，按 ⌘R 安装
3. 首次启动：创建孩子档案 → 设置家长 PIN（抄下 6 位恢复码）→ 选择并下载学期内容
4. 之后每 7～30 天（免费账号 7 天）在 Xcode 里重签一次；**重签不会丢数据，只有卸载才会**

### 内容服务（待实现）

在家里电脑上起一个只读静态服务（监听 8080），提供学期包与 `manifest.json`；只需内网访问，不做端口映射。

iPad 端地址：`http://<host>.local:8080`（Bonjour 主机名，避免 IP 变化；设置页可手动改）。

---

## 开发流程（OpenSpec）

本项目的设计与实现以 `openspec/` 为准，不靠口头约定。

```bash
openspec list                                            # 有哪些 change、完成度
openspec status --change ipad-elementary-english-learning --json
openspec validate ipad-elementary-english-learning        # 校验产物结构
openspec doctor                                          # 根健康检查（config.yaml）
```

配合项目内技能使用：

| 场景 | 技能 |
|---|---|
| 讨论/审视设计 | `openspec-explore` |
| 提新需求 | `openspec-propose` |
| 按任务实现 | `openspec-apply-change` |
| 实现后验收 | `openspec-verify-change` |
| 完成后归档 | `openspec-archive-change` |

实现顺序建议：`2.x 模型改造 → 1.x 工程与配置 → 7.4/7.5 内容打包与服务 → 3.x 课程与首页 → 4.x 学习环节 → 5.x/6.x 奖励与家长 → 8.x/9.x 验证与测试`。

---

## 内容与版权

- 目前素材：课文原声来自公开教学站点，单词发音与配图来自第三方词库，**仅供个人学习使用**
- 若要分发或上架，必须替换为授权素材或自采录音
- 句型音频当前用 TTS 生成，后续可**原路径替换**为教材原音切片，代码与 JSON 都不用改
- 原始素材与抓取清单只保留在本地，不随仓库分发

## 数据与隐私

- 学习记录、录音、星星流水全部**只存本机**，不上传任何服务器
- 录音仅在跟读评分时临时生成，评分完成即删
- 不接入任何第三方语音评测 SDK，正确率基于「音量 + 时长」启发式判定
- **卸载 App 会清空全部学习记录**，设置页提供导出 JSON 备份

---

## 已知限制与待定项

| 项 | 状态 |
|---|---|
| `bundle id` | **待定**，首次装 iPad 前必须确定，之后不可更改 |
| 二年级下（xiace） | 教材版本待定，推迟到寒假补录 |
| 课文对话全文 / 故事 | 列为后续内容任务（需转录 129 条原声） |
| 徽章图标 / 头像 | 原型为占位，需绘制矢量素材 |
| 词块排序、图表趋势线等视觉细节 | 原型阶段，未细化 |
| 测试 | 计划补 XCTest：内容加载器、复习调度、星星幂等、正确率聚合 |

---

## 常用命令速查

```bash
# git / LFS
git lfs ls-files | wc -l          # 195 个 LFS 文件（音频/图片）
git lfs pull                      # 克隆后拉取真实素材

# 进度
openspec list
openspec status --change ipad-elementary-english-learning --json
```

---

## 许可证

个人项目，未授权他人使用或分发。内容素材版权归原出处所有。
