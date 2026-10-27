import Foundation
import SwiftData

/// 间隔重复调度（design「奖励与防沉迷参数」）：
/// 间隔 1 → 3 → 7 → 14 → 30 天；答对进一级，答错退一级（最低回到 1 天）；
/// 新学完的条目首次复习 = 学完次日，到点由首页「到期复习」出队（上限读 `LearningSettings.reviewLimitPerSession`）。
enum ReviewScheduler {
    static let intervals: [Int] = [1, 3, 7, 14, 30]

    /// 首次达标时排复习；已有排期就不动（重复达标不重置进度）
    @discardableResult
    static func scheduleFirstReview(profileID: UUID,
                                    itemCode: String,
                                    itemKind: ItemKind,
                                    existing: ReviewSchedule?,
                                    in context: ModelContext,
                                    now: Date = Date()) -> ReviewSchedule {
        if let existing { return existing }
        let calendar = Calendar.current
        let due = calendar.date(byAdding: .day, value: intervals[0],
                                to: calendar.startOfDay(for: now)) ?? now
        let schedule = ReviewSchedule(profileID: profileID, itemCode: itemCode, itemKind: itemKind,
                                      scheduledAt: due, intervalDays: intervals[0], stage: 1)
        context.insert(schedule)
        return schedule
    }

    /// 答对：进一级（封顶 30 天），下次复习 = 今天 + 新一级间隔
    static func advance(_ schedule: ReviewSchedule, now: Date = Date()) {
        schedule.stage = min(intervals.count, schedule.stage + 1)
        schedule.intervalDays = intervals[schedule.stage - 1]
        schedule.scheduledAt = Calendar.current.date(byAdding: .day, value: schedule.intervalDays, to: now) ?? now
        schedule.lastReviewedAt = now
    }

    /// 答错：退一级（最低 1 天），明天再来
    static func retreat(_ schedule: ReviewSchedule, now: Date = Date()) {
        schedule.stage = max(1, schedule.stage - 1)
        schedule.intervalDays = intervals[schedule.stage - 1]
        schedule.scheduledAt = Calendar.current.date(byAdding: .day, value: schedule.intervalDays, to: now) ?? now
        schedule.lastReviewedAt = now
    }

    /// 到期队列：按到期时间早的在前，取前 `limit` 个（「今天」按本地 0 点切分，`scheduledAt <= now` 即到期）
    static func dueQueue(from schedules: [ReviewSchedule],
                         profileID: UUID,
                         limit: Int,
                         now: Date = Date()) -> [ReviewSchedule] {
        schedules
            .filter { $0.profileID == profileID && $0.scheduledAt <= now }
            .sorted { $0.scheduledAt < $1.scheduledAt }
            .prefix(max(0, limit))
            .map { $0 }
    }

    /// 队列长度（首页「到期复习」数字用它，保证和点进去看到的条数一致）
    static func dueCount(from schedules: [ReviewSchedule],
                         profileID: UUID,
                         limit: Int,
                         now: Date = Date()) -> Int {
        dueQueue(from: schedules, profileID: profileID, limit: limit, now: now).count
    }
}
