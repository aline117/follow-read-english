import Foundation

// MARK: - 内容结构版本

/// 内容结构（`curriculum.json` / manifest）的版本闸门。
/// 包里的 `schemaVersion` 高于这里就判定「需要更新 App」（design「版本兼容」）。
enum ContentSchema {
    static let supported = 2
}

// MARK: - 内置学期目录（tasks 7.6）

/// App 内置的学期目录：只列「有哪些学期可以下」，不含媒体与词表。
struct ContentCatalog: Decodable {
    struct Semester: Decodable, Identifiable {
        let id: String
        let grade: Int
        let title: String
        let approxSizeMB: Int?
    }

    let semesters: [Semester]

    static func bundled(bundle: Bundle = .main) -> ContentCatalog {
        guard let url = bundle.url(forResource: "catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(ContentCatalog.self, from: data)
        else {
            return ContentCatalog(semesters: [])
        }
        return catalog
    }
}

// MARK: - 服务端 manifest（design「manifest 协议」）

struct ContentManifest: Decodable {
    let contentSchemaVersion: Int
    let packs: [ManifestPack]

    /// 本机支持的内容结构版本是否覆盖服务端声明的版本。
    var isServerCompatible: Bool { contentSchemaVersion <= ContentSchema.supported }
}

struct ManifestPack: Decodable, Identifiable {
    struct Previous: Decodable {
        let contentVersion: Int
        let sha256: String
        let url: String
    }

    let id: String
    let grade: Int
    let title: String
    let contentVersion: Int
    let schemaVersion: Int
    let sizeBytes: Int64
    let sha256: String
    let url: String
    let previous: Previous?

    var requiresAppUpdate: Bool { schemaVersion > ContentSchema.supported }

    /// 主包 → 可供安装的远端描述
    func remote(baseURL: URL) -> RemotePack {
        RemotePack(id: id, grade: grade, title: title, contentVersion: contentVersion,
                   schemaVersion: schemaVersion, sizeBytes: sizeBytes,
                   sha256: sha256, url: url, baseURL: baseURL)
    }

    /// 上一版本 → 可供回退的远端描述（大小未知，按主包估）
    func previousRemote(baseURL: URL) -> RemotePack? {
        guard let previous else { return nil }
        return RemotePack(id: id, grade: grade, title: title, contentVersion: previous.contentVersion,
                          schemaVersion: schemaVersion, sizeBytes: sizeBytes,
                          sha256: previous.sha256, url: previous.url, baseURL: baseURL)
    }
}

/// 待安装 / 待回退的远端包（manifest 主包与 previous 都归一到这里）。
struct RemotePack {
    let id: String
    let grade: Int
    let title: String
    let contentVersion: Int
    let schemaVersion: Int
    let sizeBytes: Int64
    let sha256: String
    let url: String
    let baseURL: URL

    var downloadURL: URL? {
        URL(string: url, relativeTo: baseURL)?.absoluteURL
    }
}

// MARK: - 本机已安装记录（`Curriculum/<id>/pack-info.json`）

struct InstalledPack: Codable, Identifiable, Equatable {
    let id: String
    let grade: Int
    let title: String
    let contentVersion: Int
    let schemaVersion: Int
    let sha256: String
    let sizeBytes: Int64
    let installedAt: Date
}
