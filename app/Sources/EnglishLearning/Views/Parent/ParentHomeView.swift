import SwiftData
import SwiftUI

/// 家长模式（design C14）：先过 PIN 闸门，再进 8 个入口 + 退出。
/// 进 / 出都写审计（`ParentAuth.audit`），退出不需要再次验证。
struct ParentHomeView: View {
    let profile: Profile
    @Binding var isPresented: Bool

    @State private var parentName: String?

    var body: some View {
        Group {
            if let parentName {
                adminHome(parentName: parentName)
            } else {
                ParentGateView { name in
                    parentName = name
                } onCancel: {
                    isPresented = false
                }
            }
        }
    }

    // MARK: - 家长首页

    private func adminHome(parentName: String) -> some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        ReportView(profile: profile)
                    } label: {
                        Label("学习报告", systemImage: "chart.bar.fill")
                    }

                    NavigationLink {
                        PracticeSettingsView(profile: profile)
                    } label: {
                        Label("练习强度", systemImage: "slider.horizontal.3")
                    }

                    NavigationLink {
                        ContentManagementView()
                    } label: {
                        Label("内容管理", systemImage: "square.and.arrow.down")
                    }
                }

                Section("奖励") {
                    NavigationLink {
                        RewardLibraryView()
                    } label: {
                        Label("奖励库", systemImage: "gift.fill")
                    }

                    NavigationLink {
                        RedemptionReviewView(reviewerName: parentName)
                    } label: {
                        Label("兑换审核", systemImage: "checkmark.seal.fill")
                    }
                }

                Section("孩子") {
                    NavigationLink {
                        ProfilesView()
                    } label: {
                        Label("孩子与档案", systemImage: "person.2.fill")
                    }

                    NavigationLink {
                        UnlockUnitView(profile: profile)
                    } label: {
                        Label("手动解锁单元", systemImage: "lock.open")
                    }
                }

                Section {
                    NavigationLink {
                        ParentSettingsView(profile: profile)
                    } label: {
                        Label("设置与安全", systemImage: "gearshape.fill")
                    }

                    Button(role: .destructive) {
                        exit()
                    } label: {
                        Label("退出家长模式", systemImage: "lock.fill")
                    }
                }
            }
            .navigationTitle("家长模式 · \(parentName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("退出") { exit() }
                }
            }
        }
    }

    private func exit() {
        ParentAuth.audit("exit_parent_mode")
        isPresented = false
    }
}

/// 通用占位页（还没做的入口）。
struct PlaceholderScreen: View {
    let title: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "hammer.fill").font(.system(size: 44)).foregroundStyle(.secondary)
            Text(title).font(.title3.bold())
            Text("这个入口还在做").font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
