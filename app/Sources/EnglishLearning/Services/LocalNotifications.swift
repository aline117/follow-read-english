import Foundation
import UIKit
import UserNotifications

/// 本地通知（tasks 6.9）：兑换提交提醒家长审核、学期包下载完成。
/// 只用 `UNUserNotificationCenter`，不接任何推送服务。
enum LocalNotifications {
    static func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// 孩子提交兑换 → 提醒家长
    static func redemptionSubmitted(title: String, starCost: Int) async {
        await requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = "有兑换申请等你确认"
        content.body = "\(title) · \(starCost) 颗星"
        content.sound = .default
        let request = UNNotificationRequest(identifier: "redemption-\(UUID().uuidString)",
                                            content: content,
                                            trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// 学期包下载完成
    static func packInstalled(title: String) async {
        await requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = "内容下载好了"
        content.body = "\(title) 已经可以离线学习"
        content.sound = .default
        let request = UNNotificationRequest(identifier: "pack-\(UUID().uuidString)",
                                            content: content,
                                            trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    // MARK: - 习惯提醒（tasks 19.4.2）

    private static let dailyReminderID = "daily-learning-reminder"

    /// 每天固定时间的"该学英语了"。重复触发，由系统跨天保留
    static func scheduleDailyReminder(hour: Int, minute: Int) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [dailyReminderID])

        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        guard await center.notificationSettings().authorizationStatus == .authorized else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "到学英语的时间啦"
        content.body = "今天 20 分钟，跟着课本读一读"
        content.sound = .default

        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(identifier: dailyReminderID, content: content, trigger: trigger)
        try? await center.add(request)
    }

    static func cancelDailyReminder() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [dailyReminderID])
    }

    /// 今日任务完成的一次性反馈；文案不带任何学习数据（design：通知文案不含明细）
    static func dailyTaskCompleted() async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "今天学完啦"
        content.body = "20 分钟到，休息一下吧"
        content.sound = .default
        let request = UNNotificationRequest(identifier: "daily-done-\(UUID().uuidString)",
                                            content: content, trigger: nil)
        try? await center.add(request)
    }
}

/// 提醒偏好（设备级，不进备份）：默认关闭，家长在「设置与安全」里开。
/// 放在 UserDefaults 而不是 `LearningSettings`：它是这台 iPad 的设置，不随孩子档案走。
enum ReminderSettings {
    private static let enabledKey = "reminder.dailyEnabled"
    private static let hourKey = "reminder.dailyHour"
    private static let minuteKey = "reminder.dailyMinute"
    private static let completionKey = "reminder.completionEnabled"
    private static let lastCompletionNoticeKey = "reminder.lastCompletionNoticeDay"

    static var isDailyEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var hour: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: hourKey)
            return UserDefaults.standard.object(forKey: hourKey) == nil ? 19 : value
        }
        set { UserDefaults.standard.set(newValue, forKey: hourKey) }
    }

    static var minute: Int {
        get { UserDefaults.standard.integer(forKey: minuteKey) }
        set { UserDefaults.standard.set(newValue, forKey: minuteKey) }
    }

    static var isCompletionEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: completionKey) }
        set { UserDefaults.standard.set(newValue, forKey: completionKey) }
    }

    static var timeText: String {
        String(format: "%02d:%02d", hour, minute)
    }

    /// 每天最多发一次完成反馈（App 反复启动不该反复提醒）
    static func shouldSendCompletionNotice(now: Date = Date()) -> Bool {
        guard isCompletionEnabled else { return false }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: now)
        guard UserDefaults.standard.string(forKey: lastCompletionNoticeKey) != today else { return false }
        UserDefaults.standard.set(today, forKey: lastCompletionNoticeKey)
        return true
    }

    /// 偏好变化后调用：开就排、关就撤
    static func apply() async {
        if isDailyEnabled {
            await LocalNotifications.scheduleDailyReminder(hour: hour, minute: minute)
        } else {
            LocalNotifications.cancelDailyReminder()
        }
    }
}
