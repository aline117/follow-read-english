import AVFoundation
import Foundation
import Observation

/// 音频播放器（design「音频方案」）。
///
/// - 原速：`AVAudioPlayerNode` 直接播
/// - 0.5x / 0.75x：串一个 `AVAudioUnitTimePitch`（**变速不变调**），不预生成慢速文件
@MainActor
@Observable
final class AudioPlayer {
    static let shared = AudioPlayer()

    private(set) var playingURL: URL?
    private(set) var playingRate: Double = 1
    private(set) var lastError: String?
    /// 麦克风正在录音：这期间拒绝播放，避免把录音会话抢掉
    private var isInputBusy = false

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var file: AVAudioFile?
    private var nodesAttached = false
    /// 被系统打断（来电/闹钟）暂停过：用于判断能否 resume
    private var pausedByInterruption = false

    /// 三档配速（design「单词跟读」）：新学默认 0.75x，复习默认原速
    static let halfRate: Double = 0.5
    static let slowRate: Double = 0.75
    static let normalRate: Double = 1

    func isPlaying(_ url: URL, rate: Double? = nil) -> Bool {
        guard playingURL == url else { return false }
        guard let rate else { return true }
        return abs(playingRate - rate) < 0.01
    }

    /// 点同一个再点一次就停
    func toggle(url: URL, rate: Double = 1) {
        if isPlaying(url, rate: rate) {
            stop()
        } else {
            play(url: url, rate: rate)
        }
    }

    func play(url: URL, rate: Double = 1) {
        guard !isInputBusy else { return }
        stop()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)

            let file = try AVAudioFile(forReading: url)
            self.file = file
            try prepareEngine(format: file.processingFormat)

            timePitch.rate = Float(rate)
            playerNode.scheduleFile(file, at: nil) { [weak self] in
                Task { @MainActor in
                    guard let self, self.playingURL == url else { return }
                    self.playingURL = nil
                }
            }
            if !engine.isRunning {
                try engine.start()
            }
            playerNode.play()
            playingURL = url
            playingRate = rate
            lastError = nil
        } catch {
            stop()
            lastError = "播放失败：\(error.localizedDescription)"
        }
    }

    func stop() {
        playerNode.stop()
        if engine.isRunning { engine.pause() }
        file = nil
        playingURL = nil
        playingRate = 1
        pausedByInterruption = false
    }

    /// 系统打断（来电/闹钟）时暂停：保留 `playingURL`，等 `.shouldResume` 再续
    func pause() {
        guard playingURL != nil, !pausedByInterruption else { return }
        playerNode.pause()
        if engine.isRunning { engine.pause() }
        pausedByInterruption = true
    }

    /// 打断结束后恢复（只在"被打断暂停过、音频还在"的情况下生效）
    func resume() {
        guard pausedByInterruption, playingURL != nil else { return }
        do {
            if !engine.isRunning { try engine.start() }
            playerNode.play()
            pausedByInterruption = false
        } catch {
            stop()
            lastError = "恢复播放失败：\(error.localizedDescription)"
        }
    }

    /// 录音器在开始/结束录音时调用
    func setInputBusy(_ busy: Bool) {
        isInputBusy = busy
    }

    /// 每次播放按文件格式重新接线；mp3 之间格式一致时等于没变动。
    private func prepareEngine(format: AVAudioFormat) throws {
        if !nodesAttached {
            engine.attach(playerNode)
            engine.attach(timePitch)
            nodesAttached = true
        }
        if engine.isRunning { engine.stop() }

        engine.disconnectNodeOutput(playerNode)
        engine.disconnectNodeOutput(timePitch)
        engine.connect(playerNode, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        engine.prepare()
    }
}
