import Foundation

/// 媒体缓存（tasks 11.5 / 12.1）：
/// 文件放 `Library/Caches/Media/`（系统空间紧张可回收），索引 `media-cache.json` 记 LRU 信息。
/// 默认上限 2 GB，家长可调；剩余空间 < 1 GB 时停止预取，只串流。
final class MediaCacheStore {
    static let shared = MediaCacheStore()

    struct Entry: Codable {
        let itemID: String
        let fileName: String
        var bytes: Int64
        var cachedAt: Date
        var lastAccessAt: Date
    }

    /// 家长可调档位（GB）
    static let limitOptions = [1, 2, 5]
    static let defaultLimitGB = 2
    /// 低于这个剩余空间就不再预取
    static let freeSpaceFloor: Int64 = 1_000_000_000

    private let queue = DispatchQueue(label: "com.aline117.englishlearning.media-cache")
    private var index: [String: Entry] = [:]
    private var loaded = false

    private init() {}

    // MARK: - 路径

    static var directory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Media", isDirectory: true)
    }

    static var indexURL: URL { directory.appendingPathComponent("media-cache.json") }

    func fileURL(for itemID: String) -> URL? {
        queue.sync {
            loadIfNeeded()
            guard let entry = index[itemID] else { return nil }
            let url = Self.directory.appendingPathComponent(entry.fileName)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    func isCached(_ itemID: String) -> Bool {
        fileURL(for: itemID) != nil
    }

    var totalBytes: Int64 {
        queue.sync {
            loadIfNeeded()
            return index.values.reduce(0) { $0 + $1.bytes }
        }
    }

    // MARK: - 写入 / 访问

    /// 把下载好的临时文件收进缓存；超出上限按 LRU 淘汰最久未访问的
    @discardableResult
    func store(tempURL: URL, itemID: String, limitGB: Int = MediaCacheStore.defaultLimitGB) -> Bool {
        queue.sync {
            loadIfNeeded()
            let fileName = Self.fileName(for: itemID, source: tempURL)
            let target = Self.directory.appendingPathComponent(fileName)
            do {
                try FileManager.default.createDirectory(at: Self.directory,
                                                        withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
                try FileManager.default.moveItem(at: tempURL, to: target)
            } catch {
                DiagnosticsLog.log("media_cache_store_failed", ["item": itemID, "error": "\(error)"])
                return false
            }

            let size = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int64) ?? 0
            let now = Date()
            index[itemID] = Entry(itemID: itemID, fileName: fileName, bytes: size,
                                  cachedAt: now, lastAccessAt: now)
            evictIfNeeded(limitGB: limitGB)
            save()
            return true
        }
    }

    /// 播放时调用，刷新 LRU 时间
    func touch(_ itemID: String) {
        queue.sync {
            loadIfNeeded()
            guard var entry = index[itemID] else { return }
            entry.lastAccessAt = Date()
            index[itemID] = entry
            save()
        }
    }

    func remove(_ itemID: String) {
        queue.sync {
            loadIfNeeded()
            if let entry = index[itemID] {
                try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent(entry.fileName))
            }
            index[itemID] = nil
            save()
        }
    }

    func removeAll() {
        queue.sync {
            loadIfNeeded()
            try? FileManager.default.removeItem(at: Self.directory)
            index = [:]
            save()
        }
    }

    /// 空间是否够预取这一项（剩余 < 1 GB 就停）
    static func hasSpaceFor(bytes: Int64) -> Bool {
        guard let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage else {
            return true
        }
        return available > freeSpaceFloor + bytes
    }

    // MARK: - 内部

    private func evictIfNeeded(limitGB: Int) {
        let limit = Int64(max(1, limitGB)) * 1_000_000_000
        var total = index.values.reduce(Int64(0)) { $0 + $1.bytes }
        guard total > limit else { return }
        for entry in index.values.sorted(by: { $0.lastAccessAt < $1.lastAccessAt }) {
            guard total > limit else { break }
            try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent(entry.fileName))
            index[entry.itemID] = nil
            total -= entry.bytes
            DiagnosticsLog.log("media_cache_evicted", ["item": entry.itemID])
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: Self.indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let entries = try? decoder.decode([String: Entry].self, from: data) {
            index = entries
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(index) else { return }
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try? data.write(to: Self.indexURL, options: .atomic)
    }

    /// 文件名取 id 的后半段，避免 `m:` 这类字符进路径
    private static func fileName(for itemID: String, source: URL) -> String {
        let base = itemID
            .replacingOccurrences(of: "m:", with: "")
            .replacingOccurrences(of: "/", with: "-")
        let ext = source.pathExtension.isEmpty ? "mp4" : source.pathExtension
        return "\(base).\(ext)"
    }
}
