## 1. 项目脚手架

- [x] 1.1 创建 SwiftUI iPad 项目结构（Xcode 项目或 Swift Package）
- [x] 1.2 配置 iPad 目标、横竖屏支持、**iOS 18+** 部署目标（`Package.swift` 现为 `.iOS(.v16)`，需改 `.iOS(.v18)`；Info.plist 横竖屏配置随 App 工程一并补齐）
  - 2026-10-27：原型是 iPad 横屏 1024×768，Info.plist 先锁成仅横屏；若要竖屏需重排学习页（本条改为只支持横屏）。
- [x] 1.3 设置 SwiftData 模型容器和基础目录结构
- [x] 1.4 补合规配置：`NSMicrophoneUsageDescription`（跟读、仅本地处理）、`NSFaceIDUsageDescription`（家长验证找回）、`CFBundleDevelopmentRegion = zh_CN`（中文界面不跟随系统）、`PrivacyInfo.xcprivacy`（required-reason API + 不追踪声明）
- [x] 1.5 补本地网络配置：`NSLocalNetworkUsageDescription`、`NSAppTransportSecurity > NSAllowsLocalNetworking = true`、`NSBonjourServices = _http._tcp`（见 design「内容分发：家园局域网」）
- [ ] 1.6 补适配约定：`UIRequiresFullScreen = true`（关闭 iPad 多任务）、动画响应 `accessibilityReduceMotion`、锁定字号、可点元素 ≥44x44pt（见 design「适配约定」）
- [x] 1.7 引入 **ZIPFoundation**（SPM）作为学期包解压依赖（iOS 无原生 zip API）
- [ ] 1.8 确定并固定 `bundle id`（**首次装到 iPad 前必须定**，一旦确定不可再改；占用例 `com.aline117.englishlearning`）
- [x] 1.9 搭导航骨架：孩子模式只有「学习 / 奖励」两个 Tab + 顶栏右上角 🔒 家长入口；家长模式用 `fullScreenCover` + 独立 `NavigationStack`（6 个入口 + 退出家长模式）——见 design「导航结构」

## 2. 数据模型

- [x] 2.1 定义核心数据模型：Student、Profile、Course、Lesson、Word、Sentence
- [x] 2.2 定义激励数据模型：Reward、Badge、RedemptionRule、Redemption
- [x] 2.3 定义学习记录模型：LearningSession、WordProgress、ReviewSchedule
- [x] 2.4 创建 JSON 内容加载器和解析器
- [x] 2.5 统一内容身份：内容实体用业务码 String（`UnitWord.id="758201"`、`Sentence.id="s1"`、`Unit.id="u1"`、`Volume.id="shangce"`）；条目统一编码 `itemCode`（`w:758201` / `s:u1-s1`），单词与句型共用同一套进度/复习/评分表；`ReviewSchedule.wordID: UUID` → `itemCode: String`，`LearningSession.courseID: UUID` → `unitCode` + `volumeCode`；`ItemProgress` 用 `#Unique([\.profileID, \.itemCode])`（决策见 design Decision 6）
- [x] 2.6 调整模型形态：删除 4 个内容型 `@Model`（`CurriculumCourse` / `Lesson` / `Word` / `Sentence`），内容只保留 `Decodable` struct（新增 `Sentence` 的 `Decodable` 版：`en` / `zh` / `pattern` / `chunks` / `audio`）；`WordProgress` 改名 `ItemProgress` 并加 `itemKind`（word/sentence）；新增 `Attempt` 明细模型（`profileID` / `sessionID` / `itemCode` / `itemKind` / `unitCode` / `kind` / `passed` / `at`，加 `#Index([\.profileID, \.at])`）；新增 `LearningSettings`（每个孩子一份练习强度设置，字段见 design「可调设置」）；新增 `ParentProfile`（最多 2 位家长：name / avatar / isActive，仅用于审核记录）；`Redemption` 加 `reviewedBy`；`LearningSession` 只留会话边界与时长（删 `correctCount` / `totalCount` / `accuracy`）；`Reward` 聚合模型改为 `StarLedger` 流水（`grantKey` 唯一，`#Unique`）；`Schema([...])` 最终为 11 个类型（决策见 design「指标口径与数据字典」+「健壮性与合规约定」）
- [x] 2.7 实现 `ProfileDataPurger`：按 `profileID` 逐表删除 8 张表（`ItemProgress` / `Attempt` / `LearningSession` / `ReviewSchedule` / `StarLedger` / `Badge` / `Redemption` / `LearningSettings`，幂等），不依赖 `@Relationship` cascade（见 design Decision 5）

## 3. 年级与课程模块

- [ ] 3.1 实现年级选择页面（1-6 年级卡片；**首版仅"二年级"可选**，其余置灰标"即将推出"）
  - 2026-10-27：原型里没有这一页（首页 A6 直接是「今天的任务」，学期在 A4/C4 里选），故按原型改为首版不做年级卡片页；如需保留请更新本条与 design。
- [x] 3.2 实现课程列表页面（按课本章节展示；严格线性解锁，未解锁单元**置灰不可点**）
- [x] 3.3 实现课程内容数据加载和缓存
- [ ] 3.4 实现首页今日任务卡（按 design「今日任务与学习调度」：复习优先 → 仅从**当前已解锁单元**按课本顺序推新词；上限 20 复习 / 5 新词 / 1 句型；单元完成 +5 星并解锁下一单元；进度条按条目计；含"继续学习 = 第一个未完成环节"、学完整册终态卡、"今天"按本地时区 00:00 切分）
- [x] 3.5 实现 `ResourceLocator`（按 (学期, 相对路径) 在 `Application Support/Curriculum/<semester>/` 定位，找不到判定"内容未安装"）并改造 `CurriculumLoader` 走它
- [x] 3.6 实现内容下载管理 UI：manifest 探测（2s 超时）、`schemaVersion` 兼容性判断（超版本置灰标"需要更新 App"）、可下载学期列表、下载进度/后台、sha256 校验（ZIPFoundation 解压）、失败重试、回退上一版本（`previous`）、解码失败则隔离并提示重下、删除释放空间、空间预检查、空状态页（无已安装学期时）

## 4. 核心学习循环

- [x] 4.1 实现"听"模块：音频播放器 + 图片/文字展示（**新学默认 0.75x、复习默认原速**；0.5x / 0.75x / 原速三档，`AVAudioEngine` + `AVAudioUnitTimePitch` 变速不变调）
  - 2026-10-27：现有播放器只有「慢速 0.7 / 原速」两档，待按设计改为三档并支持本次学习内记忆选择
- [x] 4.2 实现"说"模块：录音功能 + 语音评测
  - 2026-10-27：按用户要求，单词的「认」和「说」合并成一个循环（见 design「单词跟读（认·说合练）」）：`AudioRecorder`（按原音自动定录音上限）+ `PronunciationEvaluator`（设备端语音识别转文本，与目标词比相似度，音量/时长兜底）+ `FollowReadPanel`（录音/对比/达标/再试一次/先跳过），达标自动进入下一个词；当前游戏/句型/复习未接入，全部达标或主动结束时先进结算页，接入后续环节后改为进入游戏
  - 待对齐设计：①评测基础设施异常（识别超时 / 音频不可读 / 录音被打断）应"提示重试、不写 `Attempt`"，当前实现会写失败明细；②首次达标 +3、每次达标 +2（同一 item 每天一次），当前实现是首次 +1；③失败卡需给「原因 + 建议配速按钮 + 差异位置 + 三步纠错法」，当前只有一句提示
- [x] 4.3 实现"认"模块（已并入 4.2）
  - 2026-10-27：单词的「认」=「看大图认词」，与跟读同屏；原计划的图片-单词拖拽配对与「每屏配对数 / 最少练习轮数」设置一并取消（句型的词块排序仍属 4.10）
- [ ] 4.4 实现"游戏"模块：听音选图小游戏
- [ ] 4.5 实现"复习"模块：间隔重复调度器（队列按 design「今日任务与学习调度」生成：到期优先、上限读 `LearningSettings`；间隔规则见「奖励与防沉迷参数」，每次作答写 `Attempt(kind="review")`）
- [ ] 4.6 实现学习单元拆分逻辑（5-8分钟/单元）
- [ ] 4.7 实现音频会话管理：category 切换（playback / playAndRecord+defaultToSpeaker）、interruption / routeChange / mediaServicesWereReset 三类通知、录音被打断时丢弃半截 Attempt（见 design「健壮性与合规约定」）
- [ ] 4.8 实现麦克风权限流程：说明页 → `AVAudioApplication.requestRecordPermission` → 拒绝后降级（跳过说环节、正确率显示 `—`、去设置深链）
  - 2026-10-27：已做「请求权限 + 拒绝后卡片（去设置深链 / 先跳过）」，独立说明页与正确率 `—` 待补
- [ ] 4.9 实现缺失资产降级：占位图 / 静音 3 秒推进 / debug 断言 / 本地诊断日志
- [ ] 4.10 实现句子学习环节（首版范围 A）：听整句（0.5x / 0.75x / 原速）、跟读整句（复用单词跟读的设备端识别评测与纠错建议）、词块排序（`chunks` 拖拽）、听音补全（3 选 1）、整句复习（共用 `ReviewSchedule`）
- [ ] 4.11 实现「先跳过」机制：连续失败次数读 `LearningSettings`（默认 3 次，可关闭）后出现跳过入口；不写 `ItemProgress`、不计星、记一条 `Attempt(passed=false)`、不进复习调度
  - 2026-10-27：跟读面板已固定 3 次后出现「先练下一个」，且跳过不计星、不写 `ItemProgress`；读 `LearningSettings`、关闭开关与「不进复习调度」待接

## 5. 激励系统

- [ ] 5.1 实现星星即时反馈（答对+1，动画庆祝）；每次发星写一条 `StarLedger`，`grantKey` 幂等（重进结算页不重复加分）
  - 2026-10-27：跟读已按 `grantKey = "first:<itemCode>"` 幂等发星、头部余额读流水；设计定稿为「首次达标 +3、每次达标 +2（同一 item 每天一次）」，当前实现是首次 +1，待按设计调整；撒花动画与结算页庆祝待做
- [ ] 5.2 实现徽章系统（design 参数表的 6 个徽章：初次学习 / 连学 3 天 / 连学 7 天 / 完成首个单元 / 完成整册 / 跟读达标 20 次）
- [ ] 5.3 实现星星余额和进度展示（余额 = `StarLedger` 聚合，"今日已发"同理，不存聚合字段）
- [ ] 5.4 实现防沉迷控制（每日 20 分钟上限、兑换冷却 3 天、星星上限 500、系统时间回拨冻结——见 design「健壮性与合规约定」）

## 6. 家长面板

- [ ] 6.1 实现家长验证与恢复：4 位 PIN（Keychain salt/哈希）+ 6 位恢复码（可复制/分享/存图、可重新生成）+ 四层恢复路径（设备密码·Face ID 经 `LocalAuthentication` → 恢复码 → 重新生成 → Debug 重置且保留数据）+ 家长面板进入日志 —— 见 design「家长凭据与恢复策略」
- [ ] 6.2 实现学习报告页面（时长、正确率、进度；正确率按 `AccuracyRule.countedKinds` 聚合 `Attempt`，不读 `LearningSession` 聚合字段——见 design「指标口径与数据字典」）
- [ ] 6.3 实现兑换规则管理：`RedemptionRule` 补全 11 个字段（id / title / icon / category / starCost / dailyLimit / weeklyLimit / cooldownDays / requiresApproval / isActive / sortOrder）+ 奖励库页（预置模板启停与改价）+ 兑换限制开关（必须完成今日任务 / 单日 1 次 / 大额二次确认）——见 design「奖励体系」
- [ ] 6.4 实现兑换审核流程（记录 `reviewedBy`：审核记录显示"妈妈同意了"）
- [ ] 6.5 实现多 Profile 切换与生命周期管理（创建上限 4 个、切换时 `profileID` 持久化、删除时逐表清理 8 张表且至少保留 1 个、家长 Tab 可改年级——见 design Decision 5）
- [ ] 6.6 实现设置页合规项：卸载即清空的明示、学习记录导出 JSON、本地诊断日志查看
- [ ] 6.7 实现家长手动解锁单元（应对学校进度超前；只放行访问，不改星星与进度统计）
- [ ] 6.8 实现「练习强度」设置页（按 Profile 保存，档位选择，即时生效并重算首页预计时长）：连续失败几次可跳过 / 每日新词数 / 每日新句型数 / 单次复习上限（见 design「可调设置」）
  - 2026-10-27：「认环节每屏配对数」「每单元最少练习轮数」随「认」并入「说」取消，剩 4 项
- [ ] 6.9 实现本地通知：兑换提交 → 提醒家长审核；学期包下载完成 → 通知（`UNUserNotificationCenter`，点通知直达对应页）

## 7. 内容资源

- [x] 7.1 收集 2 年级沪教版课本单词数据（JSON 格式）
- [x] 7.2 从网络资源获取单词发音音频
- [x] 7.3 从网络资源获取单词配图
- [ ] 7.4 把二上资源迁出 App：`app/Resources/Curriculum/` → 学期包 `packs/g2s1.zip`（内含 `curriculum.json` + `audio/ words/ img/`）
- [x] 7.5 实现 `_download/serve.js`（静态服务 + 扫描 `packs/` 生成 `manifest.json`：`schemaVersion` / `contentVersion` / size / sha256 / `previous`）与 `serve.bat`，并写 runbook（开机自启、防火墙只放行专用网络、`<host>.local` 主机名）
- [x] 7.6 内置 `catalog.json`（学期目录：id / 标题 / 大小 / 版本，不含任何媒体与词表）
- [ ] 7.7 管线入版本库 + 学期包异地备份：`_download/build_resources.js`、`serve.js`、`jx_audio_manifest.json`、`words_raw.json` 纳入 git（调整 `.gitignore`，媒体不进 git，只留 `curriculum.json` 与脚本），`packs/*.zip` 备份到云盘或移动硬盘
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

---

> 以下 8 组（第 10–17 组）来自原 `add-media-library` 变更（听和看 / 媒体库），设计见 `design.md` 的「媒体库（听和看）」一节，规格见 `specs/media-library/spec.md`。
>
> 前置依赖标注：**[素材]** 需要本地素材目录（`G:\新概念英语\...`，不入库）；**[家里电脑]** 需要 Node 服务在局域网可访问；**[真机]** 需要 iPad + Mac 侧载；**[ffmpeg]** 需要在本机安装 ffmpeg（本次不阻塞，仅 remux 兜底时用）。

## 10. 内容侧（家里电脑）

- [ ] 10.1 建立 `media/` 目录结构与命名规则（`media.json` + `files/songs/<id>.mp4` + `files/picture/<id>.mp4`），从素材目录挑出儿歌 82 首与绘本 164 段并重命名为稳定 id；验证：脚本输出条目数 = 246，且每行与源文件一一对应（无重复 id、无空标题）**[素材]**
- [ ] 10.2 写 `scripts/build-media-manifest.mjs` 产出 `media.json`（字段：`id` / `title` / `kind`(song|picture) / `part` / `durationSec` / `bytes` / `sha256` / `relPath` / `streamable`）；验证：跑一次产出 246 条，`id` 全部以 `m:` 开头、唯一，且体积合计 ≈ 6.30 GB（±1%）**[素材]**
- [ ] 10.3 写 `scripts/check-faststart.mjs`（读文件头前 1 MB 查找 `moov` box，判定 `streamable`）；验证：对至少 3 个样本文件的判定结果与「拖到中段能否秒开」的真机表现一致 **[素材]**
- [ ] 10.4 Node 静态服务增加 `/media/*` 路由与 Range 支持；验证：`curl -H "Range: bytes=0-1023"` 返回 `206` 且 `Content-Range` / `Content-Length` 正确，`curl -I` 返回 `Accept-Ranges: bytes` **[家里电脑]**
- [ ] 10.5 打包脚本加路径守卫：目标目录落在仓库内时非零退出并提示改用仓库外目录；验证：`node scripts/build-media-manifest.mjs --out ./media` 退出码 ≠ 0，`git status` 无新增 mp4
- [ ] 10.6 写内容侧 runbook（`docs/media-runbook.md`，仓库内只写流程不写本机绝对路径）：加一批新素材的完整步骤 + Range/faststart 自检命令；验证：按文档从空目录走一遍能产出可用 `media.json`
- [ ] 10.7 给 82 首儿歌各标注 2–3 个可跟读句（文本 + 起止秒），写入 `media.json` 的 `lines[]`，避开 `la la la`、拟声词与说唱段；验证：82 首全部 2–3 句，人工试读抽样 10 首一次性通过率 ≥ 70%，不达标的句子重标 **[素材]**
- [ ] 10.8 产出素材验收清单 `docs/media-acceptance.md` 并完成 10 条抽样（水印/片头广告、爆音与音量一致性、是否以英文为主、时长、首尾完整性）；验证：10 条记录齐全，不合格项从 `media.json` 移除并写明原因 **[素材]**

## 11. 清单与状态层（App）

- [ ] 11.1 定义 `MediaManifest` / `MediaAsset` 为纯 `Decodable`（不新增 `@Model`），含 `mediaSchemaVersion` 校验与 `m:` 命名空间校验；验证：单测覆盖「正常清单」「含 `w:` 前缀的非法项」「缺必需字段」三种输入，后两种整体拒绝
- [ ] 11.2 实现版本闸门：`mediaSchemaVersion` 高于 App 上限时整包置灰且不删本地缓存；验证：用伪造清单跑单测，断言状态为 `.requiresAppUpdate` 且缓存索引未变
- [ ] 11.3 实现 `MediaStateStore`（`Application Support/media/media-state.json`，按 `profileID` 分组，单写队列 + 临时文件原子替换，损坏按空状态重建）；验证：单测并发写 100 次后读取字段完整；注入截断 JSON 后重建为空且不抛错
- [ ] 11.4 实现观看时长聚合（按本地 0 点切日，保留 14 天，5 秒落盘）；验证：单测用可注入时钟跨 0 点累加，断言分属两天的数值正确、第 15 天被淘汰
- [ ] 11.5 实现 `MediaCacheStore`（`Library/Caches/Media/`，索引 `media-cache.json`，LRU + 剩余空间 < 1 GB 停止预取）；验证：单测「加 3 项越界」断言淘汰 `lastAccessAt` 最旧项；模拟剩余空间 0.5 GB 时断言拒绝新任务
- [ ] 11.6 验证删除 Profile 会清掉该 profile 在 `media-state.json` 的键且不影响其他 profile；验证：单测 + 手工走查各一次
- [ ] 11.7 实现时长回填（`media-duration.json`：清单 `durationSec` 为 0/缺失时，首次播放写入 `AVAsset.duration`；显示优先级 清单 > 回填 >「未看过」；两者差 > 2 秒写诊断日志）；验证：单测覆盖三档优先级，真机播放一首时长为 0 的项后家长端显示实测值（对应 spec「时长缺失时的回填」）**[真机]**

## 12. 下载与校验

- [ ] 12.1 实现逐项下载器（`URLSession`，下载到临时文件 → `sha256` 校验 → 原子移入缓存 → 更新索引），状态机：未请求 / 下载中 / 已就绪 / 损坏；验证：真机下载 1 项后 `sha256` 与清单一致；手工改坏 1 字节后重试判定为「内容损坏」且不影响其他项 **[家里电脑]**
- [ ] 12.2 实现顺序预取队列（并发固定 1，可取消）；验证：连续点 5 项时观察服务端日志同时只有 1 个请求在传输
- [ ] 12.3 下载进度与「已下载」标记接入列表；验证：真机观察单条从 0% 到「已下载」，中途退出重进后状态仍正确（不重复下载）
- [ ] 12.4 校验失败隔离：仅坏项不可播，其余项正常；验证：构造清单里 3 项 sha256 错误，真机断言 3 项显示「内容损坏」、其余 243 项可播（对应 spec「单项校验失败」）

## 13. 播放

- [ ] 13.1 实现 `MediaPlayerService`：`AVPlayer` + `AVPlayerLayer` + 自绘控件（≥64 pt 按钮、进度条、返回、「跟读」入口），不做画中画/AirPlay；验证：真机分别播放本地缓存文件与 `http://` 串流地址各 1 条，画面声音正常、可暂停/恢复 **[真机]**
- [ ] 13.2 串流期间并行后台预取，预取完成后优先播本地；验证：串流播放一首儿歌（≤20 MB），播完时缓存目录已出现该文件，再断网重播成功
- [ ] 13.3 续播：每 5 秒记录位置，最后 5 秒视为看完并清零；验证：真机中途退出后重进位置偏差 ≤ 3 秒；播到结束后重进从 0 开始
- [ ] 13.4 等待与降级：8 秒未起播显示「正在加载」；无缓存且服务不可达显示「需要家里电脑开着，或先下载到 iPad」+ 重试/返回；验证：关掉 Node 服务后逐条走查，无无限菊花 **[家里电脑]**
- [ ] 13.5 `streamable: false` 的项走「先下后播」；验证：构造 1 条 `streamable:false` 的测试项，点开后显示下载进度并在完成后自动起播
- [ ] 13.6 每日上限计时与软拦截（只计正在播放的墙钟时间；达到上限允许当前条播完，之后拦截新条目；设为 0 时整区不可播）；验证：把上限设为 1 分钟真机验证拦截文案；改系统日期验证次日自动清零 **[真机]**
- [ ] 13.7 实现播放故障埋点（起播 8 秒超时、HTTP 非 200/206、解码失败、校验失败、缓存写入失败 → `diagnostics.jsonl`，环形 500 条，字段 itemID/模式/错误码/时间）；验证：手工制造 3 类失败各产生 1 条记录，条数超 500 时最旧被淘汰（对应 spec「播放故障本地诊断」）**[真机]**

## 14. 孩子端界面

- [ ] 14.1 新增「听和看」入口与「儿歌 / 绘本」两个分区列表（含已下载、时长、上次看到哪）；验证：真机进入后 246 项加载可交互、滚动无明显卡顿（Instruments 抽样）
- [ ] 14.2 绘本逐句跟读流程：播原声 → 录音 → 判定 → 下一句，复用既有录音与评分器；验证：真机完整跟读一段 4 句以上，通过/不通过判定与课本「说」环节标准一致
- [ ] 14.3 发星接入既有发星服务，`grantKey = m:<itemID>#s<句号>`；验证：同一句通过两次只产生 1 条 `StarLedger`；当日发星达上限后不再发星但跟读流程仍可继续
- [ ] 14.4 空态与异常态：无 `media.json`（入口隐藏）、清单损坏、全部离线、缓存被系统清理；验证：手工走查 4 种状态各自文案与出口正确
- [ ] 14.5 家长入口不影响媒体浏览权限（孩子可看，但设置只在家长模式）；验证：孩子模式无设置入口，顶栏 🔒 仍可进家长模式
- [ ] 14.6 儿歌跟读：播放页新增「跟读这 2 句」入口，逐句「听原声 → 录 → 判」（复用绘本跟读组件，`grantKey` 用 `m:<id>#l<句号>`）；验证：真机对一首歌完成 2 句跟读各发 1 星，同一句重复通过不重复发星（对应 spec「儿歌跟读达标发星」）**[真机]**

## 15. 家长端

- [ ] 15.1 媒体设置页：每日上限（0/5/10/15/关闭）、缓存上限（1/2/5 GB）、仅 Wi-Fi 预取、清除缓存（二次确认）；验证：改上限保存后孩子端即时生效；清缓存后缓存目录为空且离线标记全部消失
- [ ] 15.2 「今天看了什么」：当日与近 7 天的条目、累计时长、跟读通过句数，总时长与当日上限并列；验证：造 3 条观看记录 + 2 次跟读通过后逐项核对数值（对应 spec「查看当日观看明细」）
- [ ] 15.3 家长操作审计：改设置、清缓存、改上限写入现有审计日志；验证：审计列表出现对应条目并带家长档案名
- [ ] 15.4 观看明细只呈现事实：无排名、无好坏评价、无红黄绿标；验证：对照原型文案走查一遍
- [ ] 15.5 家长端媒体明细显示「通过 x/N · 一次通过 y/N · 复读 z 次」；验证：构造「8 句、通过 3、其中 2 句一次通过、第 3 句重试 2 次」的数据后数值完全一致（对应 spec「跟读评价口径」）
- [ ] 15.6 诊断页增加「媒体日志」查看与清空；验证：清空后条数为 0，之后的新事件继续记录 **[真机]**

## 16. 合规与仓库卫生

- [ ] 16.1 `.gitignore` 覆盖媒体素材与打包产物（`media/`、`*.mp4`、`_download/`），并确认构建产物不含媒体；验证：`git status` 干净；`unzip -l` 或 `du` 检查 App 包体，安装体积较接入前增幅 < 1 MB
- [ ] 16.2 打包脚本仓库守卫回归；验证：`node scripts/build-media-manifest.mjs --out <仓库内路径>` 非零退出（对应 spec「打包脚本拒绝写入仓库」）
- [ ] 16.3 README 增加「本地素材接入」章节，只写目录用途与流程，不写本机绝对路径；验证：`grep -i "G:\\\\"` 无命中
- [ ] 16.4 隐私确认：播放与跟读只在本机处理，无外网上报；验证：断掉外网（保留局域网）后完整走一遍串流 + 跟读 + 发星，功能不受影响

## 17. 集成验证（媒体库）

- [ ] 17.1 端到端主流程：家里电脑开机 → 串流看一段绘本 → 跟读通过发星 → 关掉服务 → 重看同一段（离线）→ 家长端明细数值正确 **[家里电脑][真机]**
- [ ] 17.2 回滚验证：删除本地 `media.json` 后「听和看」入口消失，课本学习 / 奖励 / 家长面板完全正常；恢复清单后入口回来、缓存仍在
- [ ] 17.3 容量验证：把缓存上限设为 1 GB 并连看 8 段，断言超限时按 LRU 淘汰且不触发系统低存储告警 **[真机]**
- [ ] 17.4 与既有功能的隔离验证：媒体播完后 `ItemProgress` / `ReviewSchedule` 无新增，课本正确率统计不变（对应 spec「看完绘本不产生学习进度」）
- [ ] 17.5 评价口径走查：家长端与孩子端所有媒体信息只含事实（时长 / 通过率 / 一次通过率 / 复读次数 / 星星），无分数、等级、颜色分级与孩子间排名；验证：对照 spec「跟读评价口径」逐条勾选并留走查记录 **[真机]**

## Workflow follow-up

- 待用户确认后归档本变更（`openspec archive ipad-elementary-english-learning`），归档前需先跑 `openspec validate ipad-elementary-english-learning --strict`。
- 素材 remux（`-movflags +faststart`）若 10.3 判定不达标项超过 20%，另开小变更处理，不并入本次。
