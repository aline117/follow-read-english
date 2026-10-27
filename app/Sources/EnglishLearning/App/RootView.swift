import SwiftUI
import SwiftData

/// 导航骨架（design「导航结构」）：
/// 孩子模式只有「学习 / 奖励」两个 Tab，家长入口是顶栏右上角的小锁；
/// 家长模式用 `fullScreenCover` + 独立 `NavigationStack`，退出要显式操作。
struct RootView: View {
    @AppStorage("selectedProfileID") private var selectedProfileIDRaw: String = ""
    @Query(sort: \Profile.createdAt) private var profiles: [Profile]
    @State private var isParentModePresented = false

    var body: some View {
        Group {
            if let profile = currentProfile {
                childMode(for: profile)
            } else {
                ProfileSetupView()
            }
        }
    }

    private var currentProfile: Profile? {
        if let id = UUID(uuidString: selectedProfileIDRaw),
           let match = profiles.first(where: { $0.id == id }) {
            return match
        }
        return profiles.first
    }

    @ViewBuilder
    private func childMode(for profile: Profile) -> some View {
        TabView {
            NavigationStack {
                // 学习 Tab = 原型 A6 首页（问候 + 今天的任务 + 本册进度）
                HomeView(profile: profile) {
                    isParentModePresented = true
                }
            }
            .tabItem { Label("学习", systemImage: "book.fill") }

            NavigationStack {
                RewardCenterView(profile: profile)
                    .toolbar { parentEntryToolbar }
            }
            .tabItem { Label("奖励", systemImage: "star.fill") }
        }
        .tint(Theme.orange)
        .fullScreenCover(isPresented: $isParentModePresented) {
            ParentHomeView(profile: profile, isPresented: $isParentModePresented)
        }
        .onAppear { selectedProfileIDRaw = profile.id.uuidString }
    }

    @ToolbarContentBuilder
    private var parentEntryToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                isParentModePresented = true
            } label: {
                Image(systemName: "lock.fill")
            }
            .accessibilityLabel("家长模式")
        }
    }
}
