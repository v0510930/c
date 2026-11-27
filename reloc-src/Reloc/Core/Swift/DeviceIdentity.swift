import Foundation
import CryptoKit
import Security

/// 设备身份：生成与本机绑定、卸载重装也不会变的设备码。
/// 设备码是注册机的输入；App 端只内置公钥，不内置私钥。
enum DeviceIdentity {
    private static let uuidKey = "dev.reloc.device.uuid"

    /// 设备码，形如 RLC-ABCD-EFGH-IJKL-MNOP
    static func code() -> String {
        let uuid = stableUUID()
        let digest = SHA256.hash(data: Data(uuid.utf8))
        let raw = Base32.encode(Data(digest.prefix(15))) // 15 bytes -> 24 chars
        var parts: [String] = []
        var index = raw.startIndex
        while index < raw.endIndex {
            let end = raw.index(index, offsetBy: 6, limitedBy: raw.endIndex) ?? raw.endIndex
            parts.append(String(raw[index..<end]))
            index = end
        }
        return "RLC-" + parts.joined(separator: "-")
    }

    /// 规范化设备码：去掉所有空白并转大写（与注册机一致）
    static func normalize(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined().uppercased()
    }

    private static func stableUUID() -> String {
        if let saved = KeychainStore.read(uuidKey), !saved.isEmpty {
            return saved
        }
        let fresh = UUID().uuidString
        KeychainStore.save(fresh, key: uuidKey)
        return fresh
    }
}

/// RFC 4648 Base32（无填充，大写字母 A-Z2-7）
enum Base32 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    static func encode(_ data: Data) -> String {
        var bits = 0
        var value = 0
        var out = ""
        for byte in data {
            value = (value << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[(value >> (bits - 5)) & 31])
                bits -= 5
            }
        }
        if bits > 0 {
            out.append(alphabet[(value << (5 - bits)) & 31])
        }
        return out
    }

    static func decode(_ value: String) -> Data? {
        var bits = 0
        var buffer = 0
        var out = [UInt8]()
        for character in value.uppercased() {
            guard let index = alphabet.firstIndex(of: character) else { return nil }
            buffer = (buffer << 5) | index
            bits += 5
            if bits >= 8 {
                out.append(UInt8((buffer >> (bits - 8)) & 0xff))
                bits -= 8
            }
        }
        return Data(out)
    }
}

/// Base64url（无填充）解码，用于把激活码还原成 Ed25519 签名
enum Base64URL {
    static func decode(_ value: String) -> Data? {
        var s = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = s.count % 4
        if remainder == 2 { s += "==" }
        else if remainder == 3 { s += "=" }
        else if remainder == 1 { return nil }
        return Data(base64Encoded: s)
    }
}

/// 最小 Keychain 封装：设备 UUID 存这里，删除 App 后仍然存在
enum KeychainStore {
    static func read(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ value: String, key: String) -> Bool {
        let data = Data(value.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        var status = SecItemAdd(base.merging([kSecValueData as String: data]) { _, new in new } as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
        return status == errSecSuccess
    }
}
