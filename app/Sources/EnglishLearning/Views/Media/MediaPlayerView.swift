import AVFoundation
import SwiftUI

/// 媒体播放页（tasks 13.1 / 13.4）：自绘控件、缓存优先、串流降级、续播。
/// 不做画中画 / AirPlay；跟读入口留到 14.2 / 14.6。
struct MediaPlayerView: View {
    let profile: Profile
    let item: MediaAsset

    @Environment(\.dismiss) private var dismiss
    @State private var service = MediaPlayerService()
    @State private var showFollowReadNote = false
    @State private var scrub: Double?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerSurface(player: service.player)
                .ignoresSafeArea()

            LinearGradient(colors: [.black.opacity(0.55), .clear, .black.opacity(0.75)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                statusOverlay
                Spacer(minLength: 0)
                bottomControls
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
        }
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden(true)
        .onAppear { service.open(item, profileID: profile.id) }
        .onDisappear { service.close() }
        .onChange(of: service.state) { _, state in
            if state == .ended { scrub = nil }
        }
        .alert("跟读还没做", isPresented: $showFollowReadNote) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("媒体跟读属于 tasks 14.2 / 14.6，下一版接。")
        }
    }

    // MARK: - 顶栏

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("返回")

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 20, weight: .heavy))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(item.kind == .song ? "儿歌" : "绘本 · 第 \(max(1, item.part)) 部")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.7))
            }

            Spacer(minLength: 0)

            if service.isUsingCache {
                Label("已下载", systemImage: "arrow.down.circle.fill")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(.white.opacity(0.18))
                    .clipShape(Capsule())
            }
        }
    }

    // MARK: - 中间状态

    @ViewBuilder
    private var statusOverlay: some View {
        switch service.state {
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                if let progress = service.downloadProgress {
                    Text("正在下载到 iPad… \(Int(progress * 100))%")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                } else {
                    Text("正在加载…")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .background(.black.opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        case .blocked(let message), .failed(let message):
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Theme.orange)
                Text(message)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                HStack(spacing: 12) {
                    Button("返回") { dismiss() }
                        .buttonStyle(PlayerPillStyle())
                    Button("重试") { service.retry() }
                        .buttonStyle(PlayerPillStyle(primary: true))
                }
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .background(.black.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        case .playing, .paused, .ended, .idle:
            EmptyView()
        }
    }

    // MARK: - 底部控件

    private var bottomControls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Text(Self.clock(scrub ?? service.position))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 52, alignment: .trailing)

                Slider(value: Binding(
                    get: { scrub ?? service.position },
                    set: { scrub = $0 }
                ), in: 0...max(service.duration, 1), onEditingChanged: { editing in
                    if !editing, let value = scrub {
                        service.seek(to: value)
                        scrub = nil
                    }
                })
                .tint(Theme.orange)
                .frame(height: 44)

                Text(Self.clock(service.duration))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 52, alignment: .leading)
            }

            HStack(spacing: 18) {
                Button {
                    service.togglePlay()
                } label: {
                    Image(systemName: playSymbol)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 72, height: 72)
                        .background(Theme.orange)
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(service.isPlaying ? "暂停" : "播放")

                Button {
                    showFollowReadNote = true
                } label: {
                    Label("跟读", systemImage: "mic.fill")
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .frame(height: 48)
                        .background(.white.opacity(0.18))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)

                if service.state == .ended {
                    Button("重播") {
                        service.togglePlay()
                    }
                    .buttonStyle(PlayerPillStyle(primary: true))
                }
            }
        }
    }

    private var playSymbol: String {
        switch service.state {
        case .playing: return "pause.fill"
        case .ended: return "arrow.counterclockwise"
        default: return "play.fill"
        }
    }

    private static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - 视频画面

private struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: PlayerLayerView, context: Context) {
        uiView.playerLayer.player = player
    }
}

private final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

// MARK: - 小按钮样式

private struct PlayerPillStyle: ButtonStyle {
    var primary = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .heavy))
            .foregroundStyle(primary ? .black : .white)
            .padding(.horizontal, 22)
            .frame(height: 46)
            .background(primary ? Color.white : Color.white.opacity(0.18))
            .clipShape(Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
