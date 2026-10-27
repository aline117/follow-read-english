import Foundation
import SwiftData

/// 6 个徽章（tasks 5.2 / design 奖励参数表）。
/// 判定全部由现有明细现算（`ItemProgress` / `Attempt` / `LearningSession`），不存聚合状态。
enum BadgeKind: String, CaseIterable {
    case firstLearn = "first_learn"
    case streak3 = "streak_3"
    case streak7 = "streak_7"
    case firstUnit = "first_unit"
    case bookDone = "book_done"
    case speak20 = "speak_20"

    var title: String {
        switch self {
        case .firstLearn: return "初次学习"
        case .streak3: return "连学 3 天"
        case .streak7: return "连学 7 天"
        case .firstUnit: return "首个单元"
        case .bookDone: return "完成整册"
        case .speak20: return "跟读达人"
        }
    }

    var icon: String {
        switch self {
        case .firstLearn: return "★"
        case .streak3: return "3"
        case .streak7: return "7"
        case .firstUnit: return "单"
        case .bookDone: return "册"
        case .speak20: return "20"
        }
    }

    var conditionText: String {
        switch self {
        case .firstLearn: return "第一次跟读达标"
        case .streak3: return "连续 3 天学习"
        case .streak7: return "连续 7 天学习"
        case .firstUnit: return "学完第一个单元"
        case .bookDone: return "学完整册"
        case .speak20: return "跟读累计达标 20 次"
        }
    }
}

/// 徽章判定：多次调用无副作用（已有同 kind 就跳过）。
enum BadgeEngine {
    @discardableResult
    static func evaluate(profileID: UUID,
                         curriculum: Curriculum?,
                         in context: ModelContext,
                         now: Date = Date()) -> [BadgeKind] {
        let pid = profileID
        let progress = (try? context.fetch(
            FetchDescriptor<ItemProgress>(predicate: #Predicate { $0.profileID == pid }))) ?? []
        let attempts = (try? context.fetch(
            FetchDescriptor<Attempt>(predicate: #Predicate { $0.profileID == pid }))) ?? []
        let sessions = (try? context.fetch(
            FetchDescriptor<LearningSession>(predicate: #Predicate { $0.profileID == pid }))) ?? []
        let owned = (try? context.fetch(
            FetchDescriptor<Badge>(predicate: #Predicate { $0.profileID == pid }))) ?? []
        let ownedKinds = Set(owned.map(\.kind))

        let learned = progress.filter { $0.firstPassedAt != nil }
        let speakPassed = attempts.filter { $0.kind == "speak" && $0.passed }

        var earned: [BadgeKind] = []
        func award(_ kind: BadgeKind, _ condition: Bool) {
            guard condition, !ownedKinds.contains(kind.rawValue) else { return }
            context.insert(Badge(profileID: pid, kind: kind.rawValue))
            earned.append(kind)
        }

        award(.firstLearn, !learned.isEmpty)
        award(.speak20, speakPassed.count >= 20)
        award(.streak3, streakDays(sessions: sessions) >= 3)
        award(.streak7, streakDays(sessions: sessions) >= 7)

        if let curriculum {
            let learnedCodes = Set(learned.map(\.itemCode))
            let units = curriculum.volumes.first?.units ?? []
            let completedUnit = units.contains { unit in
                !unit.itemCodes.isEmpty && unit.itemCodes.allSatisfy { learnedCodes.contains($0) }
            }
            award(.firstUnit, completedUnit)
            let allCodes = units.flatMap(\.itemCodes)
            award(.bookDone, !allCodes.isEmpty && allCodes.allSatisfy { learnedCodes.contains($0) })
        }

        if !earned.isEmpty {
            try? context.save()
            for kind in earned { DiagnosticsLog.log("badge_earned", ["kind": kind.rawValue]) }
        }
        return earned
    }

    /// 连续学习天数（与首页同一口径：去重自然日，今天没学不算断）
    static func streakDays(sessions: [LearningSession], now: Date = Date()) -> Int {
        let calendar = Calendar.current
        let days = Set(sessions.map { calendar.startOfDay(for: $0.startedAt) })
        guard !days.isEmpty else { return 0 }
        let today = calendar.startOfDay(for: now)
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

    /// 已获得的徽章 kind 集合
    static func ownedKinds(profileID: UUID, in context: ModelContext) -> Set<String> {
        let pid = profileID
        let owned = (try? context.fetch(
            FetchDescriptor<Badge>(predicate: #Predicate { $0.profileID == pid }))) ?? []
        return Set(owned.map(\.kind))
    }
}
