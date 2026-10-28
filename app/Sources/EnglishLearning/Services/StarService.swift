import Foundation
import SwiftData

/// 发星与防沉迷（tasks 5.1 / 5.4）：所有发星都走这里，保证三条规则只有一处实现。
/// - **幂等**：`grantKey` 唯一，重进结算页不会重复加
/// - **余额上限 500**：将超额时不再发（只记诊断，不报错）
/// - **系统时间回拨冻结**：发现"现在"比上次记录还早，就暂停发星，避免改系统时间刷星
enum StarService {
    static let balanceCap = 500

    private static let lastSeenKey = "clockGuard.lastSeen"
    /// 允许的时钟漂移（秒）；超过这个回拨量视为"改过系统时间"
    private static let rollbackTolerance: TimeInterval = 300

    enum GrantResult {
        case granted(total: Int)
        case duplicate
        case balanceCapped(current: Int)
        case clockRollback
    }

    // MARK: - 发星

    @discardableResult
    static func grant(profileID: UUID,
                      amount: Int,
                      reason: String,
                      key: String,
                      in context: ModelContext,
                      now: Date = Date()) -> GrantResult {
        guard observeClock(now: now) else {
            DiagnosticsLog.log("star_frozen_clock_rollback")
            return .clockRollback
        }

        if hasGrant(key: key, profileID: profileID, in: context) {
            return .duplicate
        }

        let current = balance(profileID: profileID, in: context)
        if amount > 0, current + amount > balanceCap {
            DiagnosticsLog.log("star_balance_capped", ["balance": "\(current)", "amount": "\(amount)"])
            return .balanceCapped(current: current)
        }

        context.insert(StarLedger(profileID: profileID, amount: amount, reason: reason,
                                  grantKey: key, at: now))
        return .granted(total: current + amount)
    }

    /// 本地自然日戳，用于「同一 item 每天只发一次」的幂等键
    static func dayStamp(_ date: Date = Date(), calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: - 查询

    static func balance(profileID: UUID, in context: ModelContext) -> Int {
        let pid = profileID
        let entries = (try? context.fetch(
            FetchDescriptor<StarLedger>(predicate: #Predicate { $0.profileID == pid }))) ?? []
        return entries.reduce(0) { $0 + $1.amount }
    }

    /// 「今日已发」= 当天流水里正数的和（不存聚合字段，design「星星流水制」）
    static func todayGranted(profileID: UUID, in context: ModelContext, now: Date = Date()) -> Int {
        let pid = profileID
        let entries = (try? context.fetch(
            FetchDescriptor<StarLedger>(predicate: #Predicate { $0.profileID == pid }))) ?? []
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        return entries
            .filter { $0.amount > 0 && $0.at >= start }
            .reduce(0) { $0 + $1.amount }
    }

    static func hasGrant(key: String, profileID: UUID, in context: ModelContext) -> Bool {
        let pid = profileID
        let entries = (try? context.fetch(
            FetchDescriptor<StarLedger>(predicate: #Predicate { $0.profileID == pid && $0.grantKey == key }))) ?? []
        return !entries.isEmpty
    }

    // MARK: - 时钟守卫

    /// 返回 false 表示检测到时间回拨，应冻结发星
    static func observeClock(now: Date = Date()) -> Bool {
        let defaults = UserDefaults.standard
        if let last = defaults.object(forKey: lastSeenKey) as? Date {
            if now.timeIntervalSince(last) < -rollbackTolerance {
                return false
            }
            if now > last {
                defaults.set(now, forKey: lastSeenKey)
            }
        } else {
            defaults.set(now, forKey: lastSeenKey)
        }
        return true
    }

    /// 今天是否已经超过 20 分钟学习时长（软上限：允许无奖励复习）
    static func dailyMinutesReached(profileID: UUID, in context: ModelContext,
                                    limit: Int = 20, now: Date = Date()) -> Bool {
        let pid = profileID
        let sessions = (try? context.fetch(
            FetchDescriptor<LearningSession>(predicate: #Predicate { $0.profileID == pid }))) ?? []
        let start = Calendar.current.startOfDay(for: now)
        let seconds = sessions.filter { $0.startedAt >= start }
            .reduce(0) { $0 + $1.durationSeconds }
        return seconds >= limit * 60
    }
}
