import SwiftData
import SwiftUI

/// 内容体检 · 可疑条目（design「评测可信度与内容体检」/ tasks 19.2）。
///
/// 只回答一个问题：**哪些条目练了很多次却很少达标？**
/// 然后按「评测降级占比」先怀疑评测、再怀疑素材——降级判定下读对也可能判不过，
/// 直接改素材会把好内容改坏。
///
/// 三条硬约束（spec `parent-panel`）：
/// - 样本 < 5 不展示（太少说明不了问题）
/// - 达标率 < 50% 才标「可疑」
/// - **只读 + 导出**，不提供改阈值 / 重标 / 替换的入口
struct SuspiciousItemsView: View {
    let profile: Profile

    @Query private var attempts: [Attempt]
    @State private var curriculum: Curriculum?
    @State private var exportURL: URL?

    private let library = ContentLibrary.shared

    /// 判定参数（spec 里写死的口径，界面上不开放修改）
    private enum Rule {
        static let minSample = 5
        static let passRateFloor = 0.5
        static let fallbackShareFloor = 0.5
    }

    private enum Attribution: String {
        case evaluation
        case content

        var title: String {
            switch self {
            case .evaluation: return "可能是评测兜底"
            case .content: return "可能是素材问题"
            }
        }

        var hint: String {
            switch self {
            case .evaluation: return "降级判定的比例高，先修评测（权限 / 听写资源 / 环境噪音），别急着改素材"
            case .content: return "识别正常但长期不达标，值得回听原音、核对标注与断句"
            }
        }
    }

    private struct Row: Identifiable {
        let id: String
        let title: String
        let table: String        // 「单词 / 句型 / 媒体跟读」
        let sample: Int
        let passed: Int
        let lastMode: RecognitionMode?
        let fallbackShare: Double?
        let attribution: Attribution

        var passRate: Double { sample == 0 ? 0 : Double(passed) / Double(sample) }
        var passRateText: String { "\(Int((passRate * 100).rounded()))%" }
    }

    var body: some View {
        List {
            if studyRows.isEmpty && mediaRows.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("暂时没有可疑条目")
                            .font(.callout.weight(.medium))
                        Text("样本少于 \(Rule.minSample) 次的条目不参与判断；达标率要低于 \(Int(Rule.passRateFloor * 100))% 才会出现在这里。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }

            if !studyRows.isEmpty {
                Section {
                    ForEach(studyRows) { row in rowView(row) }
                } header: {
                    Text("跟读条目")
                } footer: {
                    Text("达标率 = 通过次数 / 跟读次数（只算跟读，不算游戏与选择）。")
                }
            }

            if !mediaRows.isEmpty {
                Section {
                    ForEach(mediaRows) { row in rowView(row) }
                } header: {
                    Text("媒体跟读")
                } footer: {
                    Text("一次通过率 = 第一次就通过的句子 / 通过过的句子。")
                }
            }

            Section {
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("分享导出的 JSON", systemImage: "square.and.arrow.up")
                    }
                } else {
                    Button {
                        export()
                    } label: {
                        Label("导出可疑条目（JSON）", systemImage: "square.and.arrow.down")
                    }
                }
            } header: {
                Text("导出")
            } footer: {
                Text("导出只包含条目码、样本数、达标率与归因，不含孩子姓名。这里只做展示，改阈值与重标都不在本页做。")
            }
        }
        .navigationTitle("可疑条目")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
    }

    // MARK: - 行

    private func rowView(_ row: Row) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(row.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(row.table)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(Capsule())
                Spacer()
                Text(row.passRateText)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(row.passRate < Rule.passRateFloor ? .red : .secondary)
            }

            Text("样本 \(row.sample) 次 · 通过 \(row.passed) 次"
                 + (row.lastMode.map { " · 最近判定：\($0.displayName)" } ?? " · 最近判定未记录"))
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("归因：\(row.attribution.title)")
                .font(.caption)
                .foregroundStyle(row.attribution == .evaluation ? .orange : .secondary)
            Text(row.attribution.hint)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    // MARK: - 数据

    private var myAttempts: [Attempt] {
        attempts.filter { $0.profileID == profile.id }
    }

    private var studyRows: [Row] {
        var stats: [String: [Attempt]] = [:]
        for attempt in myAttempts where AccuracyRule.countedKinds.contains(attempt.kind) {
            stats[attempt.itemCode, default: []].append(attempt)
        }

        var rows: [Row] = []
        for (code, list) in stats {
            let sample = list.count
            guard sample >= Rule.minSample else { continue }
            let passed = list.filter(\.passed).count
            let rate = Double(passed) / Double(sample)
            guard rate < Rule.passRateFloor else { continue }

            let device = list.filter { $0.recognitionModeValue == .device }.count
            let fallback = list.filter { $0.recognitionModeValue == .fallback }.count
            let fallbackShare = device + fallback == 0 ? nil : Double(fallback) / Double(device + fallback)
            let last = list.max(by: { $0.at < $1.at })

            rows.append(Row(id: code,
                            title: itemTitles[code] ?? code,
                            table: last?.itemKind == ItemKind.sentence.rawValue ? "句型" : "单词",
                            sample: sample,
                            passed: passed,
                            lastMode: last?.recognitionModeValue,
                            fallbackShare: fallbackShare,
                            attribution: (fallbackShare ?? 0) >= Rule.fallbackShareFloor ? .evaluation : .content))
        }
        return rows.sorted { $0.passRate < $1.passRate }
    }

    private var mediaRows: [Row] {
        var rows: [Row] = []
        for item in MediaLibrary.shared.items {
            let state = MediaStateStore.shared.itemState(item.id, profileID: profile.id)
            let sample = state.passedLines.count
            guard sample >= Rule.minSample else { continue }
            let passed = state.firstTryPassed.count
            let rate = Double(passed) / Double(sample)
            guard rate < Rule.passRateFloor else { continue }

            let device = state.devicePassCount ?? 0
            let fallback = state.fallbackPassCount ?? 0
            let fallbackShare = device + fallback == 0 ? nil : Double(fallback) / Double(device + fallback)
            let lastMode: RecognitionMode? = fallback > device ? .fallback : (device > 0 ? .device : nil)

            rows.append(Row(id: item.id,
                            title: item.title,
                            table: "媒体跟读",
                            sample: sample,
                            passed: passed,
                            lastMode: lastMode,
                            fallbackShare: fallbackShare,
                            attribution: (fallbackShare ?? 0) >= Rule.fallbackShareFloor ? .evaluation : .content))
        }
        return rows.sorted { $0.passRate < $1.passRate }
    }

    /// 内容只在内存里解码，不进库
    private var itemTitles: [String: String] {
        guard let curriculum else { return [:] }
        var map: [String: String] = [:]
        for volume in curriculum.volumes {
            for unit in volume.units {
                for word in unit.words { map[word.itemCode] = word.en }
                for sentence in unit.sentences { map[sentence.itemCode(in: unit.id)] = sentence.en }
            }
        }
        return map
    }

    private func load() {
        guard curriculum == nil, let pack = library.installed.first else { return }
        curriculum = try? library.curriculum(for: pack)
    }

    // MARK: - 导出

    private func export() {
        let rows = studyRows + mediaRows
        let payload: [String: Any] = [
            "schemaVersion": 1,
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "profileID": profile.id.uuidString,
            "rules": [
                "minSample": Rule.minSample,
                "passRateFloor": Rule.passRateFloor,
                "fallbackShareFloor": Rule.fallbackShareFloor
            ],
            "items": rows.map { row -> [String: Any] in
                var item: [String: Any] = [
                    "itemCode": row.id,
                    "title": row.title,
                    "kind": row.table,
                    "sample": row.sample,
                    "passed": row.passed,
                    "passRate": (row.passRate * 1000).rounded() / 1000,
                    "attribution": row.attribution.rawValue
                ]
                if let share = row.fallbackShare {
                    item["fallbackShare"] = (share * 1000).rounded() / 1000
                }
                item["lastRecognitionMode"] = row.lastMode?.rawValue ?? NSNull()
                return item
            }
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: payload,
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("内容体检-\(profile.name).json")
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        exportURL = url
        ParentAuth.audit("content_check_exported", detail: "items=\(rows.count)")
    }
}
