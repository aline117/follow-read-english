import SwiftData
import SwiftUI

/// 复习模块（原型 B8）：只练到期队列里的条目，翻卡 → 听常速原声 → 跟读判定。
/// 通过 = 进一级（1→3→7→14→30 天），不通过 = 退一级、明天再来；每次作答写 `Attempt(kind: "review")`。
/// 复习不额外发星（发星只认首次达标，见 design 指标口径表）。
struct ReviewView: View {
    let profile: Profile
    let pack: InstalledPack

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Query private var schedules: [ReviewSchedule]
    @Query private var settingsList: [LearningSettings]

    @State private var curriculum: Curriculum?
    @State private var queue: [ReviewSchedule] = []
    @State private var prepared = false
    @State private var index = 0
    @State private var passedCount = 0
    @State private var failedCount = 0
    @State private var showSummary = false
    @State private var sessionID = UUID()
    @State private var session: LearningSession?
    @State private var lastAssessment: PronunciationAssessment?
    @State private var advanceTask: Task<Void, Never>?

    private let player = AudioPlayer.shared
    private let library = ContentLibrary.shared

    var body: some View {
        VStack(spacing: 0) {
            topBar

            if !prepared {
                Spacer()
            } else if queue.isEmpty {
                emptyState
            } else if let schedule = currentSchedule, let item = currentItem {
                HStack(alignment: .center, spacing: 26) {
                    itemPanel(item, schedule: schedule)
                    FollowReadPanel(word: item.text,
                                    referenceURL: item.audioURL,
                                    isPaused: showSummary,
                                    onAssessment: { handle($0, schedule: schedule) },
                                    onSkip: { skip(schedule) })
                        .frame(width: 430)
                        .id(schedule.itemCode)
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
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text("复习")
                    .font(.system(size: 20, weight: .heavy))
                    .foregroundStyle(Theme.ink)
                Text("到期 \(queue.count) 条 · 还剩 \(max(0, queue.count - index)) 条")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.muted)
            }

            Spacer()

            if !queue.isEmpty {
                Text("\(index) / \(queue.count)")
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(Theme.orangeDark)
            }
        }
        .padding(.horizontal, 36)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("✨").font(.system(size: 44))
            Text("今天没有到期复习")
                .font(.system(size: 20, weight: .heavy))
                .foregroundStyle(Theme.ink)
            Text("学过的词会按 1 / 3 / 7 / 14 / 30 天的间隔回来找你")
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.muted)
            Button {
                dismiss()
            } label: {
                KidButtonLabel(title: "回到学习", style: .ghost)
            }
            .buttonStyle(KidButtonStyle())
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 卡片

    private func itemPanel(_ item: ReviewItem, schedule: ReviewSchedule) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(item.kind == .word ? "单词" : "句型")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(item.kind == .word ? Theme.blueInk : Theme.orangeDark)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(item.kind == .word ? Theme.blueSoft : Theme.orangeSoft)
                    .clipShape(Capsule())

                Spacer()

                Text("第 \(schedule.stage) 级 · \(schedule.intervalDays) 天间隔")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.muted)
            }

            Spacer(minLength: 10)

            if let imageURL = item.imageURL {
                AsyncImage(url: imageURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit()
                    } else {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Theme.chipBg)
                            .overlay(Text("🖼").font(.system(size: 40)).foregroundStyle(Theme.faint))
                    }
                }
                .frame(maxWidth: 320, maxHeight: 240)
                .frame(maxWidth: .infinity)
            }

            Text(item.text)
                .font(.system(size: item.kind == .word ? 36 : 26, weight: .heavy))
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 14)

            Text(item.meaning)
                .font(.system(size: 16))
                .foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)

            Button {
                play(item)
            } label: {
                KidButtonLabel(title: "听一遍原声", style: .ghost, compact: true)
            }
            .buttonStyle(KidButtonStyle())
            .frame(maxWidth: .infinity)
            .padding(.top, 16)

            if let lastAssessment {
                Text(lastAssessment.isPassed ? "✅ 通过" : "再听一次试试")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(lastAssessment.isPassed ? Theme.greenInk : Theme.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 10)
            }

            Spacer(minLength: 10)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1.5)
        )
    }

    // MARK: - 结算

    private var summarySheet: some View {
        VStack(spacing: 14) {
            Text(passedCount > 0 ? "🎉" : "👋").font(.system(size: 44))
            Text(passedCount > 0 ? "复习完成" : "这次先到这里")
                .font(.system(size: 23, weight: .heavy))
                .foregroundStyle(Theme.ink)
            Text("通过 \(passedCount) 条 · 没通过 \(failedCount) 条")
                .font(.system(size: 15.5, weight: .semibold))
                .foregroundStyle(Theme.orangeDark)
            Text("没通过的明天会再来一次")
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)

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

    private var currentSchedule: ReviewSchedule? {
        queue.indices.contains(index) ? queue[index] : nil
    }

    private var currentItem: ReviewItem? {
        guard let schedule = currentSchedule else { return nil }
        return items[schedule.itemCode]
    }

    /// itemCode → 展示信息（en / zh / 图 / 音）
    private struct ReviewItem {
        let code: String
        let kind: ItemKind
        let text: String
        let meaning: String
        let imageURL: URL?
        let audioURL: URL?
    }

    private var items: [String: ReviewItem] {
        guard let curriculum else { return [:] }
        var map: [String: ReviewItem] = [:]
        for volume in curriculum.volumes {
            for unit in volume.units {
                for word in unit.words {
                    map[word.itemCode] = ReviewItem(
                        code: word.itemCode,
                        kind: .word,
                        text: word.en,
                        meaning: Self.stripPartOfSpeech(word.zh),
                        imageURL: ResourceLocator.url(semester: pack.id, relativePath: word.image),
                        audioURL: ResourceLocator.url(semester: pack.id, relativePath: word.audio)
                    )
                }
                for sentence in unit.sentences {
                    let code = sentence.itemCode(in: unit.id)
                    map[code] = ReviewItem(
                        code: code,
                        kind: .sentence,
                        text: sentence.en,
                        meaning: sentence.zh,
                        imageURL: nil,
                        audioURL: sentence.audio.isEmpty
                            ? nil
                            : ResourceLocator.url(semester: pack.id, relativePath: sentence.audio)
                    )
                }
            }
        }
        return map
    }

    /// JSON 里是 `v.感觉到`，界面只显示主体词义（design「内容编码」）
    private static func stripPartOfSpeech(_ zh: String) -> String {
        guard let dot = zh.firstIndex(of: "."), zh.distance(from: zh.startIndex, to: dot) <= 3 else {
            return zh
        }
        return String(zh[zh.index(after: dot)...])
    }

    private var settings: LearningSettings? {
        settingsList.first { $0.profileID == profile.id }
    }

    // MARK: - 流程

    private func play(_ item: ReviewItem) {
        guard let url = item.audioURL else {
            DiagnosticsLog.assertAsset(nil, path: item.code, context: "ReviewView.play")
            return
        }
        player.play(url: url, rate: 1)   // 复习默认常速
    }

    private func handle(_ assessment: PronunciationAssessment, schedule: ReviewSchedule) {
        lastAssessment = assessment
        let now = Date()
        modelContext.insert(Attempt(profileID: profile.id, sessionID: sessionID,
                                    itemCode: schedule.itemCode, itemKind: schedule.kind,
                                    unitCode: unitCode(for: schedule.itemCode),
                                    kind: "review", passed: assessment.isPassed, at: now))

        if assessment.isPassed {
            ReviewScheduler.advance(schedule, now: now)
            passedCount += 1
            try? modelContext.save()
            advanceTask?.cancel()
            advanceTask = Task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run { next() }
            }
        } else {
            ReviewScheduler.retreat(schedule, now: now)
            failedCount += 1
            try? modelContext.save()
        }
    }

    private func skip(_ schedule: ReviewSchedule) {
        // 跳过按「没通过」处理：退一级，明天再来，避免用过跳过刷进度
        modelContext.insert(Attempt(profileID: profile.id, sessionID: sessionID,
                                    itemCode: schedule.itemCode, itemKind: schedule.kind,
                                    unitCode: unitCode(for: schedule.itemCode),
                                    kind: "review", passed: false, at: Date()))
        ReviewScheduler.retreat(schedule, now: Date())
        failedCount += 1
        try? modelContext.save()
        next()
    }

    private func next() {
        lastAssessment = nil
        if index + 1 < queue.count {
            index += 1
        } else {
            index = queue.count
            showSummary = true
        }
    }

    private func unitCode(for itemCode: String) -> String {
        if itemCode.hasPrefix("s:") {
            let rest = itemCode.dropFirst(2)          // u1-s1
            return String(rest.split(separator: "-").first ?? "")
        }
        for volume in curriculum?.volumes ?? [] {
            for unit in volume.units where unit.words.contains(where: { $0.itemCode == itemCode }) {
                return unit.id
            }
        }
        return ""
    }

    private func prepareIfNeeded() {
        guard !prepared else { return }
        prepared = true
        do {
            curriculum = try library.curriculum(for: pack)
        } catch {
            queue = []
            return
        }
        let limit = settings?.reviewLimitPerSession ?? 20
        queue = ReviewScheduler.dueQueue(from: schedules, profileID: profile.id, limit: limit)
        startSession()
    }

    private func startSession() {
        guard session == nil, !queue.isEmpty else { return }
        let session = LearningSession(profileID: profile.id, volumeCode: pack.id,
                                      unitCode: queue.first.map { unitCode(for: $0.itemCode) } ?? "")
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
