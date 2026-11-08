import XCTest
@testable import EnglishLearning

/// 习惯提醒的偏好口径（spec `parent-panel` / tasks 19.4.2）
///
/// 这里盯三个容易写错的地方：
/// 1. 默认值是「关 + 19:00」，而不是「开 + 00:00」；
/// 2. 家长显式把时间设成 00:00 时不能被默认值兜底成 19:00；
/// 3. 「学完给个提示」每天最多一条，关掉就一条都不发。
final class ReminderSettingsTests: XCTestCase {

    /// 与 `ReminderSettings` 内部键名保持一致；测试要能自己清干净，不能依赖 App 的其它状态
    private let keys = [
        "reminder.dailyEnabled",
        "reminder.dailyHour",
        "reminder.dailyMinute",
        "reminder.completionEnabled",
        "reminder.lastCompletionNoticeDay"
    ]

    override func setUp() {
        super.setUp()
        clearKeys()
    }

    override func tearDown() {
        clearKeys()
        super.tearDown()
    }

    private func clearKeys() {
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    func testDefaultsAreOffAndSevenPM() {
        XCTAssertFalse(ReminderSettings.isDailyEnabled)
        XCTAssertFalse(ReminderSettings.isCompletionEnabled)
        XCTAssertEqual(ReminderSettings.hour, 19)
        XCTAssertEqual(ReminderSettings.minute, 0)
        XCTAssertEqual(ReminderSettings.timeText, "19:00")
    }

    func testExplicitMidnightIsNotReplacedByDefault() {
        ReminderSettings.hour = 0
        ReminderSettings.minute = 0
        XCTAssertEqual(ReminderSettings.hour, 0, "家长设成 00:00 时不能被「没存过」的兜底覆盖")
        XCTAssertEqual(ReminderSettings.timeText, "00:00")
    }

    func testTimeTextPadsSingleDigits() {
        ReminderSettings.hour = 8
        ReminderSettings.minute = 5
        XCTAssertEqual(ReminderSettings.timeText, "08:05")
    }

    func testCompletionNoticeIsSilentWhenDisabled() {
        XCTAssertFalse(ReminderSettings.shouldSendCompletionNotice(),
                       "默认关闭时不该发完成提示")
    }

    func testCompletionNoticeOnlyOncePerDay() {
        ReminderSettings.isCompletionEnabled = true
        let now = Date()
        XCTAssertTrue(ReminderSettings.shouldSendCompletionNotice(now: now))
        XCTAssertFalse(ReminderSettings.shouldSendCompletionNotice(now: now),
                       "同一天第二次调用必须是 false，App 反复启动不能反复提醒")
    }

    func testCompletionNoticeResumesOnNextDay() {
        ReminderSettings.isCompletionEnabled = true
        let day1 = Date(timeIntervalSince1970: 1_800_000_000)
        let day2 = day1.addingTimeInterval(24 * 60 * 60)
        XCTAssertTrue(ReminderSettings.shouldSendCompletionNotice(now: day1))
        XCTAssertTrue(ReminderSettings.shouldSendCompletionNotice(now: day2))
    }

    func testTurningCompletionOffStopsNotice() {
        ReminderSettings.isCompletionEnabled = true
        let now = Date()
        XCTAssertTrue(ReminderSettings.shouldSendCompletionNotice(now: now))
        ReminderSettings.isCompletionEnabled = false
        XCTAssertFalse(ReminderSettings.shouldSendCompletionNotice(now: now.addingTimeInterval(24 * 60 * 60)))
    }
}
