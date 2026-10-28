import Foundation
import Observation

/// 家长可调的媒体设置（tasks 13.6 / 15.1 的服务层）。
/// 与学习无关，单独存 UserDefaults；家长页面后续直接读写这里。
@MainActor
@Observable
final class MediaSettingsStore {
    static let shared = MediaSettingsStore()

    /// 每日观看上限档位（分钟）；`-1` = 关闭（不限），`0` = 整区不可播
    static let dailyLimitOptions = [0, 5, 10, 15, -1]
    static let defaultDailyLimit = 5

    private enum Key {
        static let dailyLimit = "media.dailyLimitMinutes"
        static let cacheLimit = "media.cacheLimitGB"
        static let wifiOnly = "media.wifiOnlyPrefetch"
    }

    /// 0 = 今天不能看，-1 = 不限
    var dailyLimitMinutes: Int {
        didSet { UserDefaults.standard.set(dailyLimitMinutes, forKey: Key.dailyLimit) }
    }

    /// 缓存上限档位（GB）：1 / 2 / 5
    var cacheLimitGB: Int {
        didSet { UserDefaults.standard.set(cacheLimitGB, forKey: Key.cacheLimit) }
    }

    /// 只在 Wi-Fi 下预取（真机可读蜂窝状态；模拟器默认 true）
    var wifiOnlyPrefetch: Bool {
        didSet { UserDefaults.standard.set(wifiOnlyPrefetch, forKey: Key.wifiOnly) }
    }

    private init() {
        let defaults = UserDefaults.standard
        dailyLimitMinutes = defaults.object(forKey: Key.dailyLimit) as? Int ?? Self.defaultDailyLimit
        cacheLimitGB = defaults.object(forKey: Key.cacheLimit) as? Int ?? MediaCacheStore.defaultLimitGB
        wifiOnlyPrefetch = defaults.object(forKey: Key.wifiOnly) as? Bool ?? true
    }

    /// 观看区是否整体禁用（上限设为 0）
    var isAreaDisabled: Bool { dailyLimitMinutes == 0 }

    /// 今天是否还能开新的一条；`-1` 不限
    func canStartNewItem(profileID: UUID, now: Date = Date()) -> Bool {
        guard dailyLimitMinutes >= 0 else { return true }
        let watched = MediaStateStore.shared.watchedToday(profileID: profileID, now: now)
        return watched < Double(dailyLimitMinutes * 60)
    }

    /// 今日剩余秒数；`nil` = 不限
    func remainingToday(profileID: UUID, now: Date = Date()) -> Double? {
        guard dailyLimitMinutes >= 0 else { return nil }
        let watched = MediaStateStore.shared.watchedToday(profileID: profileID, now: now)
        return max(0, Double(dailyLimitMinutes * 60) - watched)
    }
}
