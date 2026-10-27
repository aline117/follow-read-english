import AVFoundation
import SwiftUI
import UIKit

/// 「认·说」合练里的跟读面板：点麦克风 → 录音 → 和原音对比 → 达标 / 再试一次。
///
/// 只负责录音与反馈，进度写入、奖励、翻到下一个词由 `WordLearningView` 处理。
struct FollowReadPanel: View {
    /// 目标词（可能与原音文本一致，只用于识别对比与文案）
    let word: String
    /// 原音音频；缺失时降级为「只按音量 + 时长」判定
    let referenceURL: URL?
    /// 上层弹出结算页 / 页面切走时暂停：停录音、停播放
    var isPaused = false

    var onAssessment: (PronunciationAssessment) -> Void = { _ in }
    /// 连续失败 / 没有麦克风时允许先练下一个
    var onSkip: () -> Void = {}

    @State private var recorder = AudioRecorder()
    @State private var phase: Phase = .idle
    @State private var assessment: PronunciationAssessment?
    @State private var failures = 0
    @State private var micDenied = false
    @State private var errorMessage: String?
    /// 丢弃过期的评测结果（录音被取消 / 结算页弹出）
    @State private var assessmentID = UUID()
    /// 第一次点麦克风先看说明页，再弹系统授权（tasks 4.8）
    @AppStorage("micPrimerSeen") private var micPrimerSeen = false
    @State private var showMicPrimer = false

    private let player = AudioPlayer.shared

    private enum Phase {
        case idle
        case recording
        case assessing
        case result
    }

    var body: some View {
        VStack(spacing: 10) {
            header
            stage
                .frame(height: 248)
                .frame(maxWidth: .infinity)
            controls
            footer
        }
        .kidCard(padding: 20)
        .onAppear {
            recorder.onFinish = handleRecording
            recorder.onInterrupted = handleAudioInterruption
            wireAudioSession()
        }
        .onDisappear {
            let coordinator = AudioSessionCoordinator.shared
            coordinator.onInterruptionBegan = nil
            coordinator.onInterruptionEnded = nil
            coordinator.onRouteLost = nil
            coordinator.onMediaServicesReset = nil
            recorder.cleanUp()
            player.stop()
        }
        .sheet(isPresented: $showMicPrimer) {
            MicPermissionPrimer {
                micPrimerSeen = true
                showMicPrimer = false
                startRecording()
            } onLater: {
                showMicPrimer = false
            }
            .presentationDetents([.height(430)])
            .presentationDragIndicator(.hidden)
        }
        .onChange(of: isPaused) { _, paused in
            guard paused else { return }
            assessmentID = UUID()
            recorder.cancel()
            player.stop()
            if phase == .recording || phase == .assessing {
                assessment = nil
                phase = .idle
            }
        }
    }

    // MARK: - 标题

    private var header: some View {
        HStack(spacing: 8) {
            Text("认一认 · 说一说")
                .font(.system(size: 15, weight: .heavy))
                .foregroundStyle(Theme.ink)
            Spacer()
            if failures > 0 && phase != .result {
                Text("第 \(failures + 1) 次尝试")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.orangeDark)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Theme.orangeSoft)
                    .clipShape(Capsule())
            }
        }
    }

    // MARK: - 主区

    @ViewBuilder
    private var stage: some View {
        if micDenied {
            deniedStage
        } else {
            switch phase {
            case .idle:
                idleStage
            case .recording:
                recordingStage
            case .assessing:
                assessingStage
            case .result:
                resultStage
            }
        }
    }

    private var idleStage: some View {
        VStack(spacing: 12) {
            MicButton(active: false, symbol: "mic.fill", tint: Theme.orange) {
                startRecording()
            }
            .accessibilityLabel("开始跟读录音")

            Text("听会了？点麦克风读一遍")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.ink)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.red)
            } else {
                Text("最多录 \(Int(Self.recordingLimit(for: referenceURL).rounded())) 秒，读完点一下方块")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.faint)
            }
        }
    }

    private var recordingStage: some View {
        VStack(spacing: 10) {
            MicButton(active: true, symbol: "stop.fill", tint: Theme.red) {
                recorder.stop()
            }
            .accessibilityLabel("结束录音")

            Waveform(level: recorder.level, tint: Theme.red)

            Text("正在听你说…")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.ink)

            Text("还剩 \(Int(ceil(recorder.remaining))) 秒")
                .font(.system(size: 12.5).monospacedDigit())
                .foregroundStyle(Theme.faint)
        }
    }

    private var assessingStage: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
                .tint(Theme.orange)
            Text("正在和原音对比…")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Text("听听像不像，马上就好")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.faint)
        }
    }

    @ViewBuilder
    private var resultStage: some View {
        if let assessment {
            VStack(spacing: 10) {
                Image(systemName: assessment.isPassed ? "checkmark.seal.fill" : "arrow.clockwise.circle.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(assessment.isPassed ? Theme.greenInk : Theme.orangeDark)

                Text(assessment.headline)
                    .font(.system(size: 20, weight: .heavy))
                    .foregroundStyle(Theme.ink)

                Text(assessment.hint)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 8)

                if assessment.isPassed {
                    Text("准备下一个词…")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.greenInk)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(Theme.greenSoft)
                        .clipShape(Capsule())
                } else {
                    Button {
                        startRecording()
                    } label: {
                        KidButtonLabel(title: "再读一次", systemImage: "mic.fill", compact: true)
                            .frame(width: 170)
                    }
                    .buttonStyle(KidButtonStyle())
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(14)
            .background(assessment.isPassed ? Theme.greenSoft : Theme.orangeSoft)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private var deniedStage: some View {
        VStack(spacing: 12) {
            Image(systemName: "mic.slash.fill")
                .font(.system(size: 38))
                .foregroundStyle(Theme.red)
            Text("还没有麦克风权限")
                .font(.system(size: 18, weight: .heavy))
                .foregroundStyle(Theme.ink)
            Text("跟读要用麦克风录下你的声音（只在 iPad 上，不上传）。\n去设置里打开就能继续，也可以先跳过跟读。")
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button {
                    openSettings()
                } label: {
                    KidButtonLabel(title: "去设置", compact: true)
                }
                .buttonStyle(KidButtonStyle())

                Button {
                    onSkip()
                } label: {
                    KidButtonLabel(title: "先跳过", style: .ghost, compact: true)
                }
                .buttonStyle(KidButtonStyle())
            }
            .padding(.top, 2)
        }
    }

    // MARK: - 底部按钮

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                playReference()
            } label: {
                KidButtonLabel(title: "听原音", systemImage: "speaker.wave.2.fill",
                               style: .ghost, compact: true)
            }
            .buttonStyle(KidButtonStyle())
            .disabled(referenceURL == nil)
            .opacity(referenceURL == nil ? 0.5 : 1)

            if let url = assessment?.recordingURL {
                Button {
                    player.toggle(url: url)
                } label: {
                    KidButtonLabel(title: player.isPlaying(url) ? "停止我的录音" : "我的录音",
                                   systemImage: player.isPlaying(url) ? "stop.fill" : "play.fill",
                                   style: .ghost, compact: true)
                }
                .buttonStyle(KidButtonStyle())
            }
        }
    }

    private var footer: some View {
        Group {
            if failures >= 3 && phase != .result {
                Button {
                    onSkip()
                } label: {
                    Text("连续 3 次没达标 · 先练下一个 →")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.muted)
                        .underline()
                }
                .buttonStyle(.plain)
            } else if phase == .idle {
                Text("读完后会自动和原音对比，达标就进入下一个词")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.faint)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(height: 18)
    }

    // MARK: - 动作

    /// 音频会话事件接线（tasks 4.7）：来电/闹钟暂停播放，拔耳机丢录音
    private func wireAudioSession() {
        let coordinator = AudioSessionCoordinator.shared
        coordinator.start()
        coordinator.onInterruptionBegan = {
            player.pause()
            recorder.discardForInterruption()
        }
        coordinator.onInterruptionEnded = { shouldResume in
            if shouldResume { player.resume() }
        }
        coordinator.onRouteLost = {
            player.stop()
            recorder.discardForInterruption()
        }
        coordinator.onMediaServicesReset = {
            player.stop()
        }
    }

    /// 录音被系统打断：回到 idle 并提示重读（不写半截评测结果）
    private func handleAudioInterruption() {
        assessmentID = UUID()
        assessment = nil
        phase = .idle
        micDenied = false
        errorMessage = "刚才被打断了，再读一次"
    }

    private func startRecording() {
        // 第一次：先看说明页，同意后再弹系统授权（系统授权只能弹一次，不能浪费）
        if !micPrimerSeen, AVAudioApplication.shared.recordPermission == .undetermined {
            showMicPrimer = true
            return
        }
        player.stop()
        recorder.maxDuration = Self.recordingLimit(for: referenceURL)
        Task {
            switch await recorder.start() {
            case .started:
                assessmentID = UUID()
                assessment = nil
                errorMessage = nil
                micDenied = false
                phase = .recording
            case .denied:
                micDenied = true
                phase = .idle
            case .failed(let message):
                errorMessage = message
                phase = .idle
            }
        }
    }

    private func handleRecording(_ recording: AudioRecorder.Recording) {
        let id = UUID()
        assessmentID = id
        phase = .assessing
        Task {
            let result = await PronunciationEvaluator.shared.assess(recording: recording,
                                                                    referenceURL: referenceURL,
                                                                    target: word)
            guard assessmentID == id else { return }
            assessment = result
            if !result.isPassed { failures += 1 }
            phase = .result
            onAssessment(result)
        }
    }

    private func playReference() {
        guard let referenceURL else { return }
        player.toggle(url: referenceURL, rate: AudioPlayer.slowRate)
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// 录音上限跟着原音走：短语比单词长，留足「读完再停一下」的余量
    private static func recordingLimit(for referenceURL: URL?) -> TimeInterval {
        let reference = PronunciationEvaluator.referenceDuration(of: referenceURL) ?? 2
        return min(9, max(4.5, reference + 2.5))
    }
}

// MARK: - 麦克风按钮

private struct MicButton: View {
    let active: Bool
    let symbol: String
    let tint: Color
    let action: () -> Void

    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            ZStack {
                if active {
                    Circle()
                        .fill(tint.opacity(pulse && !reduceMotion ? 0.10 : 0.22))
                        .frame(width: 148, height: 148)
                        .scaleEffect(pulse && !reduceMotion ? 1.06 : 0.94)
                }
                Circle()
                    .fill(tint)
                    .frame(width: 100, height: 100)
                    .shadow(color: tint.opacity(0.35), radius: 0, x: 0, y: 6)
                Image(systemName: symbol)
                    .font(.system(size: 38, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 156, height: 156)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onAppear { pulse = true }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                   value: pulse)
    }
}

// MARK: - 实时音量柱

private struct Waveform: View {
    let level: CGFloat
    let tint: Color

    private static let factors: [CGFloat] = [0.45, 0.7, 1.0, 0.8, 0.55, 0.85, 1.0, 0.65, 0.4]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(Self.factors.enumerated()), id: \.offset) { _, factor in
                Capsule()
                    .fill(tint.opacity(0.75))
                    .frame(width: 7, height: 10 + level * 44 * factor)
            }
        }
        .frame(height: 56)
        .animation(.easeOut(duration: 0.08), value: level)
    }
}
