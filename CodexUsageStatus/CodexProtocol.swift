import Foundation

struct GetAccountRateLimitsResponse: Decodable, Equatable, Sendable {
    let rateLimits: RateLimitSnapshot
    let rateLimitsByLimitId: [String: RateLimitSnapshot]?
    let rateLimitResetCredits: RateLimitResetCreditsSummary?
}

struct RateLimitSnapshot: Decodable, Equatable, Sendable {
    let limitId: String?
    let limitName: String?
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?
}

struct RateLimitWindow: Decodable, Equatable, Sendable {
    let usedPercent: Int
    let windowDurationMins: Int64?
    let resetsAt: Int64?
}

struct RateLimitResetCreditsSummary: Decodable, Equatable, Sendable {
    let availableCount: Int64
    var credits: [RateLimitResetCredit]? = nil
}

struct RateLimitResetCredit: Decodable, Equatable, Sendable {
    let status: String
    let expiresAt: Int64?
}

struct AccountReadResponse: Decodable, Equatable, Sendable {
    let account: AccountInfo?
    let requiresOpenaiAuth: Bool
}

struct AccountInfo: Decodable, Equatable, Sendable {
    let type: String
    let email: String?
    let planType: String?
}

struct AccountRateLimitsUpdatedNotification: Decodable, Equatable, Sendable {
    let rateLimits: RateLimitSnapshot
}

enum CodexAppServerEvent: Equatable, Sendable {
    case rateLimitsUpdated(AccountRateLimitsUpdatedNotification)
    case disconnected(exitCode: Int32?)
}

protocol RateLimitProviding: Sendable {
    func start() async throws
    func readAccount() async throws -> AccountReadResponse
    func readRateLimits() async throws -> GetAccountRateLimitsResponse
    func events() async -> AsyncStream<CodexAppServerEvent>
    func stop() async
}

enum CodexAppServerError: LocalizedError, Equatable, Sendable {
    case executableNotFound
    case executableNotRunnable(String)
    case launchFailed
    case disconnected(Int32?)
    case requestTimedOut(String)
    case server(code: Int, message: String)
    case invalidResponse
    case notAuthenticated
    case unsupportedAccount(String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            L10n.tr("Codex CLI not found. Choose the codex executable in Settings")
        case let .executableNotRunnable(path):
            L10n.tr("Codex CLI is not executable: %@", "\(path)")
        case .launchFailed:
            L10n.tr("Unable to start Codex App Server")
        case let .disconnected(code):
            code.map { L10n.tr("Codex App Server exited (%@)", "\($0)") }
                ?? L10n.tr("Codex App Server disconnected")
        case let .requestTimedOut(method):
            L10n.tr("Codex request timed out: %@", "\(method)")
        case let .server(_, message):
            sanitizedServerMessage(message)
        case .invalidResponse:
            L10n.tr("Codex App Server returned unrecognized data")
        case .notAuthenticated:
            L10n.tr("Sign in to a ChatGPT account in Codex CLI first")
        case let .unsupportedAccount(type):
            L10n.tr("This Codex sign-in method does not support account usage queries: %@", "\(type)")
        }
    }

    private func sanitizedServerMessage(_ message: String) -> String {
        let lowered = message.lowercased()
        if lowered.contains("not logged in") || lowered.contains("authentication") {
            return L10n.tr("Sign in to a ChatGPT account in Codex CLI first")
        }
        if lowered.contains("method not found") {
            return L10n.tr("This Codex CLI version does not support usage queries. Upgrade Codex")
        }
        return L10n.tr("Codex App Server request failed")
    }
}
