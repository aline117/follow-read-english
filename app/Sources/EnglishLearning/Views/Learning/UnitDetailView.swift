import SwiftUI
import UIKit

/// 单元内容（原型 B2/B3 的视觉语言：大图卡片 + 大圆角 + 橙蓝配色）。
/// 单词卡进入「认·说」合练；句型、游戏、复习等环节属于 tasks 4.x。
struct UnitDetailView: View {
    let profile: Profile
    let pack: InstalledPack
    let unit: Unit

    @Environment(\.dismiss) private var dismiss
    @State private var learningStart: Int?
    private let player = AudioPlayer.shared

    private let columns = [GridItem(.adaptive(minimum: 300), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            topBar

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !unit.words.isEmpty {
                        sectionTitle("单词 \(unit.words.count)")
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(Array(unit.words.enumerated()), id: \.element.id) { offset, word in
                                wordCard(word, index: offset)
                            }
                        }
                    }

                    if !unit.sentences.isEmpty {
                        sectionTitle("句型 \(unit.sentences.count)")
                            .padding(.top, 4)
                        sentenceCard
                    }

                    if !unit.listenings.isEmpty {
                        sectionTitle("跟我读 · 课文原声 \(unit.listenings.count)")
                            .padding(.top, 4)
                        listeningCard
                    }

                    Text("点单词卡进入「认·说」合练：看图认词 → 听原音 → 跟读，达标自动换下一个词。")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.faint)
                        .padding(.top, 6)
                }
                .padding(.horizontal, 40)
                .padding(.top, 18)
                .padding(.bottom, 26)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(item: $learningStart) { start in
            WordLearningView(profile: profile, pack: pack, unit: unit, startIndex: start)
        }
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
                Text("Unit \(unit.number)")
                    .font(.system(size: 21, weight: .heavy))
                    .foregroundStyle(Theme.ink)
                Text(unit.title)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }

            Spacer()

            Text(headerChip)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.orangeDark)
                .padding(.horizontal, 13)
                .padding(.vertical, 6)
                .background(Theme.orangeSoft)
                .clipShape(Capsule())
        }
        .padding(.horizontal, 26)
        .frame(height: 80)
        .background(Color.white)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line).frame(height: 2)
        }
    }

    /// 右上角小胶囊：有句型才显示句型数
    private var headerChip: String {
        var parts = ["\(unit.words.count) 词"]
        if !unit.sentences.isEmpty { parts.append("\(unit.sentences.count) 句") }
        return parts.joined(separator: " · ")
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 18, weight: .heavy))
            .foregroundStyle(Theme.ink)
    }

    // MARK: - 单词卡

    private func wordCard(_ word: UnitWord, index: Int) -> some View {
        let audioURL = ResourceLocator.url(semester: pack.id, relativePath: word.audio)
        let playing = audioURL.map { player.isPlaying($0) } ?? false

        return HStack(spacing: 14) {
            wordImage(word.image)

            VStack(alignment: .leading, spacing: 2) {
                Text(word.en)
                    .font(.system(size: 24, weight: .heavy))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(Self.meaningOnly(word.zh))
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.muted)
            }

            Spacer(minLength: 0)

            Button {
                if let audioURL { player.toggle(url: audioURL) }
            } label: {
                Image(systemName: playing ? "stop.circle.fill" : "play.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(playing ? Theme.orangeDark : Theme.blue)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playing ? "停止播放" : "播放 \(word.en)")
        }
        .padding(14)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(playing ? Theme.orange : Theme.line, lineWidth: 2)
        )
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture { learningStart = index }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(word.en) \(Self.meaningOnly(word.zh))")
    }

    @ViewBuilder
    private func wordImage(_ relativePath: String) -> some View {
        let url = ResourceLocator.url(semester: pack.id, relativePath: relativePath)
        ZStack {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0xDFF4FB), Color(hex: 0xBCE9F7)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            if let url, let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo").foregroundStyle(Theme.blueInk)
            }
        }
        .frame(width: 74, height: 74)
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    // MARK: - 句型 / 课文原声

    private var sentenceCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(unit.sentences.enumerated()), id: \.element.id) { index, sentence in
                let audioURL = ResourceLocator.url(semester: pack.id, relativePath: sentence.audio)
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(sentence.en)
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                        Text(sentence.zh)
                            .font(.system(size: 13.5))
                            .foregroundStyle(Theme.muted)
                        if !sentence.pattern.isEmpty {
                            Text(sentence.pattern)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.faint)
                        }
                    }
                    Spacer(minLength: 0)
                    playButton(audioURL)
                }
                .padding(.vertical, 10)

                if index < unit.sentences.count - 1 {
                    Rectangle().fill(Theme.line).frame(height: 1)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 2)
        )
    }

    private var listeningCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(unit.listenings.enumerated()), id: \.element.id) { index, listening in
                let audioURL = ResourceLocator.url(semester: pack.id, relativePath: listening.audio)
                HStack(spacing: 12) {
                    Text(listening.label)
                        .font(.system(size: 16, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.ink)
                    Spacer(minLength: 0)
                    playButton(audioURL)
                }
                .padding(.vertical, 8)

                if index < unit.listenings.count - 1 {
                    Rectangle().fill(Theme.line).frame(height: 1)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 2)
        )
    }

    @ViewBuilder
    private func playButton(_ url: URL?) -> some View {
        if let url {
            let playing = player.isPlaying(url)
            Button {
                player.toggle(url: url)
            } label: {
                Image(systemName: playing ? "stop.circle.fill" : "play.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(playing ? Theme.orangeDark : Theme.blue)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playing ? "停止播放" : "播放")
        } else {
            Text("缺音频")
                .font(.system(size: 11))
                .foregroundStyle(Theme.red)
        }
    }

    /// `v.感觉到` → `感觉到`（二年级不显示词性缩写）
    private static func meaningOnly(_ zh: String) -> String {
        guard let dot = zh.firstIndex(of: ".") else { return zh }
        let head = zh[zh.startIndex..<dot]
        guard head.count <= 4, head.allSatisfy({ $0.isLetter || $0 == "/" }) else { return zh }
        return String(zh[zh.index(after: dot)...])
    }
}
