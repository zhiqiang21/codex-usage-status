import Foundation

enum RefreshInterval: Int, CaseIterable, Identifiable, Sendable {
    case tenMinutes = 600
    case thirtyMinutes = 1_800
    case oneHour = 3_600

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .tenMinutes:
            "10 分钟"
        case .thirtyMinutes:
            "30 分钟"
        case .oneHour:
            "1 小时"
        }
    }

    var timeInterval: TimeInterval {
        TimeInterval(rawValue)
    }
}

@MainActor
final class UserSettings: ObservableObject {
    private enum Key {
        static let refreshInterval = "refreshInterval"
        static let executablePath = "codexExecutablePath"
    }

    private let defaults: UserDefaults

    @Published private(set) var refreshInterval: RefreshInterval
    @Published private(set) var executablePath: String

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        refreshInterval = RefreshInterval(
            rawValue: defaults.integer(forKey: Key.refreshInterval)
        ) ?? .tenMinutes
        executablePath = defaults.string(forKey: Key.executablePath) ?? ""
    }

    func setRefreshInterval(_ interval: RefreshInterval) {
        guard refreshInterval != interval else { return }
        refreshInterval = interval
        defaults.set(interval.rawValue, forKey: Key.refreshInterval)
    }

    func setExecutablePath(_ path: String?) {
        let normalizedPath = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard executablePath != normalizedPath else { return }
        executablePath = normalizedPath

        if normalizedPath.isEmpty {
            defaults.removeObject(forKey: Key.executablePath)
        } else {
            defaults.set(normalizedPath, forKey: Key.executablePath)
        }
    }
}

struct UsageSnapshot: Equatable, Sendable {
    let remainingPercent: Int
    let resetsAt: Date?
    let resetCreditCount: Int?
    let updatedAt: Date

    static let preview = UsageSnapshot(
        remainingPercent: 75,
        resetsAt: Date().addingTimeInterval(3 * 24 * 60 * 60 + 3_600),
        resetCreditCount: 1,
        updatedAt: Date()
    )
}

enum UsageViewState: Equatable, Sendable {
    case idle
    case loading
    case loaded(snapshot: UsageSnapshot, isStale: Bool, message: String?)
    case failed(message: String)

    var snapshot: UsageSnapshot? {
        switch self {
        case let .loaded(snapshot, _, _):
            snapshot
        case .idle, .loading, .failed:
            nil
        }
    }
}

struct UsageMenuBarPresentation: Equatable, Sendable {
    let remainingText: String
    let resetText: String
    let resetCreditText: String?

    static func make(
        from state: UsageViewState,
        now: Date
    ) -> UsageMenuBarPresentation {
        guard let snapshot = state.snapshot else {
            return switch state {
            case .idle, .loading:
                UsageMenuBarPresentation(
                    remainingText: "…",
                    resetText: "…",
                    resetCreditText: nil
                )
            case .failed, .loaded:
                UsageMenuBarPresentation(
                    remainingText: "--%",
                    resetText: "--",
                    resetCreditText: nil
                )
            }
        }

        return UsageMenuBarPresentation(
            remainingText: "\(snapshot.remainingPercent)%",
            resetText: compactResetText(until: snapshot.resetsAt, now: now),
            resetCreditText: snapshot.resetCreditCount.flatMap {
                $0 > 0 ? String($0) : nil
            }
        )
    }

    private static func compactResetText(
        until resetDate: Date?,
        now: Date
    ) -> String {
        guard let resetDate else { return "--" }

        let remainingSeconds = resetDate.timeIntervalSince(now)
        guard remainingSeconds > 0 else { return "now" }

        let totalMinutes = max(
            Int(ceil(remainingSeconds / 60)),
            1
        )
        let days = totalMinutes / (24 * 60)
        let hours = totalMinutes % (24 * 60) / 60
        let minutes = totalMinutes % 60

        if days > 0 {
            return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
        }

        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }

        return "\(minutes)m"
    }
}

enum UsageSelectionError: LocalizedError, Equatable, Sendable {
    case weeklyWindowUnavailable

    var errorDescription: String? {
        switch self {
        case .weeklyWindowUnavailable:
            "Codex 未返回 7 天用量窗口"
        }
    }
}

enum UsageSnapshotBuilder {
    static let weeklyWindowDurationMinutes: Int64 = 10_080

    static func makeSnapshot(
        from response: GetAccountRateLimitsResponse,
        now: Date
    ) throws -> UsageSnapshot {
        guard let window = selectWeeklyWindow(from: response) else {
            throw UsageSelectionError.weeklyWindowUnavailable
        }

        return UsageSnapshot(
            remainingPercent: remainingPercent(from: window.usedPercent),
            resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            resetCreditCount: response.rateLimitResetCredits.flatMap {
                safeNonnegativeInt($0.availableCount)
            },
            updatedAt: now
        )
    }

    static func merging(
        _ update: AccountRateLimitsUpdatedNotification,
        into snapshot: UsageSnapshot,
        now: Date
    ) -> UsageSnapshot {
        guard update.rateLimits.limitId == nil || update.rateLimits.limitId == "codex",
              let window = selectWeeklyWindow(in: update.rateLimits)
        else {
            return snapshot
        }

        return UsageSnapshot(
            remainingPercent: remainingPercent(from: window.usedPercent),
            resetsAt: window.resetsAt
                .map { Date(timeIntervalSince1970: TimeInterval($0)) }
                ?? snapshot.resetsAt,
            resetCreditCount: snapshot.resetCreditCount,
            updatedAt: now
        )
    }

    static func selectWeeklyWindow(
        from response: GetAccountRateLimitsResponse
    ) -> RateLimitWindow? {
        var snapshots: [RateLimitSnapshot] = []

        if let codexSnapshot = response.rateLimitsByLimitId?["codex"] {
            snapshots.append(codexSnapshot)
        }

        if !snapshots.contains(where: { $0 == response.rateLimits }) {
            snapshots.append(response.rateLimits)
        }

        return snapshots.lazy.compactMap(selectWeeklyWindow(in:)).first
    }

    private static func selectWeeklyWindow(
        in snapshot: RateLimitSnapshot
    ) -> RateLimitWindow? {
        [snapshot.primary, snapshot.secondary]
            .compactMap { $0 }
            .first { $0.windowDurationMins == weeklyWindowDurationMinutes }
    }

    private static func remainingPercent(from usedPercent: Int) -> Int {
        min(max(100 - usedPercent, 0), 100)
    }

    private static func safeNonnegativeInt(_ value: Int64) -> Int? {
        guard value >= 0, value <= Int64(Int.max) else { return nil }
        return Int(value)
    }
}

enum RefreshPolicy {
    static func nextRefreshDate(
        after date: Date,
        interval: RefreshInterval
    ) -> Date {
        date.addingTimeInterval(interval.timeInterval)
    }

    static func shouldRefresh(
        lastFullRefreshAt: Date?,
        resetDate: Date?,
        now: Date,
        interval: RefreshInterval
    ) -> Bool {
        if let resetDate, resetDate <= now {
            return true
        }

        guard let lastFullRefreshAt else { return true }
        return now.timeIntervalSince(lastFullRefreshAt) >= interval.timeInterval
    }

    static func resetRefreshDate(for resetDate: Date?) -> Date? {
        resetDate?.addingTimeInterval(2)
    }
}
