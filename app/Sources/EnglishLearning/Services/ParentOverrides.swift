import Foundation

/// 家长手动放行的单元（tasks 6.7）。
/// 只影响「能不能点进去」，**不改星星与进度统计**；按孩子分开存，删档案时一起清。
enum ParentOverrides {
    private static func key(_ profileID: UUID) -> String {
        "manualUnlock.\(profileID.uuidString)"
    }

    static func unlockedUnits(profileID: UUID) -> Set<String> {
        let raw = UserDefaults.standard.stringArray(forKey: key(profileID)) ?? []
        return Set(raw)
    }

    static func isUnlocked(_ unitID: String, profileID: UUID) -> Bool {
        unlockedUnits(profileID: profileID).contains(unitID)
    }

    static func setUnlocked(_ unlocked: Bool, unitID: String, profileID: UUID) {
        var current = unlockedUnits(profileID: profileID)
        if unlocked {
            current.insert(unitID)
        } else {
            current.remove(unitID)
        }
        UserDefaults.standard.set(Array(current).sorted(), forKey: key(profileID))
    }

    static func clear(profileID: UUID) {
        UserDefaults.standard.removeObject(forKey: key(profileID))
    }
}
