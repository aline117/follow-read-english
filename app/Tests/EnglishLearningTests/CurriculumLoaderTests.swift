import XCTest
@testable import EnglishLearning

final class CurriculumLoaderTests: XCTestCase {
    func testValidateCountsAssets() throws {
        let folder = try makeFolder()
        let result = try CurriculumLoader.validate(folder: folder)
        XCTAssertEqual(result.curriculum.volumes.first?.units.first?.words.first?.en, "see")
        XCTAssertEqual(result.assetCount, 4)   // 2 个单词资产 + 1 条课文原声 + 1 条句型
    }

    func testMissingAssetIsRejected() throws {
        let folder = try makeFolder(missing: "img/u1/1.png")
        XCTAssertThrowsError(try CurriculumLoader.validate(folder: folder)) { error in
            guard case CurriculumError.assetMissing(let paths) = error else {
                return XCTFail("期望 assetMissing，实际 \(error)")
            }
            XCTAssertEqual(paths, ["img/u1/1.png"])
        }
    }

    func testNewerSchemaIsRejected() throws {
        let folder = try makeFolder(schemaVersion: ContentSchema.supported + 1)
        XCTAssertThrowsError(try CurriculumLoader.validate(folder: folder)) { error in
            guard case CurriculumError.incompatibleSchema(let found, _) = error else {
                return XCTFail("期望 incompatibleSchema，实际 \(error)")
            }
            XCTAssertEqual(found, ContentSchema.supported + 1)
        }
    }

    func testBrokenJSONThrows() throws {
        let folder = try makeFolder(rawJSON: "{ not json")
        XCTAssertThrowsError(try CurriculumLoader.validate(folder: folder))
    }

    // MARK: - Fixture

    private func makeFolder(schemaVersion: Int = ContentSchema.supported,
                            missing: String? = nil,
                            rawJSON: String? = nil) throws -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("curriculum-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let json = rawJSON ?? """
        {
          "grade": 2,
          "textbook": "沪教版",
          "schemaVersion": \(schemaVersion),
          "volumes": [{
            "id": "shangce",
            "units": [{
              "id": "u1",
              "title": "Unit 1",
              "words": [{
                "id": "1", "en": "see", "zh": "看见",
                "image": "img/u1/1.png", "audio": "words/1/1.mp3"
              }],
              "listenings": [{
                "id": "l1", "period": 1, "label": "Listen", "audio": "listening/1.mp3"
              }],
              "sentences": [{
                "id": "s1", "en": "I see.", "zh": "我看见。",
                "pattern": "I see.", "chunks": ["I", "see"], "audio": "sentences/u1-s1.mp3"
              }]
            }]
          }]
        }
        """
        try json.data(using: .utf8)!.write(to: folder.appendingPathComponent("curriculum.json"))

        for path in ["img/u1/1.png", "words/1/1.mp3", "listening/1.mp3", "sentences/u1-s1.mp3"]
        where path != missing {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data([0x01]).write(to: url)
        }
        return folder
    }
}
