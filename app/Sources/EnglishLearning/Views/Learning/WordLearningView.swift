import SwiftData
import SwiftUI
import UIKit

/// 单词学习 · 「认·说」合练（把原型的 B3 听 + B4 说 + B5 认并成一个循环）。
///
/// 每个词的流程：看大图认词 → 听原音（默认慢速）→ 点麦克风跟读 →
/// 和原音对比达标 → 自动进入下一个词；不达标就留在本词再读一次。
/// 一直走到「主动结束」或「本单元每个词都达标」。
struct WordLearningView: View {
    let profile: Profile
    let pack: InstalledPack
    let unit: Unit

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    /// 适配约定：动效响应「减弱动态效果」
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query private var allProgress: [ItemProgress]
    @Query private var ledger: [StarLedger]
    @Query private var allReviews: [ReviewSchedule]
    @Query private var settingsList: [LearningSettings]

    @State private var index: Int = 0
    @State private var prepared = false
    @State private var preLearned: Set<String> = []
    @State private var practiceAll = false
    @State private var passedThisSession: Set<String> = []
    @State private var skippedThisSession: Set<String> = []
    @State private var starsThisSession = 0
    /// 本次学单词的配速（0.5 / 0.75 / 1），后续词沿用；离开学习页即重置
    @State private var playbackRate: Double = 0.75
    /// 本次是否拿到了「单元完成 +5」奖励（只影响结算文案）
    @State private var unitRewardGranted = false
    /// 今天的新词配额用完（tasks 4.6：一次会话 5-8 分钟，不把整单元一次灌完）
    @State private var quotaReached = false
    @State private var newItemsThisSession = 0
    @State private var showSummary = false
    @State private var sessionID = UUID()
    @State private var session: LearningSession?
    @State private var advanceTask: Task<Void, Never>?

    private let player = AudioPlayer.shared
    private let explicitStart: Int?

    private static let stepNames = ["学单词", "游戏", "句型", "复习"]

    init(profile: Profile, pack: InstalledPack, unit: Unit, startIndex: Int? = nil) {
        self.profile = profile
        self.pack = pack
        self.unit = unit
        self.explicitStart = startIndex
    }

    private var word: UnitWord? {
        unit.words.indices.contains(index) ? unit.words[index] : nil
    }

    private var audioURL: URL? {
        guard let word else { return nil }
        return ResourceLocator.url(semester: pack.id, relativePath: word.audio)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar

            if unit.words.isEmpty {
                Spacer()
                Text("这个单元还没有单词")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.muted)
                Spacer()
            } else if let word {
                HStack(alignment: .center, spacing: 26) {
                    wordPanel(word)
                    FollowReadPanel(word: word.en, referenceURL: audioURL,
                                    isPaused: showSummary,
                                    initialRate: playbackRate,
                                    onRateChange: { playbackRate = $0 },
                                    onAssessment: { handle($0) },
                                    onSkip: { skipCurrentWord() },
                                    skipAfterFailures: settings?.skipAfterFailures ?? 3)
                        .frame(width: 430)
                        .id(word.id)
                }
                .padding(.horizontal, 36)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task { prepareIfNeeded() }
        .onDisappear {
            advanceTask?.cancel()
            player.stop()
            endSession()
        }
        .sheet(isPresented: $showSummary, onDismiss: { dismiss() }) {
            summarySheet
                .presentationDetents([.height(400)])
                .presentationDragIndicator(.hidden)
        }
    }

    // MARK: - 顶部

    private var topBar: some View {
        HStack(spacing: 14) {
            Button {
                if passedThisSession.isEmpty {
                    dismiss()
                } else {
                    showSummary = true
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("结束学习并返回")

            VStack(alignment: .leading, spacing: 3) {
                Text("Unit \(unit.number) · 学单词")
                    .font(.system(size: 19, weight: .heavy))
                    .foregroundStyle(Theme.ink)
                Text("听 → 认 → 说 一起练")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.faint)
            }

            stepBar

            Spacer()

            Text("第 \(index + 1) / \(unit.words.count) 个词")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.muted)

            StarPill(stars: starBalance)

            Button {
                showSummary = true
            } label: {
                Text("结束学习")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 13)
                    .frame(height: 36)
                    .background(Theme.chipBg)
                    .clipShape(Capsule())
                    .kidTapTarget()
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 26)
        .frame(height: 76)
        .background(Color.white)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line).frame(height: 2)
        }
    }

    private var stepBar: some View {
        HStack(spacing: 6) {
            ForEach(Array(Self.stepNames.enumerated()), id: \.offset) { step, _ in
                Capsule()
                    .fill(step == 0 ? Theme.orange : Color(hex: 0xEADFD2))
                    .frame(width: 26, height: 8)
            }
        }
        .padding(.leading, 6)
    }

    // MARK: - 左栏：认词 + 听原音

    private func wordPanel(_ word: UnitWord) -> some View {
        VStack(spacing: 14) {
            picture(word)

            VStack(spacing: 4) {
                Text(word.en)
                    .font(.system(size: 52, weight: .heavy))
                    .foregroundStyle(Theme.ink)
                    .minimumScaleFactor(0.5)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(Self.meaningOnly(word.zh))
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.muted)
            }

            HStack(spacing: 10) {
                Button {
                    if isPlayingReference { player.stop() } else { playReference() }
                } label: {
                    KidButtonLabel(title: isPlayingReference ? "停止" : "再听一遍（\(Self.rateLabel(playbackRate))）",
                                   systemImage: isPlayingReference ? "stop.fill" : "play.fill",
                                   compact: true)
                }
                .buttonStyle(KidButtonStyle())
            }
            .frame(maxWidth: 280)

            HStack(spacing: 6) {
                ForEach(Array(unit.words.enumerated()), id: \.element.id) { offset, item in
                    Capsule()
                        .fill(dotColor(offset, item))
                        .frame(width: offset == index ? 22 : 8, height: 8)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: index)

            Text(statusLine)
                .font(.system(size: 13))
                .foregroundStyle(Theme.faint)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func picture(_ word: UnitWord) -> some View {
        let url = ResourceLocator.url(semester: pack.id, relativePath: word.image)
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0xDFF4FB), Color(hex: 0xBCE9F7)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            if let url, let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(20)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 48))
                    .foregroundStyle(Theme.blueInk)
            }
        }
        .frame(width: 320, height: 236)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .onTapGesture { playReference() }
        .accessibilityLabel("\(word.en) 的图片，点一下播放读音")
    }

    private func dotColor(_ offset: Int, _ item: UnitWord) -> Color {
        if passedThisSession.contains(item.itemCode) { return Theme.green }
        if skippedThisSession.contains(item.itemCode) { return Theme.faint }
        return offset == index ? Theme.orange : Color(hex: 0xEADFD2)
    }

    private var statusLine: String {
        let passed = unit.words.filter { passedThisSession.contains($0.itemCode) }.count
        return "本次达标 \(passed) / \(unit.words.count) 个词 · 达标后自动进入下一个"
    }

    // MARK: - 结算

    private var summarySheet: some View {
        VStack(spacing: 14) {
            Text(unitCompleted ? "🎉" : (quotaReached ? "🌙" : "👋"))
                .font(.system(size: 46))

            Text(unitCompleted ? "Unit \(unit.number) 学完啦！"
                 : (quotaReached ? "今天的 \(newItemsThisSession) 个新词学完了" : "本次先学到这里"))
                .font(.system(size: 24, weight: .heavy))
                .foregroundStyle(Theme.ink)

            if quotaReached && !unitCompleted {
                Text("明天再学后面的词，今天先把这几个记牢")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                    .padding(.top, 2)
            }

            Text("达标 \(passedThisSession.count) 个词 · 得到 \(starsThisSession) 颗星")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.orangeDark)

            if unitRewardGranted {
                Text("含单元完成奖励 +5 ★")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.greenInk)
            }

            if !passedWordNames.isEmpty {
                Text(passedWordNames.joined(separator: " · "))
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .lineLimit(3)
            }

            if !skippedThisSession.isEmpty {
                Text("还有 \(skippedThisSession.count) 个词没达标，下次接着练")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.faint)
            }

            Spacer(minLength: 4)

            Button {
                showSummary = false
            } label: {
                KidButtonLabel(title: "完成")
            }
            .buttonStyle(KidButtonStyle())
            .padding(.horizontal, 24)
        }
        .padding(.top, 26)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }

    private var passedWordNames: [String] {
        unit.words.filter { passedThisSession.contains($0.itemCode) }.map(\.en)
    }

    // MARK: - 学习循环

    private func prepareIfNeeded() {
        guard !prepared else { return }
        prepared = true

        let learned = Set(allProgress
            .filter { $0.profileID == profile.id && $0.firstPassedAt != nil }
            .map(\.itemCode))
        preLearned = learned.intersection(Set(unit.words.map(\.itemCode)))
        practiceAll = !unit.words.isEmpty && unit.words.allSatisfy { preLearned.contains($0.itemCode) }

        if let explicitStart, unit.words.indices.contains(explicitStart) {
            index = explicitStart
        } else if let firstNew = unit.words.firstIndex(where: { !preLearned.contains($0.itemCode) }) {
            index = firstNew
        } else {
            index = 0
        }

        startSession()
        playReference()
    }

    private func handle(_ assessment: PronunciationAssessment) {
        guard let word else { return }
        if assessment.isPassed {
            markPassed(word)
            advanceTask?.cancel()
            advanceTask = Task {
                try? await Task.sleep(nanoseconds: 1_400_000_000)
                guard !Task.isCancelled else { return }
                advance()
            }
        } else {
            markFailed(word)
        }
    }

    private func skipCurrentWord() {
        guard let word else { return }
        // 跳过：不写 ItemProgress、不发星、不进复习调度；只留一条失败 Attempt 供报告统计薄弱项
        modelContext.insert(Attempt(profileID: profile.id, sessionID: sessionID,
                                    itemCode: word.itemCode, itemKind: .word,
                                    unitCode: unit.id, kind: "speak", passed: false, at: Date()))
        save()
        skippedThisSession.insert(word.itemCode)
        advanceTask?.cancel()
        advance()
    }

    private func advance() {
        // 今天的新词配额用完就先收工（剩下的留给明天，别一次灌太多）
        if quotaReached, !unitCompleted {
            showSummary = true
            return
        }
        if let next = pendingIndices.first(where: { $0 > index }) ?? pendingIndices.first {
            index = next
            player.stop()
            playReference()
        } else {
            showSummary = true
        }
    }

    /// 还没达标、也没跳过的词（含本次之前没学过的）
    private var pendingIndices: [Int] {
        unit.words.indices.filter {
            let code = unit.words[$0].itemCode
            return !doneCodes.contains(code) && !skippedThisSession.contains(code)
        }
    }

    private var doneCodes: Set<String> {
        practiceAll ? passedThisSession : passedThisSession.union(preLearned)
    }

    private var settings: LearningSettings? {
        settingsList.first { $0.profileID == profile.id }
    }

    /// 还有"从没学过"的词 → 今天是真学不完，按配额收工
    private var hasRemainingNewWords: Bool {
        unit.words.contains { word in
            let code = word.itemCode
            return !preLearned.contains(code) && !passedThisSession.contains(code)
        }
    }

    private var unitCompleted: Bool {
        !unit.words.isEmpty && unit.words.allSatisfy { doneCodes.contains($0.itemCode) }
    }

    private func playReference() {
        guard let audioURL else {
            // 内容缺音频：记一条诊断（Debug 下直接断言），界面继续可用
            DiagnosticsLog.assertAsset(nil, path: word?.audio ?? "-", context: "WordLearningView.play")
            return
        }
        player.play(url: audioURL, rate: playbackRate)
    }

    private var isPlayingReference: Bool {
        guard let audioURL else { return false }
        return player.isPlaying(audioURL, rate: playbackRate)
    }

    private static func rateLabel(_ rate: Double) -> String {
        abs(rate - 1) < 0.01 ? "原速" : String(format: "%.2gx", rate)
    }

    // MARK: - 进度写入

    private func markPassed(_ word: UnitWord) {
        let now = Date()
        let progress = allProgress.first { $0.profileID == profile.id && $0.itemCode == word.itemCode }
        let target: ItemProgress
        if let progress {
            target = progress
        } else {
            target = ItemProgress(profileID: profile.id, itemCode: word.itemCode, itemKind: .word,
                                  unitCode: unit.id, volumeCode: pack.id)
            modelContext.insert(target)
        }

        let isFirstPass = target.firstPassedAt == nil
        target.timesSeen += 1
        target.timesPassed += 1
        target.lastSeenAt = now
        if target.firstPassedAt == nil { target.firstPassedAt = now }
        target.masteryLevel = Self.masteryLevel(timesPassed: target.timesPassed,
                                                firstPassedAt: target.firstPassedAt,
                                                now: now)

        modelContext.insert(Attempt(profileID: profile.id, sessionID: sessionID,
                                    itemCode: word.itemCode, itemKind: .word,
                                    unitCode: unit.id, kind: "speak", passed: true, at: now))

        if isFirstPass {
            newItemsThisSession += 1
            // 配额只统计"今天新学的词"，练习模式（整单元已学过）不受限
            if !practiceAll,
               newItemsThisSession >= max(1, settings?.newWordsPerDay ?? 5),
               hasRemainingNewWords {
                quotaReached = true
            }
            // 首次达标 → 排复习：明天第一次复习（1 → 3 → 7 → 14 → 30 天，见 ReviewScheduler）
            ReviewScheduler.scheduleFirstReview(
                profileID: profile.id,
                itemCode: word.itemCode,
                itemKind: .word,
                existing: allReviews.first { $0.profileID == profile.id && $0.itemCode == word.itemCode },
                in: modelContext,
                now: now
            )
            BadgeEngine.evaluate(profileID: profile.id, curriculum: nil, in: modelContext, now: now)
        }

        // 发星统一走 StarService：+2 每次达标（同一词每天一次）+ 首次额外 +3
        let day = StarService.dayStamp(now)
        let daily = StarService.grant(profileID: profile.id, amount: 2, reason: "跟读达标",
                                      key: "speak:\(word.itemCode):\(day)", in: modelContext, now: now)
        if case .granted = daily { starsThisSession += 2 }
        if isFirstPass {
            let first = StarService.grant(profileID: profile.id, amount: 3, reason: "首次达标",
                                          key: "first:\(word.itemCode)", in: modelContext, now: now)
            if case .granted = first { starsThisSession += 3 }
        }

        passedThisSession.insert(word.itemCode)
        save()
        grantUnitRewardIfNeeded()
    }

    /// 单元完成 +5 星（幂等键 `unit:<学期>-<单元>`）：解锁下一单元与发星在同一时刻发生。
    private func grantUnitRewardIfNeeded() {
        guard unitCompleted else { return }
        let key = "unit:\(pack.id)-\(unit.id)"
        let result = StarService.grant(profileID: profile.id, amount: 5,
                                       reason: "Unit \(unit.number) 完成",
                                       key: key, in: modelContext)
        if case .granted = result {
            unitRewardGranted = true
            starsThisSession += 5
        }
        save()
    }

    private func markFailed(_ word: UnitWord) {
        let now = Date()
        if let progress = allProgress.first(where: { $0.profileID == profile.id && $0.itemCode == word.itemCode }) {
            progress.timesSeen += 1
            progress.lastSeenAt = now
        } else {
            let progress = ItemProgress(profileID: profile.id, itemCode: word.itemCode, itemKind: .word,
                                        unitCode: unit.id, volumeCode: pack.id)
            progress.timesSeen = 1
            progress.lastSeenAt = now
            modelContext.insert(progress)
        }

        modelContext.insert(Attempt(profileID: profile.id, sessionID: sessionID,
                                    itemCode: word.itemCode, itemKind: .word,
                                    unitCode: unit.id, kind: "speak", passed: false, at: now))
        save()
    }

    private func hasFirstPassStar(_ itemCode: String) -> Bool {
        let key = "first:\(itemCode)"
        return ledger.contains { $0.profileID == profile.id && $0.grantKey == key }
    }

    private func startSession() {
        guard session == nil else { return }
        let session = LearningSession(profileID: profile.id, volumeCode: pack.id, unitCode: unit.id)
        modelContext.insert(session)
        self.session = session
        sessionID = session.id
        save()
    }

    private func endSession() {
        guard let session, session.endedAt == nil else { return }
        session.endedAt = Date()
        session.durationSeconds = Int(session.endedAt?.timeIntervalSince(session.startedAt) ?? 0)
        session.newItemsLearned = newItemsThisSession
        save()
    }

    private func save() {
        try? modelContext.save()
    }

    private var starBalance: Int {
        ledger.filter { $0.profileID == profile.id }.reduce(0) { $0 + $1.amount }
    }

    /// 掌握度分级（design「奖励与防沉迷参数」）
    private static func masteryLevel(timesPassed: Int, firstPassedAt: Date?, now: Date) -> Int {
        guard timesPassed > 0 else { return 1 }
        let days = firstPassedAt.map {
            Calendar.current.dateComponents([.day], from: $0, to: now).day ?? 0
        } ?? 0
        if timesPassed >= 5 && days >= 3 { return 4 }
        if timesPassed >= 3 && days >= 2 { return 3 }
        return 2
    }

    /// `v.感觉到` → `感觉到`
    private static func meaningOnly(_ zh: String) -> String {
        guard let dot = zh.firstIndex(of: ".") else { return zh }
        let head = zh[zh.startIndex..<dot]
        guard head.count <= 4, head.allSatisfy({ $0.isLetter || $0 == "/" }) else { return zh }
        return String(zh[zh.index(after: dot)...])
    }
}
