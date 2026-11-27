import Foundation
import Combine

/// 设备绑定授权：注册机用共享密钥对「设备码」做 HMAC，App 用同一密钥校验。
/// 一个激活码只对生成它的设备有效；换机需重新签发。
/// 本类只读写 UserDefaults / Keychain，不触碰定位、配对或回环逻辑。
final class ActivationManager: ObservableObject {
    @Published private(set) var isActivated: Bool

    private let activatedKey = "dev.reloc.activation.v3"

    /// 与注册机 keygen.py 中的 SECRET 保持一致（32 字节）
    private static let secret: [UInt8] = [
        242, 69, 248, 169, 96, 183, 99, 119, 100, 52, 230, 200, 163, 206, 157, 183,
        100, 110, 143, 254, 155, 242, 196, 63, 143, 212, 91, 125, 9, 185, 254, 143
    ]

    init() {
        // 只有「当前设备码」对应的激活记录才算数，换机需重新授权
        let stored = UserDefaults.standard.string(forKey: activatedKey)
        isActivated = (stored == DeviceIdentity.code())
    }

    /// 展示给注册机的设备码
    var deviceCode: String { DeviceIdentity.code() }

    /// 校验激活码：Base32 解码后与本机设备码的 HMAC 前 16 字节比对
    @discardableResult
    func activate(with input: String) -> Bool {
        let code = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
        guard let provided = Base32.decode(code), provided.count == 16 else { return false }

        let mac = SimpleCrypto.hmacsha256(key: Self.secret, message: Array(deviceCode.utf8))
        let expected = Array(mac.prefix(16))

        guard Array(provided) == expected else { return false }
        UserDefaults.standard.set(deviceCode, forKey: activatedKey)
        isActivated = true
        return true
    }

    func deactivate() {
        UserDefaults.standard.removeObject(forKey: activatedKey)
        isActivated = false
    }
}
