import SwiftUI
import SwiftData

/// 「学习」Tab 的入口页。首版只有二年级可用（tasks 3.1 正式实现）。
struct GradeSelectionView: View {
    let profile: Profile

    private let grades = Array(1...6)

    var body: some View {
        VStack(spacing: 20) {
            Text("选择年级")
                .font(.title.bold())

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 16)], spacing: 16) {
                ForEach(grades, id: \.self) { grade in
                    gradeCard(grade)
                }
            }
            .frame(maxWidth: 720)
        }
        .padding(32)
        .navigationTitle("学习")
    }

    @ViewBuilder
    private func gradeCard(_ grade: Int) -> some View {
        let enabled = grade == 2
        VStack(spacing: 6) {
            Text("\(grade) 年级").font(.headline)
            Text(enabled ? "沪教版 · 二年级上" : "即将推出")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 96)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(enabled ? Color.orange.opacity(0.15) : Color.gray.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(enabled ? Color.orange : Color.clear, lineWidth: 2)
        )
        .foregroundStyle(enabled ? Color.primary : Color.secondary)
    }
}
