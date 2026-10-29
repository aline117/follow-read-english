import SwiftUI

/// 家长 · 媒体日志（tasks 15.6）：只看与媒体有关的事件，可单独清空。
struct MediaDiagnosticsView: View {
    @State private var entries: [DiagnosticsLog.Entry] = []
    @State private var confirmClear = false

    var body: some View {
        List {
            if entries.isEmpty {
                Text("还没有媒体日志")
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entry.event)
                                .font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Text(entry.at.formatted(date: .abbreviated, time: .standard))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        if !entry.detail.isEmpty {
                            Text(entry.detail
                                .sorted { $0.key < $1.key }
                                .map { "\($0.key)=\($0.value)" }
                                .joined(separator: " · "))
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("媒体日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("清空", role: .destructive) { confirmClear = true }
                    .disabled(entries.isEmpty)
            }
        }
        .confirmationDialog("清空媒体日志？", isPresented: $confirmClear) {
            Button("清空", role: .destructive) {
                DiagnosticsLog.clearMedia()
                reload()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只清媒体相关事件，学习与家长操作日志保留。")
        }
        .task { reload() }
    }

    private func reload() {
        entries = DiagnosticsLog.mediaEntries().reversed()
    }
}
