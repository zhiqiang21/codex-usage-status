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
            "未找到 Codex CLI，请在设置中选择 codex 可执行文件"
        case let .executableNotRunnable(path):
            "Codex CLI 不可执行：\(path)"
        case .launchFailed:
            "无法启动 Codex App Server"
        case let .disconnected(code):
            code.map { "Codex App Server 已退出（\($0)）" }
                ?? "Codex App Server 连接已断开"
        case let .requestTimedOut(method):
            "Codex 请求超时：\(method)"
        case let .server(_, message):
            sanitizedServerMessage(message)
        case .invalidResponse:
            "Codex App Server 返回了无法识别的数据"
        case .notAuthenticated:
            "请先在 Codex CLI 中登录 ChatGPT 账户"
        case let .unsupportedAccount(type):
            "当前 Codex 登录方式不支持账户用量查询：\(type)"
        }
    }

    private func sanitizedServerMessage(_ message: String) -> String {
        let lowered = message.lowercased()
        if lowered.contains("not logged in") || lowered.contains("authentication") {
            return "请先在 Codex CLI 中登录 ChatGPT 账户"
        }
        if lowered.contains("method not found") {
            return "当前 Codex CLI 版本不支持用量查询，请升级 Codex"
        }
        return "Codex App Server 请求失败"
    }
}
