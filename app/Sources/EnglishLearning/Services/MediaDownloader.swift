import CryptoKit
import Foundation
import Observation

/// 媒体逐项下载（tasks 12.1 / 12.2 / 12.4）：
/// 下到临时文件 → sha256 校验 → 原子移入缓存 → 更新索引；并发固定 1（顺序预取）。
/// 校验失败只把**这一项**标记为损坏，其余项照常可用。
@MainActor
@Observable
final class MediaDownloader {
    static let shared = MediaDownloader()

    enum Status: Equatable {
        case idle
        case downloading(progress: Double)
        case ready
        case corrupted
        case failed(String)
    }

    /// `itemID → 状态`，界面直接用
    private(set) var statuses: [String: Status] = [:]

    private var pending: [Task<Void, Never>] = []
    private var isRunning = false
    private var queue: [(asset: MediaAsset, url: URL)] = []
    private let session: URLSession
    private let cache = MediaCacheStore.shared

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    var pendingCount: Int { queue.count }

    func status(for itemID: String) -> Status {
        if let status = statuses[itemID] { return status }
        return cache.isCached(itemID) ? .ready : .idle
    }

    // MARK: - 入队（并发 1）

    /// 串流播放时顺手预取，或家长点「下载到 iPad」
    func enqueue(_ asset: MediaAsset, baseURL: URL, limitGB: Int = MediaCacheStore.defaultLimitGB) {
        guard !cache.isCached(asset.id) else {
            statuses[asset.id] = .ready
            return
        }
        guard MediaCacheStore.hasSpaceFor(bytes: asset.bytes) else {
            statuses[asset.id] = .failed("空间不足，只在线播放")
            DiagnosticsLog.log("media_prefetch_skipped_space", ["item": asset.id])
            return
        }
        // 已在队列里就不重复加
        if queue.contains(where: { $0.asset.id == asset.id }) { return }
        queue.append((asset, baseURL))
        pump(limitGB: limitGB)
    }

    /// 清空缓存后调用：让列表重新按磁盘判断「已下载」
    func forgetAll() {
        statuses.removeAll()
    }

    func cancelAll() {
        queue.removeAll()
        pending.forEach { $0.cancel() }
        pending.removeAll()
        isRunning = false
    }

    private func pump(limitGB: Int) {
        guard !isRunning, let next = queue.first else { return }
        queue.removeFirst()
        isRunning = true
        statuses[next.asset.id] = .downloading(progress: 0)

        let task = Task { [weak self] in
            guard let self else { return }
            await self.download(next.asset, from: next.url, limitGB: limitGB)
            await MainActor.run {
                self.isRunning = false
                self.pump(limitGB: limitGB)
            }
        }
        pending.append(task)
    }

    // MARK: - 真正的下载

    private func download(_ asset: MediaAsset, from baseURL: URL, limitGB: Int) async {
        let url = baseURL.appendingPathComponent(asset.relPath)
        do {
            let (tempURL, response) = try await session.download(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                statuses[asset.id] = .failed("服务器返回 \(http(status: response))")
                return
            }

            let digest = try Self.sha256Hex(of: tempURL)
            guard digest == asset.sha256.lowercased() else {
                statuses[asset.id] = .corrupted
                DiagnosticsLog.log("media_checksum_failed",
                                   ["item": asset.id, "expected": asset.sha256, "actual": digest])
                try? FileManager.default.removeItem(at: tempURL)
                return
            }

            if cache.store(tempURL: tempURL, itemID: asset.id, limitGB: limitGB) {
                statuses[asset.id] = .ready
            } else {
                statuses[asset.id] = .failed("写入缓存失败")
            }
        } catch is CancellationError {
            statuses[asset.id] = .idle
        } catch {
            statuses[asset.id] = .failed(Self.describe(error))
            DiagnosticsLog.log("media_download_failed", ["item": asset.id, "error": "\(error)"])
        }
    }

    // MARK: - 工具

    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = try? handle.read(upToCount: 1 << 20)
            guard let chunk, !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func http(status: URLResponse) -> String {
        (status as? HTTPURLResponse).map { "\($0.statusCode)" } ?? "未知"
    }

    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        switch ns.code {
        case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost:
            return "连不上家里电脑"
        case NSURLErrorTimedOut:
            return "超时了，检查 Wi-Fi"
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
            return "网络断了"
        default:
            return "下载失败（\(ns.code)）"
        }
    }
}
