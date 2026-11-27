import CommonCrypto
import LocalAuthentication
import Security
import SwiftUI

@MainActor
final class AppLock: ObservableObject {
    static let shared = AppLock()
    static let pinLength = 6

    static let lockNowNotification = Notification.Name("AppLock.lockNow")

    enum AutoLockDelay: Int, Codable, CaseIterable {
        case disabled = -1, immediate = 0, oneMinute = 60, fiveMinutes = 300
        case oneHour = 3600, fiveHours = 18000

        var title: String {
            switch self {
            case .disabled: return "停用"
            case .immediate: return "立即"
            case .oneMinute: return "离开 1 分钟后"
            case .fiveMinutes: return "离开 5 分钟后"
            case .oneHour: return "离开 1 小时后"
            case .fiveHours: return "离开 5 小时后"
            }
        }

        func hasElapsed(nanoseconds: UInt64) -> Bool {
            self != .disabled && nanoseconds >= UInt64(rawValue) * 1_000_000_000
        }
    }

    struct Credential: Codable {
        let id: UUID
        let salt: Data
        let verifier: Data
        // Records written before PIN support contain unrestricted passwords.
        var numericPIN: Bool?
        var faceIDState: Data?
        var autoLockDelay: AutoLockDelay?
        var failures = 0
        var nextAttempt = Date.distantPast
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    @Published private(set) var credential: Credential?
    @Published private(set) var storageUnavailable = false

    private var query: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword,
         kSecAttrService: (Bundle.main.bundleIdentifier ?? "miaoreader") + ".app-lock",
         kSecAttrAccount: "credential"]
    }

    private init() { reload() }

    func reload() {
        var request = query
        request[kSecReturnData] = true
        var result: CFTypeRef?
        switch SecItemCopyMatching(request as CFDictionary, &result) {
        case errSecItemNotFound:
            credential = nil
        case errSecSuccess:
            guard let data = result as? Data,
                  let record = try? JSONDecoder().decode(Credential.self, from: data) else {
                storageUnavailable = true
                return
            }
            credential = record
        default:
            storageUnavailable = true
            return
        }
        storageUnavailable = false
    }

    private func save(_ record: Credential) throws {
        let data = try JSONEncoder().encode(record)
        let status: OSStatus
        if credential == nil {
            var item = query
            item[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            item[kSecValueData] = data
            status = SecItemAdd(item as CFDictionary, nil)
        } else {
            status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        }
        guard status == errSecSuccess else { throw Failure("无法保存应用锁设置，请重试。") }
        credential = record
    }

    private func verifier(_ password: String, salt: Data) throws -> Data {
        let bytes = Array(password.utf8)
        var key = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltBytes in
            bytes.withUnsafeBytes { passwordBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBytes.bindMemory(to: Int8.self).baseAddress, bytes.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 600_000, &key, 32)
            }
        }
        guard status == kCCSuccess else { throw Failure("无法校验密码，请重试。") }
        return Data(key)
    }

    func setPassword(_ password: String, replacing old: String) throws {
        guard !storageUnavailable else { throw Failure("请先解锁设备，再重试。") }
        guard password.utf8.count == Self.pinLength, password.utf8.allSatisfy({ (48...57).contains($0) }) else {
            throw Failure("请设置 6 位数字密码。")
        }
        if credential != nil { try verify(old) }
        var salt = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt) == errSecSuccess else {
            throw Failure("无法创建密码，请重试。")
        }
        let data = Data(salt)
        try save(Credential(id: UUID(), salt: data, verifier: try verifier(password, salt: data),
                            numericPIN: true, faceIDState: credential?.faceIDState, autoLockDelay: autoLockDelay))
    }

    func verify(_ password: String) throws {
        guard !storageUnavailable, var record = credential else { throw Failure("无法读取应用锁。") }
        let seconds = Int(ceil(record.nextAttempt.timeIntervalSinceNow))
        guard seconds <= 0 else { throw Failure("尝试次数过多，请在 \(seconds) 秒后重试。") }
        guard try verifier(password, salt: record.salt) == record.verifier else {
            record.failures = min(10, record.failures + 1)
            if record.failures >= 5 {
                record.nextAttempt = Date().addingTimeInterval(30 * pow(2, Double(record.failures - 5)))
            }
            try save(record)
            throw Failure(record.failures >= 5 ? "密码错误，请稍后重试。" : "密码错误，请重新输入。")
        }
        if record.failures > 0 {
            record.failures = 0
            record.nextAttempt = .distantPast
            try save(record)
        }
    }

    func disable(password: String) throws {
        try verify(password)
        guard SecItemDelete(query as CFDictionary) == errSecSuccess else {
            throw Failure("无法关闭应用锁，请重试。")
        }
        credential = nil
    }

    var autoLockDelay: AutoLockDelay { credential?.autoLockDelay ?? .immediate }

    func setAutoLockDelay(_ delay: AutoLockDelay) throws {
        guard var record = credential, !storageUnavailable else { throw Failure("无法读取应用锁。") }
        record.autoLockDelay = delay
        try save(record)
    }

    func lockNow() {
        guard credential != nil else { return }
        NotificationCenter.default.post(name: Self.lockNowNotification, object: self)
    }

    static var supportsFaceID: Bool {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return context.biometryType == .faceID
    }

    static func authenticateFaceID(_ context: LAContext) async throws -> Data {
        let policy = LAPolicy.deviceOwnerAuthenticationWithBiometrics
        context.localizedFallbackTitle = "使用应用密码"
        let unavailable = Failure("Face ID 暂不可用，请使用应用密码。")
        guard context.canEvaluatePolicy(policy, error: nil), context.biometryType == .faceID,
              try await context.evaluatePolicy(policy, localizedReason: "验证身份以使用喵阅应用锁") else {
            throw unavailable
        }
        let state: Data?
        if #available(iOS 18, *) {
            state = context.domainState.biometry.stateHash
        } else {
            state = context.evaluatedPolicyDomainState
        }
        guard let state else { throw unavailable }
        return state
    }

    func setFaceID(_ state: Data?, for id: UUID) throws {
        guard var record = credential, record.id == id, !storageUnavailable else {
            throw Failure("应用锁设置已变更，请重新操作。")
        }
        record.faceIDState = state
        try save(record)
    }
}
