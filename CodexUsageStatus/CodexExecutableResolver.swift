import Foundation

enum CodexExecutableResolver {
    private static let knownPaths = [
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex",
    ]

    static func resolve(preferredPath: String, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        let candidates = candidatePaths(
            preferredPath: preferredPath,
            environment: environment
        )

        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path).standardizedFileURL
        }

        if !preferredPath.isEmpty {
            throw CodexAppServerError.executableNotRunnable(preferredPath)
        }
        throw CodexAppServerError.executableNotFound
    }

    static func candidatePaths(
        preferredPath: String,
        environment: [String: String]
    ) -> [String] {
        var candidates: [String] = []

        if !preferredPath.isEmpty {
            candidates.append(preferredPath)
        }

        if let path = environment["PATH"] {
            candidates.append(
                contentsOf: path
                    .split(separator: ":")
                    .map { String($0) + "/codex" }
            )
        }

        candidates.append(contentsOf: knownPaths)

        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }
}
