import SwiftData
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 孩子与档案（tasks 6.5）

struct ProfilesView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Profile.createdAt) private var profiles: [Profile]
    @AppStorage("selectedProfileID") private var selectedProfileIDRaw: String = ""
    @State private var newName = ""
    @State private var pendingDelete: Profile?

    private let maxProfiles = 4

    var body: some View {
        List {
            Section("孩子") {
                ForEach(profiles) { profile in
                    row(profile)
                }
            }

            Section {
                HStack {
                    TextField("新孩子的名字", text: $newName)
                    Button("添加") { addProfile() }
                        .disabled(!canAdd || newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if !canAdd {
                    Text("最多 \(maxProfiles) 个档案").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            } footer: {
                Text("切换后首页 / 奖励 / 家长页都只看这个孩子的数据；删除会清掉他的 8 张学习表，至少保留 1 个档案。")
            }
        }
        .navigationTitle("孩子与档案")
        .navigationBarTitleDisplayMode(.inline)
        .alert("删除「\(pendingDelete?.name ?? "")」？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("删除", role: .destructive) { confirmDelete() }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("学习进度、星星、徽章、兑换记录都会被清掉，无法恢复。")
        }
    }

    private func row(_ profile: Profile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(profile.avatarSymbol).font(.system(size: 24))
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name).font(.system(size: 16, weight: .semibold))
                    Text("\(profile.grade) 年级" + (isCurrent(profile) ? " · 当前使用" : ""))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !isCurrent(profile) {
                    Button("切换") { switchTo(profile) }
                        .buttonStyle(.bordered)
                }
            }

            HStack(spacing: 8) {
                Text("年级").font(.system(size: 12)).foregroundStyle(.secondary)
                ForEach(1...6, id: \.self) { grade in
                    Button("\(grade)") { setGrade(grade, for: profile) }
                        .buttonStyle(.bordered)
                        .disabled(grade != 2)
                        .opacity(grade == 2 ? 1 : 0.4)
                }
                Spacer()
                if profiles.count > 1 {
                    Button(role: .destructive) {
                        pendingDelete = profile
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var canAdd: Bool { profiles.count < maxProfiles }

    private func isCurrent(_ profile: Profile) -> Bool {
        selectedProfileIDRaw == profile.id.uuidString
    }

    private func switchTo(_ profile: Profile) {
        selectedProfileIDRaw = profile.id.uuidString
        ParentAuth.audit("profile_switched", detail: profile.name)
    }

    private func setGrade(_ grade: Int, for profile: Profile) {
        profile.grade = grade
        profile.updatedAt = Date()
        try? modelContext.save()
    }

    private func addProfile() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard canAdd, !name.isEmpty else { return }
        let profile = Profile(name: name, grade: 2)
        modelContext.insert(profile)
        modelContext.insert(LearningSettings(profileID: profile.id))
        try? modelContext.save()
        newName = ""
        ParentAuth.audit("profile_created", detail: name)
    }

    private func confirmDelete() {
        guard let profile = pendingDelete else { return }
        guard profiles.count > 1 else {
            pendingDelete = nil
            return
        }
        do {
            try ProfileDataPurger.purge(profileID: profile.id, in: modelContext)
            ParentOverrides.clear(profileID: profile.id)
            modelContext.delete(profile)
            try modelContext.save()
            ParentAuth.audit("profile_deleted", detail: profile.name)
            if selectedProfileIDRaw == profile.id.uuidString {
                selectedProfileIDRaw = profiles.first(where: { $0.id != profile.id })?.id.uuidString ?? ""
            }
        } catch {
            DiagnosticsLog.log("profile_delete_failed", ["error": "\(error)"])
        }
        pendingDelete = nil
    }
}

// MARK: - 手动解锁单元（tasks 6.7）

/// 应对"学校进度超前"：只放行访问权限，不改星星与进度统计。
struct UnlockUnitView: View {
    let profile: Profile
    @Query private var progressList: [ItemProgress]
    @State private var curriculum: Curriculum?
    @State private var unlocked: Set<String> = []

    private let library = ContentLibrary.shared

    var body: some View {
        List {
            Section {
                ForEach(units, id: \.id) { unit in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(unit.title).font(.system(size: 14.5, weight: .semibold))
                            Text("\(unit.words.count) 词 · \(unit.sentences.count) 句")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { unlocked.contains(unit.id) },
                            set: { set($0, unit: unit) }
                        ))
                        .labelsHidden()
                    }
                }
            } footer: {
                Text("打开后这个单元立即可点进去；星星和进度统计不变，学完该单元照样按正常规则结算。")
            }
        }
        .navigationTitle("手动解锁单元")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
    }

    private var units: [Unit] {
        curriculum?.volumes.first?.units ?? []
    }

    private func load() {
        if let pack = library.installed.first {
            curriculum = try? library.curriculum(for: pack)
        }
        unlocked = ParentOverrides.unlockedUnits(profileID: profile.id)
    }

    private func set(_ on: Bool, unit: Unit) {
        ParentOverrides.setUnlocked(on, unitID: unit.id, profileID: profile.id)
        unlocked = ParentOverrides.unlockedUnits(profileID: profile.id)
        ParentAuth.audit("unit_override", detail: "\(unit.id)=\(on)")
    }
}

// MARK: - 设置与安全（tasks 6.6）

struct ParentSettingsView: View {
    let profile: Profile
    @Environment(\.modelContext) private var modelContext
    @AppStorage("largeRedemptionNeedsConfirm") private var largeRedemptionNeedsConfirm = true
    @AppStorage("requireDailyTaskBeforeRedeem") private var requireDailyTaskBeforeRedeem = true

    @State private var exportURL: URL?
    @State private var showShare = false
    @State private var auditLines: [String] = []
    @State private var diagnostics: [DiagnosticsLog.Entry] = []
    @State private var showResetConfirm = false
    @State private var showImporter = false
    @State private var pendingBackup: BackupFile?
    @State private var showRestoreConfirm = false
    @State private var resultMessage: String?
    @State private var showResult = false

    var body: some View {
        List {
            Section {
                LabeledContent("卸载 App 前请先备份", value: "没备份就会清空记录")
                    .font(.system(size: 13.5))

                Button {
                    exportBackup()
                } label: {
                    Label("导出备份（全部孩子）", systemImage: "square.and.arrow.up")
                }
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("分享备份文件", systemImage: "doc.badge.arrow.up")
                    }
                }

                Button {
                    showImporter = true
                } label: {
                    Label("从文件导入备份", systemImage: "square.and.arrow.down")
                }
            } header: {
                Text("备份与恢复")
            } footer: {
                Text("备份含全部孩子的进度、星星、徽章与家长配置；不含 PIN / 恢复码（恢复后需重新设置），也不含课文与媒体（重新下载即可）。导入会覆盖当前全部数据。家里电脑开着内容服务时，「内容管理」页还会每 24 小时自动备份一次。")
            }

            ReminderSection()

            Section {
                Toggle("大额兑换需要二次确认", isOn: $largeRedemptionNeedsConfirm)
                Toggle("完成今日任务后才能兑换", isOn: requireDailyTaskBeforeRedemptionBinding)
            } header: {
                Text("兑换限制")
            }

            Section {
                Button("查看诊断日志（\(diagnostics.count) 条）") { reloadLogs() }
                NavigationLink {
                    MediaDiagnosticsView()
                } label: {
                    Label("媒体日志（\(DiagnosticsLog.mediaEntries().count) 条）",
                          systemImage: "film")
                }
                Button("清空诊断日志", role: .destructive) {
                    DiagnosticsLog.clear()
                    reloadLogs()
                }
            } header: {
                Text("诊断")
            }

            Section {
                if auditLines.isEmpty {
                    Text("还没有家长操作记录").font(.system(size: 12.5)).foregroundStyle(.secondary)
                } else {
                    ForEach(auditLines.prefix(12), id: \.self) { line in
                        Text(line.replacingOccurrences(of: "\t", with: " · "))
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("家长操作记录")
            }

            Section {
                Button("重置家长 PIN（保留学习记录）", role: .destructive) {
                    showResetConfirm = true
                }
            } footer: {
                Text("重置后需要重新设置 PIN，会生成新的恢复码；孩子的进度与星星不受影响。")
            }
        }
        .navigationTitle("设置与安全")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reloadLogs() }
        .confirmationDialog("重置家长 PIN？", isPresented: $showResetConfirm) {
            Button("重置", role: .destructive) {
                ParentAuth.resetCredentials()
                ParentAuth.audit("pin_reset_by_parent")
            }
            Button("取消", role: .cancel) {}
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.json],
                      allowsMultipleSelection: false) { result in
            handleImport(result)
        }
        .confirmationDialog("覆盖恢复会替换当前全部数据",
                            isPresented: $showRestoreConfirm,
                            titleVisibility: .visible) {
            Button("覆盖恢复", role: .destructive) { performRestore() }
            Button("取消", role: .cancel) { pendingBackup = nil }
        } message: {
            Text(restoreSummary)
        }
        .alert("备份", isPresented: $showResult) {
            Button("好", role: .cancel) {}
        } message: {
            Text(resultMessage ?? "")
        }
    }

    private var restoreSummary: String {
        guard let backup = pendingBackup else { return "" }
        let date = backup.exportedAt.formatted(date: .numeric, time: .shortened)
        let kids = backup.counts["profiles"] ?? 0
        let attempts = backup.counts["attempts"] ?? 0
        let stars = backup.counts["starLedger"] ?? 0
        return "备份时间 \(date)，\(kids) 个孩子、\(attempts) 条学习明细、\(stars) 条星星流水。当前数据将被替换。"
    }

    private var requireDailyTaskBeforeRedemptionBinding: Binding<Bool> {
        Binding(get: { requireDailyTaskBeforeRedeem },
                set: { requireDailyTaskBeforeRedeem = $0 })
    }

    private func reloadLogs() {
        auditLines = ParentAuth.auditLines()
        diagnostics = DiagnosticsLog.entries().suffix(20).reversed()
    }

    /// 导出：11 张表 + 媒体观看状态，够在另一台 iPad 上完整还原
    private func exportBackup() {
        do {
            let file = try BackupService.makeBackup(context: modelContext)
            let data = try BackupService.encode(file)
            exportURL = try BackupService.writeTemporaryFile(data)
            DiagnosticsLog.log("backup_exported", ["bytes": "\(data.count)"])
        } catch {
            resultMessage = "导出失败：\(error.localizedDescription)"
            showResult = true
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            resultMessage = "读取文件失败：\(error.localizedDescription)"
            showResult = true
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                pendingBackup = try BackupService.decode(data)
                showRestoreConfirm = true
            } catch {
                resultMessage = "无法导入：\(error.localizedDescription)"
                showResult = true
            }
        }
    }

    private func performRestore() {
        guard let backup = pendingBackup else { return }
        pendingBackup = nil
        do {
            let counts = try BackupService.restore(backup, into: modelContext)
            exportURL = nil
            ParentAuth.audit("backup_restored")
            resultMessage = """
            已恢复 \(counts["profiles"] ?? 0) 个孩子、\(counts["attempts"] ?? 0) 条学习明细、\(counts["starLedger"] ?? 0) 条星星流水。

            PIN 与恢复码不在备份内，请重新设置家长凭据；课文内容请到「内容管理」重新下载。
            """
            showResult = true
        } catch {
            resultMessage = "恢复失败：\(error.localizedDescription)"
            showResult = true
        }
    }
}

// MARK: - 提醒

/// 习惯提醒（tasks 19.4.2）：默认关闭，开了才排通知；完成反馈与每日提醒共用一次授权。
private struct ReminderSection: View {
    @State private var dailyEnabled = ReminderSettings.isDailyEnabled
    @State private var completionEnabled = ReminderSettings.isCompletionEnabled
    @State private var remindAt: Date = {
        Calendar.current.date(bySettingHour: ReminderSettings.hour,
                              minute: ReminderSettings.minute,
                              second: 0, of: Date()) ?? Date()
    }()

    var body: some View {
        Section {
            Toggle("每日学习提醒", isOn: $dailyEnabled)
            if dailyEnabled {
                DatePicker("提醒时间", selection: $remindAt, displayedComponents: .hourAndMinute)
            }
            Toggle("学完给个提示", isOn: $completionEnabled)
        } header: {
            Text("提醒")
        } footer: {
            Text("默认关闭。提醒只在这台 iPad 上本地发出，不含任何学习数据；和兑换审核的通知共用一次系统授权。")
        }
        .onChange(of: dailyEnabled) { _, value in
            ReminderSettings.isDailyEnabled = value
            applyTime()
            Task { await ReminderSettings.apply() }
        }
        .onChange(of: completionEnabled) { _, value in
            ReminderSettings.isCompletionEnabled = value
        }
        .onChange(of: remindAt) { _, _ in
            applyTime()
            Task { await ReminderSettings.apply() }
        }
    }

    private func applyTime() {
        let components = Calendar.current.dateComponents([.hour, .minute], from: remindAt)
        ReminderSettings.hour = components.hour ?? 19
        ReminderSettings.minute = components.minute ?? 0
    }
}
