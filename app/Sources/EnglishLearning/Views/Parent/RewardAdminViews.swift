import SwiftData
import SwiftUI

// MARK: - 奖励库（tasks 6.3）

/// 预置 16 个模板分三档：小额 20–60 / 中额 80–200 / 大额 300–600。
/// 家长在这里启停与改价；规则本身是全局的，不按孩子拆。
struct RewardLibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RedemptionRule.sortOrder) private var rules: [RedemptionRule]

    var body: some View {
        List {
            ForEach(RewardTemplates.groups, id: \.name) { group in
                Section(group.name) {
                    ForEach(rules.filter { $0.category == group.category }) { rule in
                        row(rule)
                    }
                }
            }

            Section {
                Button("恢复预置模板（不会删除已有记录）") {
                    RewardTemplates.seedIfNeeded(in: modelContext, force: true)
                }
            } footer: {
                Text("改动即时生效；孩子端只会看到已启用的奖励。")
            }
        }
        .navigationTitle("奖励库")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { RewardTemplates.seedIfNeeded(in: modelContext) }
    }

    private func row(_ rule: RedemptionRule) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(rule.icon).font(.system(size: 20))
                VStack(alignment: .leading, spacing: 2) {
                    Text(rule.title).font(.system(size: 15, weight: .semibold))
                    Text(limitsText(rule)).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { rule.isActive },
                    set: { rule.isActive = $0; try? modelContext.save(); ParentAuth.audit("rule_toggled", detail: rule.title) }
                ))
                .labelsHidden()
            }

            HStack(spacing: 8) {
                Text("\(rule.starCost) ★").font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(Theme.orangeDark)
                Button("-10") { adjust(rule, delta: -10) }
                    .buttonStyle(.bordered)
                Button("+10") { adjust(rule, delta: 10) }
                    .buttonStyle(.bordered)
                Spacer()
                if rule.requiresApproval {
                    Text("需家长审核").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func adjust(_ rule: RedemptionRule, delta: Int) {
        rule.starCost = max(10, min(999, rule.starCost + delta))
        try? modelContext.save()
    }

    private func limitsText(_ rule: RedemptionRule) -> String {
        var parts: [String] = []
        parts.append(rule.dailyLimit == 0 ? "不限次" : "每天 \(rule.dailyLimit) 次")
        if rule.weeklyLimit > 0 { parts.append("每周 \(rule.weeklyLimit) 次") }
        if rule.cooldownDays > 0 { parts.append("冷却 \(rule.cooldownDays) 天") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 预置模板

enum RewardTemplates {
    struct Group {
        let name: String
        let category: String
    }

    static let groups: [Group] = [
        Group(name: "小额（20–60 ★）", category: "small"),
        Group(name: "中额（80–200 ★）", category: "medium"),
        Group(name: "大额（300–600 ★）", category: "large"),
        Group(name: "学习型（用星星换「再多学一点」）", category: "learning")
    ]

    private struct Template {
        let title: String
        let icon: String
        let category: String
        let cost: Int
        let dailyLimit: Int
        let cooldownDays: Int
    }

    private static let templates: [Template] = [
        // 小额
        Template(title: "选一个今天的水果", icon: "🍎", category: "small", cost: 20, dailyLimit: 1, cooldownDays: 0),
        Template(title: "多听一个睡前故事", icon: "🌙", category: "small", cost: 30, dailyLimit: 1, cooldownDays: 0),
        Template(title: "挑一首路上听的歌", icon: "🎵", category: "small", cost: 30, dailyLimit: 2, cooldownDays: 0),
        Template(title: "和妈妈玩 10 分钟", icon: "🧩", category: "small", cost: 40, dailyLimit: 1, cooldownDays: 0),
        Template(title: "晚饭后散步 20 分钟", icon: "🚶", category: "small", cost: 50, dailyLimit: 1, cooldownDays: 0),
        Template(title: "周末晚睡 15 分钟", icon: "⏰", category: "small", cost: 60, dailyLimit: 0, cooldownDays: 3),
        // 中额
        Template(title: "看一集动画片", icon: "📺", category: "medium", cost: 80, dailyLimit: 1, cooldownDays: 0),
        Template(title: "和爸爸玩 20 分钟桌游", icon: "🎲", category: "medium", cost: 120, dailyLimit: 0, cooldownDays: 1),
        Template(title: "点一次外卖加餐", icon: "🍜", category: "medium", cost: 150, dailyLimit: 0, cooldownDays: 3),
        Template(title: "买一本新绘本", icon: "📚", category: "medium", cost: 200, dailyLimit: 0, cooldownDays: 7),
        // 大额
        Template(title: "去一次公园/游乐场", icon: "🎠", category: "large", cost: 300, dailyLimit: 0, cooldownDays: 14),
        Template(title: "挑一个新玩具（小额）", icon: "🧸", category: "large", cost: 400, dailyLimit: 0, cooldownDays: 30),
        Template(title: "一次亲子半日游", icon: "🚗", category: "large", cost: 600, dailyLimit: 0, cooldownDays: 30),
        // 学习型
        Template(title: "当 10 分钟小老师", icon: "🧑‍🏫", category: "learning", cost: 100, dailyLimit: 1, cooldownDays: 0),
        Template(title: "解锁一个「故事时间」", icon: "📖", category: "learning", cost: 120, dailyLimit: 0, cooldownDays: 0),
        Template(title: "录一段朗读进作品集", icon: "🎙", category: "learning", cost: 60, dailyLimit: 1, cooldownDays: 0)
    ]

    /// 幂等：已有同名规则就不重复插入
    static func seedIfNeeded(in context: ModelContext, force: Bool = false) {
        let existing = (try? context.fetch(FetchDescriptor<RedemptionRule>())) ?? []
        let names = Set(existing.map(\.title))
        var order = existing.count
        for template in templates {
            if !force, names.contains(template.title) { continue }
            if force, names.contains(template.title) { continue }
            let rule = RedemptionRule(title: template.title, icon: template.icon,
                                      category: template.category, starCost: template.cost,
                                      dailyLimit: template.dailyLimit, weeklyLimit: 0,
                                      cooldownDays: template.cooldownDays,
                                      requiresApproval: true, isActive: true, sortOrder: order)
            context.insert(rule)
            order += 1
        }
        try? context.save()
    }
}

// MARK: - 兑换审核（tasks 6.4）

struct RedemptionReviewView: View {
    let reviewerName: String
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Redemption.createdAt, order: .reverse) private var redemptions: [Redemption]
    @Query private var ledger: [StarLedger]

    var body: some View {
        List {
            if pending.isEmpty {
                Section {
                    Text("没有待审核的申请").foregroundStyle(.secondary)
                }
            } else {
                Section("待审核") {
                    ForEach(pending) { item in
                        row(item)
                    }
                }
            }

            Section("最近处理") {
                ForEach(decided.prefix(10)) { item in
                    HStack {
                        Text(item.ruleTitle)
                        Spacer()
                        Text(statusText(item))
                            .font(.system(size: 12.5))
                            .foregroundStyle(item.status == "approved" ? Theme.greenInk : Theme.muted)
                    }
                }
            }
        }
        .navigationTitle("兑换审核")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ item: Redemption) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(item.ruleTitle).font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("\(item.starCost) ★").font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(Theme.orangeDark)
            }
            Text(Self.formatter.string(from: item.createdAt))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button("同意") { decide(item, approved: true) }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.green)
                Button("拒绝") { decide(item, approved: false) }
                    .buttonStyle(.bordered)
                    .tint(Theme.red)
            }
        }
        .padding(.vertical, 4)
    }

    private var pending: [Redemption] { redemptions.filter { $0.status == "pending" } }
    private var decided: [Redemption] { redemptions.filter { $0.status != "pending" } }

    private func statusText(_ item: Redemption) -> String {
        let who = item.reviewedBy ?? "家长"
        return item.status == "approved" ? "\(who)同意了" : "\(who)拒绝了"
    }

    private func decide(_ item: Redemption, approved: Bool) {
        item.status = approved ? "approved" : "rejected"
        item.reviewedBy = reviewerName
        item.reviewedAt = Date()
        if approved {
            // 同意时才真正扣星：写一条负数流水，幂等键 redeem:<id>
            let key = "redeem:\(item.id.uuidString)"
            if !ledger.contains(where: { $0.grantKey == key }) {
                modelContext.insert(StarLedger(profileID: item.profileID, amount: -item.starCost,
                                               reason: "兑换：\(item.ruleTitle)", grantKey: key))
            }
        }
        try? modelContext.save()
        ParentAuth.audit("redemption_reviewed", detail: "\(item.ruleTitle)/\(approved ? "approved" : "rejected")")
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 HH:mm"
        return f
    }()
}
