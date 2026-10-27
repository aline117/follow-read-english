import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// 家长凭据与四层恢复（tasks 6.1 / design「家长凭据与恢复策略」）。
///
/// - 4 位 PIN：Keychain 存 `salt + SHA256(salt+pin)`，不存明文
/// - 6 位恢复码：同样只存哈希；明文只在生成那一刻展示一次
/// - 四层恢复：① 设备密码 / Face ID（`LocalAuthentication`）→ ② 恢复码 → ③ 重新生成恢复码 → ④ Debug 重置（保留学习数据）
enum ParentAuth {
    // MARK: - Keychain 键

    private static let service = "com.aline117.englishlearning.parent"
    private static let pinKey = "parent.pin"
    private static let recoveryKey = "parent.recovery"

    // MARK: - 状态

    static var hasPin: Bool {
        Keychain.string(service: service, account: pinKey) != nil
    }

    /// 是否还有恢复码（明文不可读，只知道存过）
    static var hasRecoveryCode: Bool {
        Keychain.string(service: service, account: recoveryKey) != nil
    }

    // MARK: - PIN

    /// 第一次设置 PIN，同时生成一次性恢复码；返回恢复码明文供展示
    @discardableResult
    static func setPin(_ pin: String) -> String? {
        guard pin.count == 4, pin.allSatisfy(\.isNumber) else { return nil }
        let salt = randomHex(bytes: 16)
        Keychain.set(hash(pin, salt: salt), service: service, account: pinKey)
        return regenerateRecoveryCode()
    }

    /// 校验 PIN
    static func verify(pin: String) -> Bool {
        guard let stored = Keychain.string(service: service, account: pinKey) else { return false }
        let parts = stored.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return false }
        return hash(pin, salt: parts[0]) == stored
    }

    /// 改 PIN（沿用旧 salt 会失去意义，这里换新 salt）
    static func changePin(_ pin: String) -> Bool {
        guard pin.count == 4, pin.allSatisfy(\.isNumber) else { return false }
        let salt = randomHex(bytes: 16)
        Keychain.set(hash(pin, salt: salt), service: service, account: pinKey)
        return true
    }

    // MARK: - 恢复码

    /// 重新生成 6 位恢复码，旧码立即失效；返回明文
    @discardableResult
    static func regenerateRecoveryCode() -> String {
        let code = (0..<6).map { _ in String(Int.random(in: 0...9)) }.joined()
        let salt = randomHex(bytes: 16)
        Keychain.set(hash(code, salt: salt), service: service, account: recoveryKey)
        return code
    }

    static func verifyRecoveryCode(_ code: String) -> Bool {
        guard let stored = Keychain.string(service: service, account: recoveryKey) else { return false }
        let parts = stored.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return false }
        return hash(code, salt: parts[0]) == stored
    }

    // MARK: - 第 ① 层：设备密码 / Face ID

    /// 用设备密码或 Face ID 确认是家长本人；只用于「忘记 PIN」，不能替代日常验证
    static func confirmWithDeviceOwner(reason: String = "确认是家长本人") async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "取消"
        var error: NSError?
        // 只允许 biometrics 或设备密码，避免误用其它策略
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return false
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                    localizedReason: reason)
        } catch {
            return false
        }
    }

    // MARK: - 第 ④ 层：Debug 重置（保留学习数据）

    /// 清掉 PIN 与恢复码，重新进入设置流程；`ItemProgress` / `Attempt` 等学习数据不动
    static func resetCredentials() {
        Keychain.remove(service: service, account: pinKey)
        Keychain.remove(service: service, account: recoveryKey)
        audit("credentials_reset")
    }

    // MARK: - 审计（进入 / 退出 / 重置）

    static var auditFileURL: URL {
        DiagnosticsLog.directory.appendingPathComponent("parent-audit.jsonl")
    }

    static func audit(_ event: String, detail: String = "") {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp)\t\(event)\t\(detail)\n"
        guard let data = line.data(using: .utf8) else { return }
        try? FileManager.default.createDirectory(at: DiagnosticsLog.directory,
                                                 withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: auditFileURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: auditFileURL)
        }
    }

    static func auditLines(limit: Int = 200) -> [String] {
        guard let text = try? String(contentsOf: auditFileURL, encoding: .utf8) else { return [] }
        return Array(text.split(separator: "\n").suffix(limit).map(String.init).reversed())
    }

    // MARK: - 内部

    /// `salt:hash`
    private static func hash(_ secret: String, salt: String) -> String {
        let digest = SHA256.hash(data: Data((salt + secret).utf8))
        return salt + ":" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func randomHex(bytes: Int) -> String {
        var buffer = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &buffer)
        return buffer.map { String(format: "%02x", $0) }.joined()
    }
}

/// 极简 Keychain 包装（只存字符串，设备解锁后可读）
enum Keychain {
    static func set(_ value: String, service: String, account: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func string(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func remove(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
