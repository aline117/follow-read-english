import Foundation
import Observation

/// 媒体清单（tasks 11.1 / 11.2 / 14.4）：`Application Support/media/media.json` 只读缓存。
/// 家里电脑上的 `media.json` 是唯一来源；本地有就看本地，没有就临时从内容服务拉一次。
@MainActor
@Observable
final class MediaLibrary {
    static let shared = MediaLibrary()

    enum State: Equatable {
        case missing
        case ready
        case requiresAppUpdate(Int)
        case broken(String)
    }

    private(set) var state: State = .missing
    private(set) var manifest: MediaManifest?
    private(set) var isRefreshing = false

    private static let baseURLKey = "contentServerBaseURL"
    private static let defaultBaseURL = "http://localhost:8080"

    private init() {}

    static var directory: URL {
        MediaStateStore.directory
    }

    static var manifestURL: URL {
        directory.appendingPathComponent("media.json")
    }

    var items: [MediaAsset] { manifest?.items ?? [] }
    var songs: [MediaAsset] { items.filter { $0.kind == .song } }
    var pictures: [MediaAsset] { items.filter { $0.kind == .picture } }
    var hasContent: Bool { !items.isEmpty && isPlayable }

    var isPlayable: Bool {
        if case .ready = state { return true }
        return false
    }

    var baseURL: URL? {
        let raw = UserDefaults.standard.string(forKey: Self.baseURLKey) ?? Self.defaultBaseURL
        return URL(string: raw)
    }

    /// 串流地址：内容服务的 `/media/files/...`
    func streamURL(for item: MediaAsset) -> URL? {
        guard let base = baseURL else { return nil }
        return base.appendingPathComponent("media").appendingPathComponent(item.relPath)
    }

    // MARK: - 读取

    /// 先读本地；本地没有就尝试从服务端拉一次（2 秒超时）。入口是否显示由 `hasContent` 决定。
    func refresh(tryRemote: Bool = true) async {
        isRefreshing = true
        defer { isRefreshing = false }

        if loadLocal() { return }
        guard tryRemote, let remote = await fetchRemote() else {
            if case .broken = state { return }
            state = .missing
            manifest = nil
            return
        }
        manifest = remote
        switch remote.gate {
        case .ready:
            state = .ready
        case .requiresAppUpdate(let version):
            state = .requiresAppUpdate(version)
        }
    }

    /// 同步读本地（界面首次渲染用，不发网络）
    @discardableResult
    func loadLocal() -> Bool {
        guard FileManager.default.fileExists(atPath: Self.manifestURL.path) else { return false }
        do {
            let manifest = try MediaManifest.load(from: Self.manifestURL)
            self.manifest = manifest
            switch manifest.gate {
            case .ready:
                state = .ready
            case .requiresAppUpdate(let version):
                state = .requiresAppUpdate(version)
            }
            return true
        } catch {
            manifest = nil
            state = .broken("媒体清单损坏：\(error.localizedDescription)")
            DiagnosticsLog.log("media_manifest_broken", ["error": "\(error)"])
            return true
        }
    }

    /// 从内容服务拉清单并落盘；失败返回 nil（入口继续隐藏）
    func fetchRemote() async -> MediaManifest? {
        guard let base = baseURL else { return nil }
        var request = URLRequest(url: base.appendingPathComponent("media.json"))
        request.timeoutInterval = 2
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let manifest = try JSONDecoder().decode(MediaManifest.self, from: data)
            try manifest.validate()
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            try data.write(to: Self.manifestURL, options: .atomic)
            return manifest
        } catch {
            DiagnosticsLog.log("media_manifest_fetch_failed", ["error": "\(error.localizedDescription)"])
            return nil
        }
    }

    func reloadFromDisk() {
        manifest = nil
        state = .missing
        _ = loadLocal()
    }
}
