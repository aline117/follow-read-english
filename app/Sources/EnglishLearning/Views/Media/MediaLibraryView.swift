import SwiftUI

/// 「听和看」媒体库（tasks 14.1 / 14.4）：儿歌 / 绘本两个分区，带下载状态、时长与续播进度。
/// 没有 `media.json` 时只显示空状态，不影响课本学习。
struct MediaLibraryView: View {
    let profile: Profile

    @Environment(\.dismiss) private var dismiss
    @State private var library = MediaLibrary.shared
    @State private var downloads = MediaDownloader.shared
    @State private var settings = MediaSettingsStore.shared
    @State private var refreshing = false
    @State private var selectedID: String?

    var body: some View {
        VStack(spacing: 0) {
            topBar

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    limitBanner
                    content
                }
                .padding(.horizontal, 40)
                .padding(.top, 18)
                .padding(.bottom, 26)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task { await load() }
        .navigationDestination(item: $selectedID) { id in
            if let item = library.items.first(where: { $0.id == id }) {
                MediaPlayerView(profile: profile, item: item)
            }
        }
    }

    // MARK: - 顶栏

    private var topBar: some View {
        HStack(spacing: 14) {
            Button {
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
                Text("听和看")
                    .font(.system(size: 21, weight: .heavy))
                    .foregroundStyle(Theme.ink)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
            }

            Spacer()

            Text("\(library.songs.count) 首儿歌 · \(library.pictures.count) 段绘本")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.blueInk)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(Theme.blueSoft)
                .clipShape(Capsule())
        }
        .padding(.horizontal, 26)
        .frame(height: 80)
        .background(Color.white)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line).frame(height: 2)
        }
    }

    private var subtitle: String {
        if settings.isAreaDisabled { return "今天不能看视频（家长设为 0 分钟）" }
        if let remaining = settings.remainingToday(profileID: profile.id) {
            return "今天还能看 \(max(0, Int(ceil(remaining / 60)))) 分钟"
        }
        return "不限观看时长"
    }

    // MARK: - 今日上限

    @ViewBuilder
    private var limitBanner: some View {
        if settings.isAreaDisabled {
            banner("今天不能看视频", "家长把每日观看时间设成了 0；学习任务照常可以做。", color: Theme.orangeDark)
        } else if !settings.canStartNewItem(profileID: profile.id) {
            banner("今天看够啦", "明天再来；当前这条播放完就会停下。", color: Theme.orangeDark)
        }
    }

    private func banner(_ title: String, _ message: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "hourglass")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .heavy)).foregroundStyle(Theme.ink)
                Text(message).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.orangeSoft)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Theme.orangeLine, lineWidth: 2))
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        switch library.state {
        case .ready:
            if library.songs.isEmpty && library.pictures.isEmpty {
                emptyState(title: "媒体清单是空的", message: "让家长在家里电脑上生成 media.json。")
            } else {
                section("儿歌", items: library.songs)
                if !library.pictures.isEmpty {
                    section("绘本", items: library.pictures)
                }
            }
        case .missing:
            emptyState(title: "还没有媒体清单",
                       message: "家里电脑开着内容服务时，点重试会自动拉取；也可以让家长先在家长模式里下载。")
        case .requiresAppUpdate(let version):
            emptyState(title: "需要更新 App",
                       message: "媒体清单版本 \(version) 比当前 App 新；本地缓存已保留。")
        case .broken(let message):
            emptyState(title: "媒体清单损坏", message: message)
        }
    }

    private func section(_ title: String, items: [MediaAsset]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 18, weight: .heavy))
                    .foregroundStyle(Theme.ink)
                Text("\(items.count)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.chipBg)
                    .clipShape(Capsule())
                Spacer()
            }
            ForEach(items) { item in
                let status = downloads.status(for: item.id)
                Button {
                    // tasks 12.4：校验失败的坏项不可播，点一下重下；其余项照常打开
                    if case .corrupted = status {
                        retryDownload(item)
                    } else {
                        selectedID = item.id
                    }
                } label: {
                    row(item, status: status)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 4)
    }

    private func row(_ item: MediaAsset, status: MediaDownloader.Status) -> some View {
        let state = MediaStateStore.shared.itemState(item.id, profileID: profile.id)
        let duration = MediaStateStore.shared.displayDuration(for: item)
        let cached = MediaCacheStore.shared.isCached(item.id)
        let progress = (duration ?? 0) > 0 ? min(1, state.positionSec / (duration ?? 1)) : 0
        // tasks 12.4：只有校验失败的坏项被拦下，其余（含「下载失败但可在线播放」）照常可播
        let corrupted: Bool = {
            if case .corrupted = status { return true }
            return false
        }()

        return HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: 0xDFF4FB), Color(hex: 0xBCE9F7)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: item.kind == .song ? "music.note" : "book.fill")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Theme.blueInk)
            }
            .frame(width: 64, height: 64)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if let duration {
                        Text(Self.clock(duration))
                    } else {
                        Text("未看过")
                    }
                    if cached && !corrupted {
                        Label("已下载", systemImage: "arrow.down.circle.fill")
                            .foregroundStyle(Theme.greenInk)
                    }
                    if state.positionSec > 1 {
                        Text("看到 \(Self.clock(state.positionSec))")
                            .foregroundStyle(Theme.orangeDark)
                    }
                }
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.muted)

                downloadStatusLine(status)

                if progress > 0.01 {
                    KidProgressBar(value: progress, tint: .orange, height: 6)
                        .frame(maxWidth: 360)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: corrupted ? "arrow.clockwise.circle.fill" : "play.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(corrupted ? Theme.red : Theme.orange)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous)
            .strokeBorder(corrupted ? Theme.red.opacity(0.5) : Theme.line, lineWidth: 2))
    }

    /// tasks 12.3：把逐项下载状态接进列表（进度 / 已下好 / 内容损坏 / 下载失败）
    @ViewBuilder
    private func downloadStatusLine(_ status: MediaDownloader.Status) -> some View {
        switch status {
        case .downloading(let progress):
            HStack(spacing: 8) {
                Text("下载中 \(Int((progress * 100).rounded()))%")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.blueInk)
                KidProgressBar(value: progress, tint: .green, height: 6)
                    .frame(maxWidth: 220)
            }
        case .corrupted:
            Label("内容损坏 · 点一下重新下载", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.red)
        case .failed(let message):
            Label("下载失败（可在线播放）· \(message)", systemImage: "wifi.exclamationmark")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.orangeDark)
                .lineLimit(2)
        case .ready, .idle:
            EmptyView()
        }
    }

    /// 坏项重下：清掉旧的坏状态，重新入队（并发仍由 `MediaDownloader` 控制）
    private func retryDownload(_ item: MediaAsset) {
        guard let base = library.baseURL else { return }
        downloads.enqueue(item, baseURL: base, limitGB: settings.cacheLimitGB)
    }

    private func emptyState(title: String, message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles.tv")
                .font(.system(size: 44))
                .foregroundStyle(Theme.blueInk)
            Text(title)
                .font(.system(size: 20, weight: .heavy))
                .foregroundStyle(Theme.ink)
            Text(message)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            Button {
                Task { await reload() }
            } label: {
                KidButtonLabel(title: refreshing ? "正在连接…" : "重试",
                               systemImage: "arrow.clockwise")
                    .frame(width: 180)
            }
            .buttonStyle(KidButtonStyle())
            .disabled(refreshing)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .kidCard()
    }

    private func load() async {
        library.loadLocal()
        if library.state == .missing {
            await reload()
        }
    }

    private func reload() async {
        refreshing = true
        await library.refresh()
        refreshing = false
    }

    private static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
