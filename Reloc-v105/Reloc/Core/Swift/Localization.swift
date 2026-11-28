import Foundation

public enum AppLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case system
    case en
    case zhHans = "zh-Hans"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: return L10n.tr("settings.language.system")
        case .en: return "English"
        case .zhHans: return "简体中文"
        }
    }

    public var locale: Locale {
        switch self {
        case .system: return .autoupdatingCurrent
        case .en: return Locale(identifier: "en")
        case .zhHans: return Locale(identifier: "zh-Hans")
        }
    }
}

public enum L10n {
    public static let languageDefaultsKey = "reloc.language"

    public static var currentLanguage: AppLanguage {
        if let raw = UserDefaults.standard.string(forKey: languageDefaultsKey),
           let lang = AppLanguage(rawValue: raw) {
            return lang
        }
        return .system
    }

    public static var resolvedLanguageCode: String {
        switch currentLanguage {
        case .en:
            return "en"
        case .zhHans:
            return "zh-Hans"
        case .system:
            let preferred = Bundle.main.preferredLocalizations.first ?? Locale.preferredLanguages.first ?? "en"
            return preferred.lowercased().hasPrefix("zh") ? "zh-Hans" : "en"
        }
    }

    public static var isChinese: Bool {
        resolvedLanguageCode.lowercased().hasPrefix("zh")
    }

    public static var activeBundle: Bundle {
        let code = resolvedLanguageCode
        if let path = Bundle.main.path(forResource: code, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }
        return .main
    }

    public static func tr(_ key: String) -> String {
        activeBundle.localizedString(forKey: key, value: nil, table: nil)
    }

    public static func format(_ key: String, _ args: CVarArg...) -> String {
        let template = tr(key)
        return String(format: template, locale: currentLanguage.locale, arguments: args)
    }
}
