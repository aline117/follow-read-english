import CryptoKit
import Foundation
import SwiftData
import UIKit

/// 备份与恢复（design「备份与恢复」/ spec `data-backup`）。
///
/// 两个通道（App 内导出、家园在线备份）共用这里的打包与恢复实现：
/// - 导出 = 把 11 张表逐条平铺 + 媒体观看状态原文，编码成一个 JSON
/// - 恢复 = 整包覆盖（先清空再写回），`Profile.id` 沿用备份值
enum BackupService {

    // MARK: - 导出

    /// 生成备份文件（含 `payloadSha256` 与各表行数）
    static func makeBackup(context: ModelContext, now: Date = Date()) throws -> BackupFile {
        let payload = BackupPayload(
            profiles: try fetch(context, Profile.self).map(BackupProfile.init),
            parentProfiles: try fetch(context, ParentProfile.self).map(BackupParentProfile.init),
            learningSettings: try fetch(context, LearningSettings.self).map(BackupLearningSettings.init),
            itemProgress: try fetch(context, ItemProgress.self).map(BackupItemProgress.init),
            attempts: try fetch(context, Attempt.self).map(BackupAttempt.init),
            sessions: try fetch(context, LearningSession.self).map(BackupLearningSession.init),
            reviews: try fetch(context, ReviewSchedule.self).map(BackupReviewSchedule.init),
            starLedger: try fetch(context, StarLedger.self).map(BackupStarLedger.init),
            badges: try fetch(context, Badge.self).map(BackupBadge.init),
            redemptionRules: try fetch(context, RedemptionRule.self).map(BackupRedemptionRule.init),
            redemptions: try fetch(context, Redemption.self).map(BackupRedemption.init),
            mediaStateJSON: try readText(MediaStateStore.stateURL),
            mediaDurationJSON: try readText(MediaStateStore.durationURL),
            installedSemesters: ContentStorage.installedPacks().map(\.id).sorted()
        )

        return BackupFile(
            backupFormatVersion: BackupFormat.currentVersion,
            exportedAt: now,
            appVersion: appVersion,
            deviceName: UIDevice.current.name,
            counts: payload.counts,
            payloadSha256: try digest(of: payload),
            payload: payload
        )
    }

    /// 编码成可写入磁盘的 JSON（排序键 + 缩进，便于人工核对）
    static func encode(_ file: BackupFile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(file)
    }

    /// 导出到临时目录（分享面板只接受文件 URL）
    static func writeTemporaryFile(_ data: Data, fileName: String? = nil) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(fileName ?? BackupFormat.fileName())
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - 读取与校验

    /// 解码并做完整校验：版本、校验和、行数、孤儿记录、唯一键。
    /// 任何一项不通过都**不**写入数据——校验全部先于恢复执行。
    static func decode(_ data: Data) throws -> BackupFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // 先只看版本号：未来格式可能缺字段，不能让它报"文件损坏"
        if let probe = try? decoder.decode(VersionProbe.self, from: data),
           probe.backupFormatVersion != BackupFormat.currentVersion {
            throw BackupError.unsupportedVersion(probe.backupFormatVersion)
        }

        let file: BackupFile
        do {
            file = try decoder.decode(BackupFile.self, from: data)
        } catch {
            throw BackupError.decodeFailed
        }
        try validate(file)
        return file
    }

    private struct VersionProbe: Decodable {
        var backupFormatVersion: Int
    }

    static func validate(_ file: BackupFile) throws {
        guard file.backupFormatVersion == BackupFormat.currentVersion else {
            throw BackupError.unsupportedVersion(file.backupFormatVersion)
        }
        guard try digest(of: file.payload) == file.payloadSha256 else {
            throw BackupError.checksumMismatch
        }

        let payload = file.payload
        guard !payload.profiles.isEmpty else { throw BackupError.emptyProfiles }

        // 行数声明与实际一致（防止手改 payload 后忘了改 counts）
        for (table, expected) in file.counts {
            let actual = payload.counts[table] ?? 0
            if expected != actual { throw BackupError.countsMismatch(table: table) }
        }

        // 归属检查：所有带 profileID 的表都必须能对上档案
        let profileIDs = Set(payload.profiles.map(\.id))
        let ownedTables: [(String, [UUID])] = [
            ("learningSettings", payload.learningSettings.map(\.profileID)),
            ("itemProgress", payload.itemProgress.map(\.profileID)),
            ("attempts", payload.attempts.map(\.profileID)),
            ("sessions", payload.sessions.map(\.profileID)),
            ("reviews", payload.reviews.map(\.profileID)),
            ("starLedger", payload.starLedger.map(\.profileID)),
            ("badges", payload.badges.map(\.profileID)),
            ("redemptions", payload.redemptions.map(\.profileID))
        ]
        for (table, ids) in ownedTables where ids.contains(where: { !profileIDs.contains($0) }) {
            throw BackupError.orphanRow(table: table)
        }

        // 唯一键：与 @Model 上的 #Unique 约束保持一致，进库前先拦住
        try assertUnique(payload.profiles.map { $0.id.uuidString }, table: "profiles")
        try assertUnique(payload.parentProfiles.map { $0.id.uuidString }, table: "parentProfiles")
        try assertUnique(payload.itemProgress.map { "\($0.profileID.uuidString)|\($0.itemCode)" },
                         table: "itemProgress")
        try assertUnique(payload.learningSettings.map { $0.profileID.uuidString },
                         table: "learningSettings")
        try assertUnique(payload.starLedger.map(\.grantKey), table: "starLedger")
    }

    // MARK: - 恢复（整包覆盖）

    /// 覆盖恢复：清空 11 张表 → 写回备份内容 → 落盘。
    ///
    /// 删除与写入在同一个 `ModelContext` 事务里，任何一步抛错都 `rollback()`，
    /// 不会留下"删了一半"的中间态。媒体观看状态在 SwiftData 落盘成功后再替换。
    @discardableResult
    static func restore(_ file: BackupFile, into context: ModelContext) throws -> [String: Int] {
        try validate(file)
        let payload = file.payload

        do {
            try wipeAll(in: context)
            try upsertProfiles(payload.profiles, in: context)
            try upsertParentProfiles(payload.parentProfiles, in: context)

            for row in payload.learningSettings { context.insert(row.makeModel()) }
            for row in payload.itemProgress { context.insert(row.makeModel()) }
            for row in payload.attempts { context.insert(row.makeModel()) }
            for row in payload.sessions { context.insert(row.makeModel()) }
            for row in payload.reviews { context.insert(row.makeModel()) }
            for row in payload.starLedger { context.insert(row.makeModel()) }
            for row in payload.badges { context.insert(row.makeModel()) }
            for row in payload.redemptionRules { context.insert(row.makeModel()) }
            for row in payload.redemptions { context.insert(row.makeModel()) }

            try context.save()
        } catch {
            context.rollback()
            throw error
        }

        // 媒体观看状态：整包替换，内存缓存一并刷新
        MediaStateStore.shared.replaceState(withJSON: payload.mediaStateJSON)
        MediaStateStore.shared.replaceDurations(withJSON: payload.mediaDurationJSON)

        DiagnosticsLog.log("backup_restored", [
            "profiles": "\(payload.profiles.count)",
            "attempts": "\(payload.attempts.count)",
            "stars": "\(payload.starLedger.count)"
        ])
        return payload.counts
    }

    // MARK: - 工具

    /// payload 的规范编码（sortedKeys + iso8601，且结构里没有浮点）→ 往返稳定
    static func digest(of payload: BackupPayload) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return sha256Hex(try encoder.encode(payload))
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func fetch<T: PersistentModel>(_ context: ModelContext, _ type: T.Type) throws -> [T] {
        try context.fetch(FetchDescriptor<T>())
    }

    private static func readText(_ url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func wipeAll(in context: ModelContext) throws {
        try context.delete(model: Attempt.self)
        try context.delete(model: ItemProgress.self)
        try context.delete(model: LearningSession.self)
        try context.delete(model: ReviewSchedule.self)
        try context.delete(model: StarLedger.self)
        try context.delete(model: Badge.self)
        try context.delete(model: Redemption.self)
        try context.delete(model: RedemptionRule.self)
        try context.delete(model: LearningSettings.self)
    }

    /// 档案就地更新：家长模式此时正持有 `Profile` 对象，整表删除会让它失效（读到已删除模型会崩）。
    /// 效果与"覆盖"一致——备份里没有的档案仍然会被删掉。
    private static func upsertProfiles(_ rows: [BackupProfile], in context: ModelContext) throws {
        var existing = Dictionary(uniqueKeysWithValues:
            try context.fetch(FetchDescriptor<Profile>()).map { ($0.id, $0) })
        for row in rows {
            if let model = existing.removeValue(forKey: row.id) {
                model.name = row.name
                model.avatarSymbol = row.avatarSymbol
                model.grade = row.grade
                model.createdAt = row.createdAt
                model.updatedAt = row.updatedAt
            } else {
                context.insert(row.makeModel())
            }
        }
        for leftover in existing.values { context.delete(leftover) }
    }

    private static func upsertParentProfiles(_ rows: [BackupParentProfile], in context: ModelContext) throws {
        var existing = Dictionary(uniqueKeysWithValues:
            try context.fetch(FetchDescriptor<ParentProfile>()).map { ($0.id, $0) })
        for row in rows {
            if let model = existing.removeValue(forKey: row.id) {
                model.name = row.name
                model.avatarSymbol = row.avatarSymbol
                model.isActive = row.isActive
                model.createdAt = row.createdAt
            } else {
                context.insert(row.makeModel())
            }
        }
        for leftover in existing.values { context.delete(leftover) }
    }

    private static func assertUnique(_ keys: [String], table: String) throws {
        var seen = Set<String>()
        for key in keys {
            if !seen.insert(key).inserted {
                throw BackupError.duplicateRow(table: table, key: key)
            }
        }
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
}
