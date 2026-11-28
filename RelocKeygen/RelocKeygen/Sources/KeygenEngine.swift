import Foundation

/// 注册机核心算法（与桌面 keygen.py 完全一致）：
/// - 永久码：Base32(HMAC(secret, 设备码)[:16])，26 字符
/// - 限时码：RLC2-YYYYMMDD-<26字符签名>，签名覆盖 设备码+到期日
enum KeygenEngine {
    /// 与 App 内置密钥一致（32 字节）
    private static let secret: [UInt8] = [
        242, 69, 248, 169, 96, 183, 99, 119, 100, 52, 230, 200, 163, 206, 157, 183,
        100, 110, 143, 254, 155, 242, 196, 63, 143, 212, 91, 125, 9, 185, 254, 143
    ]

    static func normalize(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined().uppercased()
    }

    private static func sign(_ payload: String) -> String {
        let mac = SimpleCrypto.hmacsha256(key: secret, message: Array(payload.utf8))
        return Base32.encode(Data(mac.prefix(16)))
    }

    /// 生成激活码。expiryDay 为 nil 表示永久；否则为 8 位到期日 YYYYMMDD
    static func generate(from input: String, expiryDay: String? = nil) -> String? {
        let device = normalize(input)
        guard !device.isEmpty else { return nil }

        guard let stamp = expiryDay else {
            return sign(device)
        }
        guard stamp.count == 8, stamp.allSatisfy({ $0.isNumber }), isValidDay(stamp) else {
            return nil
        }
        return "RLC2-\(stamp)-\(sign(device + "|" + stamp))"
    }

    private static func isValidDay(_ stamp: String) -> Bool {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        f.locale = Locale(identifier: "en_US_POSIX")
        guard let date = f.date(from: stamp) else { return false }
        return f.string(from: date) == stamp
    }

    /// 计算从今天起 N 天后的到期日字符串
    static func dayString(daysFromNow days: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? Date()
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        return f.string(from: date)
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
