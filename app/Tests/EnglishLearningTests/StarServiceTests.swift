import SwiftData
import XCTest
@testable import EnglishLearning

final class StarServiceTests: XCTestCase {
    func testSameGrantKeyIsIdempotent() throws {
        let context = try makeContext()
        let profileID = UUID()

        let first = StarService.grant(profileID: profileID, amount: 2,
                                      reason: "跟读达标", key: "speak:w:1:2026-10-28",
                                      in: context)
        guard case .granted = first else { return XCTFail("第一次应发星") }
        try context.save()

        let second = StarService.grant(profileID: profileID, amount: 2,
                                       reason: "跟读达标", key: "speak:w:1:2026-10-28",
                                       in: context)
        guard case .duplicate = second else { return XCTFail("重复 key 应被挡下") }
        XCTAssertEqual(StarService.balance(profileID: profileID, in: context), 2)
    }

    func testDifferentProfilesDoNotShareGrants() throws {
        let context = try makeContext()
        let a = UUID(), b = UUID()
        _ = StarService.grant(profileID: a, amount: 1, reason: "首次达标", key: "first:w:1", in: context)
        try context.save()
        _ = StarService.grant(profileID: b, amount: 1, reason: "首次达标", key: "first:w:1", in: context)
        try context.save()
        XCTAssertEqual(StarService.balance(profileID: a, in: context), 1)
        XCTAssertEqual(StarService.balance(profileID: b, in: context), 1)
    }

    private func makeContext() throws -> ModelContext {
        let schema = Schema([StarLedger.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }
}
