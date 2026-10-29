import SwiftData
import SwiftUI

/// 句型学习环节（tasks 4.10 / design「句子学习环节」）：一条句型走三步
/// 1. **听**：整句音频（0.5x / 0.75x / 原速），不做逐词高亮
/// 2. **说**：跟读整句，复用单词跟读的识别与判定口径
/// 3. **认**：打乱的词块拖/点回原位，拼成整句
/// 三步都过才算这条句型"学完"：写 `ItemProgress`、发首次星、排复习（明天第一次复习）。
struct SentenceLearningView: View {
    let profile: Profile
    let pack: InstalledPack
    let unit: Unit

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var allProgress: [ItemProgress]
    @Query private var ledger: [StarLedger]
    @Query private var allReviews: [ReviewSchedule]
    @Query private var settingsList: [LearningSettings]

    @State private var queue: [Sentence] = []
    @State private var index = 0
    @State private var step: Step = .listen
    @State private var prepared = false
    @State private var showSummary = false
    @State private var sessionID = UUID()
    @State private var session: LearningSession?
    @State private var starsThisSession = 0
    @State private var passedThisSession: Set<String> = []

    // 词块排序状态
    @State private var slot: [String] = []
    @State private var pool: [String] = []
    @State private var matchResult: Bool?
    @State private var advanceTask: Task<Void, Never>?
    /// 缺音频时「静音 3 秒推进」的计时（tasks 4.9 的降级路径）
    @State private var silentAdvanceTask: Task<Void, Never>?

    private let player = AudioPlayer.shared

    private enum Step {
        case listen
        case speak
        case match
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar

            if !prepared || queue.isEmpty {
                emptyState
            } else if let sentence = currentSentence {
                content(sentence)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task { prepareIfNeeded() }
        .onDisappear {
            advanceTask?.cancel()
            silentAdvanceTask?.cancel()
            player.stop()
            endSession()
        }
        .sheet(isPresented: $showSummary, onDismiss: { dismiss() }) {
            summarySheet
                .presentationDetents([.height(380)])
                .presentationDragIndicator(.hidden)
        }
    }

    // MARK: - 顶部

    private var topBar: some View {
        HStack(spacing: 14) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 38, height: 38)
                    .background(Theme.chipBg)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .kidTapTarget()
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text("学句型")
                    .font(.system(size: 20, weight: .heavy))
                    .foregroundStyle(Theme.ink)
                Text("Unit \(unit.number) · 第 \(min(index + 1, queue.count)) / \(queue.count) 条")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.muted)
            }

            Spacer()

            stepChips
        }
        .padding(.horizontal, 36)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var stepChips: some View {
        HStack(spacing: 6) {
            chip("听", active: step == .listen, done: step != .listen)
            chip("说", active: step == .speak, done: step == .match)
            chip("认", active: step == .match, done: false)
        }
    }

    private func chip(_ title: String, active: Bool, done: Bool) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .heavy))
            .foregroundStyle(active ? .white : (done ? Theme.greenInk : Theme.muted))
            .frame(width: 38, height: 28)
            .background(active ? Theme.orange : (done ? Theme.greenSoft : Theme.chipBg))
            .clipShape(Capsule())
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("📖").font(.system(size: 44))
            Text(prepared ? "这个单元还没有句型" : "加载中…")
                .font(.system(size: 19, weight: .heavy))
                .foregroundStyle(Theme.ink)
            Button {
                dismiss()
            } label: {
                KidButtonLabel(title: "回到单元", style: .ghost)
            }
            .buttonStyle(KidButtonStyle())
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 主体

    @ViewBuilder
    private func content(_ sentence: Sentence) -> some View {
        HStack(alignment: .top, spacing: 26) {
            VStack(alignment: .leading, spacing: 14) {
                sentenceCardBody(sentence)
                rateButtons(sentence)
            }
            .frame(maxWidth: .infinity, alignment: .top)

            Group {
                switch step {
                case .listen:
                    listenPanel(sentence)
                case .speak:
                    FollowReadPanel(word: sentence.en,
                                    referenceURL: audioURL(of: sentence),
                                    isPaused: showSummary,
                                    initialRate: 0.75,
                                    onAssessment: { handleAssessment($0, sentence: sentence) },
                                    onSkip: { advanceStep(from: .speak, sentence: sentence) },
                                    skipAfterFailures: settings?.skipAfterFailures ?? 3)
                case .match:
                    matchPanel(sentence)
                }
            }
            .frame(width: 430)
            .id("\(sentence.id)-\(stepKey)")
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var stepKey: String {
        switch step {
        case .listen: return "l"
        case .speak: return "s"
        case .match: return "m"
        }
    }

    private func sentenceCardBody(_ sentence: Sentence) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(sentence.en)
                .font(.system(size: 30, weight: .heavy))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)

            Text(sentence.zh)
                .font(.system(size: 17))
                .foregroundStyle(Theme.muted)

            if !sentence.pattern.isEmpty {
                Text(sentence.pattern)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.blueInk)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.blueSoft)
                    .clipShape(Capsule())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1.5)
        )
    }

    // MARK: - 听

    private func rateButtons(_ sentence: Sentence) -> some View {
        HStack(spacing: 10) {
            rateButton("0.5x", rate: 0.5, sentence: sentence)
            rateButton("0.75x", rate: 0.75, sentence: sentence)
            rateButton("原速", rate: 1, sentence: sentence)
            Spacer()
        }
    }

    private func rateButton(_ title: String, rate: Double, sentence: Sentence) -> some View {
        Button {
            play(sentence, rate: rate)
        } label: {
            Text(title)
                .font(.system(size: 14, weight: .heavy))
                .foregroundStyle(Theme.orangeDark)
                .frame(width: 66, height: 40)
                .background(Theme.orangeSoft)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .kidTapTarget()
        }
        .buttonStyle(.plain)
        .disabled(audioURL(of: sentence) == nil)
        .opacity(audioURL(of: sentence) == nil ? 0.45 : 1)
    }

    private func listenPanel(_ sentence: Sentence) -> some View {
        VStack(spacing: 12) {
            Text("先听整句，再跟读")
                .font(.system(size: 16, weight: .heavy))
                .foregroundStyle(Theme.ink)

            Text(audioURL(of: sentence) == nil
                 ? "这条暂时没有音频，先看句子"
                 : "可以点左边的 0.5x / 0.75x 听慢一点")
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)

            Button {
                advanceStep(from: .listen, sentence: sentence)
            } label: {
                KidButtonLabel(title: "听好了，去跟读")
            }
            .buttonStyle(KidButtonStyle())
            .padding(.top, 4)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .kidCard()
    }

    // MARK: - 说

    private func handleAssessment(_ assessment: PronunciationAssessment, sentence: Sentence) {
        guard assessment.isPassed else { return }
        recordSpeakPass(sentence)
        advanceStep(from: .speak, sentence: sentence)
    }

    // MARK: - 认（词块排序）

    private func matchPanel(_ sentence: Sentence) -> some View {
        VStack(spacing: 12) {
            Text("把词块排成一句话")
                .font(.system(size: 16, weight: .heavy))
                .foregroundStyle(Theme.ink)

            // 已选词块
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Theme.chipBg)
                        .frame(minHeight: 62)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(Array(slot.enumerated()), id: \.offset) { offset, chunk in
                            Button {
                                removeChunk(at: offset)
                            } label: {
                                chunkPill(chunk, tint: Theme.orangeSoft, tintText: Theme.orangeDark)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(10)
                }
            }

            // 待选词块
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(Array(pool.enumerated()), id: \.offset) { offset, chunk in
                    Button {
                        pickChunk(at: offset)
                    } label: {
                        chunkPill(chunk, tint: Color.white, tintText: Theme.ink)
                    }
                    .buttonStyle(.plain)
                }
            }

            if let matchResult {
                Text(matchResult ? "✅ 排对了" : "顺序还不对，再试试")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(matchResult ? Theme.greenInk : Theme.muted)
            }

            HStack(spacing: 10) {
                if !slot.isEmpty {
                    Button {
                        resetChunks(sentence)
                    } label: {
                        KidButtonLabel(title: "重来", style: .ghost, compact: true)
                    }
                    .buttonStyle(KidButtonStyle())
                }
                Button {
                    checkChunks(sentence)
                } label: {
                    KidButtonLabel(title: "看看对不对", compact: true)
                }
                .buttonStyle(KidButtonStyle())
                .disabled(!pool.isEmpty)
            }
            .padding(.top, 2)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .kidCard()
        .onAppear { resetChunks(sentence) }
    }

    private func chunkPill(_ text: String, tint: Color, tintText: Color) -> some View {
        Text(text)
            .font(.system(size: 15, weight: .heavy))
            .foregroundStyle(tintText)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(tint)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.line, lineWidth: 1.2)
            )
            .kidTapTarget()
    }

    // MARK: - 结算

    private var summarySheet: some View {
        VStack(spacing: 14) {
            Text(passedThisSession.isEmpty ? "👋" : "🎉").font(.system(size: 44))
            Text(passedThisSession.isEmpty ? "这次先到这里" : "句型学完了")
                .font(.system(size: 23, weight: .heavy))
                .foregroundStyle(Theme.ink)
            Text("达标 \(passedThisSession.count) 条 · 得到 \(starsThisSession) 颗星")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.orangeDark)
            if quotaReached {
                Text("今天的句型配额到了，明天再学后面的")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
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
        .padding(.top, 24)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }

    // MARK: - 数据

    private var currentSentence: Sentence? {
        queue.indices.contains(index) ? queue[index] : nil
    }

    private var settings: LearningSettings? {
        settingsList.first { $0.profileID == profile.id }
    }

    private var quotaReached: Bool {
        let limit = max(1, settings?.newSentencesPerDay ?? 1)
        return passedThisSession.count >= limit
    }

    private func audioURL(of sentence: Sentence) -> URL? {
        sentence.audio.isEmpty ? nil : ResourceLocator.url(semester: pack.id, relativePath: sentence.audio)
    }

    private func itemCode(of sentence: Sentence) -> String {
        sentence.itemCode(in: unit.id)
    }

    // MARK: - 流程

    private func prepareIfNeeded() {
        guard !prepared else { return }
        prepared = true
        let learned = Set(allProgress
            .filter { $0.profileID == profile.id && $0.firstPassedAt != nil }
            .map(\.itemCode))
        let pending = unit.sentences.filter { !learned.contains(itemCode(of: $0)) }
        let quota = max(1, settings?.newSentencesPerDay ?? 1)
        // 今天只推进 N 条（0 = 家长关掉了句型学习，直接给空状态）
        queue = (settings?.newSentencesPerDay ?? 1) == 0 ? [] : Array(pending.prefix(quota))
        if queue.isEmpty { return }
        startSession()
        autoPlayOrSilentAdvance(queue[0])
    }

    private func autoPlayOrSilentAdvance(_ sentence: Sentence) {
        if audioURL(of: sentence) != nil {
            play(sentence, rate: 0.75)   // 新学默认慢一点
        } else {
            // 缺音频：静音 3 秒后放行（tasks 4.9 降级），并记一条诊断
            DiagnosticsLog.assertAsset(nil, path: sentence.audio, context: "SentenceLearningView.listen")
            silentAdvanceTask?.cancel()
            silentAdvanceTask = Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    if step == .listen { step = .speak }
                }
            }
        }
    }

    private func play(_ sentence: Sentence, rate: Double) {
        guard let url = audioURL(of: sentence) else { return }
        player.play(url: url, rate: rate)
    }

    private func advanceStep(from current: Step, sentence: Sentence) {
        player.stop()
        silentAdvanceTask?.cancel()
        switch current {
        case .listen:
            step = .speak
        case .speak:
            step = .match
        case .match:
            completeSentence(sentence)
        }
    }

    private func completeSentence(_ sentence: Sentence) {
        // 走到这里说明 听·说·认 都过了
        passedThisSession.insert(itemCode(of: sentence))
        if index + 1 < queue.count {
            index += 1
            step = .listen
            matchResult = nil
            slot = []
            pool = []
            if let next = currentSentence { autoPlayOrSilentAdvance(next) }
        } else {
            showSummary = true
        }
    }


    // MARK: - 词块逻辑

    private func resetChunks(_ sentence: Sentence) {
        let chunks = sentence.chunks.isEmpty ? [sentence.en] : sentence.chunks
        slot = []
        pool = chunks.shuffled()
        matchResult = nil
    }

    private func pickChunk(at offset: Int) {
        guard pool.indices.contains(offset) else { return }
        slot.append(pool.remove(at: offset))
        matchResult = nil
    }

    private func removeChunk(at offset: Int) {
        guard slot.indices.contains(offset) else { return }
        pool.append(slot.remove(at: offset))
        matchResult = nil
    }

    private func checkChunks(_ sentence: Sentence) {
        let chunks = sentence.chunks.isEmpty ? [sentence.en] : sentence.chunks
        let correct = slot.count == chunks.count
            && slot.joined(separator: " ") == chunks.joined(separator: " ")
        matchResult = correct

        modelContext.insert(Attempt(profileID: profile.id, sessionID: sessionID,
                                    itemCode: itemCode(of: sentence), itemKind: .sentence,
                                    unitCode: unit.id, kind: "match", passed: correct, at: Date()))
        try? modelContext.save()

        if correct {
            Task {
                try? await Task.sleep(nanoseconds: 700_000_000)
                await MainActor.run { advanceStep(from: .match, sentence: sentence) }
            }
        }
    }

    // MARK: - 进度写入

    private func recordSpeakPass(_ sentence: Sentence) {
        let now = Date()
        let code = itemCode(of: sentence)
        modelContext.insert(Attempt(profileID: profile.id, sessionID: sessionID,
                                    itemCode: code, itemKind: .sentence,
                                    unitCode: unit.id, kind: "speak", passed: true, at: now))

        let existing = allProgress.first { $0.profileID == profile.id && $0.itemCode == code }
        let target: ItemProgress
        if let existing {
            target = existing
        } else {
            target = ItemProgress(profileID: profile.id, itemCode: code, itemKind: .sentence,
                                  unitCode: unit.id, volumeCode: pack.id)
            modelContext.insert(target)
        }
        let isFirstPass = target.firstPassedAt == nil
        target.timesSeen += 1
        target.timesPassed += 1
        target.lastSeenAt = now
        if target.firstPassedAt == nil { target.firstPassedAt = now }
        target.masteryLevel = min(4, target.masteryLevel + (isFirstPass ? 1 : 0))

        if isFirstPass {
            // 首次达标：+1 星（幂等）+ 排复习（明天第一次）
            let key = "first:\(code)"
            let result = StarService.grant(profileID: profile.id, amount: 1, reason: "句型跟读达标",
                                           key: key, in: modelContext, now: now)
            if case .granted = result { starsThisSession += 1 }
            BadgeEngine.evaluate(profileID: profile.id, curriculum: nil, in: modelContext, now: now)
            ReviewScheduler.scheduleFirstReview(
                profileID: profile.id, itemCode: code, itemKind: .sentence,
                existing: allReviews.first { $0.profileID == profile.id && $0.itemCode == code },
                in: modelContext, now: now
            )
        }
        try? modelContext.save()
    }

    private func startSession() {
        guard session == nil else { return }
        let session = LearningSession(profileID: profile.id, volumeCode: pack.id, unitCode: unit.id)
        modelContext.insert(session)
        self.session = session
        sessionID = session.id
        try? modelContext.save()
    }

    private func endSession() {
        guard let session, session.endedAt == nil else { return }
        session.endedAt = Date()
        session.durationSeconds = Int(session.endedAt?.timeIntervalSince(session.startedAt) ?? 0)
        try? modelContext.save()
    }
}
