import SwiftUI
import SwiftData

/// 「奖励」Tab 的入口页。星星余额、徽章、兑换商店在 tasks 5.x 实现。
struct RewardCenterView: View {
    let profile: Profile
    @Query private var ledger: [StarLedger]

    init(profile: Profile) {
        self.profile = profile
        let pid = profile.id
        _ledger = Query(filter: #Predicate<StarLedger> { $0.profileID == pid })
    }

    private var balance: Int {
        ledger.reduce(0) { $0 + $1.amount }
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "star.fill").foregroundStyle(.orange)
                Text("\(balance)").font(.largeTitle.bold())
                Text("颗星星").font(.headline).foregroundStyle(.secondary)
            }
            Text("徽章墙与兑换商店即将上线")
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .navigationTitle("奖励")
    }
}
