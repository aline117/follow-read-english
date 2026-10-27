import Foundation

/// 媒体清单（tasks 11.1 / 11.2）：纯 `Decodable`，不进 SwiftData。
/// 与学期包一样靠「清单 + 逐项 sha256 + 结构版本闸门」管内容，但媒体不打包 zip、按项下载。
struct MediaManifest: Decodable {
    let mediaSchemaVersion: Int
    let contentVersion: Int
    let generatedAt: String?
    let items: [MediaAsset]

    /// App 支持的最高媒体结构版本
    static let supportedSchemaVersion = 1

    enum Gate {
        /// 可用
        case ready
        /// 清单结构比 App 新 → 整包置灰，但**不删**本地缓存
        case requiresAppUpdate(manifestVersion: Int)
    }

    var gate: Gate {
        mediaSchemaVersion > Self.supportedSchemaVersion
            ? .requiresAppUpdate(manifestVersion: mediaSchemaVersion)
            : .ready
    }

    var isPlayable: Bool {
        if case .ready = gate { return true }
        return false
    }
}

/// 一个媒体项。`id` 形如 `m:song-001` / `m:pb-l1-01`（与 `w:` / `s:` 并列的第三个命名空间）。
struct MediaAsset: Decodable, Identifiable {
    enum Kind: String, Decodable {
        case song
        case picture
    }

    let id: String
    let title: String
    let kind: Kind
    /// 绘本按「第 N 部」分组；儿歌为 0
    let part: Int
    let durationSec: Double?
    let bytes: Int64
    let sha256: String
    let relPath: String
    /// `false` 表示 moov 在文件尾，不能秒开 → 走「先下后播」
    let streamable: Bool
    /// 可跟读句（儿歌 2–3 句；绘本为整段逐句）
    let lines: [MediaLine]

    var displayDuration: Double? {
        guard let durationSec, durationSec > 0 else { return nil }
        return durationSec
    }
}

/// 一条可跟读的句子（含起止秒，供播放时定位）
struct MediaLine: Decodable, Identifiable {
    let index: Int
    let text: String
    let startSec: Double?
    let endSec: Double?

    var id: Int { index }
}

// MARK: - 校验

enum MediaManifestError: Error, CustomStringConvertible {
    case badNamespace(String)
    case badSha256(String)
    case duplicateID(String)
    case empty

    var description: String {
        switch self {
        case .badNamespace(let id): return "媒体项 id 必须用 m: 前缀：\(id)"
        case .badSha256(let id): return "媒体项 sha256 不是 64 位十六进制：\(id)"
        case .duplicateID(let id): return "媒体项 id 重复：\(id)"
        case .empty: return "媒体清单是空的"
        }
    }
}

extension MediaManifest {
    /// 解码后再做一遍语义校验（缺字段由 `Decodable` 直接抛错）
    func validate() throws {
        guard !items.isEmpty else { throw MediaManifestError.empty }
        var seen = Set<String>()
        for item in items {
            guard item.id.hasPrefix("m:") else { throw MediaManifestError.badNamespace(item.id) }
            guard !seen.contains(item.id) else { throw MediaManifestError.duplicateID(item.id) }
            seen.insert(item.id)
            let hex = item.sha256.lowercased()
            guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else {
                throw MediaManifestError.badSha256(item.id)
            }
        }
    }

    static func load(from url: URL) throws -> MediaManifest {
        let data = try Data(contentsOf: url)
        let manifest = try JSONDecoder().decode(MediaManifest.self, from: data)
        try manifest.validate()
        return manifest
    }

    func item(withID id: String) -> MediaAsset? {
        items.first { $0.id == id }
    }
}
