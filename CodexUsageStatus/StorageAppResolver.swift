import CoreServices
import Foundation

protocol StorageAppResolving: Sendable {
    func installedAppURLs(forBundleIdentifier identifier: String) -> [URL]
}

struct LaunchServicesAppResolver: StorageAppResolving {
    func installedAppURLs(forBundleIdentifier identifier: String) -> [URL] {
        guard let urls = LSCopyApplicationURLsForBundleIdentifier(identifier as CFString, nil)?
            .takeRetainedValue() as? [URL] else { return [] }
        return urls
    }
}

enum StorageAppBundleID {
    // A directory name only counts as a bundle identifier when it looks like a
    // reverse-DNS name. Anything else cannot be resolved to an owning app.
    private static let pattern = #"^[A-Za-z][A-Za-z0-9-]*(?:\.[A-Za-z0-9-]+)+$"#

    static func isBundleID(_ name: String) -> Bool {
        name.range(of: pattern, options: .regularExpression) != nil
    }
}
