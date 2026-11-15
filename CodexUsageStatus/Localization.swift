import Foundation

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
