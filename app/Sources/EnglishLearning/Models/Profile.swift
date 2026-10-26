import Foundation
import SwiftData

/// 孩子档案。所有学习状态表都用裸 `profileID`（UUID）关联，便于按孩子批量过滤与删除。
@Model
final class Profile {
    var id: UUID
    var name: String
    var avatarSymbol: String
    var grade: Int
    var createdAt: Date
    var updatedAt: Date

    init(name: String, avatarSymbol: String = "face.smiling", grade: Int = 2) {
        let now = Date()
        self.id = UUID()
        self.name = name
        self.avatarSymbol = avatarSymbol
        self.grade = grade
        self.createdAt = now
        self.updatedAt = now
    }
}

/// 家长档案（最多 2 位，仅用于审核记录；PIN 不在这里，存 Keychain）。
@Model
final class ParentProfile {
    var id: UUID
    var name: String
    var avatarSymbol: String
    var isActive: Bool
    var createdAt: Date

    init(name: String, avatarSymbol: String = "person.crop.circle", isActive: Bool = true) {
        self.id = UUID()
        self.name = name
        self.avatarSymbol = avatarSymbol
        self.isActive = isActive
        self.createdAt = Date()
    }
}
