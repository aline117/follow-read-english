import SwiftData
import XCTest
@testable import EnglishLearning

/// 备份格式往返与校验（spec `data-backup` / tasks 18.6）
final class BackupServiceTests: XCTestCase {

    func testRoundTripKeepsRowsAndRestores() throws {
        let source = try makeContext()
        let profile = Profile(name: "小满", grade: 2)
        source.insert(profile)

        let progress = ItemProgress(profileID: profile.id, itemCode: "w:758201",
                                    itemKind: .word, unitCode: "u1", volumeCode: "shangce")
        progress.timesSeen = 3
        progress.timesPassed = 2
        source.insert(progress)

        source.insert(StarLedger(profileID: profile.id, amount: 2,
                                 reason: "跟读达标", grantKey: "speak:w:758201:2026-11-01"))
        source.insert(Attempt(profileID: profile.id, sessionID: UUID(), itemCode: "w:758201",
                              itemKind: .word, unitCode: "u1", kind: "speak", passed: true))
        try source.save()

        let file = try BackupService.makeBackup(context: source)
        let data = try BackupService.encode(file)
        let decoded = try BackupService.decode(data)

        XCTAssertEqual(decoded.counts["profiles"], 1)
        XCTAssertEqual(decoded.counts["itemProgress"], 1)
        XCTAssertEqual(decoded.counts["attempts"], 1)
        XCTAssertEqual(decoded.counts["starLedger"], 1)

        // 目标库先放一条无关数据，恢复必须是"整包覆盖"
        let target = try makeContext()
        target.insert(Profile(name: "旧档案"))
        try target.save()

        let counts = try BackupService.restore(decoded, into: target)
        XCTAssertEqual(counts["profiles"], 1)

        let profiles = try target.fetch(FetchDescriptor<Profile>())
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles.first?.id, profile.id)

        let stars = try target.fetch(FetchDescriptor<StarLedger>())
        XCTAssertEqual(stars.count, 1)
        XCTAssertEqual(stars.first?.grantKey, "speak:w:758201:2026-11-01")
        XCTAssertEqual(StarService.balance(profileID: profile.id, in: target), 2)
    }

    func testTamperedPayloadIsRejected() throws {
        let context = try makeContext()
        let profile = Profile(name: "小满")
        context.insert(profile)
        try context.save()

        var file = try BackupService.makeBackup(context: context)
        let forged = Attempt(profileID: profile.id, sessionID: UUID(), itemCode: "w:1",
                             itemKind: .word, unitCode: "u1", kind: "speak", passed: true)
        file.payload.attempts.append(BackupAttempt(forged))

        XCTAssertThrowsError(try BackupService.validate(file)) { error in
            guard case BackupError.checksumMismatch = error else {
                return XCTFail("应当因校验和不符被拒绝，实际：\(error)")
            }
        }
    }

    func testUnsupportedVersionIsRejected() throws {
        let context = try makeContext()
        context.insert(Profile(name: "小满"))
        try context.save()

        var file = try BackupService.makeBackup(context: context)
        file.backupFormatVersion = BackupFormat.currentVersion + 1

        XCTAssertThrowsError(try BackupService.validate(file)) { error in
            guard case BackupError.unsupportedVersion = error else {
                return XCTFail("应当因版本过高被拒绝，实际：\(error)")
            }
        }
    }

    func testEmptyProfilesIsRejected() throws {
        let context = try makeContext()
        let file = try BackupService.makeBackup(context: context)

        XCTAssertThrowsError(try BackupService.validate(file)) { error in
            guard case BackupError.emptyProfiles = error else {
                return XCTFail("空备份应当被拒绝，实际：\(error)")
            }
        }
    }

    /// 同一份备份恢复两次，结果必须一致（不做合并，也不会翻倍）
    func testRestoreTwiceIsIdempotent() throws {
        let source = try makeContext()
        let profile = Profile(name: "小满", grade: 2)
        source.insert(profile)
        source.insert(StarLedger(profileID: profile.id, amount: 3, reason: "学单词",
                                 grantKey: "learn:w:1:2026-11-01"))
        try source.save()

        let file = try BackupService.decode(BackupService.encode(try BackupService.makeBackup(context: source)))

        let target = try makeContext()
        let first = try BackupService.restore(file, into: target)
        let second = try BackupService.restore(file, into: target)

        XCTAssertEqual(first, second)
        XCTAssertEqual(try target.fetch(FetchDescriptor<Profile>()).count, 1)
        XCTAssertEqual(try target.fetch(FetchDescriptor<StarLedger>()).count, 1)
        XCTAssertEqual(StarService.balance(profileID: profile.id, in: target), 3)
    }

    /// 服务端索引用 `toISOString()`（带毫秒），解析不能因为小数秒整条失败
    func testRemoteIndexDecodingHandlesFractionalSeconds() throws {
        let json = """
        {"backupFormatVersion":1,"keepPerDevice":30,"items":[
          {"deviceID":"550E8400-E29B-41D4-A716-446655440000",
           "name":"20261107-140000.json","bytes":2048,
           "modifiedAt":"2026-11-07T14:53:58.915Z",
           "sha256":"abc"}
        ]}
        """.data(using: .utf8)!

        let index = try JSONDecoder().decode(RemoteBackupIndex.self, from: json)
        XCTAssertEqual(index.items.count, 1)
        let item = try XCTUnwrap(index.items.first)
        XCTAssertEqual(item.bytes, 2048)
        XCTAssertEqual(item.sizeText.isEmpty, false)

        // 文件名前缀优先于 mtime：展示的是备份生成时间，而不是上传落盘时间
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        XCTAssertEqual(formatter.string(from: item.backupTime), "20261107-140000")
    }

    private func makeContext() throws -> ModelContext {
        let schema = EnglishLearningApp.schema
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }
}
