import Foundation
import SwiftData

/// 家长趋势报表的按日快照（design「家长趋势报表」/ tasks 19.3）。
///
/// `report/daily-snapshots.jsonl`，一行一天一孩子，保留 90 天，同一天幂等（只留一条）。
///
/// 为什么要有快照：报告打开时才聚合全量 `Attempt` 会随数据量越来越慢，而折线图只需要
/// 每天几个数。快照**可以随时由明细重建**，所以它不进备份（恢复后按需回填）。
///
/// 口径注意（design 2026-11-07 补充）：**复习完成数必须从 `Attempt(kind=review, passed)`
/// 按 `itemCode` 去重聚合**，不能读 `ReviewSchedule` 的当前状态——那张表只有"现在"，
/// 隔几天再回填会把当天的复习完成算成 0 或重复计。
enum DailySnapshotStore {

    static let retentionDays = 90

    struct Snapshot: Codable, Identifiable, Equatable {
        var profileID: UUID
        /// `yyyy-MM-dd`（本地时区）
        var date: String
        /// 当日跟读明细条数（`AccuracyRule.countedKinds`）
        var attempts: Int
        var passed: Int
        /// 当日学习时长（分钟，向下取整）
        var minutes: Int
        var newWords: Int
        var newSentences: Int
        /// 当日"通过"的复习条目数（按 itemCode 去重）
        var reviewsCompleted: Int
        /// 当日发星数（只算正向发放）
        var stars: Int

        var id: String { "\(profileID.uuidString)#\(date)" }

        /// 当日正确率；没有跟读明细时为 nil（折线断开，不要画成 0）
        var accuracy: Double? {
            attempts == 0 ? nil : Double(passed) / Double(attempts)
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static var directory: URL {
        DiagnosticsLog.directory.appendingPathComponent("report", isDirectory: true)
    }

    /// 测试用：指向临时文件，避免动到真实报表目录
    static var fileURLOverride: URL?

    static var fileURL: URL {
        fileURLOverride ?? directory.appendingPathComponent("daily-snapshots.jsonl")
    }

    // MARK: - 读

    static func all() -> [Snapshot] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: 0x0A).compactMap { line in
            try? decoder.decode(Snapshot.self, from: Data(line))
        }
    }

    /// 某个孩子的快照，按日期升序（折线图直接消费）
    static func snapshots(profileID: UUID) -> [Snapshot] {
        all().filter { $0.profileID == profileID }.sorted { $0.date < $1.date }
    }

    // MARK: - 回填

    /// 从明细重算最近 `days` 天的快照并合并写入（幂等）。报告页每次打开调用一次即可。
    @discardableResult
    static func backfill(profileID: UUID, context: ModelContext,
                         days: Int = 30, now: Date = Date()) -> [Snapshot] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -(max(1, days) - 1), to: today) else {
            return snapshots(profileID: profileID)
        }

        let computed = compute(profileID: profileID, context: context, from: start, to: now)

        var merged = all().filter { snapshot in
            // 只替换这段窗口内、这个孩子的行；窗口外原样保留
            !(snapshot.profileID == profileID && snapshot.date >= key(start))
        }
        merged.append(contentsOf: computed)
        merged = prune(merged, now: now).sorted { $0.date < $1.date }
        write(merged)
        return merged.filter { $0.profileID == profileID }
    }

    // MARK: - 计算

    private static func compute(profileID: UUID, context: ModelContext,
                                from start: Date, to end: Date) -> [Snapshot] {
        let pid = profileID

        let attempts = (try? context.fetch(FetchDescriptor<Attempt>(
            predicate: #Predicate { $0.profileID == pid && $0.at >= start }))) ?? []
        let sessions = (try? context.fetch(FetchDescriptor<LearningSession>(
            predicate: #Predicate { $0.profileID == pid && $0.startedAt >= start }))) ?? []
        let ledger = (try? context.fetch(FetchDescriptor<StarLedger>(
            predicate: #Predicate { $0.profileID == pid && $0.at >= start }))) ?? []
        let progress = (try? context.fetch(FetchDescriptor<ItemProgress>(
            predicate: #Predicate { $0.profileID == pid }))) ?? []

        var days: [String: Snapshot] = [:]
        func row(_ date: Date) -> Snapshot {
            let key = self.key(date)
            if let existing = days[key] { return existing }
            let fresh = Snapshot(profileID: profileID, date: key, attempts: 0, passed: 0,
                                 minutes: 0, newWords: 0, newSentences: 0,
                                 reviewsCompleted: 0, stars: 0)
            days[key] = fresh
            return fresh
        }

        for attempt in attempts {
            guard attempt.at <= end else { continue }
            var current = row(attempt.at)
            if AccuracyRule.countedKinds.contains(attempt.kind) {
                current.attempts += 1
                if attempt.passed { current.passed += 1 }
            }
            days[current.date] = current
        }

        for session in sessions where session.startedAt <= end {
            var current = row(session.startedAt)
            current.minutes += session.durationSeconds
            days[current.date] = current
        }

        for item in ledger where item.at <= end && item.amount > 0 {
            var current = row(item.at)
            current.stars += item.amount
            days[current.date] = current
        }

        // 新学词 / 句：首次达标时间落在当天
        for entry in progress {
            guard let first = entry.firstPassedAt, first >= start, first <= end else { continue }
            var current = row(first)
            if entry.itemKind == ItemKind.sentence.rawValue {
                current.newSentences += 1
            } else {
                current.newWords += 1
            }
            days[current.date] = current
        }

        // 复习完成：当天通过的复习明细，按 itemCode 去重（同一句重读多次只算一次）
        var reviewCodes: [String: Set<String>] = [:]
        for attempt in attempts where attempt.kind == "review" && attempt.passed && attempt.at <= end {
            reviewCodes[key(attempt.at), default: []].insert(attempt.itemCode)
        }
        for (dateKey, codes) in reviewCodes {
            guard var current = days[dateKey] else { continue }
            current.reviewsCompleted = codes.count
            days[dateKey] = current
        }

        // 分钟取整放在最后，避免边加边截断
        for (dateKey, var snapshot) in days {
            snapshot.minutes = snapshot.minutes / 60
            days[dateKey] = snapshot
        }

        return Array(days.values)
    }

    // MARK: - 私有

    private static func key(_ date: Date) -> String { dayFormatter.string(from: date) }

    /// 日期 → `yyyy-MM-dd`（UI 与测试共用同一口径）
    static func dayKey(_ date: Date) -> String { key(date) }

    /// 测试用：直接落盘（模拟历史遗留行）
    static func writeForTesting(_ snapshots: [Snapshot]) { write(snapshots) }

    private static func write(_ snapshots: [Snapshot]) {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        var out = Data()
        for snapshot in snapshots {
            guard let line = try? encoder.encode(snapshot) else { continue }
            out.append(line)
            out.append(0x0A)
        }
        try? out.write(to: fileURL, options: .atomic)
    }

    private static func prune(_ snapshots: [Snapshot], now: Date) -> [Snapshot] {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: now) else {
            return snapshots
        }
        let cutoffKey = key(cutoff)
        return snapshots.filter { $0.date >= cutoffKey }
    }
}
