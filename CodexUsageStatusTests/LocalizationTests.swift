import Foundation
import XCTest
@testable import CodexUsageStatus

final class LocalizationTests: XCTestCase {
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
