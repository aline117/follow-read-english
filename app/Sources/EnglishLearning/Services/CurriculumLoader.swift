import Foundation

enum CurriculumError: Error, CustomStringConvertible, Equatable {
    case notInstalled(semester: String)
    case incompatibleSchema(found: Int?, supported: Int)
    case decodingFailed(String)
    case assetMissing([String])

    var description: String {
        switch self {
        case .notInstalled(let semester):
            return "内容未安装：\(semester)"
        case .incompatibleSchema(let found, let supported):
            return "内容结构不兼容（包 \(found.map(String.init) ?? "未知")，App 支持 \(supported)）：请重新下载该学期"
        case .decodingFailed(let reason):
            return "curriculum.json 解码失败：\(reason)"
        case .assetMissing(let paths):
            let head = paths.prefix(5).joined(separator: ", ")
            return "内容资源缺失（\(paths.count) 个）：\(head)\(paths.count > 5 ? " …" : "")"
        }
    }
}

/// 读取**已安装**的学期内容：`Application Support/Curriculum/<semester>/curriculum.json`。
///
/// App 内不带任何课文内容（design Decision 3），所以这里不再碰 bundle；
/// 资源定位一律走 `ResourceLocator`（tasks 3.5）。
enum CurriculumLoader {
    static let curriculumFileName = "curriculum.json"

    static func load(semester: String, root: URL = ContentStorage.root) throws -> Curriculum {
        let folder = ResourceLocator.folder(semester, root: root)
        let fileURL = folder.appendingPathComponent(curriculumFileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw CurriculumError.notInstalled(semester: semester)
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw CurriculumError.decodingFailed(error.localizedDescription)
        }

        let curriculum: Curriculum
        do {
            curriculum = try JSONDecoder().decode(Curriculum.self, from: data)
        } catch {
            throw CurriculumError.decodingFailed(String(describing: error))
        }

        if let found = curriculum.schemaVersion, found > ContentSchema.supported {
            throw CurriculumError.incompatibleSchema(found: found, supported: ContentSchema.supported)
        }

        let missing = ResourceLocator.missingAssets(in: curriculum, folder: folder)
        guard missing.isEmpty else {
            throw CurriculumError.assetMissing(missing)
        }
        return curriculum
    }

    /// 安装前的校验：解码 + 版本闸门 + 资产齐全（只看传入目录，不写入）。
    static func validate(folder: URL) throws -> (curriculum: Curriculum, assetCount: Int) {
        let fileURL = folder.appendingPathComponent(curriculumFileName)
        let data = try Data(contentsOf: fileURL)
        let curriculum = try JSONDecoder().decode(Curriculum.self, from: data)
        if let found = curriculum.schemaVersion, found > ContentSchema.supported {
            throw CurriculumError.incompatibleSchema(found: found, supported: ContentSchema.supported)
        }
        let missing = ResourceLocator.missingAssets(in: curriculum, folder: folder)
        guard missing.isEmpty else {
            throw CurriculumError.assetMissing(missing)
        }
        let assetCount = curriculum.volumes.reduce(0) { partial, volume in
            partial + volume.units.reduce(0) { $0 + $1.words.count * 2 + $1.listenings.count + $1.sentences.count }
        }
        return (curriculum, assetCount)
    }
}
