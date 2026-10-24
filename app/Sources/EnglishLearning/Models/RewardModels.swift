import Foundation
import SwiftData

@Model
final class Reward {
    var id: UUID
    var profileID: UUID
    var stars: Int
    var earnedToday: Int
    var lastEarnDate: Date?

    init(profileID: UUID) {
        self.id = UUID()
        self.profileID = profileID
        self.stars = 0
        self.earnedToday = 0
        self.lastEarnDate = nil
    }
}

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

@Model
final class RedemptionRule {
    var id: UUID
    var title: String
    var starCost: Int
    var emoji: String

    init(title: String, starCost: Int, emoji: String = "🎁") {
        self.id = UUID()
        self.title = title
        self.starCost = starCost
        self.emoji = emoji
    }
}

@Model
final class Redemption {
    var id: UUID
    var profileID: UUID
    var ruleID: UUID
    var ruleTitle: String
    var starCost: Int
    var createdAt: Date
    var status: String
}
