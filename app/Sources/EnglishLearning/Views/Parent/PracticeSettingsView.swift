import SwiftData
import SwiftUI

/// 练习强度（tasks 6.8）：按 Profile 保存，档位选择，改完即时生效（首页「预计 X 分钟」跟着变）。
struct PracticeSettingsView: View {
    let profile: Profile
    @Environment(\.modelContext) private var modelContext
    @Query private var settingsList: [LearningSettings]

    var body: some View {
        Form {
            if let settings {
                Section {
                    stepperRow("连续失败几次可以「先跳过」",
                               value: settings.skipAfterFailures,
                               options: LearningOption.skipAfterFailures,
                               note: "选「关闭」就必须读对才能过")
                } header: {
                    Text("卡住时")
                }

                Section {
                    stepperRow("每天新词",
                               value: settings.newWordsPerDay,
                               options: LearningOption.newWordsPerDay,
                               note: nil)
                    stepperRow("每天新句型",
                               value: settings.newSentencesPerDay,
                               options: LearningOption.newSentencesPerDay,
                               note: "0 = 今天不学句型")
                } header: {
                    Text("每天学多少")
                } footer: {
                    Text("单词和句型按课本顺序推；改完回首页，预计时长会跟着重算。")
                }

                Section {
                    stepperRow("一次复习最多",
                               value: settings.reviewLimitPerSession,
                               options: LearningOption.reviewLimitPerSession,
                               note: "到期条目多于上限时，先做最早的")
                } header: {
                    Text("复习")
                }

                Section {
                    Text("复习间隔（1 / 3 / 7 / 14 / 30 天）、掌握度分级、正确率口径、每天 20 分钟预算、发星上限、星星余额上限 500 都不开放——这些是算法与防沉迷底线。")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.muted)
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("练习强度")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: ensureSettings)
    }

    // MARK: - 行

    private func stepperRow(_ title: String, value: Int, options: [Int], note: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 15, weight: .semibold))
            HStack(spacing: 8) {
                ForEach(options, id: \.self) { option in
                    Button {
                        set(option, for: title)
                    } label: {
                        Text(label(for: option, title: title))
                            .font(.system(size: 14, weight: .heavy))
                            .foregroundStyle(value == option ? .white : Theme.ink)
                            .frame(minWidth: 52)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 10)
                            .background(value == option ? Theme.orange : Theme.chipBg)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            if let note {
                Text(note).font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
        }
        .padding(.vertical, 4)
    }

    private func label(for option: Int, title: String) -> String {
        if option == 0, title.contains("跳过") { return "关闭" }
        if option == 0, title.contains("句型") { return "0" }
        return "\(option)"
    }

    // MARK: - 数据

    private var settings: LearningSettings? {
        settingsList.first { $0.profileID == profile.id }
    }

    private func ensureSettings() {
        guard settings == nil else { return }
        modelContext.insert(LearningSettings(profileID: profile.id))
        try? modelContext.save()
    }

    private func set(_ value: Int, for title: String) {
        guard let settings else { return }
        if title.contains("跳过") {
            settings.skipAfterFailures = value
        } else if title.contains("新词") {
            settings.newWordsPerDay = value
        } else if title.contains("新句型") {
            settings.newSentencesPerDay = value
        } else if title.contains("复习") {
            settings.reviewLimitPerSession = value
        }
        settings.updatedAt = Date()
        try? modelContext.save()
        ParentAuth.audit("practice_settings_changed", detail: "\(title)=\(value)")
    }
}
