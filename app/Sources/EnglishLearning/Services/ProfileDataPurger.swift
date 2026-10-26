import Foundation
import SwiftData

/// 删除一个孩子的全部学习状态。
///
/// 各表用裸 `profileID`（UUID）关联、没有 `@Relationship`，所以不能用 `deleteRule: .cascade`，
/// 这里按表逐一删除（幂等：没有匹配行时也不报错）。
enum ProfileDataPurger {

    /// 需要清理的表数量（design 里写的是 8 张，测试可直接用它做断言）。
    static let purgedModelNames: [String] = [
        "ItemProgress",
        "Attempt",
        "LearningSession",
        "ReviewSchedule",
        "StarLedger",
        "Badge",
        "Redemption",
        "LearningSettings"
    ]

    static func purge(profileID: UUID, in context: ModelContext) throws {
        let pid = profileID

        try context.delete(model: ItemProgress.self, where: #Predicate { $0.profileID == pid })
        try context.delete(model: Attempt.self, where: #Predicate { $0.profileID == pid })
        try context.delete(model: LearningSession.self, where: #Predicate { $0.profileID == pid })
        try context.delete(model: ReviewSchedule.self, where: #Predicate { $0.profileID == pid })
        try context.delete(model: StarLedger.self, where: #Predicate { $0.profileID == pid })
        try context.delete(model: Badge.self, where: #Predicate { $0.profileID == pid })
        try context.delete(model: Redemption.self, where: #Predicate { $0.profileID == pid })
        try context.delete(model: LearningSettings.self, where: #Predicate { $0.profileID == pid })

        try context.save()
    }
}
