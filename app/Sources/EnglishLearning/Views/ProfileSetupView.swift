import SwiftData
import SwiftUI

/// 创建孩子档案（原型 A2）：昵称 + 8 个头像 + 年级。
/// 年级只有「二年级」可选，其余置灰标「即将推出」（design「首版范围」）。
struct ProfileSetupView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage("selectedProfileID") private var selectedProfileIDRaw: String = ""

    @State private var name: String = ""
    @State private var avatar: String = Self.avatars[0]
    @State private var grade: Int = 2

    /// 内置卡通头像，不用照片/相册（儿童隐私）
    private static let avatars = ["🐻", "🐰", "🦊", "🐼", "🐯", "🐨", "🐸", "🦄"]
    private static let selectableGrades = Array(1...6)
    private static let enabledGrades: Set<Int> = [2]

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        !trimmedName.isEmpty && trimmedName.count <= 10 && Self.enabledGrades.contains(grade)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 6) {
                    Text("给自己建个档案")
                        .font(.system(size: 26, weight: .heavy))
                        .foregroundStyle(Theme.ink)
                    Text("名字和头像随时可以在家长模式里改")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.muted)
                }
                .padding(.top, 8)

                nameCard
                avatarCard
                gradeCard

                Button(action: createProfile) {
                    KidButtonLabel(title: "开始学习")
                }
                .buttonStyle(KidButtonStyle())
                .disabled(!canSubmit)
                .opacity(canSubmit ? 1 : 0.45)
                .padding(.top, 4)
            }
            .frame(maxWidth: 680)
            .padding(.horizontal, 42)
            .padding(.bottom, 30)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.bg.ignoresSafeArea())
    }

    // MARK: - 昵称

    private var nameCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("你叫什么名字？")
                .font(.system(size: 18, weight: .heavy))
                .foregroundStyle(Theme.ink)

            TextField("比如：小宇", text: $name)
                .font(.system(size: 20, weight: .semibold))
                .textFieldStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .background(Theme.chipBg)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .submitLabel(.done)

            if trimmedName.count > 10 {
                Text("名字最多 10 个字")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.red)
            }
        }
        .kidCard()
    }

    // MARK: - 头像

    private var avatarCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("挑一个头像")
                .font(.system(size: 18, weight: .heavy))
                .foregroundStyle(Theme.ink)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 8), spacing: 12) {
                ForEach(Self.avatars, id: \.self) { item in
                    Button {
                        avatar = item
                    } label: {
                        Text(item)
                            .font(.system(size: 30))
                            .frame(maxWidth: .infinity, minHeight: 62)
                            .background(avatar == item ? Theme.orangeSoft : Theme.chipBg)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(avatar == item ? Theme.orange : .clear, lineWidth: 2.5)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("头像 \(item)")
                }
            }
        }
        .kidCard()
    }

    // MARK: - 年级

    private var gradeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("现在读几年级？")
                .font(.system(size: 18, weight: .heavy))
                .foregroundStyle(Theme.ink)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                ForEach(Self.selectableGrades, id: \.self) { value in
                    gradeCell(value)
                }
            }

            Text("首版只有二年级的内容；其他年级在做了，会陆续加。")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.muted)
        }
        .kidCard()
    }

    private func gradeCell(_ value: Int) -> some View {
        let enabled = Self.enabledGrades.contains(value)
        let selected = grade == value
        return Button {
            if enabled { grade = value }
        } label: {
            VStack(spacing: 3) {
                Text("\(value) 年级")
                    .font(.system(size: 17, weight: .heavy))
                Text(enabled ? (selected ? "已选择" : "可学习") : "即将推出")
                    .font(.system(size: 12))
            }
            .frame(maxWidth: .infinity, minHeight: 72)
            .foregroundStyle(enabled ? (selected ? Theme.orangeDark : Theme.ink) : Theme.faint)
            .background(enabled ? (selected ? Theme.orangeSoft : Color.white) : Theme.cardLocked)
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(selected ? Theme.orange : Theme.line, lineWidth: selected ? 2.5 : 1.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel("\(value) 年级\(enabled ? "" : "，即将推出")")
    }

    // MARK: - 创建

    private func createProfile() {
        guard canSubmit else { return }
        let profile = Profile(name: trimmedName, avatarSymbol: avatar, grade: grade)
        modelContext.insert(profile)
        modelContext.insert(LearningSettings(profileID: profile.id))
        try? modelContext.save()
        selectedProfileIDRaw = profile.id.uuidString
    }
}
