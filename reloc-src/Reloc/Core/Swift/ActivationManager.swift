import Foundation
import Combine

/// 轻量授权码机制：只读写 UserDefaults，不触碰定位、配对或回环逻辑。
/// 修改授权码只需改下面的 validCodes。
final class ActivationManager: ObservableObject {
    @Published private(set) var isActivated: Bool

    private let defaults = UserDefaults.standard
    private let activatedKey = "dev.reloc.activation.activated"

    /// 有效授权码（大小写不敏感，首尾空格会被忽略）。
    /// 想换码时直接修改这个集合即可。
    static let validCodes: Set<String> = [
        "RELOC-2026",
        "GUAIKA-666"
    ]

    init() {
        isActivated = UserDefaults.standard.bool(forKey: activatedKey)
    }

    @discardableResult
    func activate(with input: String) -> Bool {
        let normalized = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard Self.validCodes.contains(normalized) else { return false }
        defaults.set(true, forKey: activatedKey)
        isActivated = true
        return true
    }

    func deactivate() {
        defaults.set(false, forKey: activatedKey)
        isActivated = false
    }
}
