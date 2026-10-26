import Foundation
import SwiftData

// MARK: - 星星流水（替代原 Reward 聚合模型）

/// 余额与「今日已发」都由流水聚合，`grantKey` 唯一保证不重复发星。
@Model
final class StarLedger {
    #Unique<StarLedger>([\.grantKey])

    var id: UUID
    var profileID: UUID
    var amount: Int
    /// 人类可读的来源，如「跟读达标」「单元完成」
    var reason: String
    /// 幂等键：`attempt:<uuid>` / `first:<itemCode>` / `unit:<volume>-<unit>` / `m:<itemID>#s1`
    var grantKey: String
    var at: Date

    init(profileID: UUID, amount: Int, reason: String, grantKey: String, at: Date = Date()) {
        self.id = UUID()
        self.profileID = profileID
        self.amount = amount
        self.reason = reason
        self.grantKey = grantKey
        self.at = at
    }
}

// MARK: - 徽章

@Model
final class Badge {
    var id: UUID
    var profileID: UUID
    var kind: String
    var earnedAt: Date

    init(profileID: UUID, kind: String) {
        self.id = UUID()
        self.profileID = profileID
        self.kind = kind
        self.earnedAt = Date()
    }
}

// MARK: - 兑换规则（11 个字段，全局不按孩子）

@Model
final class RedemptionRule {
    var id: UUID
    var title: String
    var icon: String
    /// learning / badge / parent-child / real（见 design「奖励体系」四层）
    var category: String
    var starCost: Int
    /// 0 表示不限制
    var dailyLimit: Int
    var weeklyLimit: Int
    var cooldownDays: Int
    var requiresApproval: Bool
    var isActive: Bool
    var sortOrder: Int

    init(title: String, icon: String = "🎁", category: String = "real",
         starCost: Int, dailyLimit: Int = 0, weeklyLimit: Int = 0,
         cooldownDays: Int = 0, requiresApproval: Bool = true,
         isActive: Bool = true, sortOrder: Int = 0) {
        self.id = UUID()
        self.title = title
        self.icon = icon
        self.category = category
        self.starCost = starCost
        self.dailyLimit = dailyLimit
        self.weeklyLimit = weeklyLimit
        self.cooldownDays = cooldownDays
        self.requiresApproval = requiresApproval
        self.isActive = isActive
        self.sortOrder = sortOrder
    }
}

// MARK: - 兑换申请

@Model
final class Redemption {
    var id: UUID
    var profileID: UUID
    var ruleID: UUID
    var ruleTitle: String
    var starCost: Int
    var createdAt: Date
    /// pending / approved / rejected
    var status: String
    /// 审核人（`ParentProfile.name`），仅用于追溯
    var reviewedBy: String?
    var reviewedAt: Date?

    init(profileID: UUID, ruleID: UUID, ruleTitle: String, starCost: Int) {
        self.id = UUID()
        self.profileID = profileID
        self.ruleID = ruleID
        self.ruleTitle = ruleTitle
        self.starCost = starCost
        self.createdAt = Date()
        self.status = "pending"
        self.reviewedBy = nil
        self.reviewedAt = nil
    }
}
