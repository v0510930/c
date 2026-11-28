import Foundation
import Combine

/// 设备绑定授权（支持有效期）：
/// - 永久码（旧格式）：Base32(HMAC(secret, 设备码)[:16])，26 字符，永不过期
/// - 限时码（新格式）：RLC2-YYYYMMDD-Base32(HMAC(secret, 设备码 + "|" + 到期日)[:16])
///   到期日被签名覆盖，篡改日期会使签名失效。
/// App 只内置共享密钥与校验逻辑，不签发激活码；不触碰定位 / 配对 / 回环逻辑。
final class ActivationManager: ObservableObject {
    @Published private(set) var isActivated: Bool
    @Published private(set) var expiryDate: Date?   // nil = 永久授权

    private static let recordKey = "dev.reloc.activation.v4"
    private static let legacyKey = "dev.reloc.activation.v3"

    /// 与注册机 keygen.py / KeygenEngine.swift 中的 SECRET 保持一致（32 字节）
    private static let secret: [UInt8] = [
        242, 69, 248, 169, 96, 183, 99, 119, 100, 52, 230, 200, 163, 206, 157, 183,
        100, 110, 143, 254, 155, 242, 196, 63, 143, 212, 91, 125, 9, 185, 254, 143
    ]

    init() {
        let (active, expiry) = Self.evaluateStored(for: DeviceIdentity.code())
        self.isActivated = active
        self.expiryDate = expiry
    }

    /// 展示给注册机的设备码
    var deviceCode: String { DeviceIdentity.code() }

    /// 供非 UI 入口（如快捷指令）即时检查当前授权状态，不涉及任何定位逻辑。
    static func isCurrentlyActivated() -> Bool {
        evaluateStored(for: DeviceIdentity.code()).0
    }

    /// 授权状态文案（供界面显示）
    var statusText: String {
        guard isActivated else { return "未激活" }
        guard let expiry = expiryDate else { return "已激活 · 永久有效" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return "已激活 · 有效期至 \(f.string(from: expiry))"
    }

    /// 校验并激活。支持永久码与限时码，兼容旧版已激活用户。
    @discardableResult
    func activate(with input: String) -> Bool {
        let code = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .uppercased()

        let device = DeviceIdentity.code()

        if let result = Self.parseTimedCode(code, device: device) {
            Self.saveRecord(device: device, expiryDay: result.day)
            isActivated = true
            expiryDate = result.date
            return true
        }

        if Self.verifyPermanentCode(code, device: device) {
            Self.saveRecord(device: device, expiryDay: nil)
            isActivated = true
            expiryDate = nil
            return true
        }

        return false
    }

    func deactivate() {
        KeychainStore.remove(Self.recordKey)
        KeychainStore.remove(Self.legacyKey)
        UserDefaults.standard.removeObject(forKey: Self.legacyKey)
        isActivated = false
        expiryDate = nil
    }

    // MARK: - 校验逻辑

    private static func verifyPermanentCode(_ code: String, device: String) -> Bool {
        guard let provided = Base32.decode(code), provided.count == 16 else { return false }
        let mac = SimpleCrypto.hmacsha256(key: secret, message: Array(device.utf8))
        return Array(provided) == Array(mac.prefix(16))
    }

    /// 解析 RLC2-YYYYMMDD-签名，返回到期日（日期已过则视为无效）
    private static func parseTimedCode(_ code: String, device: String) -> (day: Int, date: Date)? {
        let parts = code.split(separator: "-")
        guard parts.count == 3, parts[0] == "RLC2" else { return nil }
        let dayString = String(parts[1])
        guard dayString.count == 8, let day = Int(dayString), Self.isValidDay(day) else { return nil }
        guard let date = Self.date(fromDay: day), date >= Self.todayStart() else { return nil }

        let signature = String(parts[2])
        guard let provided = Base32.decode(signature), provided.count == 16 else { return nil }
        let payload = "\(device)|\(dayString)"
        let mac = SimpleCrypto.hmacsha256(key: secret, message: Array(payload.utf8))
        guard Array(provided) == Array(mac.prefix(16)) else { return nil }
        return (day, date)
    }

    // MARK: - 存储与状态判定

    private static func saveRecord(device: String, expiryDay: Int?) {
        let expiry = expiryDay.map(String.init) ?? "PERMANENT"
        KeychainStore.save("\(device)|\(expiry)", key: recordKey)
    }

    /// 读取存储记录，判断是否仍有效（同时迁移旧版 UserDefaults 记录）
    private static func evaluateStored(for device: String) -> (Bool, Date?) {
        var raw: String?
        if let stored = KeychainStore.read(recordKey), !stored.isEmpty {
            raw = stored
        } else if let legacy = UserDefaults.standard.string(forKey: legacyKey), legacy == device {
            // 旧版永久授权，直接迁移
            saveRecord(device: device, expiryDay: nil)
            return (true, nil)
        }
        guard let record = raw else { return (false, nil) }

        let parts = record.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 2, String(parts[0]) == device else { return (false, nil) }

        let expiryToken = String(parts[1])
        if expiryToken == "PERMANENT" { return (true, nil) }
        guard let day = Int(expiryToken), let expiry = date(fromDay: day) else { return (false, nil) }

        if expiry < todayStart() {
            // 已过期，清除记录，回到未激活状态
            KeychainStore.remove(recordKey)
            return (false, expiry)
        }
        return (true, expiry)
    }

    // MARK: - 日期工具

    private static func todayStart() -> Date {
        let cal = Calendar.current
        return cal.startOfDay(for: Date())
    }

    private static func isValidDay(_ day: Int) -> Bool {
        guard let date = date(fromDay: day) else { return false }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        return Int(f.string(from: date)) == day
    }

    private static func date(fromDay day: Int) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: String(day))
    }
}
