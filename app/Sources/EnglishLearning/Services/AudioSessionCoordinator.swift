import AVFoundation
import Foundation
import Observation

/// 音频会话与中断（tasks 4.7，design「音频会话与中断」）：
/// - 来电 / 闹钟等系统打断：暂停播放并记住状态，`.shouldResume` 时恢复
/// - 拔耳机等路由丢失：立刻停播、丢弃正在录的音
/// - 媒体服务重置：把播放器状态清干净，避免下一次播放卡死
///
/// 只做"事件分发"，具体怎么做由播放器 / 录音器自己决定。
@MainActor
@Observable
final class AudioSessionCoordinator {
    static let shared = AudioSessionCoordinator()

    private(set) var lastEvent: String?

    var onInterruptionBegan: (() -> Void)?
    var onInterruptionEnded: ((Bool) -> Void)?
    var onRouteLost: (() -> Void)?
    var onMediaServicesReset: (() -> Void)?

    private var observers: [NSObjectProtocol] = []

    private init() {}

    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default

        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                           object: AVAudioSession.sharedInstance(),
                                           queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                self?.handleInterruption(note)
            }
        })

        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                           object: AVAudioSession.sharedInstance(),
                                           queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                self?.handleRouteChange(note)
            }
        })

        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                           object: AVAudioSession.sharedInstance(),
                                           queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.lastEvent = "mediaServicesReset"
                DiagnosticsLog.log("audio_session_reset")
                self?.onMediaServicesReset?()
            }
        })
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    // MARK: - 事件

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            lastEvent = "interruptionBegan"
            DiagnosticsLog.log("audio_interruption_began")
            onInterruptionBegan?()
        case .ended:
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume)
            lastEvent = "interruptionEnded(\(shouldResume))"
            DiagnosticsLog.log("audio_interruption_ended", ["shouldResume": "\(shouldResume)"])
            onInterruptionEnded?(shouldResume)
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        // 拔掉耳机：不能突然从扬声器放出声音，也不能留着半截录音
        guard reason == .oldDeviceUnavailable else { return }
        lastEvent = "routeLost"
        DiagnosticsLog.log("audio_route_lost")
        onRouteLost?()
    }
}
