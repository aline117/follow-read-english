import AVFoundation
import Foundation
import Speech

/// 跟读评测结果：**只给「达标 / 再试一次」的定性结论**，不显示准确率百分比。
struct PronunciationAssessment {
    let isPassed: Bool
    /// 设备本地语音识别听到的文本（没有识别能力时为 nil）
    let recognizedText: String?
    let usedSpeechRecognition: Bool
    /// 与目标词的相似度 0…1（无识别时 nil）
    let similarity: Double?
    let duration: TimeInterval
    let referenceDuration: TimeInterval?
    let peakPower: Float
    let isLoudEnough: Bool
    let isLongEnough: Bool
    let recordingURL: URL

    /// `play with lanterns` 这类短语也适用
    var headline: String {
        if isPassed { return "和原音很像！" }
        if !isLoudEnough { return "声音太小啦" }
        if !isLongEnough { return "还没读完呢" }
        if usedSpeechRecognition { return "再跟着原音读一遍" }
        return "再来一次"
    }

    var hint: String {
        if isPassed {
            if let recognizedText, !recognizedText.isEmpty {
                return "听到你说「\(recognizedText)」，下一个词继续加油"
            }
            return "读得又清楚又响亮，继续下一个词吧"
        }
        if !isLoudEnough { return "靠近 iPad 一点，大声读出来" }
        if !isLongEnough { return "把整个词读完，不要只说一半" }
        if let recognizedText, !recognizedText.isEmpty {
            return "听到的是「\(recognizedText)」，先听原音再读一遍"
        }
        if usedSpeechRecognition { return "没听清，先听原音，再完整读一遍" }
        return "先听原音，再跟着读一遍（节奏和原音差得多）"
    }
}

/// 跟读评测（tasks 4.2）：把录音和原音对比后判「达标 / 再试一次」。
///
/// 判定顺序：
/// 1. **音量/时长兜底**：太小声、太短直接不达标（这一步不需要任何权限）
/// 2. **本地语音识别**：`SFSpeechRecognizer` + `requiresOnDeviceRecognition = true`，
///    把听到的词与目标词做编辑距离比较，`similarity >= 0.7` 算读对
/// 3. 设备没有本地识别能力 / 无权限 / 识别失败 → 退回「时长落在原音 45%–220% + 音量达标」
///
/// 隐私：录音只在临时目录，识别强制走设备端，不上传。
@MainActor
final class PronunciationEvaluator {
    static let shared = PronunciationEvaluator()

    private var speechAuthorized: Bool?

    /// 相似度达标线：`apple` vs `apples` = 0.83 通过，`pig` vs `big` = 0.67 不通过
    private static let similarityPassLine: Double = 0.7
    /// 时长兜底：与原音的比值区间。原音带前后静音，孩子读得慢是常态，
    /// 这里只挡住「明显没读完 / 明显拖太久」，不做精确判定
    private static let fallbackRatioRange: ClosedRange<Double> = 0.4...2.5
    /// 低于这个峰值音量就当没开口
    private static let loudFloor: Float = -35
    private static let shortestDuration: TimeInterval = 0.25

    func assess(recording: AudioRecorder.Recording,
                referenceURL: URL?,
                target: String) async -> PronunciationAssessment {
        let referenceDuration = Self.referenceDuration(of: referenceURL)
        let isLoudEnough = recording.peakPower > Self.loudFloor && recording.voiceRatio >= 0.04
        let isLongEnough = recording.duration >= Self.shortestDuration

        let recognition: RecognitionOutcome = isLoudEnough
            ? await recognize(url: recording.url, target: target)
            : .skipped

        let heard = recognition.transcripts
        let best = heard.compactMap { text -> (text: String, score: Double)? in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return (trimmed, Self.similarity(target: target, heard: trimmed))
        }.max(by: { $0.score < $1.score })
        let similarity = best?.score

        let isPassed: Bool
        switch recognition {
        case .done where !heard.isEmpty:
            // 有识别结果：以「像不像目标词」为准，时长只做兜底
            isPassed = isLoudEnough && isLongEnough && (similarity ?? 0) >= Self.similarityPassLine
        case .done, .failed:
            // 识别通道在，但没听到词：不判达标，让孩子再读一遍
            isPassed = false
        case .skipped, .unavailable:
            // 没有识别能力（模拟器 / 未下载听写资源 / 无权限）：退回音量 + 时长
            let ratioOK = referenceDuration.map { ratio in
                Self.fallbackRatioRange.contains(recording.duration / ratio)
            } ?? (recording.duration <= 6)
            isPassed = isLoudEnough && isLongEnough && ratioOK
        }

        return PronunciationAssessment(isPassed: isPassed,
                                       recognizedText: best?.text,
                                       usedSpeechRecognition: recognition.isDone,
                                       similarity: similarity,
                                       duration: recording.duration,
                                       referenceDuration: referenceDuration,
                                       peakPower: recording.peakPower,
                                       isLoudEnough: isLoudEnough,
                                       isLongEnough: isLongEnough,
                                       recordingURL: recording.url)
    }

    // MARK: - 语音识别

    private enum RecognitionOutcome {
        /// 识别能力不可用（无权限 / 不支持设备端识别 / 模拟器）
        case unavailable
        /// 识别跑过但失败（没听到人声、资源缺失）
        case failed
        /// 识别跑过且拿到了结果
        case done([String])
        /// 声音太小，没必要识别
        case skipped

        var isDone: Bool {
            if case .done = self { return true }
            return false
        }

        var transcripts: [String] {
            if case let .done(texts) = self { return texts }
            return []
        }
    }

    private func recognize(url: URL, target: String) async -> RecognitionOutcome {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition,
              await ensureSpeechAuthorization()
        else {
            return .unavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        request.contextualStrings = Self.contextualStrings(for: target)

        let outcome: [String]? = await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    once.finish(result.transcriptions.map(\.formattedString))
                } else if error != nil {
                    once.finish([])
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                task.cancel()
                once.finish(nil)
            }
        }

        guard let outcome else { return .failed }
        return outcome.isEmpty ? .failed : .done(outcome)
    }

    /// 只允许「已授权」，未授权时弹一次系统询问
    private func ensureSpeechAuthorization() async -> Bool {
        if let speechAuthorized { return speechAuthorized }

        let granted: Bool
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            granted = true
        case .notDetermined:
            granted = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        default:
            granted = false
        }
        speechAuthorized = granted
        return granted
    }

    /// 把目标词预先喂给识别器，专有名词/短语更容易听对
    private static func contextualStrings(for target: String) -> [String] {
        let words = target.split(separator: " ").map(String.init)
        return words.count > 1 ? [target] + words : [target]
    }

    // MARK: - 对比

    /// 原音时长（跟读面板按它算录音上限）
    static func referenceDuration(of url: URL?) -> TimeInterval? {
        guard let url, let file = try? AVAudioFile(forReading: url) else { return nil }
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0 else { return nil }
        return Double(file.length) / sampleRate
    }

    /// 归一化后的编辑距离相似度；空白差异不算错（`icecream` ≈ `ice cream`）
    static func similarity(target: String, heard: String) -> Double {
        let a = normalize(target)
        let b = normalize(heard)
        guard !a.isEmpty, !b.isEmpty else { return 0 }

        let compactA = a.replacingOccurrences(of: " ", with: "")
        let compactB = b.replacingOccurrences(of: " ", with: "")
        return max(levenshteinSimilarity(a, b), levenshteinSimilarity(compactA, compactB))
    }

    private static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                 locale: Locale(identifier: "en_US"))
        var scalars: [Character] = []
        var lastWasSpace = false
        for character in folded.lowercased() {
            if character.isLetter || character.isNumber {
                scalars.append(character)
                lastWasSpace = false
            } else if !lastWasSpace {
                scalars.append(" ")
                lastWasSpace = true
            }
        }
        return String(scalars).trimmingCharacters(in: .whitespaces)
    }

    private static func levenshteinSimilarity(_ a: String, _ b: String) -> Double {
        let lhs = Array(a)
        let rhs = Array(b)
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        if lhs == rhs { return 1 }

        var previous = Array(0...rhs.count)
        var current = [Int](repeating: 0, count: rhs.count + 1)

        for i in 1...lhs.count {
            current[0] = i
            for j in 1...rhs.count {
                let cost = lhs[i - 1] == rhs[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }

        let distance = previous[rhs.count]
        return 1 - Double(distance) / Double(max(lhs.count, rhs.count))
    }
}

/// 保证 continuation 只 resume 一次（识别回调 + 超时可能都来）。
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[String]?, Never>?

    init(_ continuation: CheckedContinuation<[String]?, Never>) {
        self.continuation = continuation
    }

    func finish(_ value: [String]?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}
