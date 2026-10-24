import Foundation
import SwiftData

@Model
final class Profile {
    var id: UUID
    var name: String
    var avatarSymbol: String
    var grade: Int
    var createdAt: Date

    init(name: String, avatarSymbol: String = "face.smiling", grade: Int = 2) {
        self.id = UUID()
        self.name = name
        self.avatarSymbol = avatarSymbol
        self.grade = grade
        self.createdAt = Date()
    }
}
