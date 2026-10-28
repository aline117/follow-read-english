import AVFoundation
import Observation
import SwiftData
import SwiftUI
import UIKit

/// 媒体跟读（tasks 14.2 / 14.6 / 14.3）：绘本逐句、儿歌抽 2–3 句。
/// 复用 `AudioRecorder` + `PronunciationEvaluator` + `StarService`；
/// `grantKey = m:<itemID>#s<句号>`（绘本）/ `#l<句号>`（儿歌）。
struct MediaFollowReadView: View {
    let profile: Profile
    let item: MediaAsset
    let sourceURL: URL?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var recorder = AudioRecorder()
    @State private var linePlayer = LineSegmentPlayer()
    @State private var index: Int
    @State private var phase: Phase = .idle
    @State private var assessment: PronunciationAssessment?
    @State private var failures = 0
    @State private var micDenied = false
    @State private var errorMessage: String?
    @State private var stars = 0
    @State private var showSummary = false
    @State private var advanceTask: Task<Void, Never>?
    @State private var burst = false

    private enum Phase {
        case idle
        case recording
        case assessing
        case result
    }

    init(profile: Profile, item: MediaAsset, sourceURL: URL?) {
        self.profile = profile
        self.item = item
        self.sourceURL = sourceURL
        let state = MediaStateStore.shared.itemState(item.id, profileID: profile.id)
        let first = item.lines.firstIndex { !state.passedLines.contains($0.index) } ?? 0
        _index = State(initialValue: min(first, max(0, item.lines.count - 1)))
    }

    private var lines: [MediaLine] { item.lines }
    private var line: MediaLine? { lines.indices.contains(index) ? lines[index] : nil }

    var body: some View {
        VStack(spacing: 0) {
            topBar

            if lines.isEmpty {
                emptyState
            } else if let line {
                ScrollView {
                    VStack(spacing: 18) {
                        lineCard(line)
                        stage
                        footer
                    }
                    .padding(.horizontal, 40)
                    .padding(.top, 18)
                    .padding(.bottom, 30)
                }
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            recorder.onFinish = handleRecording
            recorder.onInterrupted = handleInterruption
        }
        .onDisappear {
            advanceTask?.cancel()
            recorder.cleanUp()
            linePlayer.stop()
        }
        .onChange(of: showSummary) { _, show in
            if show { linePlayer.stop() }
        }
        .sheet(isPresented: $showSummary, onDismiss: { dismiss() }) {
            summarySheet
                .presentationDetents([.height(380)])
                .presentationDragIndicator(.hidden)
        }
        .alert("麦克风被拒", isPresented: $micDenied) {
            Button("去设置") { openSettings() }
            Button("先跳过", role: .cancel) { skipLine() }
        } message: {
            Text("跟读要用麦克风；录音只在 iPad 上，不会上传。")
        }
    }

    // MARK: - 顶栏

    private var topBar: some View {
        HStack(spacing: 14) {
            Button {
                linePlayer.stop()
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 19, weight: .heavy))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Text(item.kind == .picture ? "绘本逐句跟读" : "儿歌跟读")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.muted)
            }

            Spacer()

            Text("第 \(index + 1) / \(lines.count) 句")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.muted)

            StarPill(stars: starBalance)
        }
        .padding(.horizontal, 26)
        .frame(height: 76)
        .background(Color.white)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line).frame(height: 2)
        }
    }

    // MARK: - 句子 / 播放

    private func lineCard(_ line: MediaLine) -> some View {
        VStack(spacing: 12) {
            Text(line.text)
                .font(.system(size: 30, weight: .heavy))
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.6)
                .lineLimit(4)

            Button {
                playLine(line)
            } label: {
                Label(linePlayer.isPlaying ? "正在播…" : "听这句",
                      systemImage: linePlayer.isPlaying ? "stop.fill" : "play.fill")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .frame(height: 48)
                    .background(Theme.blue)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(sourceURL == nil)
            .opacity(sourceURL == nil ? 0.5 : 1)

            if line.startSec == nil || line.endSec == nil {
                Text("这句还没标注起止时间，录完仍可判定")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.faint)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .padding(.horizontal, 24)
        .kidCard()
    }

    private func playLine(_ line: MediaLine) {
        guard let sourceURL else { return }
        if linePlayer.isPlaying {
            linePlayer.stop()
            return
        }
        linePlayer.play(url: sourceURL, start: line.startSec, end: line.endSec)
    }

    // MARK: - 录音 / 结果

    @ViewBuilder
    private var stage: some View {
        switch phase {
        case .idle:
            VStack(spacing: 12) {
                micButton(active: false, symbol: "mic.fill", tint: Theme.orange)
                Text("听会了？点麦克风读一遍")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                if let errorMessage {
                    Text(errorMessage).font(.system(size: 12.5)).foregroundStyle(Theme.red)
                } else {
                    Text("最多录 \(Int(recordingLimit.rounded())) 秒")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.faint)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .kidCard()
        case .recording:
            VStack(spacing: 10) {
                micButton(active: true, symbol: "stop.fill", tint: Theme.red) {
                    recorder.stop()
                }
                MediaWaveform(level: recorder.level)
                Text("正在听你说…").font(.system(size: 16, weight: .semibold))
                Text("还剩 \(Int(ceil(recorder.remaining))) 秒")
                    .font(.system(size: 12.5).monospacedDigit())
                    .foregroundStyle(Theme.faint)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .kidCard()
        case .assessing:
            VStack(spacing: 14) {
                ProgressView().controlSize(.large).tint(Theme.orange)
                Text("正在和原声对比…").font(.system(size: 16, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
            .kidCard()
        case .result:
            resultCard
        }
    }

    @ViewBuilder
    private var resultCard: some View {
        if let assessment {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: assessment.isPassed ? "checkmark.seal.fill" : "arrow.clockwise.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(assessment.isPassed ? Theme.greenInk : Theme.orangeDark)
                    Text(assessment.headline)
                        .font(.system(size: 20, weight: .heavy))
                }
                Text(assessment.advice)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                if !assessment.isPassed, let heard = assessment.recognizedText, !heard.isEmpty {
                    Text("听到的是「\(heard)」" + (assessment.difference.map { " · \($0)" } ?? ""))
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.orangeDark)
                        .lineLimit(2)
                }

                if assessment.isPassed {
                    Text("准备下一句…")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.greenInk)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(Theme.greenSoft)
                        .clipShape(Capsule())
                } else {
                    HStack(spacing: 10) {
                        Button { startRecording() } label: {
                            KidButtonLabel(title: "再读一次", systemImage: "mic.fill", compact: true)
                        }
                        .buttonStyle(KidButtonStyle())
                        Button { skipLine() } label: {
                            KidButtonLabel(title: "先跳过", style: .ghost, compact: true)
                        }
                        .buttonStyle(KidButtonStyle())
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(16)
            .background(assessment.isPassed ? Theme.greenSoft : Theme.orangeSoft)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(alignment: .center) {
                if burst {
                    Text("＋1 ★")
                        .font(.system(size: 38, weight: .black))
                        .foregroundStyle(Theme.orange)
                        .allowsHitTesting(false)
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
    }

    private var footer: some View {
        Text("跟读通过 +1 星；同一句重复通过不重复发星")
            .font(.system(size: 12))
            .foregroundStyle(Theme.faint)
            .multilineTextAlignment(.center)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "text.bubble")
                .font(.system(size: 40))
                .foregroundStyle(Theme.blueInk)
            Text("这段还没有可跟读的句子")
                .font(.system(size: 19, weight: .heavy))
            Text("先看视频就好；等 media.json 补上句子再来。")
                .font(.system(size: 13)).foregroundStyle(Theme.muted)
            Button("返回") { dismiss() }
                .buttonStyle(KidButtonStyle())
                .frame(width: 180)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 动作

    private var recordingLimit: TimeInterval {
        let segment = lineDuration ?? 2
        return min(12, max(4.5, segment + 2.5))
    }

    private var lineDuration: TimeInterval? {
        guard let line, let start = line.startSec, let end = line.endSec, end > start else { return nil }
        return end - start
    }

    private func startRecording() {
        linePlayer.stop()
        recorder.maxDuration = recordingLimit
        Task {
            switch await recorder.start() {
            case .started:
                assessment = nil
                errorMessage = nil
                phase = .recording
            case .denied:
                micDenied = true
            case .failed(let message):
                errorMessage = message
            }
        }
    }

    private func handleRecording(_ recording: AudioRecorder.Recording) {
        guard let line else { return }
        phase = .assessing
        Task {
            let result = await PronunciationEvaluator.shared.assess(
                recording: recording,
                referenceURL: nil,
                target: line.text,
                referenceDuration: lineDuration
            )
            assessment = result
            phase = .result
            if result.isPassed {
                recordPass(line)
                burst = true
                advanceTask?.cancel()
                advanceTask = Task {
                    try? await Task.sleep(nanoseconds: 1_300_000_000)
                    guard !Task.isCancelled else { return }
                    burst = false
                    advance()
                }
            } else {
                failures += 1
                MediaStateStore.shared.recordLineRetry(item.id, profileID: profile.id)
            }
        }
    }

    private func recordPass(_ line: MediaLine) {
        let firstTry = failures == 0
        MediaStateStore.shared.recordLinePassed(item.id, line: line.index,
                                                firstTry: firstTry, profileID: profile.id)
        // MediaAsset.id 已带 `m:` 前缀，别再重复加一层
        let key = item.kind == .picture
            ? "\(item.id)#s\(line.index)"
            : "\(item.id)#l\(line.index)"
        let result = StarService.grant(profileID: profile.id, amount: 1,
                                       reason: "跟读达标", key: key, in: modelContext)
        if case .granted = result {
            stars += 1
            DiagnosticsLog.log("media_followread_star", ["item": item.id, "line": "\(line.index)"])
        }
    }

    private func advance() {
        failures = 0
        assessment = nil
        phase = .idle
        errorMessage = nil
        if index + 1 < lines.count {
            index += 1
        } else {
            showSummary = true
        }
    }

    private func skipLine() {
        failures = 0
        assessment = nil
        phase = .idle
        advanceTask?.cancel()
        advance()
    }

    private func handleInterruption() {
        assessment = nil
        phase = .idle
        errorMessage = "刚才被打断了，再读一次"
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private var starBalance: Int {
        StarService.balance(profileID: profile.id, in: modelContext)
    }

    // MARK: - 结算

    private var summarySheet: some View {
        VStack(spacing: 14) {
            Text("🎉").font(.system(size: 44))
            Text("这段跟读完啦")
                .font(.system(size: 24, weight: .heavy))
                .foregroundStyle(Theme.ink)
            let state = MediaStateStore.shared.itemState(item.id, profileID: profile.id)
            Text("通过 \(state.passedLines.count) / \(lines.count) 句 · 本次 +\(stars) 星")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.orangeDark)
            Spacer(minLength: 4)
            Button {
                showSummary = false
            } label: {
                KidButtonLabel(title: "完成")
            }
            .buttonStyle(KidButtonStyle())
            .padding(.horizontal, 24)
        }
        .padding(.top, 26)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }

    // MARK: - 小控件

    private func micButton(active: Bool, symbol: String, tint: Color, action: (() -> Void)? = nil) -> some View {
        Button {
            if let action { action() } else { startRecording() }
        } label: {
            ZStack {
                Circle().fill(tint).frame(width: 104, height: 104)
                    .shadow(color: tint.opacity(0.35), radius: 0, x: 0, y: 6)
                Image(systemName: symbol)
                    .font(.system(size: 38, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 132, height: 132)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(active ? "结束录音" : "开始跟读")
    }
}

// MARK: - 句子片段播放

@MainActor
@Observable
private final class LineSegmentPlayer {
    let player = AVPlayer()
    private(set) var isPlaying = false
    private var observer: Any?

    func play(url: URL, start: Double?, end: Double?) {
        stop()
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)

        let item = AVPlayerItem(url: url)
        if let end {
            item.forwardPlaybackEndTime = CMTime(seconds: end, preferredTimescale: 600)
        }
        player.replaceCurrentItem(with: item)
        if let start, start > 0 {
            player.seek(to: CMTime(seconds: start, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
        }
        player.play()
        isPlaying = true

        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                if let end, time.seconds >= end - 0.08 {
                    self.player.pause()
                    self.isPlaying = false
                }
            }
        }
    }

    func stop() {
        player.pause()
        if let observer {
            player.removeTimeObserver(observer)
            self.observer = nil
        }
        player.replaceCurrentItem(with: nil)
        isPlaying = false
    }
}

private struct MediaWaveform: View {
    let level: CGFloat
    private static let factors: [CGFloat] = [0.45, 0.7, 1, 0.8, 0.55, 0.85, 1, 0.65, 0.4]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(Self.factors.enumerated()), id: \.offset) { _, factor in
                Capsule()
                    .fill(Theme.red.opacity(0.75))
                    .frame(width: 7, height: 10 + level * 44 * factor)
            }
        }
        .frame(height: 56)
        .animation(.easeOut(duration: 0.08), value: level)
    }
}
