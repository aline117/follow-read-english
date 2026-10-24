import Foundation

struct Curriculum: Decodable {
    let grade: Int
    let textbook: String
    let volumes: [Volume]
}

struct Volume: Decodable {
    let id: String
    let units: [Unit]
}

struct Unit: Decodable {
    let id: String
    let title: String
    let words: [UnitWord]
    let listenings: [Listening]

    var number: Int {
        Int(id.dropFirst()) ?? 0
    }
}

struct UnitWord: Decodable, Identifiable {
    let id: String
    let en: String
    let zh: String
    let image: String
    let audio: String
}

struct Listening: Decodable, Identifiable {
    let id: String
    let period: Int
    let label: String
    let audio: String
}

enum CurriculumError: Error, CustomStringConvertible {
    case resourceNotFound(String)
    case assetMissing([String])

    var description: String {
        switch self {
        case .resourceNotFound(let name):
            return "找不到课程资源: \(name)"
        case .assetMissing(let paths):
            return "课程资源缺失: \(paths.joined(separator: ", "))"
        }
    }
}

enum CurriculumLoader {
    private static let searchDirectories: [String?] = ["Curriculum", "Resources/Curriculum", nil]

    static func load(bundle: Bundle = .module) throws -> Curriculum {
        guard let url = resourceURL("grade2", extension: "json", bundle: bundle) else {
            throw CurriculumError.resourceNotFound("grade2.json")
        }
        let data = try Data(contentsOf: url)
        let curriculum = try JSONDecoder().decode(Curriculum.self, from: data)
        let missing = missingAssets(in: curriculum, bundle: bundle)
        if !missing.isEmpty {
            throw CurriculumError.assetMissing(missing)
        }
        return curriculum
    }

    static func resourceURL(_ name: String, extension ext: String, bundle: Bundle) -> URL? {
        for directory in searchDirectories {
            if let url = bundle.url(forResource: name, withExtension: ext, subdirectory: directory) {
                return url
            }
        }
        return nil
    }

    static func missingAssets(in curriculum: Curriculum, bundle: Bundle = .module) -> [String] {
        var missing: [String] = []
        for volume in curriculum.volumes {
            for unit in volume.units {
                for word in unit.words {
                    for path in [word.image, word.audio] where !assetExists(path, bundle: bundle) {
                        missing.append(path)
                    }
                }
                for listening in unit.listenings where !assetExists(listening.audio, bundle: bundle) {
                    missing.append(listening.audio)
                }
            }
        }
        return missing
    }

    static func assetExists(_ relativePath: String, bundle: Bundle) -> Bool {
        let name = (relativePath as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        let directory = (relativePath as NSString).deletingLastPathComponent
        for prefix in searchDirectories where prefix != nil {
            let candidate = prefix! + "/" + directory
            if bundle.url(forResource: base, withExtension: ext, subdirectory: candidate) != nil {
                return true
            }
        }
        if bundle.url(forResource: base, withExtension: ext, subdirectory: directory) != nil {
            return true
        }
        return false
    }
}
