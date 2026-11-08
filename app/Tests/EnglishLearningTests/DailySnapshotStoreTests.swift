import SwiftData
import XCTest
@testable import EnglishLearning

/// 趋势快照口径（spec `parent-panel` / tasks 19.3.1）
///
/// 这里最要紧的一条是「隔几天再回填，仍能还原当天的复习完成数」——
/// 如果实现去读 `ReviewSchedule` 的当前状态，这条一定挂。
final class DailySnapshotStoreTests: XCTestCase {

    private var tempURL: URL!

    override func setUpWithError() throws {
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshots-\(UUID().uuidString).jsonl")
        DailySnapshotStore.fileURLOverride = tempURL
    }

    override func tearDownWithError() throws {
        DailySnapshotStore.fileURLOverride = nil
        try? FileManager.default.removeItem(at: tempURL)
    }

    func testBackfillIsIdempotentWithinSameDay() throws {
        let context = try makeContext()
        let profile = Profile(name: "小满", grade: 2)
        context.insert(profile)
        insertSpeak(profile: profile, passed: true, at: day(-1, hour: 19), in: context)
        insertSpeak(profile: profile, passed: false, at: day(-1, hour: 19), in: context)
        try context.save()

        let now = Date()
        _ = DailySnapshotStore.backfill(profileID: profile.id, context: context, now: now)
        let first = DailySnapshotStore.snapshots(profileID: profile.id)
        _ = DailySnapshotStore.backfill(profileID: profile.id, context: context, now: now)
        let second = DailySnapshotStore.snapshots(profileID: profile.id)

        XCTAssertEqual(first.count, 1, "同一天只应写一条")
        XCTAssertEqual(second.count, 1, "重复回填不应产生第二行")
        XCTAssertEqual(second.first?.attempts, 2)
        XCTAssertEqual(second.first?.passed, 1)
        XCTAssertEqual(second.first?.accuracy ?? 0, 0.5, accuracy: 0.001)
    }

    /// 隔 3 天才打开报告：前几天的复习完成数仍应算得出来（来自 Attempt 明细，不读调度表当前状态）
    func testBackfillReconstructsReviewCountDaysLater() throws {
        let context = try makeContext()
        let profile = Profile(name: "小满", grade: 2)
        context.insert(profile)

        let reviewDay = day(-3, hour: 18)
        // 同一条目读错一次、通过一次；另一条只通过 → 当日完成 2 个条目
        insertReview(profile: profile, code: "w:1", passed: false, at: reviewDay, in: context)
        insertReview(profile: profile, code: "w:1", passed: true, at: reviewDay, in: context)
        insertReview(profile: profile, code: "w:2", passed: true, at: reviewDay, in: context)
        try context.save()

        _ = DailySnapshotStore.backfill(profileID: profile.id, context: context, now: Date())

        let snapshot = DailySnapshotStore.snapshots(profileID: profile.id)
            .first { $0.date == DailySnapshotStore.dayKey(reviewDay) }
        XCTAssertEqual(snapshot?.reviewsCompleted, 2, "按 itemCode 去重后应完成 2 条")
    }

    func testSnapshotsOlderThanRetentionAreDropped() throws {
        let context = try makeContext()
        let profile = Profile(name: "小满", grade: 2)
        context.insert(profile)
        insertSpeak(profile: profile, passed: true, at: day(-200, hour: 10), in: context)
        try context.save()

        // 先手工造一条 200 天前的行（模拟历史遗留）
        let stale = DailySnapshotStore.Snapshot(profileID: profile.id,
                                                date: DailySnapshotStore.dayKey(day(-200, hour: 10)),
                                                attempts: 1, passed: 1, minutes: 5,
                                                newWords: 1, newSentences: 0,
                                                reviewsCompleted: 0, stars: 1)
        DailySnapshotStore.writeForTesting([stale])

        _ = DailySnapshotStore.backfill(profileID: profile.id, context: context, now: Date())
        XCTAssertTrue(DailySnapshotStore.snapshots(profileID: profile.id)
            .allSatisfy { $0.date >= DailySnapshotStore.dayKey(day(-90, hour: 0)) })
    }

    // MARK: - 工具

    private func day(_ offset: Int, hour: Int) -> Date {
        let calendar = Calendar.current
        let base = calendar.date(byAdding: .day, value: offset, to: Date()) ?? Date()
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: base) ?? base
    }

    private func insertSpeak(profile: Profile, passed: Bool, at date: Date, in context: ModelContext) {
        context.insert(Attempt(profileID: profile.id, sessionID: UUID(), itemCode: "w:1",
                               itemKind: .word, unitCode: "u1", kind: "speak",
                               passed: passed, at: date, recognitionMode: .device))
    }

    private func insertReview(profile: Profile, code: String, passed: Bool,
                              at date: Date, in context: ModelContext) {
        context.insert(Attempt(profileID: profile.id, sessionID: UUID(), itemCode: code,
                               itemKind: .word, unitCode: "u1", kind: "review",
                               passed: passed, at: date, recognitionMode: .device))
    }

    private func makeContext() throws -> ModelContext {
        let schema = EnglishLearningApp.schema
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }
}
