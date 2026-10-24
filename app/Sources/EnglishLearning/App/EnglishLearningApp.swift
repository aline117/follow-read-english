import SwiftUI
import SwiftData

@main
struct EnglishLearningApp: App {
    let modelContainer: ModelContainer

    init() {
        let schema = Schema([
            Profile.self,
            CurriculumCourse.self,
            Lesson.self,
            Word.self,
            Sentence.self,
            Reward.self,
            Badge.self,
            RedemptionRule.self,
            Redemption.self,
            LearningSession.self,
            WordProgress.self,
            ReviewSchedule.self
        ])
        let config = ModelConfiguration(schema: schema)
        do {
            modelContainer = try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("无法初始化数据存储: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .modelContainer(modelContainer)
        }
    }
}
