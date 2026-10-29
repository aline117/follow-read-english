import SwiftData
import SwiftUI

/// 学习 Tab 首页（原型 A6）：问候条 + 今天的任务 + 本册进度。
/// 没有已安装学期时退回 A7 空状态，不放一个空白的学习页。
struct HomeView: View {
    let profile: Profile
    var onParentMode: () -> Void = {}

    @Environment(\.modelContext) private var modelContext

    @Query private var ledger: [StarLedger]
    @Query private var settingsList: [LearningSettings]
    @Query private var allProgress: [ItemProgress]
    @Query private var allReviews: [ReviewSchedule]
    @Query private var sessions: [LearningSession]
    @Query private var allAttempts: [Attempt]
    @Query private var badges: [Badge]

    @State private var curriculum: Curriculum?
    @State private var loadError: String?
    /// 进入学习页时把单元 id 固定下来：学完 Unit 1 后首页的「当前单元」会变成 Unit 2，
    /// 若直接用 `NavigationLink { WordLearningView(unit: currentUnit) }`，目的页会被替换成下一单元
    @State private var learningUnitID: String?
    /// 「继续学习」从本单元第一个还没达标的条目开始，而不是每次都从头
    @State private var learningStartIndex: Int?

    private let library = ContentLibrary.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header

                if let pack = library.installed.first {
                    if let loadError {
                        ContentProblemView(message: loadError) { loadCurriculum(force: true) }
                            .kidCard()
                    } else {
                        if isBookFinished {
                            completionCard(pack)
                        } else {
                            todayCard(pack)
                        }
                        bookProgressCard(pack)
                    }
                } else {
                    EmptyContentView(onRetry: refreshContent)
                }
            }
            .padding(.horizontal, 42)
            .padding(.top, 6)
            .padding(.bottom, 28)
        }
        .background(Theme.bg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task {
            loadCurriculum()
            // 进首页时补算一次徽章（单元/整册这类需要内容的条件在这里判定，tasks 5.2）
            _ = BadgeEngine.evaluate(profileID: profile.id, curriculum: curriculum, in: modelContext)
        }
        .navigationDestination(item: $learningUnitID) { id in
            if let pack = library.installed.first,
               let unit = units.first(where: { $0.id == id }) {
                WordLearningView(profile: profile, pack: pack, unit: unit,
                                 startIndex: learningStartIndex)
            }
        }
    }

    // MARK: - 顶部问候条

    private var header: some View {
        HStack(spacing: 14) {
            Text(String(profile.name.prefix(1)))
                .font(.system(size: 21, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .background(
                    LinearGradient(colors: [Color(hex: 0x9BE0F5), Theme.blue],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("\(greeting)，\(profile.name)")
                    .font(.system(size: 19, weight: .heavy))
                    .foregroundStyle(Theme.ink)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
            }

            Spacer()

            StarPill(stars: starBalance)

            Button(action: onParentMode) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.faint)
                    .frame(width: 38, height: 38)
                    .background(Theme.chipBg)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .kidTapTarget()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("家长模式")
        }
        .padding(.vertical, 4)
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "早上好"
        case 12..<18: return "下午好"
        default: return "晚上好"
        }
    }

    private var subtitle: String {
        let streak = streakDays
        guard let pack = library.installed.first else {
            return "还没有内容 · 让家长在内容管理里下载"
        }
        let state = learnedItems == 0 ? "刚装好" : "已学 \(learnedItems)/\(totalItems) 条目"
        return "连续学习 \(streak) 天 · \(pack.title) · \(state)"
    }

    // MARK: - 今天的任务

    private func todayCard(_ pack: InstalledPack) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("今天的任务")
                    .font(.system(size: 21, weight: .heavy))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text("预计 \(estimatedMinutes) 分钟")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.muted)
            }

            KidProgressBar(value: taskProgress, tint: .orange, height: 15)
                .padding(.top, 11)

            HStack(spacing: 11) {
                NavigationLink {
                    ReviewView(profile: profile, pack: pack)
                } label: {
                    StatTile(icon: "↻", iconColor: Theme.blue,
                             value: "\(dueReviewCount)", label: "到期复习")
                }
                .buttonStyle(.plain)
                .disabled(dueReviewCount == 0)
                StatTile(icon: "＋", iconColor: Theme.green,
                         value: "\(newWordsPerDay)", label: "新单词", background: Theme.greenSoft)
                if let unit = currentUnit, !unit.sentences.isEmpty, newSentencesPerDay > 0 {
                    NavigationLink {
                        SentenceLearningView(profile: profile, pack: pack, unit: unit)
                    } label: {
                        StatTile(icon: "“", iconColor: Theme.blueInk,
                                 value: "\(newSentencesPerDay)", label: "新句型", background: Theme.blueSoft)
                    }
                    .buttonStyle(.plain)
                } else {
                    StatTile(icon: "“", iconColor: Theme.blueInk,
                             value: "\(newSentencesPerDay)", label: "新句型", background: Theme.blueSoft)
                }
            }
            .padding(.top, 16)

            if dailyMinutesReached {
                Text("今天已经学够 20 分钟啦 · 想继续可以只做复习（不再发星）")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.blueInk)
                    .padding(.top, 10)
            }

            HStack(spacing: 12) {
                if let unit = currentUnit {
                    Button {
                        learningStartIndex = firstUnlearnedWordIndex(in: unit)
                        learningUnitID = unit.id
                    } label: {
                        KidButtonLabel(title: learnedItems == 0 ? "开始学习" : "继续学习")
                    }
                    .buttonStyle(KidButtonStyle())

                    NavigationLink {
                        CourseListView(profile: profile, pack: pack)
                    } label: {
                        KidButtonLabel(title: "课程列表", style: .ghost, compact: true)
                            .frame(width: 160)
                    }
                    .buttonStyle(KidButtonStyle())
                } else {
                    NavigationLink {
                        CourseListView(profile: profile, pack: pack)
                    } label: {
                        KidButtonLabel(title: "课程列表")
                    }
                    .buttonStyle(KidButtonStyle())
                }
            }
            .padding(.top, 18)
        }
        .kidCard()
    }

    // MARK: - 学完整册终态（原型 A9）

    /// 整册学完后首页换成终态卡：累计天数 / 时长 / 正确率 / 徽章 + 去下载其他学期。
    private func completionCard(_ pack: InstalledPack) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("🎉 整册学完啦！")
                .font(.system(size: 23, weight: .heavy))
                .foregroundStyle(Theme.ink)
            Text("\(pack.title) \(totalItems) 个条目全部达标")
                .font(.system(size: 14))
                .foregroundStyle(Theme.muted)
                .padding(.top, 3)

            HStack(spacing: 11) {
                StatTile(icon: "📅", iconColor: Theme.blue,
                         value: "\(studyDays)", label: "学习天数", background: Theme.blueSoft)
                StatTile(icon: "⏱", iconColor: Theme.orangeDark,
                         value: "\(totalMinutes)", label: "累计分钟", background: Theme.orangeSoft)
                StatTile(icon: "🎯", iconColor: Theme.greenInk,
                         value: accuracyText, label: "跟读正确率", background: Theme.greenSoft)
                StatTile(icon: "🏅", iconColor: Theme.orangeDark,
                         value: "\(earnedBadgeCount)", label: "徽章", background: Theme.chipBg)
            }
            .padding(.top, 16)

            Button(action: onParentMode) {
                KidButtonLabel(title: "去下载其他学期")
            }
            .buttonStyle(KidButtonStyle())
            .padding(.top, 18)
        }
        .kidCard()
    }

    // MARK: - 本册进度

    private func bookProgressCard(_ pack: InstalledPack) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("本册进度")
                    .font(.system(size: 18, weight: .heavy))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text("\(learnedItems) / \(totalItems) 个条目")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.muted)
            }

            KidProgressBar(value: bookProgress, tint: .orange, height: 11)
                .padding(.top, 11)

            Text(currentUnitLine)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.muted)
                .padding(.top, 9)
        }
        .kidCard()
    }

    private var currentUnitLine: String {
        guard let unit = currentUnit else {
            return "整册已学完 · 可以去下载其他学期了"
        }
        var parts = ["\(unit.words.count) 个单词"]
        if !unit.sentences.isEmpty { parts.append("\(unit.sentences.count) 条句型") }
        return "当前单元：\(unit.title)（\(parts.joined(separator: "、"))）"
    }

    // MARK: - 数据

    private var units: [Unit] {
        curriculum?.volumes.first?.units ?? []
    }

    /// 「已学」= 跟读达标过（`firstPassedAt` 有值）；只是试过但没达标不算
    private var learnedCodes: Set<String> {
        Set(allProgress
            .filter { $0.profileID == profile.id && $0.firstPassedAt != nil }
            .map(\.itemCode))
    }

    private var totalItems: Int { units.reduce(0) { $0 + $1.totalItemCount } }

    private var learnedItems: Int {
        let codes = learnedCodes
        return units.reduce(0) { partial, unit in
            partial + unit.itemCodes.filter { codes.contains($0) }.count
        }
    }

    private var taskProgress: Double {
        totalItems == 0 ? 0 : Double(learnedItems) / Double(totalItems)
    }

    private var bookProgress: Double { taskProgress }

    /// 第一个还没学完的单元（全学完则为 nil）
    private var currentUnit: Unit? {
        let codes = learnedCodes
        return units.first { unit in
            !unit.itemCodes.allSatisfy { codes.contains($0) }
        }
    }

    /// 星星余额 = 流水求和（design「星星流水制」）
    private var starBalance: Int {
        ledger.filter { $0.profileID == profile.id }.reduce(0) { $0 + $1.amount }
    }

    private var settings: LearningSettings? {
        settingsList.first { $0.profileID == profile.id }
    }

    private var newWordsPerDay: Int { settings?.newWordsPerDay ?? 5 }
    private var newSentencesPerDay: Int { settings?.newSentencesPerDay ?? 1 }

    /// 到期复习数：与点进去看到的队列口径一致（受 `LearningSettings.reviewLimitPerSession` 限制）
    private var dueReviewCount: Int {
        ReviewScheduler.dueCount(from: allReviews, profileID: profile.id,
                                 limit: settings?.reviewLimitPerSession ?? 20)
    }

    /// 今日是否已达 20 分钟软上限（tasks 5.4：超时后只允许无奖励复习）
    private var dailyMinutesReached: Bool {
        let start = Calendar.current.startOfDay(for: Date())
        let seconds = mySessions.filter { $0.startedAt >= start }
            .reduce(0) { $0 + $1.durationSeconds }
        return seconds >= 20 * 60
    }

    /// 20 分钟预算下按条目数估个大概（design 里 9-10 分钟/单元）
    private var estimatedMinutes: Int {
        max(6, min(20, newWordsPerDay * 2 + dueReviewCount + newSentencesPerDay * 3))
    }

    /// 连续学习天数：有学习会话的连续自然日（「今天」按本地 0 点切分）
    private var streakDays: Int {
        let calendar = Calendar.current
        let days = Set(mySessions.map { calendar.startOfDay(for: $0.startedAt) })
        guard !days.isEmpty else { return 0 }
        let today = calendar.startOfDay(for: Date())
        // 今天还没学也不算断：从「今天或昨天」往前数
        var cursor = days.contains(today)
            ? today
            : calendar.date(byAdding: .day, value: -1, to: today)!
        var streak = 0
        while days.contains(cursor) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return streak
    }

    /// 整册是否已学完（所有单元的全部条目都达标过）
    private var isBookFinished: Bool {
        totalItems > 0 && learnedItems >= totalItems
    }

    /// 本单元第一个还没达标的**单词**下标；全部达标或没有单词时返回 nil（从头开始）
    private func firstUnlearnedWordIndex(in unit: Unit) -> Int? {
        let codes = learnedCodes
        guard let index = unit.words.firstIndex(where: { !codes.contains($0.itemCode) }) else {
            return nil
        }
        return index
    }

    /// 终态卡用：累计学习天数（去重自然日）
    private var studyDays: Int {
        Set(mySessions.map { Calendar.current.startOfDay(for: $0.startedAt) }).count
    }

    /// 终态卡用：累计学习分钟
    private var totalMinutes: Int {
        mySessions.reduce(0) { $0 + $1.durationSeconds } / 60
    }

    /// 终态卡用：跟读正确率，口径只算 `AccuracyRule.countedKinds`（默认「说」）
    private var accuracyText: String {
        let counted = myAttempts.filter { AccuracyRule.countedKinds.contains($0.kind) }
        guard !counted.isEmpty else { return "—" }
        let passed = counted.filter(\.passed).count
        return "\(Int((Double(passed) / Double(counted.count) * 100).rounded()))%"
    }

    private var earnedBadgeCount: Int {
        badges.filter { $0.profileID == profile.id }.count
    }

    private var mySessions: [LearningSession] {
        sessions.filter { $0.profileID == profile.id }
    }

    private var myAttempts: [Attempt] {
        allAttempts.filter { $0.profileID == profile.id }
    }

    // MARK: - 加载

    private func loadCurriculum(force: Bool = false) {
        guard let pack = library.installed.first else {
            curriculum = nil
            return
        }
        guard force || curriculum == nil else { return }
        loadError = nil
        do {
            curriculum = try library.curriculum(for: pack)
        } catch {
            loadError = (error as? CurriculumError)?.description ?? error.localizedDescription
        }
    }

    private func refreshContent() {
        library.refresh()
        loadCurriculum(force: true)
    }
}
