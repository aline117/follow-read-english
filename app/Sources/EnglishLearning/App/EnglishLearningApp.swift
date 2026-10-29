import SwiftUI
import SwiftData

@main
struct EnglishLearningApp: App {
    let modelContainer: ModelContainer

    /// Schema 固定 11 个类型（见 design「指标口径与数据字典」）：
    /// 学习状态 8 张 + 家长配置 3 张。只读内容不进库。
    static let schema = Schema([
        Profile.self,
        ParentProfile.self,
        LearningSettings.self,
        ItemProgress.self,
        Attempt.self,
        LearningSession.self,
        ReviewSchedule.self,
        StarLedger.self,
        Badge.self,
        RedemptionRule.self,
        Redemption.self
    ])

    init() {
        let config = ModelConfiguration(schema: Self.schema)
        do {
            modelContainer = try ModelContainer(for: Self.schema, configurations: [config])
        } catch {
            // 模型结构变动导致旧数据库打不开时，先退到内存态保证能跑起来，
            // 并把原因打出来（不静默删除用户数据）。
            print("⚠️ 无法打开本地数据库，本次以内存模式运行：\(error)")
            let memory = ModelConfiguration(schema: Self.schema, isStoredInMemoryOnly: true)
            modelContainer = try! ModelContainer(for: Self.schema, configurations: [memory])
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .modelContainer(modelContainer)
                // 适配约定：首版锁定字号，不跟随 Dynamic Type（布局按固定字号排版）
                .dynamicTypeSize(.large)
        }
    }
}
