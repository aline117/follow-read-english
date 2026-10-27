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
}
