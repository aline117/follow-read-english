## 1. 项目脚手架

- [x] 1.1 创建 SwiftUI iPad 项目结构（Xcode 项目或 Swift Package）
- [ ] 1.2 配置 iPad 目标、横竖屏支持、**iOS 18+** 部署目标（`Package.swift` 现为 `.iOS(.v16)`，需改 `.iOS(.v18)`；Info.plist 横竖屏配置随 App 工程一并补齐）
- [x] 1.3 设置 SwiftData 模型容器和基础目录结构
- [ ] 1.4 补合规配置：`NSMicrophoneUsageDescription`（跟读、仅本地处理）、`CFBundleDevelopmentRegion = zh_CN`（中文界面不跟随系统）、`PrivacyInfo.xcprivacy`（required-reason API + 不追踪声明）
- [ ] 1.5 补本地网络配置：`NSLocalNetworkUsageDescription`、`NSAppTransportSecurity > NSAllowsLocalNetworking = true`、`NSBonjourServices = _http._tcp`（见 design「内容分发：家园局域网」）
- [ ] 1.6 补适配约定：`UIRequiresFullScreen = true`（关闭 iPad 多任务）、动画响应 `accessibilityReduceMotion`、锁定字号、可点元素 ≥44x44pt（见 design「适配约定」）

## 2. 数据模型

- [x] 2.1 定义核心数据模型：Student、Profile、Course、Lesson、Word、Sentence
- [x] 2.2 定义激励数据模型：Reward、Badge、RedemptionRule、Redemption
- [x] 2.3 定义学习记录模型：LearningSession、WordProgress、ReviewSchedule
- [x] 2.4 创建 JSON 内容加载器和解析器
- [ ] 2.5 统一内容身份：内容实体用业务码 String（`UnitWord.id="758201"`、`Sentence.id="s1"`、`Unit.id="u1"`、`Volume.id="shangce"`）；条目统一编码 `itemCode`（`w:758201` / `s:u1-s1`），单词与句型共用同一套进度/复习/评分表；`ReviewSchedule.wordID: UUID` → `itemCode: String`，`LearningSession.courseID: UUID` → `unitCode` + `volumeCode`；`ItemProgress` 用 `#Unique([\.profileID, \.itemCode])`（决策见 design Decision 6）
- [ ] 2.6 调整模型形态：删除 4 个内容型 `@Model`（`CurriculumCourse` / `Lesson` / `Word` / `Sentence`），内容只保留 `Decodable` struct（新增 `Sentence` 的 `Decodable` 版：`en` / `zh` / `pattern` / `chunks` / `audio`）；`WordProgress` 改名 `ItemProgress` 并加 `itemKind`（word/sentence）；新增 `Attempt` 明细模型（`profileID` / `sessionID` / `itemCode` / `itemKind` / `unitCode` / `kind` / `passed` / `at`）；`LearningSession` 只留会话边界与时长（删 `correctCount` / `totalCount` / `accuracy`）；`Reward` 聚合模型改为 `StarLedger` 流水（`grantKey` 唯一，`#Unique`）；`Schema([...])` 最终为 9 个类型（决策见 design「指标口径与数据字典」+「健壮性与合规约定」）

## 3. 年级与课程模块

- [ ] 3.1 实现年级选择页面（1-6 年级卡片；**首版仅"二年级"可选**，其余置灰标"即将推出"）
- [ ] 3.2 实现课程列表页面（按课本章节展示）
- [ ] 3.3 实现课程内容数据加载和缓存
- [ ] 3.4 实现首页今日任务卡（按 design「今日任务与学习调度」：复习优先 → 课本顺序推新词；上限 20 复习 / 5 新词 / 1 句型；单元完成 +5 星；进度条按条目计）
- [ ] 3.5 实现 `ResourceLocator`（按 (学期, 相对路径) 在 `Application Support/Curriculum/<semester>/` 定位，找不到判定"内容未安装"）并改造 `CurriculumLoader` 走它
- [ ] 3.6 实现内容下载管理 UI：manifest 探测（2s 超时）、可下载学期列表、下载进度/后台、sha256 校验、失败重试、回退上一版本（`previous`）、删除释放空间、空间预检查、空状态页（无已安装学期时）

## 4. 核心学习循环

- [ ] 4.1 实现"听"模块：音频播放器 + 图片/文字展示（慢速用 `AVAudioEngine` + `AVAudioUnitTimePitch`，变速不变调）
- [ ] 4.2 实现"说"模块：录音功能 + 简单语音评测（音量+时长）
- [ ] 4.3 实现"认"模块：图片-单词拖拽配对
- [ ] 4.4 实现"游戏"模块：听音选图小游戏
- [ ] 4.5 实现"复习"模块：间隔重复调度器（队列按 design「今日任务与学习调度」生成：到期优先、上限 20；间隔规则见「奖励与防沉迷参数」，每次作答写 `Attempt(kind="review")`）
- [ ] 4.6 实现学习单元拆分逻辑（5-8分钟/单元）
- [ ] 4.7 实现音频会话管理：category 切换（playback / playAndRecord+defaultToSpeaker）、interruption / routeChange / mediaServicesWereReset 三类通知、录音被打断时丢弃半截 Attempt（见 design「健壮性与合规约定」）
- [ ] 4.8 实现麦克风权限流程：说明页 → `AVAudioApplication.requestRecordPermission` → 拒绝后降级（跳过说环节、正确率显示 `—`、去设置深链）
- [ ] 4.9 实现缺失资产降级：占位图 / 静音 3 秒推进 / debug 断言 / 本地诊断日志
- [ ] 4.10 实现句子学习环节（首版范围 A）：听整句（含慢速）、跟读整句（沿用音量+时长口径）、词块排序（`chunks` 拖拽）、听音补全（3 选 1）、整句复习（共用 `ReviewSchedule`）

## 5. 激励系统

- [ ] 5.1 实现星星即时反馈（答对+1，动画庆祝）；每次发星写一条 `StarLedger`，`grantKey` 幂等（重进结算页不重复加分）
- [ ] 5.2 实现徽章系统（design 参数表的 6 个徽章：初次学习 / 连学 3 天 / 连学 7 天 / 完成首个单元 / 完成整册 / 跟读达标 20 次）
- [ ] 5.3 实现星星余额和进度展示（余额 = `StarLedger` 聚合，"今日已发"同理，不存聚合字段）
- [ ] 5.4 实现防沉迷控制（每日 20 分钟上限、兑换冷却 3 天、星星上限 500、系统时间回拨冻结——见 design「健壮性与合规约定」）

## 6. 家长面板

- [ ] 6.1 实现家长验证（4 位 PIN + Keychain salt/哈希；忘记 PIN 用 6 位恢复码重置）
- [ ] 6.2 实现学习报告页面（时长、正确率、进度；正确率按 `AccuracyRule.countedKinds` 聚合 `Attempt`，不读 `LearningSession` 聚合字段——见 design「指标口径与数据字典」）
- [ ] 6.3 实现兑换规则管理（创建/编辑/删除）
- [ ] 6.4 实现兑换审核流程
- [ ] 6.5 实现多 Profile 切换与生命周期管理（创建上限 4 个、切换时 `profileID` 持久化、删除级联清理 6 张表且至少保留 1 个、家长 Tab 可改年级——见 design Decision 5）
- [ ] 6.6 实现设置页合规项：卸载即清空的明示、学习记录导出 JSON、本地诊断日志查看

## 7. 内容资源

- [x] 7.1 收集 2 年级沪教版课本单词数据（JSON 格式）
- [x] 7.2 从网络资源获取单词发音音频
- [x] 7.3 从网络资源获取单词配图
- [ ] 7.4 把二上资源迁出 App：`app/Resources/Curriculum/` → 学期包 `packs/g2s1.zip`（内含 `curriculum.json` + `audio/ words/ img/`）
- [ ] 7.5 实现 `_download/serve.js`（静态服务 + 扫描 `packs/` 生成 `manifest.json`：size + sha256）与 `serve.bat`，并写 runbook（开机自启、防火墙只放行专用网络、`<host>.local` 主机名）
- [ ] 7.6 内置 `catalog.json`（学期目录：id / 标题 / 大小 / 版本，不含任何媒体与词表）
- [ ] 7.7 管线入版本库 + 学期包异地备份：`_download/build_resources.js`、`serve.js`、`jx_audio_manifest.json`、`words_raw.json` 纳入 git（调整 `.gitignore`，只忽略原始音视频），`packs/*.zip` 备份到云盘或移动硬盘
- [ ] 7.8 补录二上核心句型并生成音频：6 单元 × 2-3 条（约 18 条），写入 `sentences`（`en` / `zh` / `pattern` / `chunks` / `audio`），音频用 TTS 生成到 `sentences/{unit}/{id}.mp3`

> 后续内容任务（不阻塞首版）：档位 B「课文对话全文」约 300-400 句，需转录 129 条课文原声并按句切时间点（3-6 小时，用于逐句高亮跟读）；档位 C「Read a story」6 篇故事。两者都只涉及内容补录与 JSON 扩展，不改架构。

> 已完成范围：仅二上（shangce）6 单元 33 词；课文原声 129 条。当前产物仍在 `app/Resources/Curriculum/`（grade2.json + audio 129 + words 33 + img 33，共 195 个文件，53MB），按 7.4 迁出为学期包后 App 内不再带内容本体。
> 二下（xiace，约 25 词）教材版本待定，推迟到寒假补。

## 8. 集成验证

- [ ] 8.1 验证完整学习流程：选年级 → 选课 → 学习 → 获得奖励
- [ ] 8.2 验证家长流程：验证 → 查看报告 → 设置兑换规则 → 审核兑换
- [ ] 8.3 验证防沉迷：达到上限后停止奖励
- [ ] 8.4 验证多 Profile 数据隔离
- [ ] 8.5 验证内容分发：电脑未启动时的空状态、首次下载与校验、飞行模式下已安装内容可学、删除学期包后进度保留且重下可恢复

## 9. 质量保障

- [ ] 9.1 单元测试（XCTest）覆盖四个纯逻辑模块：`CurriculumLoader` 解码与资产校验、复习间隔算法（1→3→7→14→30 与答错回退）、`StarLedger` 幂等（同一 grantKey 重复发放只生效一次）、`AccuracyRule` 聚合口径
- [ ] 9.2 手测清单：Reduce Motion 下动画降级、VoiceOver 朗读关键按钮、44pt 点击区、连输错 5 次锁定、系统时间回拨冻结发星
