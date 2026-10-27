import Foundation

/// 内容在本机的存放位置（design「组成」）：
///
///     Application Support/Curriculum/
///     ├── g2s1/                    ← 下载解压后落这里（isExcludedFromBackup）
///     │   ├── curriculum.json
///     │   ├── pack-info.json       ← 安装记录（版本 / sha256 / 时间）
///     │   └── audio/ words/ img/
///     └── .tmp/                    ← 解压中的临时目录，校验通过后原子搬走
enum ContentStorage {
    /// 本机内容根目录
    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Curriculum", isDirectory: true)
    }

    /// 某个学期的安装目录
    static func semester(_ id: String) -> URL {
        root.appendingPathComponent(id, isDirectory: true)
    }

    /// 解压 / 换版用的临时目录
    static var tmpRoot: URL {
        root.appendingPathComponent(".tmp", isDirectory: true)
    }

    /// 下载的 zip 暂存在 Caches（可被系统回收）
    static var downloads: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ContentDownloads", isDirectory: true)
    }

    static let packInfoName = "pack-info.json"

    static func ensureDirectories() throws {
        let fm = FileManager.default
        for url in [root, tmpRoot, downloads] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var directory = root
        try? directory.setResourceValues(values)
    }

    /// 扫描已安装学期（没有 `pack-info.json` 的目录视为不完整，忽略）
    static func installedPacks() -> [InstalledPack] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return entries.compactMap { folder -> InstalledPack? in
            guard !folder.lastPathComponent.hasPrefix(".") else { return nil }
            let infoURL = folder.appendingPathComponent(packInfoName)
            guard let data = try? Data(contentsOf: infoURL) else { return nil }
            return try? decoder.decode(InstalledPack.self, from: data)
        }
    }

    static func writePackInfo(_ pack: InstalledPack) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(pack)
        try data.write(to: semester(pack.id).appendingPathComponent(packInfoName), options: .atomic)
    }

    static func removeSemester(_ id: String) throws {
        let folder = semester(id)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        try FileManager.default.removeItem(at: folder)
    }

    /// 可用空间（字节）。iOS 用 `volumeAvailableCapacityForImportantUsage`。
    static func availableCapacity() -> Int64? {
        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
