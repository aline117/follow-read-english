import SwiftUI
import SwiftData

/// 家长模式首页（design 里 C14 屏）：独立 `NavigationStack`，6 个入口 + 退出家长模式。
/// PIN 验证与各入口的正式内容在 tasks 6.x 实现，这里先给可点的骨架。
struct ParentHomeView: View {
    let profile: Profile
    @Binding var isPresented: Bool

    private struct Entry: Identifiable {
        enum Destination {
            case placeholder
            case contentManagement
        }

        let id = UUID()
        let title: String
        let systemImage: String
        var destination: Destination = .placeholder
    }

    private let entries: [Entry] = [
        Entry(title: "学习报告", systemImage: "chart.bar.fill"),
        Entry(title: "内容管理", systemImage: "square.and.arrow.down", destination: .contentManagement),
        Entry(title: "练习强度", systemImage: "slider.horizontal.3"),
        Entry(title: "奖励库", systemImage: "gift.fill"),
        Entry(title: "兑换审核", systemImage: "checkmark.seal.fill"),
        Entry(title: "孩子与档案", systemImage: "person.2.fill")
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(entries) { entry in
                        NavigationLink {
                            switch entry.destination {
                            case .contentManagement:
                                ContentManagementView()
                            case .placeholder:
                                PlaceholderScreen(title: entry.title)
                            }
                        } label: {
                            Label(entry.title, systemImage: entry.systemImage)
                        }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        isPresented = false
                    } label: {
                        Label("退出家长模式", systemImage: "lock.open.fill")
                    }
                }
            }
            .navigationTitle("家长模式")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("退出") { isPresented = false }
                }
            }
        }
    }
}

/// 占位页：入口已通、内容待实现。
struct PlaceholderScreen: View {
    let title: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "hammer.fill").font(.system(size: 44)).foregroundStyle(.secondary)
            Text(title).font(.title3.bold())
            Text("这个入口还在做（见 tasks 6.x）").font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
