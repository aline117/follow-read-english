import Foundation
import SwiftData

// MARK: - 会话（只保留边界与时长）

@Model
final class LearningSession {
    var id: UUID
    var profileID: UUID
    var volumeCode: String
    var unitCode: String
    var startedAt: Date
    var endedAt: Date?
    var durationSeconds: Int
    var newItemsLearned: Int

    init(profileID: UUID, volumeCode: String, unitCode: String) {
        self.id = UUID()
        self.profileID = profileID
        self.volumeCode = volumeCode
        self.unitCode = unitCode
        self.startedAt = Date()
        self.endedAt = nil
        self.durationSeconds = 0
        self.newItemsLearned = 0
    }
}

// MARK: - 条目进度（单词与句型共用）

@Model
final class ItemProgress {
    /// 一个孩子 × 一个条目唯一（见 design「指标口径与数据字典」）
    #Unique<ItemProgress>([\.profileID, \.itemCode])

    var id: UUID
    var profileID: UUID
    var itemCode: String
    var itemKind: String
    var unitCode: String
    var volumeCode: String
    var timesSeen: Int
    var timesPassed: Int
    var lastSeenAt: Date?
    var firstPassedAt: Date?
    /// 0 未学 / 1 已见 1 次 / 2 达标 1 次 / 3 达标 ≥3 次且跨 ≥2 天 / 4 达标 ≥5 次且跨 ≥3 天
    var masteryLevel: Int

    var kind: ItemKind { ItemKind(rawValue: itemKind) ?? .word }

    var accuracy: Double {
        timesSeen > 0 ? Double(timesPassed) / Double(timesSeen) : 0
    }

    var isWeak: Bool {
        timesSeen >= 2 && accuracy < 0.6
    }

    init(profileID: UUID, itemCode: String, itemKind: ItemKind, unitCode: String, volumeCode: String) {
        self.id = UUID()
        self.profileID = profileID
        self.itemCode = itemCode
        self.itemKind = itemKind.rawValue
        self.unitCode = unitCode
        self.volumeCode = volumeCode
        self.timesSeen = 0
        self.timesPassed = 0
        self.lastSeenAt = nil
        self.firstPassedAt = nil
        self.masteryLevel = 0
    }
}

// MARK: - 明细（存明细不存聚合）

@Model
final class Attempt {
    /// 报告按「孩子 + 时间范围」高频查询
    #Index<Attempt>([\.profileID, \.at])

    var id: UUID
    var profileID: UUID
    var sessionID: UUID
    var itemCode: String
    var itemKind: String
    var unitCode: String
    /// listen / speak / match / game / sentence / review
    var kind: String
    var passed: Bool
    var at: Date

    init(profileID: UUID, sessionID: UUID, itemCode: String, itemKind: ItemKind,
         unitCode: String, kind: String, passed: Bool, at: Date = Date()) {
        self.id = UUID()
        self.profileID = profileID
        self.sessionID = sessionID
        self.itemCode = itemCode
        self.itemKind = itemKind.rawValue
        self.unitCode = unitCode
        self.kind = kind
        self.passed = passed
        self.at = at
    }
}

/// 正确率口径开关：只有这里列的环节计入正确率，改口径只动这一行。
enum AccuracyRule {
    static let countedKinds: Set<String> = ["speak"]
}

// MARK: - 复习调度

@Model
final class ReviewSchedule {
    var id: UUID
    var profileID: UUID
    var itemCode: String
    var itemKind: String
    var scheduledAt: Date
    var intervalDays: Int
    /// 1…5 对应 1 / 3 / 7 / 14 / 30 天，答错回退一级（最低 1）
    var stage: Int
    var lastReviewedAt: Date?

    var kind: ItemKind { ItemKind(rawValue: itemKind) ?? .word }

    init(profileID: UUID, itemCode: String, itemKind: ItemKind,
         scheduledAt: Date, intervalDays: Int = 1, stage: Int = 1) {
        self.id = UUID()
        self.profileID = profileID
        self.itemCode = itemCode
        self.itemKind = itemKind.rawValue
        self.scheduledAt = scheduledAt
        self.intervalDays = intervalDays
        self.stage = stage
        self.lastReviewedAt = nil
    }
}
