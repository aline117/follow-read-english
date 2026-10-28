import SwiftUI

/// 家长 · 听和看设置（tasks 15.1 / 15.3）：每日上限、缓存上限、仅 Wi-Fi 预取、清缓存。
struct MediaSettingsView: View {
    @State private var settings = MediaSettingsStore.shared
    @State private var confirmClear = false
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Picker("每日观看上限", selection: $settings.dailyLimitMinutes) {
                    Text("0 分钟（不能看）").tag(0)
                    Text("5 分钟").tag(5)
                    Text("10 分钟").tag(10)
                    Text("15 分钟").tag(15)
                    Text("关闭（不限）").tag(-1)
                }
                .pickerStyle(.inline)
            } header: {
                Text("观看时间")
            } footer: {
                Text("只计正在播放的时间；到达上限时当前一条可以播完，之后不能开新条目。")
            }

            Section {
                Picker("缓存上限", selection: $settings.cacheLimitGB) {
                    ForEach(MediaCacheStore.limitOptions, id: \.self) { value in
                        Text("\(value) GB").tag(value)
                    }
                }
                Toggle("只在 Wi-Fi 下预取", isOn: $settings.wifiOnlyPrefetch)
            } header: {
                Text("缓存")
            } footer: {
                Text("当前占用 \(Self.bytes(MediaCacheStore.shared.totalBytes)) · 可用空间 \(Self.freeSpace)")
            }

            Section {
                Button(role: .destructive) {
                    confirmClear = true
                } label: {
                    Label("清除全部媒体缓存", systemImage: "trash")
                }
            } footer: {
                Text("只删除已下载的视频，不删除观看记录与星星；之后再看会重新从家里电脑串流。")
            }
        }
        .navigationTitle("听和看设置")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("清除全部媒体缓存？", isPresented: $confirmClear) {
            Button("清除", role: .destructive) { clearCache() }
            Button("取消", role: .cancel) {}
        }
        .alert("已清除", isPresented: Binding(get: { message != nil },
                                             set: { if !$0 { message = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
        .onChange(of: settings.dailyLimitMinutes) { _, value in
            ParentAuth.audit("media_daily_limit_\(value)")
        }
        .onChange(of: settings.cacheLimitGB) { _, value in
            ParentAuth.audit("media_cache_limit_\(value)")
        }
        .onChange(of: settings.wifiOnlyPrefetch) { _, value in
            ParentAuth.audit("media_wifi_only_\(value ? 1 : 0)")
        }
    }

    private func clearCache() {
        MediaCacheStore.shared.removeAll()
        MediaDownloader.shared.forgetAll()
        ParentAuth.audit("media_cache_cleared")
        message = "缓存已清空，可用空间 \(Self.freeSpace)"
    }

    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private static var freeSpace: String {
        guard let values = try? MediaCacheStore.directory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let free = values.volumeAvailableCapacityForImportantUsage else { return "—" }
        return ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
    }
}
