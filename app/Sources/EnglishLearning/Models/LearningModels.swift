import Foundation
import SwiftData

@Model
final class LearningSession {
    var id: UUID
    var profileID: UUID
    var courseID: UUID
    var startedAt: Date
    var endedAt: Date?
    var durationSeconds: Int
    var newWordsLearned: Int
    var correctCount: Int
    var totalCount: Int

    var accuracy: Double {
        totalCount > 0 ? Double(correctCount) / Double(totalCount) : 0
    }

    init(profileID: UUID, courseID: UUID) {
        self.id = UUID()
        self.profileID = profileID
        self.courseID = courseID
        self.startedAt = Date()
        self.endedAt = nil
        self.durationSeconds = 0
        self.newWordsLearned = 0
        self.correctCount = 0
        self.totalCount = 0
    }
}

@Model
final class WordProgress {
    var id: UUID
    var profileID: UUID
    var wordID: UUID
    var wordText: String
    var timesSeen: Int
    var timesCorrect: Int
    var lastSeenAt: Date?
    var masteryLevel: Int

    var accuracy: Double {
        timesSeen > 0 ? Double(timesCorrect) / Double(timesSeen) : 0
    }

    var isWeak: Bool {
        timesSeen >= 2 && accuracy < 0.6
    }

    init(profileID: UUID, wordID: UUID, wordText: String) {
        self.id = UUID()
        self.profileID = profileID
        self.wordID = wordID
        self.wordText = wordText
        self.timesSeen = 0
        self.timesCorrect = 0
        self.lastSeenAt = nil
        self.masteryLevel = 0
    }
}

@Model
final class ReviewSchedule {
    var id: UUID
    var profileID: UUID
    var wordID: UUID
    var scheduledAt: Date
    var intervalDays: Int

    init(profileID: UUID, wordID: UUID, scheduledAt: Date, intervalDays: Int) {
        self.id = UUID()
        self.profileID = profileID
        self.wordID = wordID
        self.scheduledAt = scheduledAt
        self.intervalDays = intervalDays
    }
}
