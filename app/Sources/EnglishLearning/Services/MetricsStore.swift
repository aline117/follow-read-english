import Foundation

/// 按日指标（design「评测可信度与内容体检」/ tasks 19.1.2）。
///
/// `report/metrics.json`：设备和学习相关的**计数**，按天累加、原子替换、保留 90 天。
/// 为什么不用 `diagnostics.jsonl` 反算：那是环形 500 条的排查日志，一滚就丢历史，
/// 周级统计会莫名其妙变小；计数是报表口径，必须自己存。
enum MetricsStore {

    /// 保留天数（与 `daily-snapshots.jsonl` 一致）
    static let retentionDays = 90

    struct Payload: Codable {
        var schemaVersion: Int = 1
        /// `yyyy-MM-dd` → 计数
        var days: [String: Day] = [:]

        struct Day: Codable {
            /// 评测基础设施异常（识别超时 / 识别器报错 / 音频读不出），不算读错
            var recognitionErrorCount: Int = 0
        }
    }

    private static let queue = DispatchQueue(label: "com.aline117.englishlearning.metrics")
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

    static var fileURL: URL { directory.appendingPathComponent("metrics.json") }

    // MARK: - 写

    /// 记一次识别异常（识别超时 / 识别器报错）。调用点：跟读面板与媒体跟读的异常分支
    static func recordRecognitionError(on date: Date = Date()) {
        queue.async {
            var payload = read()
            let key = dayFormatter.string(from: date)
            var day = payload.days[key] ?? Payload.Day()
            day.recognitionErrorCount += 1
            payload.days[key] = day
            payload.days = prune(payload.days, now: date)
            write(payload)
        }
    }

    // MARK: - 读

    static func payload() -> Payload {
        queue.sync { read() }
    }

    /// 某天的识别异常次数（默认今天）
    static func recognitionErrorCount(on date: Date = Date()) -> Int {
        payload().days[dayFormatter.string(from: date)]?.recognitionErrorCount ?? 0
    }

    /// 最近 N 天（含今天）的识别异常次数
    static func recentRecognitionErrorCount(days: Int = 7, now: Date = Date()) -> Int {
        let payload = payload()
        var total = 0
        for offset in 0..<max(1, days) {
            guard let date = Calendar.current.date(byAdding: .day, value: -offset, to: now) else { continue }
            total += payload.days[dayFormatter.string(from: date)]?.recognitionErrorCount ?? 0
        }
        return total
    }

    /// 家长端「清空诊断日志」不该把计数一起清掉——但真要看基线时也允许归零
    static func resetRecognitionErrors() {
        queue.async {
            var payload = read()
            // 先取 keys 的快照再改，别边遍历边改字典
            for key in Array(payload.days.keys) {
                payload.days[key]?.recognitionErrorCount = 0
            }
            write(payload)
        }
    }

    // MARK: - 私有

    private static func read() -> Payload {
        guard let data = try? Data(contentsOf: fileURL) else { return Payload() }
        return (try? JSONDecoder().decode(Payload.self, from: data)) ?? Payload()
    }

    private static func write(_ payload: Payload) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(payload) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// 超过保留期的日期整条丢掉（按字符串日期比较即可，格式是定长的）
    private static func prune(_ days: [String: Payload.Day], now: Date) -> [String: Payload.Day] {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: now) else {
            return days
        }
        let cutoffKey = dayFormatter.string(from: cutoff)
        return days.filter { $0.key >= cutoffKey }
    }
}
