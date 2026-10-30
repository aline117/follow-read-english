import AVFoundation
import Foundation
import Speech

/// 跟读评测结果：**只给「达标 / 再试一次」的定性结论**，不显示准确率百分比。
struct PronunciationAssessment {
    /// 未达标的诊断，用来决定建议配速与纠正文案
    enum Issue: Equatable {
        case tooQuiet
        case tooShort
        case wrongWord
        case close
        case dragging
        case unrecognized
    }

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
    /// 未达标诊断；达标时为 nil
    let issue: Issue?
    /// 与目标词不一致的位置（开头 / 结尾 / 中间 / 漏了某个词）
    let difference: String?
    /// 评测基础设施异常（识别超时 / 识别器报错 / 音频读不出）：**不算读错**。
    /// 调用方据此只提示重试，且不得写 `Attempt`（design「评测基础设施异常 ≠ 读错」）
    var isInfrastructureFailure = false

    /// `play with lanterns` 这类短语也适用
    var headline: String {
        if isPassed { return "和原音很像！" }
        switch issue {
        case .tooQuiet: return "声音太小啦"
        case .tooShort: return "还没读完呢"
        case .wrongWord: return "读的不是这个词"
        case .close: return "有点接近了"
        case .dragging: return "读得有点拖"
        case .unrecognized, .none: return "再试一次"
        }
    }

    /// 一句可执行建议（含建议配速）
    var advice: String {
        if isPassed {
            if let recognizedText, !recognizedText.isEmpty {
                return "听到你说「\(recognizedText)」，接着往下练吧"
            }
            return "读得又清楚又响亮，接着往下练吧"
        }
        switch issue {
        case .tooQuiet: return "靠近 iPad 大声读；先 0.75x 听一遍再读"
        case .tooShort: return "把尾音读完；用 0.5x 跟着读"
        case .wrongWord: return "先 0.75x 听，再跟着读；注意开头音"
        case .close: return "用 0.5x 听，注意\(difference ?? "细节")，再读一遍"
        case .dragging: return "用 0.75x 连起来读，不要一字一顿"
        case .unrecognized, .none: return "先 0.5x 听清，再按原速读"
        }
    }

    /// 保留旧字段名，避免其它页面改动
    var hint: String { advice }

    /// 失败卡上的「建议配速」；达标时为 nil
    var suggestedRate: Double? {
        guard !isPassed else { return nil }
        switch issue {
        case .tooQuiet, .wrongWord, .dragging: return 0.75
        case .tooShort, .close, .unrecognized, .none: return 0.5
        }
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
                target: String,
                referenceDuration: TimeInterval? = nil) async -> PronunciationAssessment {
        let referenceDuration = referenceDuration ?? Self.referenceDuration(of: referenceURL)
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
        case .timedOut:
            // 基础设施异常：结论一律不达标，但调用方不会记成「读错」
            isPassed = false
        case .skipped, .unavailable:
            // 没有识别能力（模拟器 / 未下载听写资源 / 无权限）：退回音量 + 时长
            let ratioOK = referenceDuration.map { ratio in
                Self.fallbackRatioRange.contains(recording.duration / ratio)
            } ?? (recording.duration <= 6)
            isPassed = isLoudEnough && isLongEnough && ratioOK
        }

        let issue: PronunciationAssessment.Issue?
        if isPassed {
            issue = nil
        } else if !isLoudEnough {
            issue = .tooQuiet
        } else if !isLongEnough {
            issue = .tooShort
        } else {
            switch recognition {
            case .done where !heard.isEmpty:
                issue = (similarity ?? 0) < 0.4 ? .wrongWord : .close
            case .done, .failed:
                issue = .unrecognized
            case .timedOut:
                issue = .unrecognized
            case .skipped, .unavailable:
                if let referenceDuration, recording.duration / referenceDuration > 2.5 {
                    issue = .dragging
                } else {
                    issue = .unrecognized
                }
            }
        }
        let difference = best.flatMap { Self.difference(target: target, heard: $0.text) }

        return PronunciationAssessment(isPassed: isPassed,
                                       recognizedText: best?.text,
                                       usedSpeechRecognition: recognition.isDone,
                                       similarity: similarity,
                                       duration: recording.duration,
                                       referenceDuration: referenceDuration,
                                       peakPower: recording.peakPower,
                                       isLoudEnough: isLoudEnough,
                                       isLongEnough: isLongEnough,
                                       recordingURL: recording.url,
                                       issue: issue,
                                       difference: difference,
                                       isInfrastructureFailure: recognition.isInfrastructureFailure)
    }

    // MARK: - 语音识别

    private enum RecognitionOutcome {
        /// 识别能力不可用（无权限 / 不支持设备端识别 / 模拟器）
        case unavailable
        /// 识别跑过但没听到人声
        case failed
        /// 识别跑过且拿到了结果
        case done([String])
        /// 声音太小，没必要识别
        case skipped
        /// 识别超时 / 识别器报错：属基础设施异常，不是读错
        case timedOut

        var isDone: Bool {
            if case .done = self { return true }
            return false
        }

        var isInfrastructureFailure: Bool {
            if case .timedOut = self { return true }
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

        let outcome: RecognitionOutcome = await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    let texts = result.transcriptions.map(\.formattedString)
                    once.finish(texts.isEmpty ? .failed : .done(texts))
                } else if error != nil {
                    // 识别器报错：按基础设施异常处理，不记成「读错」
                    once.finish(.timedOut)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                task.cancel()
                once.finish(.timedOut)
            }
        }

        return outcome
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

    /// 指出不一致的位置：多词短语先说漏词，再退到开头 / 结尾 / 中间
    static func difference(target: String, heard: String) -> String? {
        let targetTokens = normalize(target).split(separator: " ").map(String.init)
        let heardTokens = normalize(heard).split(separator: " ").map(String.init)
        if targetTokens.count > 1 || heardTokens.count > 1 {
            let missing = targetTokens.filter { !heardTokens.contains($0) }
            if !missing.isEmpty { return "漏了 \(missing.joined(separator: "、"))" }
            let extra = heardTokens.filter { !targetTokens.contains($0) }
            if !extra.isEmpty { return "多了 \(extra.joined(separator: "、"))" }
        }

        let a = Array(normalize(target).replacingOccurrences(of: " ", with: ""))
        let b = Array(normalize(heard).replacingOccurrences(of: " ", with: ""))
        guard !a.isEmpty, !b.isEmpty else { return nil }
        if a == b { return nil }

        var prefix = 0
        while prefix < min(a.count, b.count), a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(a.count, b.count) - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }

        if prefix == 0 { return "开头不一样" }
        if prefix >= a.count || prefix >= b.count { return "结尾不一样" }
        if prefix <= 1 { return "开头不一样" }
        return "中间不一样"
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
private final class ResumeOnce<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func finish(_ value: Value) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}
