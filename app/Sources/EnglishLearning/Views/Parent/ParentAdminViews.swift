import SwiftData
import SwiftUI

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

    var body: some View {
        List {
            Section {
                LabeledContent("卸载 App 会清空全部学习记录", value: "请定期导出备份")
                    .font(.system(size: 13.5))
                Button("导出学习记录（JSON）") { exportJSON() }
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("分享导出的文件", systemImage: "square.and.arrow.up")
                    }
                }
            } header: {
                Text("数据")
            } footer: {
                Text("导出内容只在这台设备上生成，不会上传。")
            }

            Section {
                Toggle("大额兑换需要二次确认", isOn: $largeRedemptionNeedsConfirm)
                Toggle("完成今日任务后才能兑换", isOn: $requireDailyTaskBeforeRedemptionBinding)
            } header: {
                Text("兑换限制")
            }

            Section {
                Button("查看诊断日志（\(diagnostics.count) 条）") { reloadLogs() }
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
    }

    private var requireDailyTaskBeforeRedemptionBinding: Binding<Bool> {
        Binding(get: { requireDailyTaskBeforeRedeem },
                set: { requireDailyTaskBeforeRedeem = $0 })
    }

    private func reloadLogs() {
        auditLines = ParentAuth.auditLines()
        diagnostics = DiagnosticsLog.entries().suffix(20).reversed()
    }

    /// 导出：学习状态 + 家长配置，够还原"做过什么"
    private func exportJSON() {
        let pid = profile.id
        var payload: [String: Any] = [:]
        payload["profile"] = ["name": profile.name, "grade": profile.grade,
                              "id": profile.id.uuidString]
        payload["exportedAt"] = ISO8601DateFormatter().string(from: Date())

        let progress = (try? modelContext.fetch(
            FetchDescriptor<ItemProgress>(predicate: #Predicate { $0.profileID == pid }))) ?? []
        payload["progress"] = progress.map {
            ["itemCode": $0.itemCode, "timesSeen": $0.timesSeen,
             "timesPassed": $0.timesPassed, "masteryLevel": $0.masteryLevel]
        }

        let attempts = (try? modelContext.fetch(
            FetchDescriptor<Attempt>(predicate: #Predicate { $0.profileID == pid }))) ?? []
        payload["attempts"] = attempts.map {
            ["itemCode": $0.itemCode, "kind": $0.kind, "passed": $0.passed,
             "at": ISO8601DateFormatter().string(from: $0.at)]
        }

        let stars = (try? modelContext.fetch(
            FetchDescriptor<StarLedger>(predicate: #Predicate { $0.profileID == pid }))) ?? []
        payload["stars"] = stars.map {
            ["amount": $0.amount, "reason": $0.reason,
             "at": ISO8601DateFormatter().string(from: $0.at)]
        }

        guard let data = try? JSONSerialization.data(withJSONObject: payload,
                                                     options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("学习记录-\(profile.name).json")
        try? data.write(to: url)
        exportURL = url
        DiagnosticsLog.log("export_completed", ["bytes": "\(data.count)"])
    }
}
