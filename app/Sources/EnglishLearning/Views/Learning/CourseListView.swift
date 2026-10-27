import SwiftData
import SwiftUI

/// 课程列表（原型 B1）：白色卡片 + 序号方块，当前单元高亮并带进度条，未解锁单元整卡淡出。
struct CourseListView: View {
    let profile: Profile
    let pack: InstalledPack

    @Environment(\.dismiss) private var dismiss
    @Query private var allProgress: [ItemProgress]

    @State private var curriculum: Curriculum?
    @State private var loadError: String?

    private var units: [Unit] { curriculum?.volumes.first?.units ?? [] }

    /// 「已学」= 跟读达标过（`firstPassedAt` 有值）；只是试过但没达标不算
    private var learnedCodes: Set<String> {
        Set(allProgress
            .filter { profile.id == $0.profileID && $0.firstPassedAt != nil }
            .map(\.itemCode))
    }

    private var totalItems: Int { units.reduce(0) { $0 + $1.totalItemCount } }

    private var learnedItems: Int {
        let codes = learnedCodes
        return units.reduce(0) { partial, unit in
            partial + unit.itemCodes.filter { codes.contains($0) }.count
        }
    }

    private var currentIndex: Int? {
        let codes = learnedCodes
        return units.firstIndex { !$0.itemCodes.allSatisfy { codes.contains($0) } }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar

            if let loadError {
                ContentProblemView(message: loadError) { loadCurriculum(force: true) }
                    .padding(40)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 7) {
                        ForEach(Array(units.enumerated()), id: \.element.id) { index, unit in
                            unitRow(unit, index: index)
                        }
                        listeningEntry
                        Text("学校进度超前？家长可在家长面板手动解锁单元")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.faint)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                    }
                    .padding(.horizontal, 40)
                    .padding(.top, 18)
                    .padding(.bottom, 26)
                }
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task { loadCurriculum() }
    }

    // MARK: - 顶部

    private var topBar: some View {
        HStack(spacing: 14) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(pack.title) · 沪教版")
                    .font(.system(size: 21, weight: .heavy))
                    .foregroundStyle(Theme.ink)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
            }

            Spacer()
        }
        .padding(.horizontal, 26)
        .frame(height: 80)
        .background(Color.white)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line).frame(height: 2)
        }
    }

    private var subtitle: String {
        let state: String
        if learnedItems == 0 {
            state = "新用户"
        } else if learnedItems >= totalItems, totalItems > 0 {
            state = "整册已学完"
        } else {
            state = "进行中"
        }
        return "\(units.count) 个单元 · 已学 \(learnedItems)/\(totalItems) 条目 · \(state)"
    }

    // MARK: - 单元卡

    @ViewBuilder
    private func unitRow(_ unit: Unit, index: Int) -> some View {
        let unlocked = isUnlocked(at: index)
        let done = isCompleted(unit)
        let isCurrent = currentIndex == index

        if unlocked {
            NavigationLink {
                UnitDetailView(profile: profile, pack: pack, unit: unit)
            } label: {
                card(unit, locked: false, done: done, current: isCurrent)
            }
            .buttonStyle(.plain)
        } else {
            card(unit, locked: true, done: false, current: false)
        }
    }

    private func card(_ unit: Unit, locked: Bool, done: Bool, current: Bool) -> some View {
        HStack(spacing: 16) {
            UnitBadge(number: unit.number, locked: locked, done: done)

            VStack(alignment: .leading, spacing: 3) {
                Text(unit.title)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(locked ? Theme.faint : Theme.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if let meta = metaText(unit, locked: locked, done: done, current: current) {
                    Text(meta)
                        .font(.system(size: 13.5))
                        .foregroundStyle(current && !locked ? Theme.orangeDark : Theme.muted)
                }

                if current {
                    KidProgressBar(value: unitProgress(unit), tint: .green, height: 12)
                        .frame(maxWidth: 430)
                        .padding(.top, 5)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(locked ? Theme.cardLocked : Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .strokeBorder(current ? Theme.orange : Theme.line, lineWidth: 2)
        )
        .opacity(locked ? 0.45 : 1)
    }

    private func metaText(_ unit: Unit, locked: Bool, done: Bool, current: Bool) -> String? {
        if locked {
            let previous = unit.number - 1
            return previous > 0 ? "完成 Unit \(previous) 后解锁" : "完成上一单元后解锁"
        }
        if done { return "已学完 · \(unit.words.count) 词" }
        var parts = ["\(unit.words.count) 词"]
        if !unit.sentences.isEmpty { parts.append("\(unit.sentences.count) 句") }
        if current { parts.append("进行中") }
        return parts.joined(separator: " · ")
    }

    private func unitProgress(_ unit: Unit) -> Double {
        let codes = learnedCodes
        let total = unit.totalItemCount
        guard total > 0 else { return 0 }
        return Double(unit.itemCodes.filter { codes.contains($0) }.count) / Double(total)
    }

    // MARK: - 听和看（媒体库，D 组，还没实现）

    private var listeningEntry: some View {
        HStack(spacing: 16) {
            Text("♫")
                .font(.system(size: 20, weight: .heavy))
                .foregroundStyle(Theme.blueInk)
                .frame(width: 50, height: 50)
                .background(Theme.blueSoft)
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))

            Text("听和看 · 儿歌与绘本")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(Theme.ink)

            Spacer()

            Text("待做")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.faint)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Theme.chipBg)
                .clipShape(Capsule())
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .strokeBorder(Color(hex: 0xBFE9F7), lineWidth: 2)
        )
        .opacity(0.75)
    }

    // MARK: - 规则

    private func isCompleted(_ unit: Unit) -> Bool {
        let codes = learnedCodes
        return unit.itemCodes.allSatisfy { codes.contains($0) }
    }

    private func isUnlocked(at index: Int) -> Bool {
        guard index > 0 else { return true }
        return isCompleted(units[index - 1])
    }

    private func loadCurriculum(force: Bool = false) {
        guard force || curriculum == nil else { return }
        loadError = nil
        do {
            curriculum = try ContentLibrary.shared.curriculum(for: pack)
        } catch {
            loadError = (error as? CurriculumError)?.description ?? error.localizedDescription
        }
    }
}
