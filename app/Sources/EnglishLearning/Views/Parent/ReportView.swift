import SwiftData
import SwiftUI

/// 学习报告（tasks 6.2）：时长、正确率、进度、近 7 天曲线、薄弱条目。
/// 正确率**按 `AccuracyRule.countedKinds` 聚合 `Attempt`**，不读任何聚合字段（design「指标口径」）。
struct ReportView: View {
    let profile: Profile
    @Query private var attempts: [Attempt]
    @Query private var sessions: [LearningSession]
    @Query private var progressList: [ItemProgress]
    @Query private var ledger: [StarLedger]

    @State private var curriculum: Curriculum?

    private let library = ContentLibrary.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                summaryRow
                weekChart
                weakSection
                recentSection
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("学习报告")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
    }

    // MARK: - 概览

    private var summaryRow: some View {
        HStack(spacing: 12) {
            stat("累计时长", "\(totalMinutes) 分钟", Theme.orangeSoft, Theme.orangeDark)
            stat("近 7 天", "\(weekMinutes) 分钟", Theme.blueSoft, Theme.blueInk)
            stat("跟读正确率", accuracyText, Theme.greenSoft, Theme.greenInk)
            stat("星星余额", "\(starBalance)", Theme.chipBg, Theme.ink)
        }
    }

    private func stat(_ title: String, _ value: String, _ bg: Color, _ fg: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
            Text(value).font(.system(size: 20, weight: .heavy)).foregroundStyle(fg)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(bg)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - 近 7 天

    private var weekChart: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("近 7 天学习时长").font(.system(size: 15, weight: .heavy))

            HStack(alignment: .bottom, spacing: 10) {
                ForEach(weekDays, id: \.label) { day in
                    VStack(spacing: 6) {
                        Text("\(day.minutes)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(day.minutes == 0 ? Theme.faint : Theme.orangeDark)
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(day.minutes == 0 ? Theme.track : Theme.orange.opacity(0.75))
                            .frame(height: max(6, 96 * day.ratio))
                        Text(day.label)
                            .font(.system(size: 11))
                            .foregroundStyle(day.isToday ? Theme.ink : Theme.muted)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 138)
        }
        .kidCard()
    }

    // MARK: - 薄弱条目

    private var weakSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("需要多练的").font(.system(size: 15, weight: .heavy))
                Spacer()
                Text("按跟读未通过次数排").font(.system(size: 11.5)).foregroundStyle(Theme.faint)
            }

            if weakItems.isEmpty {
                Text("这几天的跟读都挺稳，没有明显薄弱的条目")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
            } else {
                ForEach(weakItems, id: \.code) { item in
                    HStack(spacing: 10) {
                        Text(item.title)
                            .font(.system(size: 14.5, weight: .semibold))
                            .lineLimit(1)
                        Spacer()
                        Text("错 \(item.failedCount) / 共 \(item.totalCount)")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.muted)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .kidCard()
    }

    // MARK: - 最近记录

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("最近学习").font(.system(size: 15, weight: .heavy))
            if recentSessions.isEmpty {
                Text("还没有学习记录").font(.system(size: 13)).foregroundStyle(Theme.muted)
            } else {
                ForEach(recentSessions, id: \.id) { session in
                    HStack {
                        Text(Self.formatter.string(from: session.startedAt))
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.muted)
                        Text(session.unitCode.isEmpty ? "自由练习" : "Unit \(session.unitCode.dropFirst())")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text("\(session.durationSeconds / 60) 分钟")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.orangeDark)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .kidCard()
    }

    // MARK: - 数据

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 HH:mm"
        return f
    }()

    private var myAttempts: [Attempt] { attempts.filter { $0.profileID == profile.id } }
    private var mySessions: [LearningSession] { sessions.filter { $0.profileID == profile.id } }

    private var countedAttempts: [Attempt] {
        myAttempts.filter { AccuracyRule.countedKinds.contains($0.kind) }
    }

    private var totalMinutes: Int {
        mySessions.reduce(0) { $0 + $1.durationSeconds } / 60
    }

    private var weekMinutes: Int {
        let start = Calendar.current.date(byAdding: .day, value: -6,
                                          to: Calendar.current.startOfDay(for: Date())) ?? Date()
        return mySessions.filter { $0.startedAt >= start }
            .reduce(0) { $0 + $1.durationSeconds } / 60
    }

    private var accuracyText: String {
        guard !countedAttempts.isEmpty else { return "—" }
        let passed = countedAttempts.filter(\.passed).count
        return "\(Int((Double(passed) / Double(countedAttempts.count) * 100).rounded()))%"
    }

    private var starBalance: Int {
        ledger.filter { $0.profileID == profile.id }.reduce(0) { $0 + $1.amount }
    }

    private struct DayPoint {
        let label: String
        let minutes: Int
        let ratio: Double
        let isToday: Bool
    }

    private var weekDays: [DayPoint] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let labels = ["日", "一", "二", "三", "四", "五", "六"]
        var points: [DayPoint] = []
        var raw: [Int] = []
        for offset in stride(from: 6, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let next = calendar.date(byAdding: .day, value: 1, to: day) ?? day
            let minutes = mySessions
                .filter { $0.startedAt >= day && $0.startedAt < next }
                .reduce(0) { $0 + $1.durationSeconds } / 60
            raw.append(minutes)
            let index = calendar.component(.weekday, from: day) - 1
            points.append(DayPoint(label: offset == 0 ? "今天" : labels[index],
                                   minutes: minutes,
                                   ratio: 0,
                                   isToday: offset == 0))
        }
        let maxValue = max(raw.max() ?? 0, 1)
        return points.map { point in
            DayPoint(label: point.label, minutes: point.minutes,
                     ratio: Double(point.minutes) / Double(maxValue), isToday: point.isToday)
        }
    }

    private struct WeakItem {
        let code: String
        let title: String
        let failedCount: Int
        let totalCount: Int
    }

    private var weakItems: [WeakItem] {
        var stats: [String: (failed: Int, total: Int)] = [:]
        for attempt in countedAttempts {
            var current = stats[attempt.itemCode] ?? (0, 0)
            current.total += 1
            if !attempt.passed { current.failed += 1 }
            stats[attempt.itemCode] = current
        }
        let titles = itemTitles
        var items: [WeakItem] = []
        for (code, value) in stats where value.failed > 0 {
            items.append(WeakItem(code: code,
                                  title: titles[code] ?? code,
                                  failedCount: value.failed,
                                  totalCount: value.total))
        }
        items.sort { lhs, rhs in
            if lhs.failedCount == rhs.failedCount {
                return lhs.totalCount > rhs.totalCount
            }
            return lhs.failedCount > rhs.failedCount
        }
        return Array(items.prefix(5))
    }

    /// itemCode → 显示的英文（内容只在内存里解码，不进库）
    private var itemTitles: [String: String] {
        guard let curriculum else { return [:] }
        var map: [String: String] = [:]
        for volume in curriculum.volumes {
            for unit in volume.units {
                for word in unit.words { map[word.itemCode] = word.en }
                for sentence in unit.sentences { map[sentence.itemCode(in: unit.id)] = sentence.en }
            }
        }
        return map
    }

    private var recentSessions: [LearningSession] {
        mySessions.sorted { $0.startedAt > $1.startedAt }.prefix(6).map { $0 }
    }

    private func load() {
        guard let pack = library.installed.first else { return }
        curriculum = try? library.curriculum(for: pack)
    }
}
