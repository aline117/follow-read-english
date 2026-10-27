import Foundation

/// 媒体观看状态（tasks 11.3 / 11.4 / 11.6 / 11.7）：
/// `Application Support/media/media-state.json`，按 `profileID` 分组，单写队列 + 原子替换。
/// 损坏时按空状态重建——只丢播放位置，不影响学习进度与星星（星星在 SwiftData）。
final class MediaStateStore {
    static let shared = MediaStateStore()

    /// 单集状态
    struct ItemState: Codable {
        var positionSec: Double = 0
        var watchedSec: Double = 0
        /// 跟读通过过的句子序号
        var passedLines: [Int] = []
        /// 第一次就通过的句子序号（算「一次通过率」用）
        var firstTryPassed: [Int] = []
        /// 复读次数（同一句重读累加）
        var retryCount: Int = 0
        var lastWatchedAt: Date?
    }

    private struct Payload: Codable {
        var profiles: [String: [String: ItemState]] = [:]
        /// profileID → "yyyy-MM-dd" → 当日观看秒数（保留 14 天）
        var daily: [String: [String: Double]] = [:]
    }

    private let queue = DispatchQueue(label: "com.aline117.englishlearning.media-state")
    private var payload = Payload()
    private var loaded = false

    private init() {}

    // MARK: - 路径

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("media", isDirectory: true)
    }

    static var stateURL: URL { directory.appendingPathComponent("media-state.json") }
    static var durationURL: URL { directory.appendingPathComponent("media-duration.json") }

    // MARK: - 读

    func itemState(_ itemID: String, profileID: UUID) -> ItemState {
        queue.sync {
            loadIfNeeded()
            return payload.profiles[key(profileID)]?[itemID] ?? ItemState()
        }
    }

    func allStates(profileID: UUID) -> [String: ItemState] {
        queue.sync {
            loadIfNeeded()
            return payload.profiles[key(profileID)] ?? [:]
        }
    }

    /// 当日已看秒数（跨天按本地 0 点切）
    func watchedToday(profileID: UUID, now: Date = Date()) -> Double {
        queue.sync {
            loadIfNeeded()
            return payload.daily[key(profileID)]?[Self.dayKey(now)] ?? 0
        }
    }

    /// 近 N 天的日汇总（家长端「近 7 天」用）
    func dailyTotals(profileID: UUID, days: Int = 7, now: Date = Date()) -> [(day: String, seconds: Double)] {
        let calendar = Calendar.current
        return queue.sync {
            loadIfNeeded()
            let map = payload.daily[key(profileID)] ?? [:]
            return (0..<days).reversed().compactMap { offset in
                guard let date = calendar.date(byAdding: .day, value: -offset, to: now) else { return nil }
                let day = Self.dayKey(date)
                return (day, map[day] ?? 0)
            }
        }
    }

    // MARK: - 写

    func updatePosition(_ itemID: String, seconds: Double, profileID: UUID, now: Date = Date()) {
        mutate { payload in
            var states = payload.profiles[self.key(profileID)] ?? [:]
            var state = states[itemID] ?? ItemState()
            state.positionSec = max(0, seconds)
            state.lastWatchedAt = now
            states[itemID] = state
            payload.profiles[self.key(profileID)] = states
        }
    }

    /// 播完或位置进入最后 5 秒 → 清零（下次从头）
    func clearPosition(_ itemID: String, profileID: UUID) {
        mutate { payload in
            guard var states = payload.profiles[self.key(profileID)], var state = states[itemID] else { return }
            state.positionSec = 0
            states[itemID] = state
            payload.profiles[self.key(profileID)] = states
        }
    }

    /// 累加观看时长：同时记到「当日」与「单集」；超过 14 天的日汇总淘汰
    func addWatched(_ seconds: Double, itemID: String, profileID: UUID, now: Date = Date()) {
        guard seconds > 0 else { return }
        mutate { payload in
            let profileKey = self.key(profileID)
            var daily = payload.daily[profileKey] ?? [:]
            let day = Self.dayKey(now)
            daily[day, default: 0] += seconds
            payload.daily[profileKey] = Self.trim(daily, now: now)

            var states = payload.profiles[profileKey] ?? [:]
            var state = states[itemID] ?? ItemState()
            state.watchedSec += seconds
            state.lastWatchedAt = now
            states[itemID] = state
            payload.profiles[profileKey] = states
        }
    }

    /// 跟读通过一句（首次通过才计入一次通过率）
    func recordLinePassed(_ itemID: String, line: Int, firstTry: Bool, profileID: UUID) {
        mutate { payload in
            var states = payload.profiles[self.key(profileID)] ?? [:]
            var state = states[itemID] ?? ItemState()
            if !state.passedLines.contains(line) { state.passedLines.append(line) }
            if firstTry, !state.firstTryPassed.contains(line) { state.firstTryPassed.append(line) }
            states[itemID] = state
            payload.profiles[self.key(profileID)] = states
        }
    }

    func recordLineRetry(_ itemID: String, profileID: UUID) {
        mutate { payload in
            var states = payload.profiles[self.key(profileID)] ?? [:]
            var state = states[itemID] ?? ItemState()
            state.retryCount += 1
            states[itemID] = state
            payload.profiles[self.key(profileID)] = states
        }
    }

    /// 删除孩子时清掉他的键（tasks 11.6）
    func purge(profileID: UUID) {
        mutate { payload in
            payload.profiles[self.key(profileID)] = nil
            payload.daily[self.key(profileID)] = nil
        }
    }

    // MARK: - 时长回填（tasks 11.7）

    /// `itemID → 实测秒数`；显示优先级：清单值 > 回填值 > nil（界面显示「未看过」）
    func backfilledDuration(_ itemID: String) -> Double? {
        queue.sync {
            let map = Self.readDictionary(Self.durationURL)
            guard let value = map[itemID], value > 0 else { return nil }
            return value
        }
    }

    func setBackfilledDuration(_ seconds: Double, itemID: String, manifestValue: Double?) {
        guard seconds > 0 else { return }
        queue.sync {
            var map = Self.readDictionary(Self.durationURL)
            if let manifestValue, manifestValue > 0, abs(manifestValue - seconds) > 2 {
                DiagnosticsLog.log("media_duration_mismatch",
                                   ["item": itemID,
                                    "manifest": "\(Int(manifestValue))",
                                    "actual": "\(Int(seconds))"])
            }
            map[itemID] = seconds
            Self.writeDictionary(map, to: Self.durationURL)
        }
    }

    /// 清单值优先，其次回填值
    func displayDuration(for item: MediaAsset) -> Double? {
        if let value = item.displayDuration { return value }
        return backfilledDuration(item.id)
    }

    // MARK: - 内部

    private func key(_ profileID: UUID) -> String { profileID.uuidString }

    private func mutate(_ body: (inout Payload) -> Void) {
        queue.sync {
            loadIfNeeded()
            body(&payload)
            save()
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        payload = Self.read(Payload.self, from: Self.stateURL) ?? Payload()
    }

    private func save() {
        Self.write(payload, to: Self.stateURL)
    }

    static func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// 只保留最近 14 天
    private static func trim(_ daily: [String: Double], now: Date) -> [String: Double] {
        let calendar = Calendar.current
        guard let cutoff = calendar.date(byAdding: .day, value: -13,
                                         to: calendar.startOfDay(for: now)) else { return daily }
        let cutoffKey = dayKey(cutoff)
        return daily.filter { $0.key >= cutoffKey }
    }

    private static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        // 临时文件 + 原子替换：写一半断电也不会把状态文件写坏
        let tmp = url.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    private static func readDictionary(_ url: URL) -> [String: Double] {
        guard let data = try? Data(contentsOf: url),
              let map = try? JSONDecoder().decode([String: Double].self, from: data) else { return [:] }
        return map
    }

    private static func writeDictionary(_ map: [String: Double], to url: URL) {
        write(map, to: url)
    }
}
