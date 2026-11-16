import Foundation
import XCTest
@testable import CodexUsageStatus

final class LocalizationTests: XCTestCase {
    @MainActor
    private func defaults() throws -> (name: String, values: UserDefaults) {
        let name = "CodexUsageStatusTests.Localization.\(UUID().uuidString)"
        let values = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { values.removePersistentDomain(forName: name) }
        return (name, values)
    }

    @MainActor
    func testLanguageDefaultsToSystemWithoutChangingExistingPreferences() throws {
        let defaults = try defaults()
        // Preserve a language selected outside the app, until the user chooses
        // an explicit override in our picker.
        defaults.values.set(["en-GB"], forKey: "AppleLanguages")
        let settings = UserSettings(defaults: defaults.values)
        XCTAssertEqual(settings.appLanguage, .system)
        XCTAssertFalse(settings.languageChangeRequiresRestart)
        XCTAssertEqual(defaults.values.persistentDomain(forName: defaults.name)?["AppleLanguages"] as? [String], ["en-GB"])
        XCTAssertEqual(AppLanguage.simplifiedChinese.title, "简体中文")
        XCTAssertEqual(AppLanguage.english.title, "English")
    }

    @MainActor
    func testLanguageSelectionPersistsNativePreferenceForNextLaunch() throws {
        let defaults = try defaults()
        let settings = UserSettings(defaults: defaults.values)
        let originalMonitor = settings.systemMonitor
        for language in [AppLanguage.simplifiedChinese, .english] {
            settings.setAppLanguage(language)
            XCTAssertEqual(settings.appLanguage, language)
            XCTAssertTrue(settings.languageChangeRequiresRestart)
            XCTAssertEqual(defaults.values.string(forKey: "appLanguage"), language.rawValue)
            // -testLanguage sets a higher-priority argument-domain value.
            // Check the persisted preference that will apply on the next launch.
            XCTAssertEqual(defaults.values.persistentDomain(forName: defaults.name)?["AppleLanguages"] as? [String], [language.rawValue])
            let restored = UserSettings(defaults: defaults.values)
            XCTAssertEqual(restored.appLanguage, language)
            XCTAssertFalse(restored.languageChangeRequiresRestart)
            XCTAssertEqual(restored.systemMonitor, originalMonitor)
            XCTAssertEqual(restored.refreshInterval, .tenMinutes)
            XCTAssertEqual(restored.menuBarDisplayMode, .both)
        }
    }

    @MainActor
    func testReturningToSystemRemovesOnlyLanguageOverrides() throws {
        let defaults = try defaults()
        let settings = UserSettings(defaults: defaults.values)
        settings.setRefreshInterval(.thirtyMinutes)
        settings.setAppLanguage(.english)
        settings.setAppLanguage(.system)
        XCTAssertFalse(settings.languageChangeRequiresRestart)
        let domain = try XCTUnwrap(defaults.values.persistentDomain(forName: defaults.name))
        XCTAssertNil(domain["appLanguage"])
        XCTAssertNil(domain["AppleLanguages"])
        let restored = UserSettings(defaults: defaults.values)
        XCTAssertEqual(restored.appLanguage, .system)
        XCTAssertEqual(restored.refreshInterval, .thirtyMinutes)
    }

    @MainActor
    func testRestartNoticeTracksChangesRelativeToLaunchSelection() throws {
        let defaults = try defaults()
        defaults.values.set(AppLanguage.english.rawValue, forKey: "appLanguage")
        defaults.values.set(["en"], forKey: "AppleLanguages")
        let settings = UserSettings(defaults: defaults.values)
        settings.setAppLanguage(.simplifiedChinese)
        XCTAssertTrue(settings.languageChangeRequiresRestart)
        settings.setAppLanguage(.english)
        XCTAssertFalse(settings.languageChangeRequiresRestart)
        settings.setAppLanguage(.system)
        XCTAssertTrue(settings.languageChangeRequiresRestart)
    }

    @MainActor
    func testUnsupportedSavedLanguageFallsBackToSystem() throws {
        let defaults = try defaults()
        defaults.values.set("unsupported", forKey: "appLanguage")
        XCTAssertEqual(UserSettings(defaults: defaults.values).appLanguage, .system)
    }

    private func bundle(_ language: String) throws -> Bundle {
        let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"))
        return try XCTUnwrap(Bundle(path: path))
    }

    private func table(_ language: String) throws -> [String: String] {
        let url = try XCTUnwrap(try bundle(language).url(forResource: "Localizable", withExtension: "strings"))
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
    }

    func testBothLanguagesArePackagedWithMatchingKeysAndFormatArguments() throws {
        let english = try table("en")
        let chinese = try table("zh-Hans")
        XCTAssertFalse(english.isEmpty)
        XCTAssertEqual(Set(english.keys), Set(chinese.keys))
        let specifier = try NSRegularExpression(pattern: #"%(?:[0-9]+\$)?@|%%"#)
        func placeholders(_ value: String) -> [String] {
            var nextArgument = 0
            return specifier.matches(in: value, range: NSRange(value.startIndex..., in: value)).map { match in
                let token = (value as NSString).substring(with: match.range)
                if token == "%%" { return token }
                if token == "%@" {
                    nextArgument += 1
                    return "argument \(nextArgument)"
                }
                return "argument " + token.dropFirst().prefix(while: { $0.isNumber })
            }.sorted()
        }
        for (key, value) in english {
            let translation = try XCTUnwrap(chinese[key])
            XCTAssertEqual(value, key, "English keys must remain usable as fallback text")
            XCTAssertFalse(translation.isEmpty, key)
            XCTAssertEqual(placeholders(value), placeholders(translation), key)
        }
    }

    func testStaticTextAndFormattedPercentagesInBothLanguages() throws {
        let english = try bundle("en")
        let chinese = try bundle("zh-Hans")
        XCTAssertEqual(L10n.tr("Developer Storage", bundle: english), "Developer Storage")
        XCTAssertEqual(L10n.tr("Developer Storage", bundle: chinese), "开发存储")
        XCTAssertEqual(L10n.tr("%@ remaining: %@%%", "5 hours", "75", bundle: english), "5 hours remaining: 75%")
        XCTAssertEqual(L10n.tr("%@ remaining: %@%%", "5 小时", "75", bundle: chinese), "5 小时剩余 75%")
        XCTAssertEqual(L10n.tr("Tmr %@", "01:00", bundle: english), "Tmr 01:00")
        XCTAssertEqual(L10n.tr("Tmr %@", "01:00", bundle: chinese), "明 01:00")
    }

    func testConfirmationFormattingPreservesPathsAndNewlines() throws {
        let path = "/tmp/测试 100% %@/device"
        for language in ["en", "zh-Hans"] {
            let text = L10n.tr("%@%@\nSize: %@%@\n\n%@", "Device\n", path, "1 MiB", "", "Impact", bundle: try bundle(language))
            XCTAssertTrue(text.contains("Device\n" + path + "\n"))
            XCTAssertTrue(text.hasSuffix("\n\nImpact"))
            XCTAssertFalse(text.contains(#"\n"#))
        }
    }

    func testLanguageNegotiationAndEnglishFallback() throws {
        XCTAssertEqual(Bundle.main.developmentLocalization, "en")
        let languages = Bundle.main.localizations
        XCTAssertTrue(languages.contains("en"))
        XCTAssertTrue(languages.contains("zh-Hans"))
        XCTAssertEqual(Bundle.preferredLocalizations(from: languages, forPreferences: ["en-GB"]), ["en"])
        XCTAssertEqual(Bundle.preferredLocalizations(from: languages, forPreferences: ["zh-Hans-CN"]), ["zh-Hans"])
        XCTAssertEqual(Bundle.preferredLocalizations(from: languages, forPreferences: ["fr"]), ["en"])
        XCTAssertEqual(L10n.tr("Missing translation %@", "value", bundle: try bundle("zh-Hans")), "Missing translation value")
    }
}
