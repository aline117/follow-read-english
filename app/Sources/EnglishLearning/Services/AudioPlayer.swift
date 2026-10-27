import AVFoundation
import Foundation
import Observation

/// 音频播放器（design「音频方案」）。
///
/// - 常速：`AVAudioPlayerNode` 直接播
/// - 慢速：串一个 `AVAudioUnitTimePitch`（rate 0.7，**变速不变调**），不预生成慢速文件
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

    /// 新学默认慢速；复习默认常速（design）
    static let slowRate: Double = 0.7

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
