import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [Profile]
    @State private var selectedProfileID: UUID?

    var body: some View {
        NavigationStack {
            if let currentProfile {
                tabView(for: currentProfile)
            } else {
                ProfileSetupView()
            }
        }
    }

    private var currentProfile: Profile? {
        profiles.first { $0.id == selectedProfileID ?? profiles.first?.id }
    }

    @ViewBuilder
    private func tabView(for profile: Profile) -> some View {
        TabView {
            NavigationStack {
                GradeSelectionView(profile: profile)
            }
            .tabItem { Label("学习", systemImage: "book.fill") }

            NavigationStack {
                RewardCenterView(profile: profile)
            }
            .tabItem { Label("奖励", systemImage: "star.fill") }

            NavigationStack {
                ParentEntryView(profile: profile)
            }
            .tabItem { Label("家长", systemImage: "person.crop.square") }
        }
    }
}
