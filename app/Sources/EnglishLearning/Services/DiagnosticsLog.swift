import Foundation
import os

/// 本机诊断日志（design「健壮性与合规约定」）：环形 500 条 JSONL，**只写本机、不上传**。
/// 用途：内容资产缺失、播放失败、录音被打断这类"孩子只会说打不开"的问题，家长端能自己查。
enum DiagnosticsLog {
    struct Entry: Codable {
        let at: Date
        let event: String
        let detail: [String: String]
    }

    static let limit = 500

    private static let queue = DispatchQueue(label: "com.aline117.englishlearning.diagnostics")
    private static let logger = Logger(subsystem: "com.aline117.englishlearning", category: "diagnostics")

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("EnglishLearning", isDirectory: true)
    }

    static var fileURL: URL { directory.appendingPathComponent("diagnostics.jsonl") }

    static func log(_ event: String, _ detail: [String: String] = [:]) {
        logger.notice("\(event, privacy: .public) \(detail.description, privacy: .public)")
        queue.async {
            append(Entry(at: Date(), event: event, detail: detail))
        }
    }

    /// 资产缺失断言：Debug 下直接断到开发期，Release 只记日志
    static func assertAsset(_ url: URL?, path: String, context: String) {
        guard url == nil else { return }
        log("asset_missing", ["path": path, "context": context])
        assert(url != nil, "内容资产缺失：\(path)（\(context)）")
    }

    static func entries() -> [Entry] {
        queue.sync { readAll() }
    }

    static func clear() {
        queue.async {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    /// 只取媒体相关事件（tasks 15.6）
    static func mediaEntries() -> [Entry] {
        entries().filter { $0.event.hasPrefix("media") }
    }

    /// 只清媒体相关事件，保留学习/家长操作的日志
    static func clearMedia() {
        queue.async {
            rewrite(readAll().filter { !$0.event.hasPrefix("media") })
        }
    }

    // MARK: - 私有

    private static func append(_ entry: Entry) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(entry) else { return }
        line.append(0x0A)   // \n

        let existing = (try? Data(contentsOf: fileURL)) ?? Data()
        var combined = existing + line
        if let trimmed = trim(combined, keeping: limit) { combined = trimmed }
        try? combined.write(to: fileURL, options: .atomic)
    }

    private static func rewrite(_ entries: [Entry]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var out = Data()
        for entry in entries {
            guard let line = try? encoder.encode(entry) else { continue }
            out.append(line)
            out.append(0x0A)
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? out.write(to: fileURL, options: .atomic)
    }

    private static func readAll() -> [Entry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).compactMap { line in
            try? decoder.decode(Entry.self, from: Data(line))
        }
    }

    /// 超过上限就丢掉最旧的（按行裁，不解析）
    private static func trim(_ data: Data, keeping limit: Int) -> Data? {
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        guard lines.count > limit else { return nil }
        let kept = lines.suffix(limit).map { Data($0) }
        var out = Data()
        for (index, line) in kept.enumerated() {
            out.append(line)
            if index < kept.count - 1 { out.append(0x0A) }
        }
        out.append(0x0A)
        return out
    }
}
