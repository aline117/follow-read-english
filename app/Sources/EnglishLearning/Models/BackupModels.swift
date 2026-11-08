import Foundation

// MARK: - 备份格式（design「备份与恢复」）

/// 备份格式版本：只有结构变更才 +1；App 遇到更高版本直接拒绝导入。
enum BackupFormat {
    static let currentVersion = 1
    static let filePrefix = "englishlearning-backup"

    /// 参与备份的 11 张表（顺序即 UI 与 `counts` 的展示顺序）
    static let tableNames: [String] = [
        "profiles", "parentProfiles", "learningSettings",
        "itemProgress", "attempts", "sessions", "reviews",
        "starLedger", "badges", "redemptionRules", "redemptions"
    ]

    static func fileName(at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return "\(filePrefix)-\(formatter.string(from: date)).json"
    }
}

/// 备份文件顶层。
///
/// `payloadSha256` 只覆盖 `payload`：文件自身不能包含自己的哈希，
/// 而 payload 用固定编码器（sortedKeys + iso8601、不含浮点）序列化，往返稳定。
struct BackupFile: Codable {
    var backupFormatVersion: Int
    var exportedAt: Date
    var appVersion: String
    var deviceName: String
    /// 各表行数，供家长确认与恢复前一致性校验
    var counts: [String: Int]
    var payloadSha256: String
    var payload: BackupPayload
}

/// 备份内容：11 张表逐条平铺，加上媒体观看状态的原始 JSON。
///
/// 媒体状态故意不解析成结构体：它由 `MediaStateStore` 私有维护，
/// 这里只做字节搬运，避免两处结构各改一半。
struct BackupPayload: Codable {
    var profiles: [BackupProfile] = []
    var parentProfiles: [BackupParentProfile] = []
    var learningSettings: [BackupLearningSettings] = []
    var itemProgress: [BackupItemProgress] = []
    var attempts: [BackupAttempt] = []
    var sessions: [BackupLearningSession] = []
    var reviews: [BackupReviewSchedule] = []
    var starLedger: [BackupStarLedger] = []
    var badges: [BackupBadge] = []
    var redemptionRules: [BackupRedemptionRule] = []
    var redemptions: [BackupRedemption] = []
    /// `media-state.json` 原文（缺失 = 没有观看记录）
    var mediaStateJSON: String?
    /// `media-duration.json` 原文
    var mediaDurationJSON: String?
    /// 已安装学期 id：内容不在备份内，恢复后提示重新下载
    var installedSemesters: [String] = []

    enum CodingKeys: String, CodingKey {
        case profiles, parentProfiles, learningSettings, itemProgress, attempts, sessions
        case reviews, starLedger, badges, redemptionRules, redemptions
        case mediaStateJSON, mediaDurationJSON, installedSemesters
    }

    init() {}

    init(profiles: [BackupProfile], parentProfiles: [BackupParentProfile],
         learningSettings: [BackupLearningSettings], itemProgress: [BackupItemProgress],
         attempts: [BackupAttempt], sessions: [BackupLearningSession],
         reviews: [BackupReviewSchedule], starLedger: [BackupStarLedger],
         badges: [BackupBadge], redemptionRules: [BackupRedemptionRule],
         redemptions: [BackupRedemption], mediaStateJSON: String?,
         mediaDurationJSON: String?, installedSemesters: [String]) {
        self.profiles = profiles
        self.parentProfiles = parentProfiles
        self.learningSettings = learningSettings
        self.itemProgress = itemProgress
        self.attempts = attempts
        self.sessions = sessions
        self.reviews = reviews
        self.starLedger = starLedger
        self.badges = badges
        self.redemptionRules = redemptionRules
        self.redemptions = redemptions
        self.mediaStateJSON = mediaStateJSON
        self.mediaDurationJSON = mediaDurationJSON
        self.installedSemesters = installedSemesters
    }

    /// 缺失的可选表按空表处理：老备份 / 手写裁剪过的备份也能读，交给 `validate` 判断是否可用。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profiles = try c.decodeIfPresent([BackupProfile].self, forKey: .profiles) ?? []
        parentProfiles = try c.decodeIfPresent([BackupParentProfile].self, forKey: .parentProfiles) ?? []
        learningSettings = try c.decodeIfPresent([BackupLearningSettings].self, forKey: .learningSettings) ?? []
        itemProgress = try c.decodeIfPresent([BackupItemProgress].self, forKey: .itemProgress) ?? []
        attempts = try c.decodeIfPresent([BackupAttempt].self, forKey: .attempts) ?? []
        sessions = try c.decodeIfPresent([BackupLearningSession].self, forKey: .sessions) ?? []
        reviews = try c.decodeIfPresent([BackupReviewSchedule].self, forKey: .reviews) ?? []
        starLedger = try c.decodeIfPresent([BackupStarLedger].self, forKey: .starLedger) ?? []
        badges = try c.decodeIfPresent([BackupBadge].self, forKey: .badges) ?? []
        redemptionRules = try c.decodeIfPresent([BackupRedemptionRule].self, forKey: .redemptionRules) ?? []
        redemptions = try c.decodeIfPresent([BackupRedemption].self, forKey: .redemptions) ?? []
        mediaStateJSON = try c.decodeIfPresent(String.self, forKey: .mediaStateJSON)
        mediaDurationJSON = try c.decodeIfPresent(String.self, forKey: .mediaDurationJSON)
        installedSemesters = try c.decodeIfPresent([String].self, forKey: .installedSemesters) ?? []
    }

    var counts: [String: Int] {
        [
            "profiles": profiles.count,
            "parentProfiles": parentProfiles.count,
            "learningSettings": learningSettings.count,
            "itemProgress": itemProgress.count,
            "attempts": attempts.count,
            "sessions": sessions.count,
            "reviews": reviews.count,
            "starLedger": starLedger.count,
            "badges": badges.count,
            "redemptionRules": redemptionRules.count,
            "redemptions": redemptions.count
        ]
    }
}

// MARK: - 行结构（与 @Model 一一对应；恢复时沿用原 id）

struct BackupProfile: Codable {
    var id: UUID
    var name: String
    var avatarSymbol: String
    var grade: Int
    var createdAt: Date
    var updatedAt: Date

    init(_ model: Profile) {
        id = model.id
        name = model.name
        avatarSymbol = model.avatarSymbol
        grade = model.grade
        createdAt = model.createdAt
        updatedAt = model.updatedAt
    }

    func makeModel() -> Profile {
        let model = Profile(name: name, avatarSymbol: avatarSymbol, grade: grade)
        model.id = id
        model.createdAt = createdAt
        model.updatedAt = updatedAt
        return model
    }
}

struct BackupParentProfile: Codable {
    var id: UUID
    var name: String
    var avatarSymbol: String
    var isActive: Bool
    var createdAt: Date

    init(_ model: ParentProfile) {
        id = model.id
        name = model.name
        avatarSymbol = model.avatarSymbol
        isActive = model.isActive
        createdAt = model.createdAt
    }

    func makeModel() -> ParentProfile {
        let model = ParentProfile(name: name, avatarSymbol: avatarSymbol, isActive: isActive)
        model.id = id
        model.createdAt = createdAt
        return model
    }
}

struct BackupLearningSettings: Codable {
    var id: UUID
    var profileID: UUID
    var pairsPerScreen: Int
    var minPracticeRounds: Int
    var skipAfterFailures: Int
    var newWordsPerDay: Int
    var newSentencesPerDay: Int
    var reviewLimitPerSession: Int
    var updatedAt: Date

    init(_ model: LearningSettings) {
        id = model.id
        profileID = model.profileID
        pairsPerScreen = model.pairsPerScreen
        minPracticeRounds = model.minPracticeRounds
        skipAfterFailures = model.skipAfterFailures
        newWordsPerDay = model.newWordsPerDay
        newSentencesPerDay = model.newSentencesPerDay
        reviewLimitPerSession = model.reviewLimitPerSession
        updatedAt = model.updatedAt
    }

    func makeModel() -> LearningSettings {
        let model = LearningSettings(profileID: profileID)
        model.id = id
        model.pairsPerScreen = pairsPerScreen
        model.minPracticeRounds = minPracticeRounds
        model.skipAfterFailures = skipAfterFailures
        model.newWordsPerDay = newWordsPerDay
        model.newSentencesPerDay = newSentencesPerDay
        model.reviewLimitPerSession = reviewLimitPerSession
        model.updatedAt = updatedAt
        return model
    }
}

struct BackupItemProgress: Codable {
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
    var masteryLevel: Int

    init(_ model: ItemProgress) {
        id = model.id
        profileID = model.profileID
        itemCode = model.itemCode
        itemKind = model.itemKind
        unitCode = model.unitCode
        volumeCode = model.volumeCode
        timesSeen = model.timesSeen
        timesPassed = model.timesPassed
        lastSeenAt = model.lastSeenAt
        firstPassedAt = model.firstPassedAt
        masteryLevel = model.masteryLevel
    }

    func makeModel() -> ItemProgress {
        let kind = ItemKind(rawValue: itemKind) ?? .word
        let model = ItemProgress(profileID: profileID, itemCode: itemCode, itemKind: kind,
                                 unitCode: unitCode, volumeCode: volumeCode)
        model.id = id
        model.timesSeen = timesSeen
        model.timesPassed = timesPassed
        model.lastSeenAt = lastSeenAt
        model.firstPassedAt = firstPassedAt
        model.masteryLevel = masteryLevel
        return model
    }
}

struct BackupAttempt: Codable {
    var id: UUID
    var profileID: UUID
    var sessionID: UUID
    var itemCode: String
    var itemKind: String
    var unitCode: String
    var kind: String
    var passed: Bool
    var at: Date

    init(_ model: Attempt) {
        id = model.id
        profileID = model.profileID
        sessionID = model.sessionID
        itemCode = model.itemCode
        itemKind = model.itemKind
        unitCode = model.unitCode
        kind = model.kind
        passed = model.passed
        at = model.at
    }

    func makeModel() -> Attempt {
        let kindValue = ItemKind(rawValue: itemKind) ?? .word
        let model = Attempt(profileID: profileID, sessionID: sessionID, itemCode: itemCode,
                            itemKind: kindValue, unitCode: unitCode, kind: kind,
                            passed: passed, at: at)
        model.id = id
        return model
    }
}

struct BackupLearningSession: Codable {
    var id: UUID
    var profileID: UUID
    var volumeCode: String
    var unitCode: String
    var startedAt: Date
    var endedAt: Date?
    var durationSeconds: Int
    var newItemsLearned: Int

    init(_ model: LearningSession) {
        id = model.id
        profileID = model.profileID
        volumeCode = model.volumeCode
        unitCode = model.unitCode
        startedAt = model.startedAt
        endedAt = model.endedAt
        durationSeconds = model.durationSeconds
        newItemsLearned = model.newItemsLearned
    }

    func makeModel() -> LearningSession {
        let model = LearningSession(profileID: profileID, volumeCode: volumeCode, unitCode: unitCode)
        model.id = id
        model.startedAt = startedAt
        model.endedAt = endedAt
        model.durationSeconds = durationSeconds
        model.newItemsLearned = newItemsLearned
        return model
    }
}

struct BackupReviewSchedule: Codable {
    var id: UUID
    var profileID: UUID
    var itemCode: String
    var itemKind: String
    var scheduledAt: Date
    var intervalDays: Int
    var stage: Int
    var lastReviewedAt: Date?

    init(_ model: ReviewSchedule) {
        id = model.id
        profileID = model.profileID
        itemCode = model.itemCode
        itemKind = model.itemKind
        scheduledAt = model.scheduledAt
        intervalDays = model.intervalDays
        stage = model.stage
        lastReviewedAt = model.lastReviewedAt
    }

    func makeModel() -> ReviewSchedule {
        let kind = ItemKind(rawValue: itemKind) ?? .word
        let model = ReviewSchedule(profileID: profileID, itemCode: itemCode, itemKind: kind,
                                   scheduledAt: scheduledAt, intervalDays: intervalDays, stage: stage)
        model.id = id
        model.lastReviewedAt = lastReviewedAt
        return model
    }
}

struct BackupStarLedger: Codable {
    var id: UUID
    var profileID: UUID
    var amount: Int
    var reason: String
    var grantKey: String
    var at: Date

    init(_ model: StarLedger) {
        id = model.id
        profileID = model.profileID
        amount = model.amount
        reason = model.reason
        grantKey = model.grantKey
        at = model.at
    }

    func makeModel() -> StarLedger {
        let model = StarLedger(profileID: profileID, amount: amount, reason: reason,
                               grantKey: grantKey, at: at)
        model.id = id
        return model
    }
}

struct BackupBadge: Codable {
    var id: UUID
    var profileID: UUID
    var kind: String
    var earnedAt: Date

    init(_ model: Badge) {
        id = model.id
        profileID = model.profileID
        kind = model.kind
        earnedAt = model.earnedAt
    }

    func makeModel() -> Badge {
        let model = Badge(profileID: profileID, kind: kind)
        model.id = id
        model.earnedAt = earnedAt
        return model
    }
}

struct BackupRedemptionRule: Codable {
    var id: UUID
    var title: String
    var icon: String
    var category: String
    var starCost: Int
    var dailyLimit: Int
    var weeklyLimit: Int
    var cooldownDays: Int
    var requiresApproval: Bool
    var isActive: Bool
    var sortOrder: Int

    init(_ model: RedemptionRule) {
        id = model.id
        title = model.title
        icon = model.icon
        category = model.category
        starCost = model.starCost
        dailyLimit = model.dailyLimit
        weeklyLimit = model.weeklyLimit
        cooldownDays = model.cooldownDays
        requiresApproval = model.requiresApproval
        isActive = model.isActive
        sortOrder = model.sortOrder
    }

    func makeModel() -> RedemptionRule {
        let model = RedemptionRule(title: title, icon: icon, category: category,
                                   starCost: starCost, dailyLimit: dailyLimit,
                                   weeklyLimit: weeklyLimit, cooldownDays: cooldownDays,
                                   requiresApproval: requiresApproval, isActive: isActive,
                                   sortOrder: sortOrder)
        model.id = id
        return model
    }
}

struct BackupRedemption: Codable {
    var id: UUID
    var profileID: UUID
    var ruleID: UUID
    var ruleTitle: String
    var starCost: Int
    var createdAt: Date
    var status: String
    var reviewedBy: String?
    var reviewedAt: Date?

    init(_ model: Redemption) {
        id = model.id
        profileID = model.profileID
        ruleID = model.ruleID
        ruleTitle = model.ruleTitle
        starCost = model.starCost
        createdAt = model.createdAt
        status = model.status
        reviewedBy = model.reviewedBy
        reviewedAt = model.reviewedAt
    }

    func makeModel() -> Redemption {
        let model = Redemption(profileID: profileID, ruleID: ruleID,
                               ruleTitle: ruleTitle, starCost: starCost)
        model.id = id
        model.createdAt = createdAt
        model.status = status
        model.reviewedBy = reviewedBy
        model.reviewedAt = reviewedAt
        return model
    }
}

// MARK: - 错误

enum BackupError: LocalizedError {
    case unsupportedVersion(Int)
    case checksumMismatch
    case emptyProfiles
    case countsMismatch(table: String)
    case orphanRow(table: String)
    case duplicateRow(table: String, key: String)
    case decodeFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "这个备份是更高版本（v\(version)）生成的，当前 App 无法读取，请先更新 App。"
        case .checksumMismatch:
            return "备份内容校验不通过，文件可能已损坏或被改动。"
        case .emptyProfiles:
            return "备份里没有任何孩子档案，无法恢复。"
        case .countsMismatch(let table):
            return "备份的 \(table) 行数与声明不一致，文件可能被改动。"
        case .orphanRow(let table):
            return "备份的 \(table) 里有找不到归属孩子的记录，已拒绝恢复。"
        case .duplicateRow(let table, let key):
            return "备份的 \(table) 里有重复记录（\(key)），已拒绝恢复。"
        case .decodeFailed:
            return "无法读取这个文件，它不是本 App 生成的备份。"
        }
    }
}
