import XCTest
@testable import EnglishLearning

final class ReviewSchedulerTests: XCTestCase {
    private let profileID = UUID()

    func testAdvanceFollowsOneThreeSevenFourteenThirty() {
        let schedule = makeSchedule()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var now = start
        let expected = [3, 7, 14, 30, 30]

        for interval in expected {
            ReviewScheduler.advance(schedule, now: now)
            XCTAssertEqual(schedule.intervalDays, interval)
            now = now.addingTimeInterval(86_400)
        }
        XCTAssertEqual(schedule.stage, 5)
    }

    func testRetreatStopsAtOneDay() {
        let schedule = makeSchedule()
        ReviewScheduler.retreat(schedule, now: Date())
        XCTAssertEqual(schedule.stage, 1)
        XCTAssertEqual(schedule.intervalDays, 1)
    }

    func testDueQueueFiltersSortsAndLimits() {
        let now = Date()
        var old = makeSchedule(); old.scheduledAt = now.addingTimeInterval(-2 * 86_400)
        var recent = makeSchedule(); recent.scheduledAt = now.addingTimeInterval(-3_600)
        var future = makeSchedule(); future.scheduledAt = now.addingTimeInterval(86_400)
        let otherProfile = makeSchedule(profileID: UUID())

        let queue = ReviewScheduler.dueQueue(from: [future, recent, old, otherProfile],
                                             profileID: profileID, limit: 1, now: now)
        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(queue.first?.itemCode, old.itemCode)
    }

    private func makeSchedule(profileID: UUID? = nil) -> ReviewSchedule {
        ReviewSchedule(profileID: profileID ?? self.profileID,
                       itemCode: UUID().uuidString,
                       itemKind: .word,
                       scheduledAt: Date(),
                       intervalDays: 1,
                       stage: 1)
    }
}
