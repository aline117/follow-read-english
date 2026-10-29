import XCTest
@testable import EnglishLearning

final class AccuracyRuleTests: XCTestCase {
    func testOnlySpeakCountsTowardAccuracy() {
        XCTAssertEqual(AccuracyRule.countedKinds, ["speak"])

        let attempts = [
            Attempt(profileID: UUID(), sessionID: UUID(), itemCode: "w:1", itemKind: .word,
                    unitCode: "u1", kind: "speak", passed: true),
            Attempt(profileID: UUID(), sessionID: UUID(), itemCode: "w:2", itemKind: .word,
                    unitCode: "u1", kind: "speak", passed: false),
            Attempt(profileID: UUID(), sessionID: UUID(), itemCode: "w:1", itemKind: .word,
                    unitCode: "u1", kind: "review", passed: true),
            Attempt(profileID: UUID(), sessionID: UUID(), itemCode: "w:1", itemKind: .word,
                    unitCode: "u1", kind: "game", passed: true)
        ]

        let counted = attempts.filter { AccuracyRule.countedKinds.contains($0.kind) }
        XCTAssertEqual(counted.count, 2)
        let passed = counted.filter(\.passed).count
        XCTAssertEqual(passed, 1)
        XCTAssertEqual(Double(passed) / Double(counted.count), 0.5, accuracy: 0.0001)
    }
}
