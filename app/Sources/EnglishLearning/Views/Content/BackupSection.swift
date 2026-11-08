import SwiftData
import SwiftUI

/// 家长模式 → 内容管理 → 「备份」卡片（tasks 18.4 / 18.5）。
///
/// 家里电脑上的 content-service 顺手做在线备份：孩子每天的学习记录每 24 小时
/// 自动传一次，家长也能手动「立即备份」；换机或重装后从这里挑一份恢复。
struct BackupSection: View {
    @Environment(\.modelContext) private var modelContext

    private var remote = BackupRemoteService.shared

    @State private var showPicker = false
    @State private var isBackingUp = false
    @State private var outcome: Outcome?

    private struct Outcome: Identifiable {
        let id = UUID()
        let title: String
        let detail: String
        let isError: Bool
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(remote.lastUploadDescription)
                    .font(.callout.weight(.medium))
                if let name = remote.lastUploadName {
                    Text(name)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
                if let error = remote.lastError, !remote.isBusy {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(.vertical, 2)

            Button {
                Task { await backupNow() }
            } label: {
                HStack {
                    Label("立即备份", systemImage: "arrow.up.to.line")
                    Spacer()
                    if isBackingUp || remote.isBusy { ProgressView() }
                }
            }
            .disabled(isBackingUp || remote.isBusy)

            Button {
                showPicker = true
            } label: {
                Label("从家里电脑恢复", systemImage: "arrow.down.to.line")
            }
            .disabled(isBackingUp || remote.isBusy)
        } header: {
            Text("备份")
        } footer: {
            Text("连上家里 Wi-Fi 后每 24 小时自动传一次，学习记录只存在你自己家的电脑上。换机或重装时用下面的「从家里电脑恢复」。")
        }
        .sheet(isPresented: $showPicker) {
            RemoteBackupPicker { item in
                showPicker = false
                Task { await restore(item) }
            }
        }
        .alert(item: $outcome) { outcome in
            Alert(
                title: Text(outcome.title),
                message: Text(outcome.detail),
                dismissButton: .default(Text("知道了"))
            )
        }
    }

    // MARK: - 动作

    private func backupNow() async {
        isBackingUp = true
        defer { isBackingUp = false }
        let ok = await remote.backupNow(context: modelContext, baseURL: ContentInstaller.storedBaseURL)
        if ok {
            outcome = Outcome(title: "备份完成",
                              detail: "已经传到家里电脑，文件名 \(remote.lastUploadName ?? "-")。",
                              isError: false)
        } else if let error = remote.lastError {
            outcome = Outcome(title: "备份没成功", detail: error, isError: true)
        }
    }

    private func restore(_ item: RemoteBackupItem) async {
        guard let baseURL = ContentInstaller.storedBaseURL else { return }
        do {
            let data = try await remote.download(item, baseURL: baseURL)
            let file = try BackupService.decode(data)
            let counts = try BackupService.restore(file, into: modelContext)

            var details = [
                "备份时间：\(item.backupTime.formatted(date: .numeric, time: .shortened))",
                "孩子 \(counts["profiles"] ?? 0) 位 · 学习明细 \(counts["attempts"] ?? 0) 条 · 星星流水 \(counts["starLedger"] ?? 0) 条"
            ]
            // 课程内容不在备份里，得让家长知道要重下哪些学期
            let installed = Set(ContentStorage.installedPacks().map(\.id))
            let missing = file.payload.installedSemesters.filter { !installed.contains($0) }
            if !missing.isEmpty {
                details.append("备份里有 \(missing.count) 个学期本机没装（\(missing.joined(separator: "、"))），去上面的「可下载学期」重下即可。")
            }
            if !ParentAuth.hasPin {
                details.append("家长 PIN 不在备份里，请重新设置一次。")
            }
            outcome = Outcome(title: "恢复完成", detail: details.joined(separator: "\n\n"), isError: false)
        } catch {
            outcome = Outcome(title: "恢复失败",
                              detail: error.localizedDescription + "\n\n本机数据没有被改动。",
                              isError: true)
        }
    }
}

// MARK: - 选择一份备份

private struct RemoteBackupPicker: View {
    let onPick: (RemoteBackupItem) -> Void

    @Environment(\.dismiss) private var dismiss
    private var remote = BackupRemoteService.shared

    @State private var items: [RemoteBackupItem] = []
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var pending: RemoteBackupItem?

    var body: some View {
        NavigationStack {
            List {
                if isLoading {
                    HStack {
                        ProgressView()
                        Text("正在读取备份列表…").font(.callout).foregroundStyle(.secondary)
                    }
                } else if let errorText {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("连不上家里的电脑")
                            .font(.callout.weight(.medium))
                        Text(errorText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("重试") { Task { await load() } }
                            .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 4)
                } else if items.isEmpty {
                    Text("家里电脑上还没有备份。先在孩子这台 iPad 上点一次「立即备份」。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Section {
                        ForEach(items) { item in
                            Button {
                                pending = item
                            } label: {
                                row(item)
                            }
                            .tint(.primary)
                        }
                    } footer: {
                        Text("恢复会把这台 iPad 上的学习记录整包替换成备份里的内容，不能撤销。")
                    }
                }
            }
            .navigationTitle("选择备份")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await load() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
            }
            .task { await load() }
            .confirmationDialog("用这份备份覆盖本机数据？",
                                isPresented: Binding(get: { pending != nil },
                                                     set: { if !$0 { pending = nil } }),
                                presenting: pending) { item in
                Button("覆盖恢复", role: .destructive) {
                    pending = nil
                    onPick(item)
                }
                Button("取消", role: .cancel) { pending = nil }
            } message: { item in
                Text("\(item.backupTime.formatted(date: .numeric, time: .shortened)) · \(item.sizeText)\n当前的学习进度、星星、徽章会被替换，且无法撤销。")
            }
        }
    }

    private func row(_ item: RemoteBackupItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.backupTime.formatted(date: .abbreviated, time: .shortened))
                .font(.body.weight(.medium))
            Text("\(item.sizeText) · 设备 \(item.shortDeviceID)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func load() async {
        guard let baseURL = ContentInstaller.storedBaseURL else {
            isLoading = false
            errorText = "内容服务地址格式不对，回上一页重新填。"
            return
        }
        isLoading = true
        errorText = nil
        do {
            items = try await remote.fetchIndex(baseURL: baseURL)
        } catch {
            errorText = error.localizedDescription
        }
        isLoading = false
    }
}
