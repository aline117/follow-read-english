import Foundation

// MARK: - 条目类型

/// 单词与句型共用同一套进度 / 复习 / 评分表，靠 `itemKind` 区分。
enum ItemKind: String, Codable, CaseIterable, Sendable {
    case word
    case sentence
}

// MARK: - 只读内容（纯 Decodable，不进 SwiftData）

/// 学期包顶层结构（`grade2.json`）。
struct Curriculum: Decodable {
    let grade: Int
    let textbook: String
    let volumes: [Volume]
}

/// 一个学期，如 `shangce`。
struct Volume: Decodable, Identifiable {
    let id: String
    let units: [Unit]
}

/// 一个单元，如 `u1`。`sentences` 缺失时按空数组处理（历史内容还没有句型）。
struct Unit: Decodable, Identifiable {
    let id: String
    let title: String
    let words: [UnitWord]
    let listenings: [Listening]
    let sentences: [Sentence]

    /// 单元序号，`u3` → 3。
    var number: Int { Int(id.dropFirst()) ?? 0 }

    private enum CodingKeys: String, CodingKey {
        case id, title, words, listenings, sentences
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        words = try container.decodeIfPresent([UnitWord].self, forKey: .words) ?? []
        listenings = try container.decodeIfPresent([Listening].self, forKey: .listenings) ?? []
        sentences = try container.decodeIfPresent([Sentence].self, forKey: .sentences) ?? []
    }
}

/// 单词。`id` 是课本业务码（如 `758201`），不是 UUID。
struct UnitWord: Decodable, Identifiable {
    let id: String
    let en: String
    let zh: String
    let image: String
    let audio: String

    var itemCode: String { "w:\(id)" }
    var itemKind: ItemKind { .word }
}

/// 课文原声片段（「跟我读」用，不写进度）。
struct Listening: Decodable, Identifiable {
    let id: String
    let period: Int
    let label: String
    let audio: String
}

/// 核心句型。`chunks` 是「认」环节词块排序用的切分。
struct Sentence: Decodable, Identifiable {
    let id: String
    let en: String
    let zh: String
    let pattern: String
    let chunks: [String]
    let audio: String

    /// 句型条目码，形如 `s:u1-s1`（需要所属单元 id）。
    func itemCode(in unitID: String) -> String { "s:\(unitID)-\(id)" }

    var itemKind: ItemKind { .sentence }

    private enum CodingKeys: String, CodingKey {
        case id, en, zh, pattern, chunks, audio
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        en = try container.decode(String.self, forKey: .en)
        zh = try container.decode(String.self, forKey: .zh)
        pattern = try container.decodeIfPresent(String.self, forKey: .pattern) ?? ""
        chunks = try container.decodeIfPresent([String].self, forKey: .chunks) ?? []
        audio = try container.decodeIfPresent(String.self, forKey: .audio) ?? ""
    }
}

// MARK: - 按条目码查找

extension Unit {
    /// 本单元全部可学条目码（单词 + 句型），按课本顺序。
    var itemCodes: [String] {
        words.map(\.itemCode) + sentences.map { $0.itemCode(in: id) }
    }

    var totalItemCount: Int { words.count + sentences.count }
}
