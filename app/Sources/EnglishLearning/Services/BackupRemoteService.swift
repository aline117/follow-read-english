import Foundation
import Observation
import SwiftData

/// 家园在线备份（design「备份与恢复 · 通道 B」/ tasks 18.3–18.5）。
///
/// 走的是家里电脑上那个 content-service：它本来就在局域网里跑内容分发，
/// 顺手多接三个备份路由，学习记录不必出家门。协议见 `serve/serve.js`：
///
///     PUT /backup/<deviceID>/<name>.json   请求头 `X-Backup-Sha256`
///     GET /backup/index.json
///     GET /backup/file/<deviceID>/<name>
///
/// 设计约束：
/// - **失败静默**：自动备份任何异常都只写诊断日志，绝不在学习界面弹窗
/// - **未变跳过**：整包摘要与上次上传一致就不重复传（家用 NAS 也是硬盘）
/// - **设备独立**：`deviceID` 首次生成后固定，换机/重装会得到新目录，旧备份仍可恢复
@MainActor
@Observable
final class BackupRemoteService {

    static let shared = BackupRemoteService()

    /// 两次自动备份的最小间隔（design：每 24 小时最多一次）
    static let autoBackupInterval: TimeInterval = 24 * 60 * 60

    enum Phase: Equatable {
        case idle
        case working(String)
        case failed(String)
    }

    enum RemoteError: LocalizedError {
        case badAddress
        case http(Int, String)
        case checksumMismatch
        case emptyIndex

        var errorDescription: String? {
            switch self {
            case .badAddress:
                return "内容服务地址格式不对"
            case .http(let code, let detail):
                return detail.isEmpty ? "内容服务返回 HTTP \(code)" : "内容服务返回 HTTP \(code)：\(detail)"
            case .checksumMismatch:
                return "下载的备份校验和不符，可能传输中损坏，请重试"
            case .emptyIndex:
                return "家里电脑上还没有任何备份"
            }
        }
    }

    private static let deviceIDKey = "backupDeviceID"
    private static let lastUploadAtKey = "backupLastUploadAt"
    private static let lastUploadSHAKey = "backupLastUploadSHA"
    private static let lastUploadNameKey = "backupLastUploadName"

    private(set) var phase: Phase = .idle
    private(set) var items: [RemoteBackupItem] = []
    private(set) var lastUploadAt: Date?
    /// 最近一次失败原因；自动备份失败只留在这里 + 诊断日志，不主动弹窗
    private(set) var lastError: String?

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private init() {
        lastUploadAt = UserDefaults.standard.object(forKey: Self.lastUploadAtKey) as? Date
    }

    // MARK: - 本机标识

    /// 稳定设备标识：首次备份时生成，之后一直复用（卸载重装会换新，旧备份仍可恢复）
    var deviceID: String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: Self.deviceIDKey), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: Self.deviceIDKey)
        return fresh
    }

    var lastUploadName: String? {
        UserDefaults.standard.string(forKey: Self.lastUploadNameKey)
    }

    var isBusy: Bool {
        if case .working = phase { return true }
        return false
    }

    var lastUploadDescription: String {
        guard let lastUploadAt else { return "还没有备份过" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        return "上次备份：" + formatter.localizedString(for: lastUploadAt, relativeTo: Date())
    }

    // MARK: - 上传

    /// 手动备份：总是上传（家长点了就传，哪怕内容没变）
    @discardableResult
    func backupNow(context: ModelContext, baseURL: URL?) async -> Bool {
        await backup(context: context, baseURL: baseURL, skipIfUnchanged: false)
    }

    /// 自动备份：距上次成功不足 24 小时直接返回；内容没变也不重复传
    @discardableResult
    func autoBackupIfDue(context: ModelContext, baseURL: URL?) async -> Bool {
        if let lastUploadAt, Date().timeIntervalSince(lastUploadAt) < Self.autoBackupInterval {
            return false
        }
        return await backup(context: context, baseURL: baseURL, skipIfUnchanged: true)
    }

    private func backup(context: ModelContext, baseURL: URL?, skipIfUnchanged: Bool) async -> Bool {
        guard !isBusy else { return false }
        guard let baseURL else {
            lastError = RemoteError.badAddress.localizedDescription
            return false
        }

        phase = .working("正在打包学习记录…")
        lastError = nil

        let file: BackupFile
        let data: Data
        do {
            file = try BackupService.makeBackup(context: context)
            data = try BackupService.encode(file)
        } catch {
            phase = .idle
            let text = "打包失败：\(error.localizedDescription)"
            lastError = text
            DiagnosticsLog.log("backup_pack_failed", ["error": text])
            return false
        }

        // 摘要没变 = 这段时间没有新的学习数据，白传一遍没意义
        let previousSHA = UserDefaults.standard.string(forKey: Self.lastUploadSHAKey)
        if skipIfUnchanged, previousSHA == file.payloadSha256, lastUploadAt != nil {
            phase = .idle
            DiagnosticsLog.log("backup_skipped_unchanged", [:])
            return false
        }

        phase = .working("正在上传到家中的电脑…")
        do {
            let item = try await upload(data: data, sha256: BackupService.sha256Hex(data),
                                        baseURL: baseURL)
            let defaults = UserDefaults.standard
            defaults.set(Date(), forKey: Self.lastUploadAtKey)
            defaults.set(file.payloadSha256, forKey: Self.lastUploadSHAKey)
            defaults.set(item.name, forKey: Self.lastUploadNameKey)
            lastUploadAt = defaults.object(forKey: Self.lastUploadAtKey) as? Date
            phase = .idle
            DiagnosticsLog.log("backup_uploaded", [
                "bytes": "\(data.count)",
                "name": item.name,
                "profiles": "\(file.payload.profiles.count)"
            ])
            await refreshIndex(baseURL: baseURL)
            return true
        } catch {
            phase = .failed(error.localizedDescription)
            lastError = error.localizedDescription
            DiagnosticsLog.log("backup_upload_failed", ["error": error.localizedDescription])
            return false
        }
    }

    private func upload(data: Data, sha256: String, baseURL: URL) async throws -> RemoteBackupItem {
        let name = Self.stampFormatter.string(from: Date()) + ".json"
        let url = baseURL
            .appendingPathComponent("backup")
            .appendingPathComponent(deviceID)
            .appendingPathComponent(name)

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(sha256, forHTTPHeaderField: "X-Backup-Sha256")
        request.httpBody = data

        let (body, response) = try await URLSession.shared.data(for: request)
        try Self.assertOK(response, body: body)

        let ack = try? JSONDecoder().decode(UploadAck.self, from: body)
        return RemoteBackupItem(
            deviceID: ack?.deviceID ?? deviceID,
            name: ack?.name ?? name,
            bytes: ack?.bytes ?? data.count,
            modifiedAt: Date(),
            sha256: ack?.sha256 ?? sha256
        )
    }

    // MARK: - 索引

    func refreshIndex(baseURL: URL) async {
        do {
            items = try await fetchIndex(baseURL: baseURL)
            if case .failed = phase { phase = .idle }
        } catch {
            lastError = error.localizedDescription
            DiagnosticsLog.log("backup_index_failed", ["error": error.localizedDescription])
        }
    }

    func fetchIndex(baseURL: URL) async throws -> [RemoteBackupItem] {
        let url = baseURL.appendingPathComponent("backup").appendingPathComponent("index.json")
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (body, response) = try await URLSession.shared.data(for: request)
        try Self.assertOK(response, body: body)
        let index = try JSONDecoder().decode(RemoteBackupIndex.self, from: body)
        return index.items.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    // MARK: - 下载（恢复用）

    /// 下载并校验：先比 sha256 再交给 `BackupService.decode`，损坏的文件不会碰到数据库
    func download(_ item: RemoteBackupItem, baseURL: URL) async throws -> Data {
        let url = baseURL
            .appendingPathComponent("backup")
            .appendingPathComponent("file")
            .appendingPathComponent(item.deviceID)
            .appendingPathComponent(item.name)

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.assertOK(response, body: data)

        guard BackupService.sha256Hex(data) == item.sha256.lowercased() else {
            throw RemoteError.checksumMismatch
        }
        return data
    }

    // MARK: - 工具

    private static func assertOK(_ response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw RemoteError.http(-1, "")
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: body, encoding: .utf8) ?? ""
            throw RemoteError.http(http.statusCode, String(text.prefix(120)))
        }
    }

    private struct UploadAck: Decodable {
        var ok: Bool?
        var deviceID: String?
        var name: String?
        var bytes: Int?
        var sha256: String?
    }
}

// MARK: - 索引模型

struct RemoteBackupIndex: Decodable {
    var backupFormatVersion: Int
    var keepPerDevice: Int?
    var items: [RemoteBackupItem]
}

struct RemoteBackupItem: Identifiable, Equatable, Decodable {
    var deviceID: String
    var name: String
    var bytes: Int
    var modifiedAt: Date
    var sha256: String

    var id: String { deviceID + "/" + name }

    /// 文件名前缀就是上传时间（`yyyyMMdd-HHmmss` 或 `yyyyMMdd-HHmm`），解析不出来就退回 mtime
    var backupTime: Date {
        let base = name.hasSuffix(".json") ? String(name.dropLast(5)) : name
        for format in ["yyyyMMdd-HHmmss", "yyyyMMdd-HHmm"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = format
            if let date = formatter.date(from: base) { return date }
        }
        return modifiedAt
    }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// 列表里显示用的短设备号（同一台 iPad 上的多次备份归在一起）
    var shortDeviceID: String {
        String(deviceID.prefix(8))
    }

    private enum CodingKeys: String, CodingKey {
        case deviceID, name, bytes, modifiedAt, sha256
    }

    init(deviceID: String, name: String, bytes: Int, modifiedAt: Date, sha256: String) {
        self.deviceID = deviceID
        self.name = name
        self.bytes = bytes
        self.modifiedAt = modifiedAt
        self.sha256 = sha256
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceID = try container.decode(String.self, forKey: .deviceID)
        name = try container.decode(String.self, forKey: .name)
        bytes = try container.decode(Int.self, forKey: .bytes)
        sha256 = try container.decode(String.self, forKey: .sha256)
        // 服务端用 `toISOString()`（带毫秒），`.iso8601` 解不了带小数秒的串
        let raw = try container.decode(String.self, forKey: .modifiedAt)
        modifiedAt = RemoteBackupItem.parseDate(raw) ?? Date.distantPast
    }

    private static func parseDate(_ raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}
