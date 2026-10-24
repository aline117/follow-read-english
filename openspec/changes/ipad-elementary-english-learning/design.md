## Context

这是一个全新项目，目标平台为 iPad（iOS 18+），使用 SwiftUI 构建。核心用户为小学生（6-10岁）及其家长。项目需要支持音频播放/录音、本地数据持久化、多用户 Profile。

## Goals / Non-Goals

**Goals:**
- 构建 iPad 原生 APP，支持横竖屏
- 实现核心学习循环（听→说→认→游戏→复习）
- 实现虚拟+现实激励系统
- 实现家长控制面板
- 支持多孩子 Profile

**Non-Goals:**
- 不做 Android/Web 版本
- 不做在线社交功能
- 不做 AI 自适应算法（首版用固定间隔重复）
- 不做内容创作工具（内容由运营录入）

## Decisions

### Decision 1: SwiftUI + SwiftData

**选择：** SwiftUI 作为 UI 框架，SwiftData 作为本地持久化。

**理由：**
- SwiftUI 原生支持 iPad 大屏幕、拖拽、动画
- SwiftData 与 SwiftUI 深度集成，适合本地数据模型
- 无需第三方依赖，降低维护成本

**备选：** UIKit（更成熟但代码量大）、Core Data（更复杂）、Realm（第三方依赖）

**落地约定（2026-10 补充）：**
- 部署最低版本锁定 **iOS 18**（SwiftData 需 iOS 17+；18 起可用 `#Unique` / `#Index`，进度表复合唯一键依赖它）
- SwiftData 只存**可变数据**（学习状态 + 家长配置）；**只读课程内容不进库**，启动时解码 `gradeN.json` 一次并常驻内存
- 因此不再需要 `CurriculumCourse` / `Lesson` / `Word` / `Sentence` 这四个内容型 `@Model`，内容改为纯 `Decodable` struct（详见 Decision 6）

### Decision 2: 音频方案

**选择：** AVAudioPlayer 播放 + AVAudioRecorder 录音 + 简单语音评测；**慢速播放用 `AVAudioEngine` + `AVAudioUnitTimePitch` 保音高**。

**理由：**
- 系统原生框架，无需第三方
- 首版语音评测用音量+时长模拟，后续可接入第三方 SDK
- `AVAudioPlayer.rate = 0.7` 会**同时降低音高**，对儿童辨音不利；`AVAudioUnitTimePitch` 变速不变调，代价是多一层 engine 配置（约半天）

**备选：** 接入讯飞/百度语音评测 API（更准确但增加依赖和成本）；接受 `AVAudioPlayer.rate` 的变调效果（实现最简单，但慢速时的音色明显失真）

### Decision 3: 内容数据管理（零内置 + 家园局域网下载）

**选择：** App 内**不打包任何课程媒体或词表**，只内置一份几 KB 的 `catalog.json`（学期目录：标题、大小、版本，无内容本体）。学习内容由家里的电脑通过局域网 HTTP 服务按学期下发，iPad 下载后存本地。

**理由：**
- **内容与代码解耦**：新增二下 / 三上不需要重新构建安装 App。自用侧载没有体积限制，省体积本身不是目的，能独立更新内容才是
- 家园局域网带宽充足（约 50MB 的学期包十几秒传完），无需断点续传、CDN、灰度
- 不上架、不走 App Review，本地 HTTP 服务足以承担分发
- 孩子日常学习仍然完全离线：已下载的学期不依赖网络

**取舍：**
- 首次使用与每次开学季都需要"家里电脑开机 + 同一 Wi-Fi"，作为家长 runbook 明示
- 家里电脑成为唯一内容源 → 学期包与管线脚本必须异地备份（见 Risks）

**备选：** 全量内置（简单，但加内容必须重发版）、On-Demand Resources（需 App Store/TestFlight 分发，自用不可用）、自建公网对象存储（多一层成本与安全面）

### Decision 4: 激励系统架构

**选择：** 本地存储星星/积分/徽章，家长端管理兑换规则。

**理由：**
- 首版无需服务器，数据本地存储
- 兑换审核由家长在 APP 内完成
- 后续可扩展为云端同步

### Decision 5: 多 Profile 支持

**选择：** 基于 SwiftData 的 Profile 模型，每个 Profile 独立数据。

**理由：**
- 简单直接，无需复杂权限系统
- 家长可切换查看不同孩子数据

**生命周期（必须实现，否则会留孤儿数据）：**
| 动作 | 行为 |
|---|---|
| 创建 | 首次启动引导创建；家长 Tab「孩子切换」里可再加（上限 4 个） |
| 切换 | 学习/奖励/家长三个 Tab 全部按 `profileID` 过滤；当前选中 `profileID` 持久化（`@AppStorage`），重启后保持 |
| 删除 | 家长确认后按 `profileID` **逐表批量删除**：`ItemProgress` / `Attempt` / `LearningSession` / `ReviewSchedule` / `StarLedger` / `Badge` / `Redemption`（`ProfileDataPurger`，幂等）；至少保留 1 个 Profile，不允许删最后一个 |
| 升年级 | 家长 Tab 改 `Profile.grade` → 首页列出对应 catalog 学期；已下学期的进度按 `itemCode` 保留，不因换年级清空 |

**为什么不用 `@Relationship(deleteRule: .cascade)`：** 各表用裸 `profileID` 才能按内容码直接过滤与批量查询；cascade 需要为 7 个模型都维护反向关系，且裸 UUID 模型上它不会自动生效。数据量很小（一年 1-2 万行），手动 purger 更可控、也便于写单元测试。

### Decision 6: 数据分层与内容身份

数据按"谁写入"分三层，只读内容不进数据库：

| 层 | 存放 | 成员 |
|---|---|---|
| 只读内容 | 内置 `catalog.json` + 下载的学期包（`Application Support/Curriculum/<semester>/`），解码后常驻内存 | `Catalog` / `Volume` / `Unit` / `UnitWord` / `Listening`（纯 `Decodable` struct，无 `@Model`） |
| 学习状态 | SwiftData | `Profile` / `LearningSession` / `Attempt` / `ItemProgress` / `ReviewSchedule` / `StarLedger` / `Badge` / `Redemption` |
| 家长配置 | SwiftData + Keychain | `RedemptionRule` / `LearningSettings`（每个孩子一份练习强度设置）/ `ParentProfile`（最多 2 位家长，共用 PIN）；家长 PIN 存 Keychain（salt + 哈希，不存明文） |

**键规则（唯一一条，避免两套 id 打架）：**
- 内容实体一律用课本**业务码 String**：`UnitWord.id = "758201"`、`Sentence.id = "s1"`、`Unit.id = "u1"`、`Volume.id = "shangce"`
- **item 统一编码**（单词与句型共用同一套进度/复习/评分表）：`itemCode = "w:<wordId>"`（`w:758201`）或 `"s:<unitId>-<sentenceId>"`（`s:u1-s1`）
- 本地生成的实体一律用 **UUID**：`Profile.id`、`LearningSession.id` 等
- 跨层关联只走业务码 String：`ItemProgress.itemCode`、`ReviewSchedule.itemCode`、`Attempt.itemCode`、`LearningSession.unitCode` + `volumeCode`
- 唯一性：`ItemProgress` 用 `#Unique([\.profileID, \.itemCode])` 保证「一个孩子 x 一个条目」唯一；`Attempt` 不做唯一约束（明细允许重复）
- `WordProgress` 重命名为 **`ItemProgress`**（语义覆盖 word / sentence），并带 `itemKind: String`（`word` / `sentence`）便于按类型统计

**奖励记账：** `Reward` 聚合模型取消，改为 `StarLedger` 流水（`grantKey` 唯一保证幂等），余额与"今日已发"由流水聚合，`earnedToday` / `lastEarnDate` 字段不再需要。

**理由：** JSON 解码不产生 UUID，若进度表存 UUID 则永远关联不到真实单词（历史缺陷）；业务码同时是排查内容问题的天然标识。

## Risks / Trade-offs

- [语音评测不准确] → 首版用音量+时长模拟，标注"beta"，后续接入专业 SDK
- [内容制作成本高] → 首版只做 2 年级课本，验证模式后再扩展
- [音频素材来源] → 使用网络免费/付费音频资源，避免 TTS 生硬问题和自行录制质量
- [项目性质] → 个人项目，首版免费，暂不考虑商业合规要求
- [儿童隐私合规] → 语音数据仅本地处理，不上传服务器
- [家长参与度不确定] → 设计简洁的家长面板，降低使用门槛
- [内容源单点] → App 内零内容本体，家里电脑是唯一来源；`packs/*.zip` 与 `build_resources.js` / `jx_audio_manifest.json` 必须异地备份并纳入版本库，原始素材依赖第三方站点、可能无法重爬
- [首次使用门槛] → 家长需先在家启动内容服务才能下到第一个学期；用空状态页 + runbook + 引导文案把门槛降到最低，并把学期包做成一次下载长期可用

## Migration Plan

1. 新增学期内容：`build_resources.js` 打成 `packs/<id>.zip` → 放进家里电脑的 `packs/` → App 端拉 manifest 后按需下载，**不需要重新构建 App**
2. 用户数据本地存储，覆盖安装保留容器，无需迁移
3. 后续若上架 App Store，可把家园局域网分发替换为 ODR 或对象存储；切换点只在 `ResourceLocator` 与下载服务，内容包结构不变

## 已确认决策

- 深圳课本具体版本：沪教版（上海教育出版社）
- 首版范围：2年级，5年级后续开发
- 音频素材：使用网络资源
- 书写练习：首版不做，后期可考虑字母选择拼写方式
- APP 语言：中文界面 + 英文学习内容
- 音频播放：支持慢速/常速切换
- 游戏形式：配对、听音选图、跟读打分
- 数据备份：首版本地存储，不做 iCloud 同步
- 家长验证：4 位 PIN 码
- 视觉风格：卡通风格，适合儿童
- 2年级内容：按课本顺序从头开始
- 屏幕时间：首版用自有计时，不接入 iOS 屏幕时间 API
- 商业模式：免费
- 家长报告：必需功能

## UI / 交互设计

### 导航结构（两种模式，不是一个 tab 里的三个页）

**孩子模式**（默认，打开 App 就是这个）底部只有 **2 个 Tab**：

- **学习**：今日任务卡（20 分钟目标 + 进度条）、继续学习按钮、复习提醒 → 单元列表（按课本 Unit 顺序，**未解锁单元置灰不可点**）→ 学习单元页（含「跟我读」课文原声入口：连播 + 逐条跟读，可选慢速播放）
- **奖励**：星星余额 + 徽章墙 → 兑换商店（家长启用的规则卡片）→ 申请兑换 → 等待审核状态；防沉迷提示语常驻底部
- **顶栏右上角一个 🔒 小图标 = 家长模式入口**（无文字）：孩子不会去点，家长一戳就知道

**家长模式**（验证后以 `fullScreenCover` 盖上来，独立 `NavigationStack`，**不显示孩子的底部 Tab**）：

- 首页 6 项：学习报告 / 奖励库 / 练习强度 / 内容管理 / 孩子档案 / 设置与安全
- 顶部固定「退出家长模式」，退出不需再验证
- 危险操作（删除学期包、删除孩子、重置 PIN）需二次确认
- 每次进入/退出写审计日志；进入时选"我是妈妈/爸爸"（**仅用于审计**，不额外验证）

首次启动仍走家长配置流程（建孩子档案 → 设 PIN → 选内容下载）；完成页明确提示"以后点右上角的小锁进入家长模式"。

### 家长档案与通知

| 项 | 设计 |
|---|---|
| `ParentProfile` | 最多 2 个（妈妈 / 爸爸），字段 `name` / `avatar` / `isActive`；**共用一组 PIN**（不再多一套密码负担），选择身份只为审计 |
| 审核记录 | `Redemption.reviewedBy` 记录是谁审核的（如"妈妈同意了"） |
| 本地通知 | 兑换提交 → 通知家长去审核；学期包下载完成 → 通知（`UNUserNotificationCenter`，无网络依赖） |
| 审计日志 | 家长模式进入/退出、PIN 重置、恢复码重新生成，均可查 |

### 学习单元流转（约 9-10 分钟/单元，含 1 条句型）
| 环节 | 时长 | 界面要点 |
|---|---|---|
| 听 | 1min | 大图+单词+中文，**新学默认慢速**、可切常速，左右滑动换词 |
| 说 | 1.5min | 按住录音，音量动画，评分反馈（"真棒!"），可重听原音 |
| 认 | 1.5min | 拖拽配对 |
| 游戏 | 2min | 听音选 4 图 |
| 句型 | 2min | 听整句 → 跟读整句 → 词块排序（当日新学 1 条句型，默认慢速） |
| 复习 | 1min | 翻卡，**默认常速**（检验真实语速下的辨识） |
| 结算 | — | 星星动画 + 徽章弹窗（如有） |

环节顺序固定为：听(词) → 说(词) → 认(词) → 游戏(词) → **句型** → 复习。句子不单独开"第 7 个环节"，作为一个组合块插在游戏与复习之间。

**认环节的轮次规则：** 一屏显示 N 对（默认 3 对，家长可调 2/3/4/6），把本单元全部单词覆盖完算 **1 轮**；二上每单元 5-6 词，默认 3 对即约 2 轮。设置里的「每单元最少练习轮数」决定何时算完成——**不是"整个单元只做 3 次配对"**。

**两个跟读入口的分工（避免混用）：**
- **主流程内**：单词跟读、句型跟读（`itemCode` 驱动，计入进度与复习）
- **「跟我读」（单元页入口）**：课本原声连播 + 逐条跟读，属"额外听力练习"，**不写入 `ItemProgress`、不参与复习调度**，只把"已跟读条数/次数"汇入当日学习数据

### 句子学习环节（首版范围 A：核心句型）

小学英语不只记单词，每单元的核心句型同样要学、要练、要复习。首版每单元 2-3 条（二上约 18 条），与单词共用同一套进度/复习/评分表（`itemCode = "s:u1-s1"`）。

| 环节 | 做法 |
|---|---|
| 听 | 整句音频 + 文本（整句高亮，不做逐词时间戳） |
| 说 | 跟读整句，评测口径完全沿用「时长 60%-140% + 音量阈值」 |
| 认 | **词块排序**：把打乱的 `chunks` 拖拽拼成句子 |
| 游戏 | **听音补全**：听句子，从 3 个词块里选出空缺项 |
| 复习 | 整句跟读，与单词共用间隔重复调度 |

- 句子**不强制配图**：教材情境图无授权，用「文本 + 音频 + 词块」三件套支撑练习
- 句型音频先用 TTS 生成（`sentences/{unit}/{id}.mp3`），后续可原路径替换为教材原音切片，JSON 与代码均不改
- 首版不做课文对话全文与故事（档位 B/C），列入后续内容任务

### 视觉规范
- 主色橙黄 + 辅助天蓝，圆角 16-24pt，大字号，星星/撒花动画

### 内容 JSON 格式

课文与单词收录在每个学期包的 `curriculum.json`（即原 `grade2.json`，随包内 `audio/ words/ img/` 一同下发），下载解压后读取一次并常驻内存。资源定位统一走 `ResourceLocator`：按 (学期, 相对路径) 在 `Application Support/Curriculum/<semester>/` 下查找，找不到即判定"内容未安装"并触发空状态/占位降级。

```jsonc
{
  "grade": 2,
  "textbook": "沪教牛津(六三制一起)(2024)",
  "volumes": [
    {
      "id": "shangce",            // 二上
      "units": [
        {
          "id": "u1",
          "title": "Unit 1 What can you do with your five senses?",
          "words": [
            { "id": "758201", "en": "feel", "zh": "v.感觉到",
              "image": "img/u1/758201.png",
              "audio": "words/1/758201.mp3" }
          ],
          "sentences": [
            { "id": "s1", "en": "I can see with my eyes.", "zh": "我用眼睛看。",
              "pattern": "I can ___ with my ___.",
              "chunks": ["I", "can", "see", "with", "my", "eyes"],
              "audio": "sentences/u1/s1.mp3" }
          ],
          "listenings": [
            { "id": "u1p1-3", "period": 1, "label": "Period 1-3",
              "audio": "audio/17635230_3.mp3" }
          ]
        }
      ]
    }
  ]
}
```

音频本体不放进 JSON，只在每条 word / listening 上记录相对路径（构建脚本按确定性命名规则落盘）：
- 课文原声：`audio/{docId}_{seq}.mp3`（docId/seq 来自抓取清单 `jx_audio_manifest.json`，129 个，Unit↔Period 均已对齐），专供单元页「跟我读」模块连播/逐条跟读，不进入单元流转「听」环节
- 单词发音：`words/{unit}/{wordId}.mp3`（来自 suyang123 清单，二上 33 个），进入单元流转「听」环节
- 句型发音：`sentences/{unit}/{sentenceId}.mp3`（首版 TTS 生成，二上约 18 条）；后续可**原路径替换**为教材原音切片，JSON 与代码均不改
- 慢速：不做预生成副本，播放时用 `AVAudioEngine` + `AVAudioUnitTimePitch`（rate 0.7，**变速不变调**）实时降速（竞品均为运行时变速，无预生成慢速文件）
- 中文释义：JSON 保留原始词性前缀（`"v.感觉到"`），但 UI **只显示主体词义**（"感觉到"）；二年级不教音标、也不要求孩子认词性缩写，因此**首版不显示音标**（JSON 同样不设 `phonetic` 字段）

验收标准：
- [ ] 学期包内 `curriculum.json` 可解码为 Curriculum 模型，且 `ResourceLocator` 能从 `Application Support/Curriculum/<semester>/` 取得全部引用资产
- [ ] 共 6 单元、单元标题与课本一致；有声单词 33 个（二上）
- [ ] 每个单元至少 2 条核心句型，字段含 `en` / `zh` / `pattern` / `chunks` / `audio`，二上合计约 18 条
- [ ] 每条 listening / word 都指向存在的资产文件，缺失时触发 debug 断言
- [ ] JSON 改动无需修改代码（遍历解码，键固定）

二下结构同构，寒假按同一流程补录数据即可。

### 音频素材落实方案

两个网络音源，一个构建脚本落盘；App 运行时无任何网络依赖：

| 素材 | 音源 | 数量 | 原始文件 |
|---|---|---|---|
| 课文原声 | 51jiaoxi（vga 接口，128kbps mp3 已验证） | 129 | `_download/jx_audio/{docId}_{seq}.mp3` |
| 单词发音+配图 | suyang123（`words_raw.json` 清单） | 33 词 × 2 | `_download/words/3003364/{wordId}.mp3/.png` |

格式决定：
- **不转码、不重采样**：源文件本身就是 mp3（课文为已验证的 128kbps，单词为原生 mp3），AVAudioPlayer 直接解码；命名维持 JSON 章节已定的 `audio/{docId}_{seq}.mp3` 与 `words/{unit}/{wordId}.mp3`
- 单词配图与发音同源成对落盘，进 `img/u{unit}/{wordId}.png`
- 不生成慢速副本（运行时变速已定）

构建脚本 `_download/build_resources.js`（Node，沿用本目录现有脚本风格）：
1. 读取 `jx_audio_manifest.json` 与 `app/Resources/Curriculum/grade2.json`
2. 复制 129 个课文 mp3 → `app/Resources/Curriculum/audio/`
3. 复制 33 组单词 mp3/png → `app/Resources/Curriculum/words/{unit}/` 与 `img/u{unit}/`
4. 校验：grade2.json 引用的每个资产文件目标位置存在且字节 > 0，二上 33 词 / 129 课文无缺失；任一缺失脚本以非 0 退出码报清单

验收标准：
- [ ] 运行脚本后产出的学期包结构与 `curriculum.json` 引用完全一致（迁移前落 `app/Resources/Curriculum/`，迁移后为 `packs/<id>.zip`，见 tasks 7.4）
- [ ] App 内播放不打网络请求，全部本地文件

### 首次启动引导流程

共 4 步，全程横屏，完成后直接进入学习 Tab，不出现其他弹窗：

1. **欢迎页（1 屏）**：App 名称 + 卡通插图 + 一句话说明「跟着课本学英语」，一个「开始」按钮
2. **创建孩子档案**：
   - 昵称（1-10 字，必填）
   - 头像：内置 8 个卡通形象选择，不用照片/相册（避免儿童隐私）
   - 年级：唯一选项「二年级」（五年级置灰，显示"即将推出"）
3. **家长 PIN 设置**：输入 4 位数字 + 二次确认；提供「稍后设置」跳过，但首次点击家长 Tab 时强制补设（4 位相同/连续数字拒绝）
   - 设置成功时生成 **6 位恢复码**，可「复制 / 分享到文件 App / 存成图片」；Keychain 只存 salt + 哈希
   - 若设备未设锁屏密码，提示"建议先给 iPad 设锁屏密码"（关系到能否用设备密码找回，见「家长凭据与恢复策略」）
4. **选择并下载内容**：探测家园内容服务 → 列出可用学期（可多选、显示大小与不可用原因）→ 下载所选（进度、可后台）；首次点下载时才申请本地网络权限
   - 跳过或探测失败 → 进入空状态页（"还没有学习内容，请在家里 Wi-Fi 下启动内容服务"），之后可在设置页补下
   - 未安装任何学期时，学习 Tab 只显示空状态 + 下载入口，不显示年级/课程骨架

Profile 存本地（首版不做 iCloud）；首次创建的孩子即家长 Tab「孩子切换」列表的初始成员。

| PIN 状态 | 行为 |
|---|---|
| 未设置 | 家长 Tab 点击后弹强制补设页 |
| 忘记 PIN | 四层兜底，见下节「家长凭据与恢复策略」：① 设备密码 / Face ID → ② 恢复码 → ③ 重新生成恢复码 → ④ Debug 重置（保留数据）；"重装清空"只作极端手段 |
| 已设置 | 4 位数字解锁键盘 |
| 连输错 5 次 | 锁定 1 分钟，倒计时提示 |

验收标准：
- [ ] 4 步全程可返回修改，进度可感（1/2/3/4 圆点）
- [ ] 若跳过 PIN，家长 Tab 首次进入必现补设流程

## 家长凭据与恢复策略

PIN 与恢复码都是"会被忘掉"的东西，**恢复路径必须比凭据本身更可靠**。分四层，任一层通过即可重设 PIN：

| 层 | 依据 | 能做什么 | 备注 |
|---|---|---|---|
| ① 设备密码 / Face ID | iPad 自身锁屏凭据（`LocalAuthentication`，`.deviceOwnerAuthentication` 含设备密码回退） | 直接重设 PIN | **零记忆负担**；需 `NSFaceIDUsageDescription`；建议家长给 iPad 设锁屏密码 |
| ② 6 位恢复码 | 首次设置时生成，Keychain 只存哈希 | 重设 PIN | 支持「复制」「分享到文件 App」「导出图片」；**随时可重新生成**（旧码立即失效） |
| ③ Debug 重置入口 | "家长 = 开发者"这个事实 | 仅清 PIN，**保留全部学习数据** | 仅 `#if DEBUG`；依赖 Xcode 覆盖安装不清数据容器 |
| ④ 重装清空 | — | 清空全部数据 | 极端情况，文档明示是最后手段 |

**防孩子绕过的三条约束：**

- 设备密码**只用于"忘记 PIN"流程**，不能替代日常家长验证：平时进家长 Tab 仍然要 PIN
- 家长面板记录**进入日志**（时间 + 验证方式：PIN / 恢复码 / 设备验证 / Debug 重置），设置页可查
- 设置里提供「允许用设备密码找回」开关（默认开）；关掉后只剩 ②③

**首次设置 PIN 时的检查：** 若设备未设锁屏密码 → 提示"强烈建议先给 iPad 设锁屏密码，这是唯一可靠的找回方式"，允许继续（此时 ① 不可用）。

**恢复码的保存方式**（不要只给"抄一次"）：

- 生成后提供「复制」「分享到文件 App」「存成图片」
- 设置 → 安全 → 「重新生成恢复码」：验证身份后生成新码，旧码立即失效
- PIN 与恢复码在设备上都只有 salt + 哈希，不存明文

## 内容分发：家园局域网

### 组成

```
iPad App (ipa 约 10MB, 零内容本体)
├── catalog.json                       内置: 学期目录(标题/大小/版本), 无媒体无词表
└── Application Support/Curriculum/
    ├── g2s1/                          下载解压后落这里, 设 isExcludedFromBackup
    │   ├── curriculum.json            该学期词表(Volume/Unit/UnitWord/Listening)
    │   ├── audio/  words/  img/
    └── .tmp/                          解压中的临时目录, 校验通过后原子 rename

家里的电脑 (同一 Wi-Fi)
├── serve.js                           Node 静态服务 + 扫描 packs/ 生成 manifest
└── packs/
    ├── g2s1.zip  g2s2.zip  ...
    └── manifest.json
```

- 服务地址：`http://<host>.local:8080`（用 Bonjour 主机名，避免 DHCP 换 IP 导致失效），设置页允许手动改成内网 IP
- 只绑内网、不做端口映射；服务只提供**只读静态文件**，不上传任何设备数据（录音与进度全部留本机）

### manifest 协议

```json
{
  "contentSchemaVersion": 2,
  "packs": [
    { "id": "g2s1", "grade": 2, "title": "二年级上",
      "contentVersion": 3,
      "schemaVersion": 2,
      "sizeBytes": 55400000, "sha256": "…", "url": "/packs/g2s1.zip",
      "previous": { "sha256": "…", "url": "/packs/g2s1-v2.zip" } }
  ]
}
```

- `contentVersion` = 该学期内容版本（内容变了 +1）；`schemaVersion` / `contentSchemaVersion` = **内容结构版本**（JSON 结构变了 +1）
- `previous` 指向上一版本包：新版本内容有误时，设置页可「回退到上一版本」（学习进度按 `itemCode` 保留不变）
- 服务端 `packs/` 至少保留最近 **2 个版本**，便于回滚

### 版本兼容（内容与代码解耦的必付代价）

内容能独立更新，就一定会出现「新内容包 + 旧 App」。规则如下：

| 场景 | 处理 |
|---|---|
| App 内置 `supportedSchemaVersion`（当前 2） | 下载列表里 `schemaVersion > supportedSchemaVersion` 的学期**置灰**，标注"需要更新 App"，不发起下载 |
| `curriculum.json` 顶层也带 `schemaVersion` | 解码前先校验，不符则判定"内容不兼容"，不进入学习流程 |
| JSON 字段演进 | 新增字段一律 `Optional` 或给默认值；**不允许**把已有必填字段改名/改类型（那必须 +1 schemaVersion） |
| 解码失败（结构不兼容 / JSON 损坏） | 该学期标记为"内容不兼容"并**隔离**（不参与今日任务与复习队列），首页提示"重新下载该学期"；App 不崩溃 |

### 客户端下载流程

```
探测 manifest（2 秒超时）
   |
   v
比对本地 installedVersion / schemaVersion 兼容性
   |
   v
下载 zip -> 校验 sha256
   |
   v
解压到 .tmp/<id> -> 校验文件数 + curriculum.json 引用的资产齐全 + schemaVersion
   |
   v
原子 rename 到 Curriculum/<id> -> 记录 installedVersion 与本地清单
```

- 解压依赖 **ZIPFoundation**（SPM 依赖，MIT）：iOS SDK **没有** zip 解包 API；不采用 `AppleArchive`（`.aar` 需要在 macOS 上打包，而内容服务器是 Windows）

- 不做断点续传（局域网十几秒），失败即整包重下
- 校验不通过就删临时目录，已安装内容不受影响
- 下载前检查可用空间 ≥ 包大小 × 1.5
- 存储落在 `Application Support`，`isExcludedFromBackup = true`

### 权限与网络配置（不配就连不上）

| 配置 | 值 | 作用 |
|---|---|---|
| `NSLocalNetworkUsageDescription` | "用于从家里的电脑下载学习内容" | iOS 14+ 本地网络权限，缺失则连接直接被拒 |
| `NSAppTransportSecurity > NSAllowsLocalNetworking` | `true` | 放行局域网明文 HTTP（不要用全局 `NSAllowsArbitraryLoads`） |
| `NSBonjourServices` | `_http._tcp` | 使用 `<host>.local` 发现时需要声明 |

权限时机：首次点"下载学期"时申请，不在启动时申请。

### 失败模式

| 情况 | 表现 |
|---|---|
| 电脑未启动 / 不在家 | 空状态提示"请在家里 Wi-Fi 下启动内容服务"，给 [重试] [手动填地址]；已安装内容不受影响 |
| 主机名或 IP 变了 | 先试 `<host>.local`，失败引导到设置页改地址 |
| 本地网络权限被拒 | 下载入口置灰 + 跳系统设置 |
| 下载/校验失败 | 清临时目录、允许重试，不污染已安装内容 |
| 空间不足 | 下载前拦截并提示需释放多少空间 |
| 新版本包内容有误 | 设置页「回退到上一版本」按 manifest 的 `previous` 重下，进度按 `itemCode` 保留 |
| 内容结构不兼容 / JSON 损坏 | 该学期标记"内容不兼容"并隔离（不进今日任务与复习队列），首页提示重新下载；App 不崩溃 |
| 删除学期包 | **保留** `ItemProgress` / `ReviewSchedule`（`itemCode` 稳定），首页该学期显示"内容未安装"，重下即恢复；复习队列只取已安装学期的条目 |

### 服务端 runbook

- `_download/build_resources.js`：把某学期资源 + `curriculum.json` 打成 `packs/<id>.zip`（包内结构 `g2s1/{curriculum.json,audio,words,img}`）
- `_download/serve.js`：静态服务 + 扫描 `packs/` 生成 `manifest.json`（size + sha256）
- 启动：`node serve.js`；Windows 用 `serve.bat` + 计划任务开机自启，防火墙只放行专用网络
- **学期包必须异地备份**（云盘或移动硬盘）：原始素材来自第三方站点，可能已无法重爬
- `packs/` 保留最近 2 个版本（`g2s1.zip` + `g2s1-v2.zip`），供 manifest 的 `previous` 回退使用

**内容是否进 git：** 学期包（约 50MB/学期）**不进 git**，媒体只存在于 `packs/` 与异地备份。git 里只保留 `curriculum.json`（文本、可 diff、便于审阅）与管线脚本（`build_resources.js` / `serve.js` / `jx_audio_manifest.json`）。理由：避免两份内容源，也避免 LFS 配额被学期包历史吃掉。

### 适配约定（多任务与无障碍）

| 项 | 决定 |
|---|---|
| iPad 多任务 | 首版**关闭**：Info.plist `UIRequiresFullScreen = true`。固定横屏排版，不做 Split View / Slide Over / Stage Manager 自适应（要做自适应需重排全部学习界面） |
| 动效 | 撒花/星星动画全部响应 `@Environment(\.accessibilityReduceMotion)`，开启时降级为淡入淡出 |
| 字号 | 首版**锁定字号**（不跟随 Dynamic Type），但所有可点区域与文本仍提供 VoiceOver label |
| 点击区 | 儿童手指精度低，可点元素最小 44x44pt，卡片间距 ≥16pt |

### 分发与安装

- 构建：家里的 Mac + Xcode，`.iOS(.v18)`
- 安装：**免费 Apple ID（Personal Team）+ Xcode 无线调试**，零费用
  - 签名有效期 7 天：每 7 天内在 Xcode 里对 iPad 按一次 Run 重新签名即可（首次有线配对一次，之后同一 Wi-Fi 下无线安装，iPad 不用拿到电脑前），耗时约 1 分钟
  - 过期表现为"图标还在、点开闪退"；重新签名即恢复，**数据容器不清空**（只有手动卸载才会丢数据）
  - 免费账号限制：最多 3 台设备；无 Push / iCloud / App Groups / ODR / TestFlight / 上架能力——本项目均不需要
  - `bundle id` 必须唯一且**确定后不再更改**（如 `com.aline117.englishlearning`）：改 id 等于换了一个新 App，数据全部丢失
  - **状态：待定**（工程里先用占位符）。首次装到 iPad 之前必须定下来；一旦定下就写死，不再改动
  - 若嫌每周重签麻烦：① AltStore / SideStore 自动续签（需家里电脑常开 AltServer，可与内容服务合用同一台机器）；② 升级付费账号 ¥688/年 + TestFlight（build 90 天）
- 不上架 → 无 App Review；但本地网络权限、麦克风用途文案、`PrivacyInfo.xcprivacy` 仍需配置

## 今日任务与学习调度

每次进入「学习」Tab 首页时按下列顺序计算当日任务。规则集中在一处（`DailyPlanBuilder`），不在 View 里散写：

```
进入学习首页
   |
   v
[1] 取到期复习词: ReviewSchedule.scheduledAt <= now
   |  按到期时间升序, 一次最多 20 个
   v
[2] 逐个复习 -> 写 Attempt(kind = "review") -> 更新 ItemProgress
   |                       -> 按结果计算下次间隔
   v
[3] 今日时长预算(20 分钟)还有剩余? --否--> 今日结束(只复习, 不推新词)
   |是
   v
[4] 按课本顺序取未学新词: 仅在**当前已解锁单元**内取 words 数组顺序, 一次最多 5 个
   |  同批取该单元未学句型 1 条(先词后句)
   v
[5] 该单元全部 word 与 sentence 都有 ItemProgress -> 单元完成: +5 星, 解锁下一个单元
   |  (首页进度条按条目计: 已学条目 / 总条目, 二上 = 51 项, 单元完成不额外跳进度)
```

| 参数 | 取值 | 说明 |
|---|---|---|
| 单次复习上限 | 20 个 | 到期数量超过上限时当日只复习，不推新词，避免新词被永久挤压 |
| 每日新词上限 | 5 个 | 约等于一个单元的新词量（二上 6 单元 33 词，均 5.5 词/单元） |
| 每日新句型上限 | 1 条 | 与同日新词同批推进（先词后句），使单元时长稳定在 9-10 分钟 |
| 新词顺序 | 课本顺序，且**只在当前已解锁单元内取** | 严格线性解锁：完成一个单元才解锁下一个；未解锁单元在课程列表置灰不可点 |
| 家长手动解锁 | 家长 Tab 可把指定单元标为已解锁 | 应对"学校已教到 Unit 4、App 还停在 Unit 1"的情况；不改变星星与进度，只放行访问 |
| 单元完成判定 | 该单元每个 word 与 sentence 都有 `ItemProgress` | 只看是否学过、不看对错，符合轻量激励定位 |
| 首页进度条 | 已学条目 / 总条目（二上 = 33 词 + 18 句 = 51 项） | 按条目计而非按单元计，避免"6 单元 × 10%"永远到不了 100% |
| 今日时长预算 | 20 分钟 | 与「奖励与防沉迷参数」的每日上限同源 |

- 复习环节的作答同样落一条 `Attempt`（`kind = "review"`），既驱动复习调度，也参与正确率聚合（见下节）
- 中途杀 App 后重入首页按最新数据重算，**不锁定"今日清单"**，避免任务卡死

**「今天」的边界：** 一律按**本地时区 00:00** 切分（跨午夜立即重置当日配额：20 分钟预算、每日 5 词 / 1 句、今日已发星）。不引入"学习日"或跨午夜宽限，规则越简单越不容易出错。

**「继续学习」按钮：** 永远等于"今日任务里第一个未完成的环节"，**不单独维护"上次学到哪"的游标**。这样只有一个状态源：孩子昨天学到 Unit 2 中途退出，今天首页仍是"复习 → 新词"，"继续学习"直接进入第一个未完成环节；若今日复习队列已占满 20 分钟，它就指向复习而不是新词。

**学完整册后的终态：** 当已学条目 = 总条目且今日无到期复习时，今日任务卡替换为"🎉 二上已学完"卡片，展示累计学习天数 / 总时长 / 平均正确率，并给"去下载其他学期"入口（跳设置页下载管理）。不会出现空白首页。

**卡住可跳过：** 同一环节连续失败 3 次（跟读未达标 或 连续答错）→ 出现「先跳过」按钮。跳过的行为：
- 不写 `ItemProgress`（不记为已学），不计星
- 仍写一条 `Attempt`（`passed = false`），供家长报告统计薄弱项
- 该条目顺延到下次队列，不进入复习调度

## 指标口径与数据字典

**架构决定：存明细，不存聚合。** 每次交互写一条 `Attempt`，正确率与薄弱词在读取时按口径聚合；`LearningSession` 退化为「会话边界 + 时长」。

```swift
@Model final class Attempt {
    #Index<Attempt>([\.profileID, \.at])   // 报告按"孩子 + 时间范围"高频查询
    var profileID: UUID
    var sessionID: UUID
    var itemCode: String      // "w:758201" / "s:u1-s1"
    var itemKind: String      // word / sentence
    var unitCode: String
    var kind: String          // speak / review / match / game
    var passed: Bool
    var at: Date
}

enum AccuracyRule {
    static let countedKinds: Set<String> = ["speak"]   // 唯一口径开关
}
```

- `LearningSession` 只保留 `startedAt` / `endedAt` / `durationSeconds`，**删除 `correctCount` / `totalCount` / `accuracy`**
- 改口径只动 `countedKinds` 一行，历史数据随新口径重算，不会出现"趋势图断层"
- 容量：约 35 条/天、一年约 1.2 万条，SwiftData 无压力；如需控体积按学期归档旧 `Attempt`

**默认口径（`countedKinds = ["speak"]`）：**

| 环节 | 是否写 Attempt | 是否计入正确率 | 是否发星 |
|---|---|---|---|
| 说（跟读） | 是（`speak`） | 是（默认唯一计入项） | 达标 +星 |
| 复习（翻卡跟读） | 是（`review`） | 否（默认不计入） | 按规则 |
| 认（拖拽配对） | 是（`match`） | 否（默认不计入） | 答对 +1 |
| 游戏（听音选图） | 是（`game`） | 否（默认不计入） | 答对 +1 |

**指标字典：**

| 指标 | 口径 | 数据来源 |
|---|---|---|
| 当日正确率 | 当日 `Attempt` 中 `kind ∈ countedKinds` 的 `passed` 占比 | `Attempt` |
| 条目掌握度 | 该 item（词或句）达标次数映射到 `masteryLevel`（分级规则见参数表） | `Attempt` + `ItemProgress` |
| 薄弱条目 | `timesSeen >= 2` 且 正确率 `< 0.6`（正确率同样按 `countedKinds` 计算） | `ItemProgress` |
| 新学单词数 / 新学句型数 | 当日首次产生 `Attempt` 的 `itemKind = word` / `sentence` 条目数，**分开统计** | `Attempt` |
| 单元完成度 | 已完成单元数 / 总单元数（二上 = 6）；单元完成 = 该单元全部 word 与 sentence 都有 `ItemProgress` | `ItemProgress` |
| 首页进度条 | 已学条目数 / 总条目数（二上 = 51 项），不按单元计 | `ItemProgress` |
| 当日学习时长 | 当日各 `LearningSession.durationSeconds` 之和 | `LearningSession` |
| 本周学习天数 | 本周内「单日累计 ≥3 分钟」的日期去重计数（不足 3 分钟不计入，避免点开即算） | `LearningSession` |

标「待确认」的项（`masteryLevel` 分级、复习间隔）已在「奖励与防沉迷参数」定稿，本节不再是待确认状态。

## 奖励与防沉迷参数

数值集中定义在一处常量文件，不散落在各 View 里。标「待确认」的尚未拍板，实现前需收敛成具体值。

| 参数 | 取值 | 状态 |
|---|---|---|
| 答对一题 | +1 星 | 已定（reward-system spec） |
| 跟读达标 | +2 星（单词与句型同规则） | 已定 |
| 完成一个学习单元 | +5 星（不额外跳进度；进度由条目数决定） | 已定 |
| 徽章目录 | 6 个：初次学习 / 连学 3 天 / 连学 7 天「坚持小达人」/ 完成首个单元 / 完成整册（6 单元）/ 跟读达标 20 次 | 已定 |
| 首次达标奖励 | 同一 `itemCode` 首次达标额外 +3 星（`grantKey = first:<itemCode>`，幂等） | 已定 |
| 每日学习时长上限 | 20 分钟（与今日任务预算同源） | 已定 |
| 每日发星上限 | 与 20 分钟联动：超时后只允许无奖励复习 | 已定 |
| 星星余额上限 | 500（达到后提示兑换，不再发星） | 已定（reward-system spec） |
| 同一奖励兑换冷却 | 3 天 | 已定（reward-system spec） |
| 兑换规则字段 | 见「奖励体系」的 `RedemptionRule` 定义（11 个字段） | 已定 |
| 复习间隔 | 1→3→7→14→30 天；答错回退一级（最低回到 1 天）；新词首次复习 = 学完次日 | 已定 |
| 掌握度分级 `masteryLevel` | 0 未学 / 1 已见 1 次 / 2 达标 1 次 / 3 达标 ≥3 次且跨 ≥2 天 / 4 达标 ≥5 次且跨 ≥3 天 | 已定 |
| 星星记账 | 流水制 `StarLedger`，余额与"今日已发"均由流水聚合，无需归零任务 | 已定（见「健壮性与合规约定」） |

## 奖励体系

### 四层结构（作用不同，不能只做第 ④ 层）

| 层 | 作用 | 发放方 | 示例 |
|---|---|---|---|
| ① 即时虚拟反馈 | 维持当下动力 | 系统自动 | 星星、火焰、音效动画 |
| ② 成就型虚拟奖励 | 建立长期目标感 | 系统自动 | 徽章、称号、头像装扮、护照印章 |
| ③ **学习型奖励** | **把星星花在"再多学一点"上** | 家长确认 | 解锁故事/挑战关、给自己的头像加装扮、录朗读进作品集、"当小老师" |
| ④ 现实奖励 | 把虚拟成果换成现实满足 | 家长确认 | 动画片、玩具、亲子时间、选择权 |

**为什么必须有第 ③ 层**：如果星星只能换"离开学习"的东西（看视频、玩游戏），等于在奖励"逃离学习"；加上"用星星换更多学习内容或展示机会"，奖励才和学习同向。

### 预置奖励模板（家长勾选启用，可改星星数）

**小额（20-60★，日常够得着）**

| 奖励 | 类别 | 默认 | 上限 |
|---|---|---|---|
| 睡前多讲一个故事 | 亲子 | 30★ | 每日 1 次 |
| 选一首歌当学习背景音 | 特权 | 20★ | 每日 1 次 |
| 给自己的头像换一顶帽子 | 学习型 | 40★ | 不限 |
| 今晚我点一道菜 | 特权 | 40★ | 每周 2 次 |
| 多 15 分钟动画片 | 现实 | 50★ | 每日 1 次 |

**中额（80-200★，一周攒得到）**

| 奖励 | 类别 | 默认 | 上限 |
|---|---|---|---|
| 看 30 分钟动画片 | 现实 | 100★ | 每日 1 次 |
| **当 10 分钟小老师，教爸爸妈妈今天学的词** | 学习型 | 100★ | 每日 1 次 |
| **解锁一个「故事时间」** | 学习型 | 120★ | 每周 2 次 |
| 和爸爸玩 20 分钟桌游 | 亲子 | 120★ | 每周 2 次 |
| 选一本新绘本 | 现实 | 150★ | 每月 2 次 |
| 周末去公园 / 骑车 | 亲子 | 150★ | 每周 1 次 |

**大额（300-600★，一个月攒得到，训练延迟满足）**

| 奖励 | 类别 | 默认 | 上限 |
|---|---|---|---|
| **给自己录一段英文朗读，存进「我的作品集」** | 学习型 | 300★ | 不限 |
| 一个想要的小玩具 | 现实 | 500★ | 每月 1 次 |
| 一次亲子外出（动物园 / 游乐场） | 亲子 | 600★ | 每季 1 次 |

- 家长可全部关掉，只留 2-3 个：**奖励太多会稀释价值**
- 大额奖励在奖励页显示"储蓄目标条"（如 `已存 320 / 500`），不做随机抽奖

### 促进学习的设计原则

1. **质量型 > 数量型**：发星/奖励条件用"跟读达标 5 次""攻克 3 个薄弱词"，不用"学满 20 分钟"——后者会让孩子磨时间
2. **过程型奖励**：连续 3 天把到期复习清空 → 小奖励；直接推动复习习惯，比"学新词"更重要
3. **输出型奖励**（最推荐）：花星星换"给家长讲今天学的 3 个词""录一段朗读"——讲出来是主动回忆，记忆效果远好于再听一遍
4. **延迟满足**：大额奖励做成储蓄目标，而不是一次性全给小奖励
5. **亲子绑定**：一部分奖励必须和家长一起完成（桌游、共读、外出）；孩子真正想要的是陪玩，家长参与本身就是最强强化物

**反面清单（不做）**：奖励"学满时长"、奖励"可空刷的连续打卡"、把奖励做成随机抽奖（赌博感 + 不可预期）。

### 家长可配置

`RedemptionRule` 字段（首版需补齐，当前只有 title/starCost/emoji）：

```
id / title / icon / category(现实·亲子·特权·学习型)
starCost / dailyLimit / weeklyLimit / cooldownDays
requiresApproval(默认 true) / isActive / sortOrder
```

家长端两个页面：

- **奖励库**：预置模板列表，勾选启用 + 改星星数 + 设每日/每周上限
- **奖励设置**：开关「必须完成今日任务才能申请」「单日最多兑换 1 次」「大额奖励需二次确认」

防刷沿用既有规则：每日发星上限、星星余额上限 500、同一奖励冷却 3 天。

## 可调设置（家长面板）

原则：**影响孩子练习强度、但不会破坏算法的项开放给家长；算法本身（复习间隔、掌握度分级、正确率口径）不开放**，避免家长调出无法验收的状态。

| 设置项 | 默认 | 可选档位 | 生效点 |
|---|---|---|---|
| 认环节每屏配对数 | 3 对 | 2 / 3 / 4 / 6 | 一屏题量；单元词多于一屏时自动分轮 |
| 每单元最少练习轮数 | 1 轮 | 1 / 2 / 3 | 未达轮数前该单元不算完成 |
| 连续失败几次出现「先跳过」 | 3 次 | 2 / 3 / 4 / 5 / 关闭 | 关闭后不出现跳过按钮，必须做对才能过 |
| 每日新词数 | 5 | 3 / 5 / 8 | 今日任务生成 |
| 每日新句型数 | 1 | 0 / 1 / 2 | 今日任务生成 |
| 单次复习上限 | 20 | 10 / 20 / 30 | 今日任务生成 |

- 按 **Profile 独立保存**：新增 `LearningSettings`（一个孩子一份），两个娃强度不同互不影响
- 用**档位选择**而非自由输入，避免填出极端值；改动即时生效，首页「预计 X 分钟」随之重算
- 每日新词 / 新句型 / 复习上限仍受 20 分钟预算约束：调大也不会突破时长上限，只会挤占当天的新内容

## 健壮性与合规约定

实现时按本节的"标准做法"来，不要各 View 自行发挥。

### 音频会话与中断

| 场景 | 处理 |
|---|---|
| Category | 听/认/游戏：`.playback`（配 `.duckOthers`）；说/跟读：`.playAndRecord` + `.defaultToSpeaker` + `.allowBluetooth`。切换前后都要 `setActive` |
| 系统打断（来电/闹钟） | 监听 `interruptionNotification`：began 时暂停并保存 `currentTime`；ended 时判断 `.shouldResume` 再恢复 |
| 拔耳机/切设备 | `routeChangeNotification` 的 `.oldDeviceUnavailable` → 暂停，**不自动改走外放**（否则课堂场景会突然外放） |
| 媒体服务重置 | `mediaServicesWereResetNotification` → 重建 session 与 player，重设 category |
| 录音中被中断 | 丢弃本次录音、提示"再试一次"，**不留半截 `Attempt`**（保证明细干净） |

### 麦克风权限

- 首次引导 3 步**不申请任何权限**
- 第一次进「说」/「跟我读」前先展示自定义说明页（"要听你读单词，需要麦克风"），用户点"开始"后才调用 `AVAudioApplication.requestRecordPermission`
- 被拒绝：给"去设置"深链（`UIApplication.openSettingsURLString`）+ 允许"跳过说环节"，其余环节照常可学
- 无麦克风权限时正确率为 0 样本，报告显示 `—` 而不是 `0%`
- 拒绝后不再自动重复弹窗（系统也只会弹一次，重复调用无意义）

### 缺失资产

- 图片缺失 → 灰底占位 + `photo` 图标，不阻断流程
- 音频缺失 → 按 3 秒静音占位推进，该词标记"暂不可发音"，仍可参与认/游戏
- Debug 构建 `assertionFailure`，缺失清单同时写入本地诊断日志（设置页可查）
- 发布版**绝不因缺资产崩溃**

### 会话与奖励一致性

- `LearningSession` 创建时 `endedAt = nil`；离开学习页或 App 进后台立即结算
- 冷启动把遗留未结算会话封口：`endedAt = lastActiveAt`（UserDefaults 记录的最后前台时刻），避免时长虚高
- 时长用单调时钟（`ProcessInfo.systemUptime` 差值）计算，不受系统时间改动影响
- **星星改流水制**：`StarLedger(profileID, amount, reason, grantKey, at)`，`grantKey` 唯一（`#Unique([\.grantKey])`），如 `unit:shangce-u1`、`attempt:<attemptID>`、`daily:<yyyy-MM-dd>`
  - 余额 = `sum(amount)`；"今日已发"= 当日流水之和（因此不需要 `earnedToday` 字段与归零任务）
  - 重复发星被唯一键挡掉 → 重进结算页不会二次加分
  - 家长报告可直接列出"今天这些星是怎么赚的"

### 系统时间被改

- UserDefaults 记 `lastKnownDate`；每次启动/回前台比较，若 `now < lastKnownDate - 5 分钟` 判定为时间回拨
- 回拨后：冻结当日发星、只允许复习、首页显示"设备时间异常"
- 复习到期判定使用 `max(now, lastKnownDate)`，防止靠调时间刷复习

### 合规清单（上架前必须齐）

| 项 | 要求 |
|---|---|
| `PrivacyInfo.xcprivacy` | 放 App target 根目录（非 SPM library）；声明 required-reason API（UserDefaults `CA92.1`、文件时间戳 `C617.1` 等）并声明"不追踪、不收集数据" |
| `NSMicrophoneUsageDescription` | 文案："用于跟读练习，录音仅在本机处理，不会上传" |
| `NSFaceIDUsageDescription` | 文案："用于家长验证，快捷进入家长面板"（仅"忘记 PIN"流程使用设备验证） |
| 录音文件生命周期 | 存 `tmp/recordings/`，评分完成即删；启动时清理超过 1 天的残留 |
| 卸载即丢数据 | 设置页明示"删除 App 会清空学习记录"；提供导出学习记录 JSON 的分享入口 |
| 中文界面不跟随系统 | `CFBundleDevelopmentRegion = zh_CN`、不做本地化，日期统一用 zh_CN 固定格式 |
| 版权 | 现有课文原声与教材配图仅限个人使用；**上架 App Store 前必须替换为授权素材或自采** |

## 竞品分析

### 直接竞品
- **同步学**（深圳方直科技）：覆盖沪教版（深圳），AI语音评测，¥298/年
- **英语天天练**：85个版本最全，¥368/年
- **学宝**：动画视频，学币兑换，免费+内购
- **小学英语同步学习**：多版本点读，¥68/年

### 差异化优势
- 虚拟→现实激励兑换闭环（市场空白）
- 听说为主的学习循环（竞品偏读写）
- 多孩子 Profile（竞品多为单用户）
- 防沉迷+家长兑换机制（竞品薄弱）
- 完全免费（竞品多为订阅制）
