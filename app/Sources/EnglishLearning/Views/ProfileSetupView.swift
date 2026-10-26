import SwiftUI
import SwiftData

/// 首次启动：建孩子档案（design 里 A2 屏；正式外观在 tasks 3.x 补齐）。
struct ProfileSetupView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage("selectedProfileID") private var selectedProfileIDRaw: String = ""
    @State private var name: String = ""

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "face.smiling")
                .font(.system(size: 72))
                .foregroundStyle(.orange)

            Text("给自己起个名字吧")
                .font(.title2.bold())

            TextField("比如：小宇", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
                .multilineTextAlignment(.center)

            Button("开始学习") {
                createProfile()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(40)
    }

    private func createProfile() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let profile = Profile(name: trimmed)
        modelContext.insert(profile)
        modelContext.insert(LearningSettings(profileID: profile.id))
        try? modelContext.save()
        selectedProfileIDRaw = profile.id.uuidString
    }
}
