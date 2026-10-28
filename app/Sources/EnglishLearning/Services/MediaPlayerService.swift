import AVFoundation
import Foundation
import Observation

/// 媒体播放（tasks 13.1–13.7）：
/// - 本地缓存优先，其次串流；`streamable == false` 的先下载再播
/// - 每 5 秒记位置，最后 5 秒视为看完；播放中按墙钟累计观看时长
/// - 8 秒没起播 / HTTP / 解码失败都给可读错误，不无限转圈
@MainActor
@Observable
final class MediaPlayerService {
    enum State: Equatable {
        case idle
        case loading
        case playing
        case paused
        case ended
        case blocked(String)
        case failed(String)
    }

    let player = AVPlayer()

    private(set) var item: MediaAsset?
    private(set) var state: State = .idle
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var isUsingCache = false
    private(set) var downloadProgress: Double?
    /// 当前播放源（本地缓存或串流），跟读页复用
    private(set) var sourceURL: URL?

    private var profileID: UUID?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var ticker: Timer?
    private var pollTask: Task<Void, Never>?
    private var loadDeadline: Date?
    private var lastTick: Date?
    private var pendingWatched: Double = 0
    private var lastSaveAt = Date.distantPast

    private let cache = MediaCacheStore.shared
    private let downloads = MediaDownloader.shared
    private let settings = MediaSettingsStore.shared

    // MARK: - 打开 / 关闭

    func open(_ item: MediaAsset, profileID: UUID) {
        close()
        self.item = item
        self.profileID = profileID
        duration = MediaStateStore.shared.displayDuration(for: item) ?? 0
        position = MediaStateStore.shared.itemState(item.id, profileID: profileID).positionSec

        guard !settings.isAreaDisabled else {
            state = .blocked("今天不能看视频（家长把观看时间设成了 0）")
            return
        }
        guard settings.canStartNewItem(profileID: profileID) else {
            state = .blocked("今天看够啦，明天再来")
            return
        }

        if let local = cache.fileURL(for: item.id) {
            start(url: local, cached: true)
            return
        }

        guard let base = MediaLibrary.shared.baseURL else {
            state = .failed("没有内容服务地址，先去家长模式里设置")
            return
        }

        if item.streamable, let stream = MediaLibrary.shared.streamURL(for: item) {
            start(url: stream, cached: false)
            // 串流时顺手预取，最多缓存到家长设的上限
            downloads.enqueue(item, baseURL: base, limitGB: settings.cacheLimitGB)
        } else {
            state = .loading
            downloadProgress = 0
            downloadThenPlay(item, baseURL: base)
        }
    }

    func pause() {
        guard state == .playing else { return }
        player.pause()
        state = .paused
        flush()
    }

    func retry() {
        guard let item, let profileID else { return }
        open(item, profileID: profileID)
    }

    func close() {
        flush()
        pollTask?.cancel()
        pollTask = nil
        ticker?.invalidate()
        ticker = nil
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        statusObservation?.invalidate()
        statusObservation = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        state = .idle
        downloadProgress = nil
        isUsingCache = false
        sourceURL = nil
        lastTick = nil
        loadDeadline = nil
    }

    // MARK: - 控制

    func togglePlay() {
        switch state {
        case .ended:
            seek(to: 0)
            player.play()
            state = .playing
        case .playing:
            player.pause()
            state = .paused
            flush()
        case .paused:
            player.play()
            state = .playing
            lastTick = Date()
        case .idle, .loading, .blocked, .failed:
            break
        }
    }

    func seek(to seconds: Double) {
        guard duration > 0 else { return }
        let target = min(max(0, seconds), duration)
        position = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        if state == .ended, target < duration - 1 { state = .paused }
    }

    var isPlaying: Bool { state == .playing }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, position / duration))
    }

    // MARK: - 起播

    private func start(url: URL, cached: Bool) {
        isUsingCache = cached
        sourceURL = url
        state = .loading
        loadDeadline = Date().addingTimeInterval(8)
        downloadProgress = nil

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)

        let playerItem = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: playerItem)
        observe(playerItem)

        let resume = position
        if resume > 0 {
            player.seek(to: CMTime(seconds: resume, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
        }
        player.play()
        startTicker()

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in self?.tick(time: time.seconds) }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleEnd() }
        }
    }

    private func observe(_ playerItem: AVPlayerItem) {
        statusObservation = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.item != nil else { return }
                switch item.status {
                case .readyToPlay:
                    if !item.duration.isIndefinite, item.duration.seconds.isFinite {
                        self.duration = max(self.duration, item.duration.seconds)
                    }
                    if self.duration > 0 {
                        MediaStateStore.shared.setBackfilledDuration(
                            self.duration,
                            itemID: self.item?.id ?? "",
                            manifestValue: self.item?.displayDuration
                        )
                    }
                case .failed:
                    let message = item.error?.localizedDescription ?? "视频解码失败"
                    self.state = .failed(message)
                    DiagnosticsLog.log("media_decode_failed", ["error": message])
                default:
                    break
                }
            }
        }
    }

    private func downloadThenPlay(_ item: MediaAsset, baseURL: URL) {
        downloads.enqueue(item, baseURL: baseURL, limitGB: settings.cacheLimitGB)
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                switch self.downloads.status(for: item.id) {
                case .ready:
                    if let url = self.cache.fileURL(for: item.id) {
                        self.start(url: url, cached: true)
                    } else {
                        self.state = .failed("下载完成了但找不到缓存文件")
                    }
                    return
                case .downloading(let progress):
                    self.downloadProgress = progress
                case .corrupted:
                    self.state = .failed("文件校验失败，点重试重新下载")
                    return
                case .failed(let message):
                    self.state = .failed(message)
                    return
                case .idle:
                    break
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
    }

    // MARK: - 计时 / 落盘

    private func startTicker() {
        ticker?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickTicker() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func tickTicker() {
        guard item != nil else { return }
        if state == .loading {
            if let deadline = loadDeadline, Date() > deadline {
                state = .failed("视频 8 秒还没起来，检查家里电脑或先下载到 iPad")
                DiagnosticsLog.log("media_start_timeout", ["item": item?.id ?? ""])
                loadDeadline = nil
                player.pause()
            }
            return
        }
        guard state == .playing else {
            lastTick = nil
            return
        }

        let now = Date()
        if let last = lastTick {
            pendingWatched += min(1, max(0, now.timeIntervalSince(last)))
        }
        lastTick = now

        if pendingWatched >= 5 {
            flush()
        }
    }

    private func tick(time: Double) {
        guard time.isFinite, time >= 0 else { return }
        position = duration > 0 ? min(time, duration) : time
        let control = player.timeControlStatus
        if control == .playing, state == .loading || state == .paused {
            state = .playing
            loadDeadline = nil
            lastTick = Date()
        } else if control == .paused, state == .playing {
            state = .paused
            lastTick = nil
        }

        if Date().timeIntervalSince(lastSaveAt) >= 5 {
            savePosition()
        }
    }

    private func savePosition() {
        guard let item, let profileID, duration > 0 else { return }
        lastSaveAt = Date()
        if position >= duration - 5 {
            MediaStateStore.shared.clearPosition(item.id, profileID: profileID)
        } else {
            MediaStateStore.shared.updatePosition(item.id, seconds: position, profileID: profileID)
        }
    }

    private func flush() {
        guard let item, let profileID else { return }
        if pendingWatched > 0 {
            MediaStateStore.shared.addWatched(pendingWatched, itemID: item.id, profileID: profileID)
            pendingWatched = 0
        }
        if duration > 0, state != .idle {
            if state == .ended || position >= duration - 5 {
                MediaStateStore.shared.clearPosition(item.id, profileID: profileID)
            } else {
                MediaStateStore.shared.updatePosition(item.id, seconds: position, profileID: profileID)
            }
        }
        lastSaveAt = Date()
    }

    private func handleEnd() {
        guard let item, let profileID else { return }
        position = duration
        state = .ended
        player.pause()
        MediaStateStore.shared.clearPosition(item.id, profileID: profileID)
        flush()
    }
}
