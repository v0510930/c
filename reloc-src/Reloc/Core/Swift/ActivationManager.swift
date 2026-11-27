import Foundation
import Combine
import CryptoKit

/// 设备绑定授权：注册机用私钥对设备码签名，App 只用内置公钥验签。
/// 私钥不在 App 内，逆向 App 无法自行签发激活码。
/// 本类只读写 UserDefaults / Keychain，不触碰定位、配对或回环逻辑。
final class ActivationManager: ObservableObject {
    @Published private(set) var isActivated: Bool

    private let activatedKey = "dev.reloc.activation.v2"

    /// 与注册机 reloc_private_key.pem 配对的 Ed25519 公钥（32 字节）
    private static let publicKeyBytes: [UInt8] = [
        20, 175, 45, 230, 250, 39, 87, 127, 58, 21, 123, 69, 79, 84,
        39, 141, 177, 35, 249, 138, 63, 95, 144, 236, 77, 187, 251,
        165, 249, 188, 140, 133
    ]

    init() {
        // 只有「当前设备码」对应的激活记录才算数，换机需重新授权
        let stored = UserDefaults.standard.string(forKey: activatedKey)
        isActivated = (stored == DeviceIdentity.code())
    }

    /// 展示给注册机的设备码
    var deviceCode: String { DeviceIdentity.code() }

    /// 校验激活码：用公钥验证「注册机对本机设备码的签名」
    @discardableResult
    func activate(with input: String) -> Bool {
        let code = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let signatureData = Base64URL.decode(code),
              let publicKey = try? Ed25519.Signing.PublicKey(rawRepresentation: Data(Self.publicKeyBytes)),
              let signature = try? Ed25519.Signing.Signature(rawRepresentation: signatureData),
              publicKey.isValidSignature(signature, for: Data(deviceCode.utf8))
        else {
            return false
        }
        UserDefaults.standard.set(deviceCode, forKey: activatedKey)
        isActivated = true
        return true
    }

    func deactivate() {
        UserDefaults.standard.removeObject(forKey: activatedKey)
        isActivated = false
    }
}
