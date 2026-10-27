import Foundation

/// 按 (学期, 相对路径) 定位本机内容资产（tasks 3.5）。
///
/// 找不到、或文件大小为 0，一律返回 nil —— 调用方据此判定「内容未安装」并降级为空状态/占位。
enum ResourceLocator {
    /// `Curriculum/<semester>/` 目录
    static func folder(_ semester: String, root: URL = ContentStorage.root) -> URL {
        root.appendingPathComponent(semester, isDirectory: true)
    }

    /// 学期目录里的一个文件（`img/u1/758201.png` 这类相对路径）
    static func url(_ relativePath: String, in folder: URL) -> URL? {
        guard !relativePath.isEmpty else { return nil }
        let candidate = folder.appendingPathComponent(relativePath)
        guard let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              (values.fileSize ?? 0) > 0
        else { return nil }
        return candidate
    }

    static func url(semester: String, relativePath: String, root: URL = ContentStorage.root) -> URL? {
        url(relativePath, in: folder(semester, root: root))
    }

    /// 学期包引用的全部资产是否就位；返回缺失清单（空数组 = 齐全）
    static func missingAssets(in curriculum: Curriculum, folder: URL) -> [String] {
        var missing: [String] = []
        for volume in curriculum.volumes {
            for unit in volume.units {
                for word in unit.words {
                    for path in [word.image, word.audio] where url(path, in: folder) == nil {
                        missing.append(path)
                    }
                }
                for listening in unit.listenings where url(listening.audio, in: folder) == nil {
                    missing.append(listening.audio)
                }
                for sentence in unit.sentences where !sentence.audio.isEmpty {
                    if url(sentence.audio, in: folder) == nil {
                        missing.append(sentence.audio)
                    }
                }
            }
        }
        return missing
    }
}
