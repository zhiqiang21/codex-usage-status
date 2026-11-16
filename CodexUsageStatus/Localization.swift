import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: L10n.tr("System Default")
        // Keep language names recognizable regardless of the current language.
        case .simplifiedChinese: "简体中文"
        case .english: "English"
        }
    }

    var preferredLanguages: [String]? {
        self == .system ? nil : [rawValue]
    }
}

/// Uses macOS language negotiation, including per-app language preferences.
/// English source keys also provide a readable fallback for missing translations.
enum L10n {
    static func tr(_ key: String, _ arguments: String..., bundle: Bundle = .main) -> String {
        let format = bundle.localizedString(forKey: key, value: key, table: "Localizable")
        guard !arguments.isEmpty else { return format }
        // String-only arguments keep format specifiers consistent across Swift
        // integer widths and allow translations to reorder them with %1$@.
        return String(format: format, locale: Locale.current, arguments: arguments)
    }
}
