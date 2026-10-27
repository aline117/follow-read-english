import Foundation
import Observation

/// 本机已安装内容的门面：状态 + 解码缓存。
/// 学习页、内容管理页都读它，安装/删除后由 `ContentInstaller` 触发 `refresh()`。
@MainActor
@Observable
final class ContentLibrary {
    static let shared = ContentLibrary()

    private(set) var installed: [InstalledPack] = []
    private var cache: [String: Curriculum] = [:]

    init() {
        try? ContentStorage.ensureDirectories()
        refresh()
    }

    func refresh() {
        installed = ContentStorage.installedPacks().sorted { lhs, rhs in
            lhs.grade == rhs.grade ? lhs.id < rhs.id : lhs.grade < rhs.grade
        }
    }

    var isEmpty: Bool { installed.isEmpty }

    func pack(forGrade grade: Int) -> InstalledPack? {
        installed.first { $0.grade == grade }
    }

    /// 解码一次后常驻内存（tasks 3.3）
    func curriculum(for pack: InstalledPack) throws -> Curriculum {
        if let cached = cache[pack.id] { return cached }
        let curriculum = try CurriculumLoader.load(semester: pack.id)
        cache[pack.id] = curriculum
        return curriculum
    }

    func invalidate(_ semesterID: String) {
        cache[semesterID] = nil
    }

    /// 删除学期包：只删内容，`ItemProgress` / `ReviewSchedule` 按 `itemCode` 保留（design「删除学期包」）
    func uninstall(_ pack: InstalledPack) throws {
        try ContentStorage.removeSemester(pack.id)
        invalidate(pack.id)
        refresh()
    }
}
