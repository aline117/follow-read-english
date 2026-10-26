import Foundation
import SwiftData

/// 家长可调的 6 项档位（用档位而非自由输入，避免填出极端值）。
enum LearningOption {
    static let pairsPerScreen = [2, 3, 4, 6]
    static let minPracticeRounds = [1, 2, 3]
    /// 0 表示关闭
    static let skipAfterFailures = [0, 2, 3, 4, 5]
    static let newWordsPerDay = [3, 5, 8]
    static let newSentencesPerDay = [0, 1, 2]
    static let reviewLimitPerSession = [10, 20, 30]
}

/// 每个孩子一份的练习强度设置（见 design「可调设置」）。
/// 复习间隔、掌握度分级、正确率口径、20 分钟预算、发星上限、星星上限 500 不在这里——那是算法底线，不开放。
@Model
final class LearningSettings {
    #Unique<LearningSettings>([\.profileID])

    var id: UUID
    var profileID: UUID
    var pairsPerScreen: Int
    var minPracticeRounds: Int
    /// 0 表示关闭（不出现「先跳过」）
    var skipAfterFailures: Int
    var newWordsPerDay: Int
    var newSentencesPerDay: Int
    var reviewLimitPerSession: Int
    var updatedAt: Date

    init(profileID: UUID) {
        self.id = UUID()
        self.profileID = profileID
        self.pairsPerScreen = 3
        self.minPracticeRounds = 1
        self.skipAfterFailures = 3
        self.newWordsPerDay = 5
        self.newSentencesPerDay = 1
        self.reviewLimitPerSession = 20
        self.updatedAt = Date()
    }
}
