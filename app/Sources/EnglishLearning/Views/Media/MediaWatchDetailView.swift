import SwiftUI

/// 家长 · 今天看了什么（tasks 15.2 / 15.4 / 15.5）：只呈现事实。
/// 通过 x/N · 一次通过 y/N · 复读 z 次；无分数、等级、颜色分级与排名。
struct MediaWatchDetailView: View {
    let profile: Profile

    @State private var library = MediaLibrary.shared
    @State private var states: [String: MediaStateStore.ItemState] = [:]
    @State private var days: [(day: String, seconds: Double)] = []
    @State private var todaySeconds: Double = 0

    var body: some View {
        List {
            Section {
                LabeledContent("今天累计", value: Self.clock(todaySeconds))
                if let limit = MediaSettingsStore.shared.remainingToday(profileID: profile.id) {
                    LabeledContent("今日上限", value: "\(Int(round((limit + todaySeconds) / 60))) 分钟")
                } else {
                    LabeledContent("今日上限", value: "关闭")
                }
            } header: {
                Text("今天")
            }

            Section("今天看了什么") {
                if todayItems.isEmpty {
                    Text("今天还没有看视频")
                        .font(.system(size: 13.5))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(todayItems, id: \.id) { item in
                        row(item)
                    }
                }
            }

            Section("近 7 天") {
                ForEach(days, id: \.day) { day in
                    LabeledContent(day.day, value: Self.clock(day.seconds))
                        .font(.system(size: 13.5))
                }
            }
        }
        .navigationTitle("今天看了什么")
        .navigationBarTitleDisplayMode(.inline)
        .task { reload() }
    }

    private var todayItems: [(id: String, asset: MediaAsset?, state: MediaStateStore.ItemState)] {
        let calendar = Calendar.current
        return states.compactMap { id, state in
            guard let last = state.lastWatchedAt, calendar.isDateInToday(last) else { return nil }
            return (id, library.items.first { $0.id == id }, state)
        }
        .sorted { ($0.state.lastWatchedAt ?? .distantPast) > ($1.state.lastWatchedAt ?? .distantPast) }
    }

    private func row(_ item: (id: String, asset: MediaAsset?, state: MediaStateStore.ItemState)) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.asset?.title ?? item.id)
                .font(.system(size: 15, weight: .semibold))
            HStack(spacing: 10) {
                Text("看了 \(Self.clock(item.state.watchedSec))")
                if let total = item.asset?.lines.count, total > 0 {
                    Text("通过 \(item.state.passedLines.count)/\(total)")
                    Text("一次通过 \(item.state.firstTryPassed.count)/\(total)")
                    Text("复读 \(item.state.retryCount) 次")
                }
            }
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func reload() {
        library.loadLocal()
        states = MediaStateStore.shared.allStates(profileID: profile.id)
        days = MediaStateStore.shared.dailyTotals(profileID: profile.id, days: 7)
        todaySeconds = MediaStateStore.shared.watchedToday(profileID: profile.id)
    }

    private static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
