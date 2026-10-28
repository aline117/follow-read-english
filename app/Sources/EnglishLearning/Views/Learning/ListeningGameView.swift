import SwiftData
import SwiftUI

/// 听音选图（tasks 4.4 / 原型 B6）：播一遍读音，从 4 张图里选对应的那个。
/// - 答对 +1 星（幂等键 `game:<会话>-<itemCode>`，同一题不重复给）
/// - 写 `Attempt(kind: "game")`，按口径**不计入正确率**
struct ListeningGameView: View {
    let profile: Profile
    let pack: InstalledPack
    let unit: Unit

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var ledger: [StarLedger]

    @State private var questions: [Question] = []
    @State private var index = 0
    @State private var picked: String?
    @State private var correctCount = 0
    @State private var starsEarned = 0
    @State private var finished = false
    @State private var sessionID = UUID()

    private let player = AudioPlayer.shared

    private struct Question {
        let answer: UnitWord
        /// 4 个选项（含正确答案），已打乱
        let options: [UnitWord]
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar

            if finished || questions.isEmpty {
                summary
            } else {
                questionBody
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onAppear(perform: buildQuestions)
        .onDisappear { player.stop() }
    }

    // MARK: - 顶部

    private var topBar: some View {
        HStack(spacing: 14) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 38, height: 38)
                    .background(Theme.chipBg)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text("听音选图")
                    .font(.system(size: 20, weight: .heavy))
                    .foregroundStyle(Theme.ink)
                Text("Unit \(unit.number) · 答对一题 +1 颗星")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.muted)
            }

            Spacer()

            if !questions.isEmpty {
                Text("\(min(index + 1, questions.count)) / \(questions.count)")
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(Theme.orangeDark)
            }
        }
        .padding(.horizontal, 36)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    // MARK: - 题目

    private var questionBody: some View {
        VStack(spacing: 16) {
            Button {
                playCurrent()
            } label: {
                VStack(spacing: 8) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 34, weight: .bold))
                    Text("再听一遍")
                        .font(.system(size: 15, weight: .heavy))
                }
                .foregroundStyle(.white)
                .frame(width: 190, height: 108)
                .background(
                    LinearGradient(colors: [Color(hex: 0xFFC46B), Theme.orange],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("再听一遍读音")

            Text(prompt)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.muted)

            if let question = currentQuestion {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)],
                          spacing: 16) {
                    ForEach(question.options) { option in
                        optionCard(option)
                    }
                }
                .frame(maxWidth: 720)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 36)
        .padding(.top, 10)
        .padding(.bottom, 24)
    }

    private var prompt: String {
        guard let question = currentQuestion else { return "" }
        if let picked {
            return picked == question.answer.id
                ? "答对啦！这是 \(question.answer.en)"
                : "这次是 \(question.answer.en)"
        }
        return "听一听，选出对应的图片"
    }

    private func optionCard(_ option: UnitWord) -> some View {
        let question = currentQuestion
        let isAnswer = question?.answer.id == option.id
        let isPicked = picked == option.id
        let revealed = picked != nil

        return Button {
            pick(option)
        } label: {
            VStack(spacing: 8) {
                wordImage(option)
                    .frame(height: 118)
                Text(option.en)
                    .font(.system(size: 17, weight: .heavy))
                    .foregroundStyle(Theme.ink)
            }
            .frame(maxWidth: .infinity)
            .padding(12)
            .background(revealed && isAnswer ? Theme.greenSoft : (isPicked ? Theme.redSoft : Color.white))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(revealed && isAnswer ? Theme.green
                                  : (isPicked ? Theme.red : Theme.line),
                                  lineWidth: (isPicked || (revealed && isAnswer)) ? 2.5 : 1.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(revealed)
        .accessibilityLabel(option.en)
    }

    @ViewBuilder
    private func wordImage(_ word: UnitWord) -> some View {
        let url = ResourceLocator.url(semester: pack.id, relativePath: word.image)
        if let url {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit()
                } else {
                    imagePlaceholder
                }
            }
        } else {
            imagePlaceholder
                .onAppear {
                    DiagnosticsLog.assertAsset(nil, path: word.image, context: "ListeningGameView")
                }
        }
    }

    private var imagePlaceholder: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Theme.chipBg)
            .overlay(Text("🖼").font(.system(size: 30)).foregroundStyle(Theme.faint))
    }

    // MARK: - 结算

    private var summary: some View {
        VStack(spacing: 14) {
            Text(correctCount == questions.count ? "🏆" : "🎉").font(.system(size: 46))
            Text(questions.isEmpty ? "这个单元还没有可玩的词" : "游戏结束")
                .font(.system(size: 23, weight: .heavy))
                .foregroundStyle(Theme.ink)

            if !questions.isEmpty {
                Text("答对 \(correctCount) / \(questions.count) · 得到 \(starsEarned) 颗星")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.orangeDark)
            }

            Button {
                dismiss()
            } label: {
                KidButtonLabel(title: "完成")
            }
            .buttonStyle(KidButtonStyle())
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 逻辑

    private var currentQuestion: Question? {
        questions.indices.contains(index) ? questions[index] : nil
    }

    private func buildQuestions() {
        guard questions.isEmpty else { return }
        let pool = unit.words
        guard pool.count >= 2 else { return }
        questions = pool.map { answer in
            var others = pool.filter { $0.id != answer.id }.shuffled()
            var options = [answer]
            while options.count < min(4, pool.count), let next = others.popLast() {
                options.append(next)
            }
            return Question(answer: answer, options: options.shuffled())
        }
        .shuffled()
        playCurrent()
    }

    private func playCurrent() {
        guard let question = currentQuestion else { return }
        guard let url = ResourceLocator.url(semester: pack.id, relativePath: question.answer.audio) else {
            DiagnosticsLog.assertAsset(nil, path: question.answer.audio, context: "ListeningGameView.play")
            return
        }
        player.play(url: url, rate: 1)
    }

    private func pick(_ option: UnitWord) {
        guard picked == nil, let question = currentQuestion else { return }
        picked = option.id
        let passed = option.id == question.answer.id
        let now = Date()

        modelContext.insert(Attempt(profileID: profile.id, sessionID: sessionID,
                                    itemCode: question.answer.itemCode, itemKind: .word,
                                    unitCode: unit.id, kind: "game", passed: passed, at: now))

        if passed {
            correctCount += 1
            let key = "game:\(sessionID.uuidString)-\(question.answer.itemCode)"
            let result = StarService.grant(profileID: profile.id, amount: 1, reason: "听音选图答对",
                                           key: key, in: modelContext, now: now)
            if case .granted = result { starsEarned += 1 }
        }
        try? modelContext.save()

        Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            await MainActor.run {
                player.stop()
                if index + 1 < questions.count {
                    index += 1
                    picked = nil
                    playCurrent()
                } else {
                    finished = true
                }
            }
        }
    }
}
