import SwiftUI

/// 家长模式 → 内容管理（tasks 3.6）：探测内容服务、下载/更新/回退/删除学期包。
///
/// App 内零内容，这里是唯一的内容入口；下载一次后离线可学。
struct ContentManagementView: View {
    @State private var installer = ContentInstaller()
    @State private var pendingDelete: InstalledPack?

    private let library = ContentLibrary.shared
    private let catalog = ContentCatalog.bundled()

    var body: some View {
        List {
            serverSection

            if let progress = installer.progress {
                progressSection(progress)
            }

            downloadSection
            installedSection
        }
        .navigationTitle("内容管理")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if installer.phase == .idle {
                await installer.probe()
            }
        }
        .refreshable { await installer.probe() }
        .alert("删除这个学期包？", isPresented: deleteAlertBinding, presenting: pendingDelete) { pack in
            Button("删除", role: .destructive) {
                try? library.uninstall(pack)
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text("只会删掉本机的课文音频和图片，学习进度按条目码保留，重下就恢复。")
        }
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } })
    }

    // MARK: - 内容服务

    private var serverSection: some View {
        Section {
            TextField("http://<host>.local:8080", text: $installer.baseURLString)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .font(.callout.monospaced())

            HStack {
                Button {
                    Task { await installer.probe() }
                } label: {
                    Label("连接内容服务", systemImage: "antenna.radiowaves.left.and.right")
                }
                .disabled(installer.phase == .probing)

                Spacer()

                if installer.phase == .probing {
                    ProgressView()
                }
            }

            Text(statusText)
                .font(.caption)
                .foregroundStyle(statusColor)
        } header: {
            Text("内容服务地址")
        } footer: {
            Text("电脑上跑 _download/serve.py（或 serve.js）后，这里填它打印的 `<host>.local:8080`。只有连接和下载需要局域网。")
        }
    }

    private var statusText: String {
        switch installer.phase {
        case .idle:
            return "还没连接"
        case .probing:
            return "正在探测 manifest（2 秒超时）…"
        case .ready:
            let version = installer.serverSchemaVersion.map(String.init) ?? "-"
            return "已连接 · 服务端内容结构 v\(version) · \(installer.packs.count) 个学期"
        case .failed(let message):
            return message
        }
    }

    private var statusColor: Color {
        if case .failed = installer.phase { return .red }
        if case .ready = installer.phase { return .green }
        return .secondary
    }

    // MARK: - 进度

    private func progressSection(_ progress: ContentInstaller.Progress) -> some View {
        Section("正在处理 \(progress.packID)") {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: progress.fraction)
                    .tint(.orange)
                HStack {
                    Text(progress.phase)
                    Spacer()
                    Text("\(Int(progress.fraction * 100))%")
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - 可下载列表

    private var downloadSection: some View {
        Section {
            if installer.packs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(installer.phase == .probing ? "正在探测…" : "没有可用学期")
                        .font(.callout.weight(.medium))
                    Text("请在家里 Wi-Fi 下、电脑上启动内容服务后点「连接内容服务」。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !catalog.semesters.isEmpty {
                        Text("本地目录：\(catalog.semesters.map { $0.title }.joined(separator: "、"))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 2)
            } else {
                ForEach(installer.packs) { pack in
                    packRow(pack)
                }
            }
        } header: {
            Text("可下载学期")
        }
    }

    private func packRow(_ pack: ManifestPack) -> some View {
        let installed = library.installed.first { $0.id == pack.id }
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(pack.title)
                    .font(.body.weight(.medium))
                Text(packSubtitle(pack, installed: installed))
                    .font(.caption)
                    .foregroundStyle(pack.requiresAppUpdate ? .red : .secondary)
            }
            Spacer()
            packAction(pack, installed: installed)
        }
        .opacity(pack.requiresAppUpdate ? 0.55 : 1)
    }

    private func packSubtitle(_ pack: ManifestPack, installed: InstalledPack?) -> String {
        let size = ByteCountFormatter.string(fromByteCount: pack.sizeBytes, countStyle: .file)
        if pack.requiresAppUpdate {
            return "需要更新 App（内容结构 v\(pack.schemaVersion)）"
        }
        if let installed {
            if installed.contentVersion >= pack.contentVersion {
                return "已安装 v\(installed.contentVersion) · \(size) · 最新"
            }
            return "可更新：本机 v\(installed.contentVersion) → 服务端 v\(pack.contentVersion) · \(size)"
        }
        return "v\(pack.contentVersion) · \(size) · 未安装"
    }

    @ViewBuilder
    private func packAction(_ pack: ManifestPack, installed: InstalledPack?) -> some View {
        if pack.requiresAppUpdate {
            Text("不可下载")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let installed, installed.contentVersion >= pack.contentVersion {
            Button("重下") {
                Task { await installer.install(pack) }
            }
            .buttonStyle(.bordered)
            .disabled(installer.isBusy)
        } else {
            Button(installed == nil ? "下载" : "更新") {
                Task { await installer.install(pack) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(installer.isBusy)
        }
    }

    // MARK: - 已安装

    private var installedSection: some View {
        Section {
            if library.installed.isEmpty {
                Text("还没有安装任何学期，学习页会显示「还没有学习内容」。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(library.installed) { pack in
                    installedRow(pack)
                }
            }
        } header: {
            Text("已安装")
        } footer: {
            Text("删除只删内容，不删学习记录；换版本失败可以用「回退」装回上一版。")
        }
    }

    private func installedRow(_ pack: InstalledPack) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(pack.title)
                    .font(.body.weight(.medium))
                Text("v\(pack.contentVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(pack.installedAt.formatted(date: .numeric, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 12) {
                Button(role: .destructive) {
                    pendingDelete = pack
                } label: {
                    Label("删除", systemImage: "trash")
                        .font(.caption)
                }
                .buttonStyle(.bordered)

                if let remote = installer.packs.first(where: { $0.id == pack.id }), remote.previous != nil {
                    Button {
                        Task { await installer.rollback(remote) }
                    } label: {
                        Label("回退上一版", systemImage: "arrow.uturn.backward")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .disabled(installer.isBusy)
                }

                Spacer()
            }
        }
        .padding(.vertical, 2)
    }
}
