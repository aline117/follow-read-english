import AVFoundation
import Foundation
import Observation

/// 跟读录音（tasks 4.2）：一次读一个词，到上限自动停（上限由跟读面板按原音时长设）。
///
/// - 只写临时文件（`tmp/recordings/`），换词或退出学习页就删，**不上传**
/// - 录音期间采样音量，给波形动画与「声音太小」判定用
/// - 录音用 `playAndRecord`，结束后把会话还给播放（`AudioPlayer` 自己会再设一次）
@MainActor
@Observable
final class AudioRecorder {
    struct Recording {
        let url: URL
        let duration: TimeInterval
        /// 录音期间的最大音量（dBFS，-160…0）
        let peakPower: Float
        /// 超过人声下限的采样占比（0…1）
        let voiceRatio: Double
    }

    enum StartResult {
        case started
        case denied
        case failed(String)
    }

    private(set) var isRecording = false
    /// 0…1，给波形柱用
    private(set) var level: CGFloat = 0
    private(set) var elapsed: TimeInterval = 0

    /// 由跟读面板按原音时长设置；到点自动停并回调
    var maxDuration: TimeInterval = 5

    /// 停止（手动或超时）后回调，交给上层去做「和原音对比」
    var onFinish: ((Recording) -> Void)?

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var startedAt: Date?
    private var currentURL: URL?
    /// 上一次录完的文件：重录时才删，留着给「我的录音」回放
    private var lastFinishedURL: URL?
    private var peakPower: Float = -160
    private var voiceSamples = 0
    private var totalSamples = 0

    /// 约「距 iPad 30cm 正常说话」的门槛
    private static let voiceFloor: Float = -45
    private static let sampleInterval: TimeInterval = 0.05

    var remaining: TimeInterval {
        max(0, maxDuration - elapsed)
    }

    func start() async -> StartResult {
        guard !isRecording else { return .started }
        guard await Self.requestPermission() else { return .denied }

        deleteTemporaryFiles()

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .spokenAudio,
                                    options: [.defaultToSpeaker])
            try session.setActive(true)

            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("recordings", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("read-\(UUID().uuidString).m4a")

            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else { return .failed("没能开始录音，再试一次") }

            self.recorder = recorder
            currentURL = url
            startedAt = Date()
            peakPower = -160
            voiceSamples = 0
            totalSamples = 0
            elapsed = 0
            level = 0
            isRecording = true
            AudioPlayer.shared.setInputBusy(true)
            startTimer()
            return .started
        } catch {
            return .failed("录音失败：\(error.localizedDescription)")
        }
    }

    /// 手动结束（点麦克风）。超时也走这里。
    func stop() {
        guard let recorder else { return }
        finish(with: recorder)
    }

    /// 丢弃当前录音（换词、退出页面）
    func cancel() {
        recorder?.stop()
        recorder = nil
        stopTimer()
        isRecording = false
        level = 0
        elapsed = 0
        deactivateSession()
        deleteTemporaryFiles()
    }

    /// 退出学习页：连临时目录一起清掉
    func cleanUp() {
        cancel()
        try? FileManager.default.removeItem(at: Self.directory)
    }

    // MARK: - 内部

    private static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("recordings", isDirectory: true)
    }

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: Self.sampleInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        guard let recorder, isRecording else { return }
        recorder.updateMeters()

        let power = recorder.averagePower(forChannel: 0)
        peakPower = max(peakPower, recorder.peakPower(forChannel: 0))
        totalSamples += 1
        if power > Self.voiceFloor { voiceSamples += 1 }

        // -60 dB → 0，0 dB → 1
        level = CGFloat(max(0, min(1, 1 + power / 60)))
        elapsed = startedAt.map { Date().timeIntervalSince($0) } ?? 0

        if elapsed >= maxDuration {
            finish(with: recorder)
        }
    }

    private func finish(with recorder: AVAudioRecorder) {
        guard self.recorder === recorder else { return }
        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? recorder.currentTime
        recorder.stop()
        self.recorder = nil
        stopTimer()
        isRecording = false
        level = 0
        elapsed = duration
        deactivateSession()

        guard let url = currentURL else { return }
        currentURL = nil
        lastFinishedURL = url
        let recording = Recording(url: url,
                                  duration: duration,
                                  peakPower: peakPower,
                                  voiceRatio: totalSamples > 0 ? Double(voiceSamples) / Double(totalSamples) : 0)
        onFinish?(recording)
    }

    private func deactivateSession() {
        AudioPlayer.shared.setInputBusy(false)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// 录音临时文件只保留最新一条
    private func deleteTemporaryFiles() {
        for url in [currentURL, lastFinishedURL].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
        currentURL = nil
        lastFinishedURL = nil
    }

    static func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
