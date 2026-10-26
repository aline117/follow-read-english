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
                GradeSelectionView(profile: profile)
                    .toolbar { parentEntryToolbar }
            }
            .tabItem { Label("学习", systemImage: "book.fill") }

            NavigationStack {
                RewardCenterView(profile: profile)
                    .toolbar { parentEntryToolbar }
            }
            .tabItem { Label("奖励", systemImage: "star.fill") }
        }
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
