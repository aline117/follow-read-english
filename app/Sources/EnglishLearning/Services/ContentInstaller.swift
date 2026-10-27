import CryptoKit
import Foundation
import Observation
import ZIPFoundation

/// 学期包下载 / 校验 / 安装（tasks 3.6，design「客户端下载流程」）。
///
///     probe（2 秒超时）→ 版本兼容性 → 下载 zip（进度）→ sha256 → 解压 .tmp
///     → 校验文件与资产齐全 → 原子换入 Curriculum/<id> → 写 pack-info.json
@MainActor
@Observable
final class ContentInstaller {
    enum Phase: Equatable {
        case idle
        case probing
        case ready
        case failed(String)
    }

    struct Progress: Equatable {
        var packID: String
        var phase: String
        var fraction: Double
    }

    enum InstallerError: LocalizedError {
        case message(String)

        var errorDescription: String? {
            switch self {
            case .message(let text): return text
            }
        }
    }

    static let defaultBaseURL = "http://localhost:8080"
    private static let baseURLKey = "contentServerBaseURL"

    private(set) var phase: Phase = .idle
    private(set) var packs: [ManifestPack] = []
    private(set) var serverSchemaVersion: Int?
    private(set) var progress: Progress?
    private(set) var lastError: String?

    /// 服务地址（可在内容管理页手改；默认 localhost，真机改成 `<host>.local`）
    var baseURLString: String

    init() {
        baseURLString = UserDefaults.standard.string(forKey: Self.baseURLKey) ?? Self.defaultBaseURL
    }

    var baseURL: URL? { URL(string: baseURLString) }
    var isBusy: Bool { progress != nil || phase == .probing }

    // MARK: - 探测 manifest

    func probe() async {
        guard let base = baseURL else {
            phase = .failed("服务地址格式不对")
            return
        }
        UserDefaults.standard.set(baseURLString, forKey: Self.baseURLKey)
        phase = .probing
        lastError = nil
        do {
            var request = URLRequest(url: base.appendingPathComponent("manifest.json"))
            request.timeoutInterval = 2   // design：2 秒超时
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw InstallerError.message("内容服务返回 HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            }
            let manifest = try JSONDecoder().decode(ContentManifest.self, from: data)
            serverSchemaVersion = manifest.contentSchemaVersion
            packs = manifest.packs
            phase = .ready
        } catch {
            packs = []
            serverSchemaVersion = nil
            let text = Self.describe(error)
            phase = .failed(text)
            lastError = text
        }
    }

    // MARK: - 安装 / 回退

    func install(_ pack: ManifestPack) async {
        guard let base = baseURL else { return }
        await install(pack.remote(baseURL: base))
    }

    /// 回退到 manifest 的 `previous`（进度按 `itemCode` 保留）
    func rollback(_ pack: ManifestPack) async {
        guard let base = baseURL, let previous = pack.previousRemote(baseURL: base) else { return }
        await install(previous)
    }

    private func install(_ remote: RemotePack) async {
        guard progress == nil, let downloadURL = remote.downloadURL else { return }
        lastError = nil
        progress = Progress(packID: remote.id, phase: "准备中", fraction: 0)
        defer { progress = nil }

        do {
            try ContentStorage.ensureDirectories()
            guard remote.schemaVersion <= ContentSchema.supported else {
                throw InstallerError.message("该学期需要更新 App 才能安装")
            }
            try checkSpace(for: remote.sizeBytes)

            let zipURL = try await download(remote, from: downloadURL)
            defer { try? FileManager.default.removeItem(at: zipURL) }

            update(phase: "校验 sha256", fraction: 1)
            let digest = try Self.sha256(of: zipURL)
            guard digest.caseInsensitiveCompare(remote.sha256) == .orderedSame else {
                throw InstallerError.message("sha256 校验不通过（包可能损坏），请重试")
            }

            update(phase: "解压中", fraction: 1)
            let stagingRoot = ContentStorage.tmpRoot
                .appendingPathComponent("stage-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: stagingRoot) }
            try FileManager.default.unzipItem(at: zipURL, to: stagingRoot)

            let stagedPack = stagingRoot.appendingPathComponent(remote.id, isDirectory: true)
            guard FileManager.default.fileExists(atPath: stagedPack.path) else {
                throw InstallerError.message("包里缺少 \(remote.id)/ 目录")
            }

            update(phase: "校验内容", fraction: 1)
            _ = try CurriculumLoader.validate(folder: stagedPack)

            try writePackInfo(remote, into: stagedPack)
            update(phase: "安装中", fraction: 1)
            try installAtomically(stagedPack, as: remote.id)

            ContentLibrary.shared.refresh()
            ContentLibrary.shared.invalidate(remote.id)
            // 下载完成通知家长（tasks 6.9）
            await LocalNotifications.packInstalled(title: remote.title)
        } catch {
            lastError = Self.describe(error)
        }
    }

    // MARK: - 步骤

    private func update(phase: String, fraction: Double) {
        guard var current = progress else { return }
        current.phase = phase
        current.fraction = fraction
        progress = current
    }

    private func checkSpace(for sizeBytes: Int64) throws {
        guard sizeBytes > 0, let available = ContentStorage.availableCapacity() else { return }
        let needed = Int64(Double(sizeBytes) * 1.5)   // design：包大小 × 1.5
        guard available < needed else { return }
        let needMB = Double(needed - available) / 1_048_576
        throw InstallerError.message(String(format: "空间不足，还需释放约 %.0f MB", needMB))
    }

    private func download(_ remote: RemotePack, from url: URL) async throws -> URL {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let delegate = ProgressDelegate { [weak self] fraction in
            guard let self, var current = self.progress else { return }
            current.phase = "下载中"
            current.fraction = fraction
            self.progress = current
        }
        let (temporaryURL, response) = try await URLSession.shared.download(for: request, delegate: delegate)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw InstallerError.message("下载失败：HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }

        let destination = ContentStorage.downloads
            .appendingPathComponent("\(remote.id)-v\(remote.contentVersion).zip")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    private func writePackInfo(_ remote: RemotePack, into folder: URL) throws {
        let info = InstalledPack(
            id: remote.id,
            grade: remote.grade,
            title: remote.title,
            contentVersion: remote.contentVersion,
            schemaVersion: remote.schemaVersion,
            sha256: remote.sha256,
            sizeBytes: remote.sizeBytes,
            installedAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(info)
        try data.write(to: folder.appendingPathComponent(ContentStorage.packInfoName), options: .atomic)
    }

    /// 原子换入：旧目录先挪到 .tmp，新目录 rename 到位；失败则把旧的放回来。
    private func installAtomically(_ staged: URL, as id: String) throws {
        let fm = FileManager.default
        let target = ContentStorage.semester(id)

        guard fm.fileExists(atPath: target.path) else {
            try fm.moveItem(at: staged, to: target)
            return
        }

        let backup = ContentStorage.tmpRoot
            .appendingPathComponent("old-\(id)-\(UUID().uuidString)", isDirectory: true)
        try fm.moveItem(at: target, to: backup)
        do {
            try fm.moveItem(at: staged, to: target)
        } catch {
            try? fm.moveItem(at: backup, to: target)
            throw error
        }
        try? fm.removeItem(at: backup)
    }

    // MARK: - 工具

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func describe(_ error: Error) -> String {
        if let installerError = error as? InstallerError {
            return installerError.errorDescription ?? "未知错误"
        }
        if let curriculumError = error as? CurriculumError {
            return curriculumError.description
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorNetworkConnectionLost:
                return "连不上内容服务：确认电脑上 serve.py/serve.js 在跑，且 iPad 与电脑在同一 Wi-Fi"
            case NSURLErrorTimedOut:
                return "连接超时：检查地址是否可访问（可先用浏览器打开 manifest.json）"
            case NSURLErrorNotConnectedToInternet:
                return "设备当前没有网络"
            default:
                return "网络错误（\(nsError.code)）：\(nsError.localizedDescription)"
            }
        }
        return nsError.localizedDescription
    }
}

/// 下载进度回调（URLSession 的 delegate 回调不在主线程，回调里 hop 回来）。
private final class ProgressDelegate: NSObject, URLSessionTaskDelegate {
    private let onProgress: @MainActor @Sendable (Double) -> Void

    init(onProgress: @escaping @MainActor @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor in
            onProgress(fraction)
        }
    }
}
