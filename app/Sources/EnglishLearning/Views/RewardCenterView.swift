import SwiftData
import SwiftUI

/// 「奖励」Tab（tasks 5.2 / 5.3 / 6.4 的孩子端）：星星余额 + 徽章墙 + 兑换商店。
/// 余额与「今日已发」都从 `StarLedger` 聚合，不存聚合字段；兑换提交后等家长审核。
struct RewardCenterView: View {
    let profile: Profile

    @Environment(\.modelContext) private var modelContext
    /// 适配约定：动效响应「减弱动态效果」
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query private var ledger: [StarLedger]
    @Query private var badges: [Badge]
    @Query(sort: \RedemptionRule.sortOrder) private var rules: [RedemptionRule]
    @Query(sort: \Redemption.createdAt, order: .reverse) private var redemptions: [Redemption]

    @State private var toast: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                balanceCard
                badgeWall
                storeSection
                pendingSection
            }
            .padding(.horizontal, 36)
            .padding(.top, 8)
            .padding(.bottom, 26)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("奖励")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .top) {
            if let toast {
                Text(toast)
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Theme.orange)
                    .clipShape(Capsule())
                    .padding(.top, 8)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .onAppear {
            RewardTemplates.seedIfNeeded(in: modelContext)
        }
    }

    // MARK: - 余额

    private var balanceCard: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(balance) 颗星星")
                    .font(.system(size: 28, weight: .heavy))
                    .foregroundStyle(Theme.orangeDark)
                Text("今天已经赚了 \(todayGranted) 颗 · 目标是攒着换想要的")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                if balance >= StarService.balanceCap {
                    Text("星星满 \(StarService.balanceCap) 了，去兑换一些吧")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.red)
                }
            }
            Spacer()
            Text("★")
                .font(.system(size: 44, weight: .black))
                .foregroundStyle(Theme.orange.opacity(0.35))
        }
        .padding(22)
        .background(
            LinearGradient(colors: [Color(hex: 0xFFF6E8), Theme.orangeSoft],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }

    // MARK: - 徽章墙

    private var badgeWall: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("徽章墙").font(.system(size: 18, weight: .heavy))
                Spacer()
                Text("\(ownedKinds.count) / \(BadgeKind.allCases.count)")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 6), spacing: 12) {
                ForEach(BadgeKind.allCases, id: \.rawValue) { kind in
                    let owned = ownedKinds.contains(kind.rawValue)
                    VStack(spacing: 5) {
                        Text(kind.icon)
                            .font(.system(size: 18, weight: .heavy))
                            .foregroundStyle(owned ? .white : Theme.faint)
                            .frame(width: 52, height: 52)
                            .background(
                                owned
                                ? AnyShapeStyle(LinearGradient(colors: [Color(hex: 0xFFE0AE), Theme.orange],
                                                               startPoint: .top, endPoint: .bottom))
                                : AnyShapeStyle(Theme.track)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                        Text(kind.title)
                            .font(.system(size: 11.5, weight: owned ? .semibold : .regular))
                            .foregroundStyle(owned ? Theme.ink : Theme.faint)
                            .lineLimit(1)
                    }
                    .help(kind.conditionText)
                }
            }
        }
        .kidCard()
    }

    // MARK: - 兑换商店

    private var storeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("兑换商店").font(.system(size: 18, weight: .heavy))
                Spacer()
                Text("提交后等家长确认")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
            }

            let active = rules.filter(\.isActive)
            if active.isEmpty {
                Text("家长还没开启任何奖励")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
            } else {
                ForEach(active) { rule in
                    storeRow(rule)
                }
            }
        }
        .kidCard()
    }

    private func storeRow(_ rule: RedemptionRule) -> some View {
        let affordable = balance >= rule.starCost
        let waiting = hasPending(rule)
        return HStack(spacing: 12) {
            Text(rule.icon).font(.system(size: 22))
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.title)
                    .font(.system(size: 15.5, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text("\(rule.starCost) ★" + (rule.requiresApproval ? " · 需家长确认" : ""))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
            }
            Spacer()
            if waiting {
                Text("等家长确认")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.blueInk)
            } else {
                Button {
                    submit(rule)
                } label: {
                    Text(affordable ? "兑换" : "还差 \(rule.starCost - balance)")
                        .font(.system(size: 13.5, weight: .heavy))
                        .foregroundStyle(affordable ? .white : Theme.muted)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(affordable ? Theme.orange : Theme.track)
                        .clipShape(Capsule())
                        .kidTapTarget()
                }
                .buttonStyle(.plain)
                .disabled(!affordable)
            }
        }
        .padding(.vertical, 4)
    }

    private var pendingSection: some View {
        Group {
            let pending = redemptions.filter { $0.status == "pending" }
            if !pending.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("正在等家长确认").font(.system(size: 15, weight: .heavy))
                    ForEach(pending) { item in
                        HStack {
                            Text(item.ruleTitle).font(.system(size: 14))
                            Spacer()
                            Text("\(item.starCost) ★").font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.orangeDark)
                        }
                    }
                }
                .kidCard()
            }
        }
    }

    // MARK: - 数据

    private var myLedger: [StarLedger] { ledger.filter { $0.profileID == profile.id } }

    private var balance: Int { myLedger.reduce(0) { $0 + $1.amount } }

    private var todayGranted: Int {
        let start = Calendar.current.startOfDay(for: Date())
        return myLedger.filter { $0.amount > 0 && $0.at >= start }.reduce(0) { $0 + $1.amount }
    }

    private var ownedKinds: Set<String> {
        Set(badges.filter { $0.profileID == profile.id }.map(\.kind))
    }

    private func hasPending(_ rule: RedemptionRule) -> Bool {
        redemptions.contains { $0.profileID == profile.id && $0.ruleID == rule.id && $0.status == "pending" }
    }

    private func submit(_ rule: RedemptionRule) {
        let redemption = Redemption(profileID: profile.id, ruleID: rule.id,
                                    ruleTitle: rule.title, starCost: rule.starCost)
        modelContext.insert(redemption)
        try? modelContext.save()
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            toast = "已提交，等家长确认"
        }
        ParentAuth.audit("redemption_submitted", detail: rule.title)
        Task {
            await LocalNotifications.redemptionSubmitted(title: rule.title, starCost: rule.starCost)
        }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run { toast = nil }
        }
    }
}
