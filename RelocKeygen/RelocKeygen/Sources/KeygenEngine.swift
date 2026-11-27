import Foundation

/// Reloc 注册机核心算法。
/// 与桌面版 keygen.py 完全一致：对设备码做 HMAC-SHA256，取前 16 字节转 Base32，得到 26 字符激活码。
/// 共享密钥只内置在注册机里，不出现在被授权的 App 中。
enum KeygenEngine {
    /// 与 Reloc App 内置密钥一致（32 字节）
    private static let secret: [UInt8] = [
        242, 69, 248, 169, 96, 183, 99, 119, 100, 52, 230, 200, 163, 206, 157, 183,
        100, 110, 143, 254, 155, 242, 196, 63, 143, 212, 91, 125, 9, 185, 254, 143
    ]

    /// 规范化设备码：去掉所有空白并转大写（与 App 端一致）
    static func normalize(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined().uppercased()
    }

    /// 输入设备码，返回 26 字符激活码
    static func generate(from input: String) -> String? {
        let device = normalize(input)
        guard !device.isEmpty else { return nil }
        let mac = SimpleCrypto.hmacsha256(key: secret, message: Array(device.utf8))
        return Base32.encode(Data(mac.prefix(16)))
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
}
