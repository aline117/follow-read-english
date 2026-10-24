import Foundation
import SwiftData

@Model
final class CurriculumCourse {
    var id: UUID
    var grade: Int
    var semester: Int
    var unitNumber: Int
    var title: String
    var lessons: [Lesson] = []

    init(grade: Int, semester: Int, unitNumber: Int, title: String) {
        self.id = UUID()
        self.grade = grade
        self.semester = semester
        self.unitNumber = unitNumber
        self.title = title
    }
}

@Model
final class Lesson {
    var id: UUID
    var order: Int
    var title: String
    var words: [Word] = []
    var sentences: [Sentence] = []

    init(order: Int, title: String) {
        self.id = UUID()
        self.order = order
        self.title = title
    }
}
