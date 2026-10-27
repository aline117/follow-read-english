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
    @Query private var allProgress: [ItemProgress]
    @Query private var ledger: [StarLedger]

    @State private var index: Int = 0
    @State private var prepared = false
    @State private var preLearned: Set<String> = []
    @State private var practiceAll = false
    @State private var passedThisSession: Set<String> = []
    @State private var skippedThisSession: Set<String> = []
    @State private var starsThisSession = 0
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
                                    onAssessment: { handle($0) },
                                    onSkip: { skipCurrentWord() })
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
                    if isSlowPlaying { player.stop() } else { play(slow: true) }
                } label: {
                    KidButtonLabel(title: isSlowPlaying ? "停止" : "再听一遍（慢速）",
                                   systemImage: isSlowPlaying ? "stop.fill" : "play.fill",
                                   compact: true)
                }
                .buttonStyle(KidButtonStyle())

                Button {
                    play(slow: false)
                } label: {
                    KidButtonLabel(title: "常速", style: .ghost, compact: true)
                        .frame(width: 96)
                }
                .buttonStyle(KidButtonStyle())
            }
            .frame(maxWidth: 360)

            HStack(spacing: 6) {
                ForEach(Array(unit.words.enumerated()), id: \.element.id) { offset, item in
                    Capsule()
                        .fill(dotColor(offset, item))
                        .frame(width: offset == index ? 22 : 8, height: 8)
                }
            }
            .animation(.easeOut(duration: 0.2), value: index)

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
        .onTapGesture { play(slow: true) }
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
            Text(unitCompleted ? "🎉" : "👋")
                .font(.system(size: 46))

            Text(unitCompleted ? "Unit \(unit.number) 学完啦！" : "本次先学到这里")
                .font(.system(size: 24, weight: .heavy))
                .foregroundStyle(Theme.ink)

            Text("达标 \(passedThisSession.count) 个词 · 得到 \(starsThisSession) 颗星")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.orangeDark)

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
        play(slow: true)
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
        skippedThisSession.insert(word.itemCode)
        advanceTask?.cancel()
        advance()
    }

    private func advance() {
        if let next = pendingIndices.first(where: { $0 > index }) ?? pendingIndices.first {
            index = next
            player.stop()
            play(slow: true)
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

    private var unitCompleted: Bool {
        !unit.words.isEmpty && unit.words.allSatisfy { doneCodes.contains($0.itemCode) }
    }

    private func play(slow: Bool) {
        guard let audioURL else { return }
        player.play(url: audioURL, rate: slow ? AudioPlayer.slowRate : 1)
    }

    private var isSlowPlaying: Bool {
        guard let audioURL else { return false }
        return player.isPlaying(audioURL, rate: AudioPlayer.slowRate)
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
            if !hasFirstPassStar(word.itemCode) {
                modelContext.insert(StarLedger(profileID: profile.id, amount: 1, reason: "跟读达标",
                                               grantKey: "first:\(word.itemCode)", at: now))
                starsThisSession += 1
            }
        }

        passedThisSession.insert(word.itemCode)
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
