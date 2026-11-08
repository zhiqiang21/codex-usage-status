import Foundation

enum MenuBarDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case fiveHour
    case weekly
    case both

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fiveHour:
            "5 小时"
        case .weekly:
            "一周"
        case .both:
            "两者都显示"
        }
    }

    var showsFiveHour: Bool { self != .weekly }
    var showsWeekly: Bool { self != .fiveHour }
}

enum RefreshInterval: Int, CaseIterable, Identifiable, Sendable {
    case fiveMinutes = 300
    case tenMinutes = 600
    case thirtyMinutes = 1_800
    case oneHour = 3_600

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .fiveMinutes:
            "5 分钟"
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
        static let menuBarDisplayMode = "menuBarDisplayMode"
        static let showsResetCreditsInMenuBar = "showsResetCreditsInMenuBar"
        static let refreshInterval = "refreshInterval"
        static let executablePath = "codexExecutablePath"
    }

    private let defaults: UserDefaults

    @Published private(set) var menuBarDisplayMode: MenuBarDisplayMode
    @Published private(set) var showsResetCreditsInMenuBar: Bool
    @Published private(set) var refreshInterval: RefreshInterval
    @Published private(set) var executablePath: String
    @Published private(set) var systemMonitor: SystemMonitorSettings

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        systemMonitor = SystemMonitorSettings(defaults: defaults)
        menuBarDisplayMode = defaults.string(forKey: Key.menuBarDisplayMode)
            .flatMap(MenuBarDisplayMode.init(rawValue:)) ?? .both
        showsResetCreditsInMenuBar = defaults.object(forKey: Key.showsResetCreditsInMenuBar)
            as? Bool ?? true
        refreshInterval = RefreshInterval(
            rawValue: defaults.integer(forKey: Key.refreshInterval)
        ) ?? .tenMinutes
        executablePath = defaults.string(forKey: Key.executablePath) ?? ""
    }

    func setSystemMetric(_ metric: SystemMetric, at location: SystemMetricLocation, visible: Bool) {
        var updated = systemMonitor
        if location == .menuBar {
            if visible { updated.menuBar.insert(metric) } else { updated.menuBar.remove(metric) }
        } else {
            if visible { updated.details.insert(metric) } else { updated.details.remove(metric) }
        }
        guard updated != systemMonitor else { return }
        defaults.set(visible, forKey: SystemMonitorSettings.visibilityKey(metric, at: location))
        systemMonitor = updated
    }

    func setSystemRefreshInterval(_ interval: SystemRefreshInterval) {
        guard systemMonitor.interval != interval else { return }
        var updated = systemMonitor
        updated.interval = interval
        defaults.set(interval.rawValue, forKey: SystemMonitorSettings.intervalKey)
        systemMonitor = updated
    }

    func setMenuBarDisplayMode(_ mode: MenuBarDisplayMode) {
        guard menuBarDisplayMode != mode else { return }
        menuBarDisplayMode = mode
        defaults.set(mode.rawValue, forKey: Key.menuBarDisplayMode)
    }

    func setShowsResetCreditsInMenuBar(_ isShown: Bool) {
        guard showsResetCreditsInMenuBar != isShown else { return }
        showsResetCreditsInMenuBar = isShown
        defaults.set(isShown, forKey: Key.showsResetCreditsInMenuBar)
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

struct UsageWindowSnapshot: Equatable, Sendable {
    let remainingPercent: Int
    let resetsAt: Date?
}

struct UsageSnapshot: Equatable, Sendable {
    let weeklyWindow: UsageWindowSnapshot?
    let fiveHourWindow: UsageWindowSnapshot?
    let resetCreditCount: Int?
    let updatedAt: Date

    var resetDates: [Date] {
        [weeklyWindow?.resetsAt, fiveHourWindow?.resetsAt].compactMap { $0 }
    }

    static let preview = UsageSnapshot(
        weeklyWindow: UsageWindowSnapshot(
            remainingPercent: 75,
            resetsAt: Date().addingTimeInterval(3 * 24 * 60 * 60 + 3_600)
        ),
        fiveHourWindow: UsageWindowSnapshot(
            remainingPercent: 60,
            resetsAt: Date().addingTimeInterval(2 * 3_600)
        ),
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
    let fiveHourRemainingText: String
    let fiveHourResetText: String
    let resetCreditText: String?

    static func make(
        from state: UsageViewState,
        now: Date,
        calendar: Calendar = .current
    ) -> UsageMenuBarPresentation {
        guard let snapshot = state.snapshot else {
            return switch state {
            case .idle, .loading:
                UsageMenuBarPresentation(
                    remainingText: "…",
                    resetText: "…",
                    fiveHourRemainingText: "…",
                    fiveHourResetText: "…",
                    resetCreditText: nil
                )
            case .failed, .loaded:
                UsageMenuBarPresentation(
                    remainingText: "--%",
                    resetText: "--",
                    fiveHourRemainingText: "--%",
                    fiveHourResetText: "--",
                    resetCreditText: nil
                )
            }
        }

        return UsageMenuBarPresentation(
            remainingText: snapshot.weeklyWindow.map { "\($0.remainingPercent)%" } ?? "--%",
            resetText: resetLabel(
                until: snapshot.weeklyWindow?.resetsAt, now: now,
                calendar: calendar, style: .date
            ),
            fiveHourRemainingText: snapshot.fiveHourWindow.map { "\($0.remainingPercent)%" } ?? "--%",
            fiveHourResetText: resetLabel(
                until: snapshot.fiveHourWindow?.resetsAt, now: now,
                calendar: calendar, style: .time
            ),
            resetCreditText: snapshot.resetCreditCount.flatMap {
                $0 > 0 ? String($0) : nil
            }
        )
    }

    private enum ResetLabelStyle {
        case time
        case date
    }

    private static func resetLabel(
        until resetDate: Date?,
        now: Date,
        calendar: Calendar,
        style: ResetLabelStyle
    ) -> String {
        guard let resetDate else { return "--" }

        guard resetDate > now else { return "待重置" }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone

        if style == .date {
            formatter.dateFormat = "MM.dd"
            return formatter.string(from: resetDate)
        }

        formatter.dateFormat = "HH:mm"
        if calendar.isDate(resetDate, inSameDayAs: now) {
            return formatter.string(from: resetDate)
        }
        // Calendar arithmetic handles daylight-saving transitions and month/year
        // boundaries without treating a local day as a fixed 86,400 seconds.
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(resetDate, inSameDayAs: tomorrow) {
            return "明 \(formatter.string(from: resetDate))"
        }

        formatter.dateFormat = "MM.dd HH:mm"
        return formatter.string(from: resetDate)
    }
}

enum UsageSelectionError: LocalizedError, Equatable, Sendable {
    case usageWindowsUnavailable

    var errorDescription: String? {
        switch self {
        case .usageWindowsUnavailable:
            "Codex 未返回 5 小时或 7 天用量窗口"
        }
    }
}

enum UsageSnapshotBuilder {
    static let weeklyWindowDurationMinutes: Int64 = 10_080
    static let fiveHourWindowDurationMinutes: Int64 = 300

    static func makeSnapshot(
        from response: GetAccountRateLimitsResponse,
        now: Date
    ) throws -> UsageSnapshot {
        let weeklyWindow = selectWeeklyWindow(from: response)
        let fiveHourWindow = selectWindow(
            from: response,
            durationMinutes: fiveHourWindowDurationMinutes
        )
        guard weeklyWindow != nil || fiveHourWindow != nil else {
            throw UsageSelectionError.usageWindowsUnavailable
        }

        return UsageSnapshot(
            weeklyWindow: weeklyWindow.map { windowSnapshot(from: $0) },
            fiveHourWindow: fiveHourWindow.map { windowSnapshot(from: $0) },
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
        guard update.rateLimits.limitId == nil || update.rateLimits.limitId == "codex" else {
            return snapshot
        }

        let weeklyWindow = selectWindow(
            in: update.rateLimits,
            durationMinutes: weeklyWindowDurationMinutes
        )
        let fiveHourWindow = selectWindow(
            in: update.rateLimits,
            durationMinutes: fiveHourWindowDurationMinutes
        )
        guard weeklyWindow != nil || fiveHourWindow != nil else { return snapshot }

        return UsageSnapshot(
            weeklyWindow: weeklyWindow.map {
                windowSnapshot(from: $0, preserving: snapshot.weeklyWindow)
            } ?? snapshot.weeklyWindow,
            fiveHourWindow: fiveHourWindow.map {
                windowSnapshot(from: $0, preserving: snapshot.fiveHourWindow)
            } ?? snapshot.fiveHourWindow,
            resetCreditCount: snapshot.resetCreditCount,
            updatedAt: now
        )
    }

    static func selectWeeklyWindow(
        from response: GetAccountRateLimitsResponse
    ) -> RateLimitWindow? {
        selectWindow(from: response, durationMinutes: weeklyWindowDurationMinutes)
    }

    private static func selectWindow(
        from response: GetAccountRateLimitsResponse,
        durationMinutes: Int64
    ) -> RateLimitWindow? {
        var snapshots: [RateLimitSnapshot] = []

        if let codexSnapshot = response.rateLimitsByLimitId?["codex"] {
            snapshots.append(codexSnapshot)
        }

        if !snapshots.contains(where: { $0 == response.rateLimits }) {
            snapshots.append(response.rateLimits)
        }

        return snapshots.lazy.compactMap {
            selectWindow(in: $0, durationMinutes: durationMinutes)
        }.first
    }

    private static func selectWindow(
        in snapshot: RateLimitSnapshot,
        durationMinutes: Int64
    ) -> RateLimitWindow? {
        [snapshot.primary, snapshot.secondary]
            .compactMap { $0 }
            .first { $0.windowDurationMins == durationMinutes }
    }

    private static func windowSnapshot(
        from window: RateLimitWindow,
        preserving previous: UsageWindowSnapshot? = nil
    ) -> UsageWindowSnapshot {
        UsageWindowSnapshot(
            remainingPercent: 100 - min(max(window.usedPercent, 0), 100),
            resetsAt: window.resetsAt
                .map { Date(timeIntervalSince1970: TimeInterval($0)) }
                ?? previous?.resetsAt
        )
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
        resetDates: [Date],
        now: Date,
        interval: RefreshInterval
    ) -> Bool {
        if resetDates.contains(where: { $0 <= now }) {
            return true
        }

        guard let lastFullRefreshAt else { return true }
        return now.timeIntervalSince(lastFullRefreshAt) >= interval.timeInterval
    }

    static func resetRefreshDate(for resetDates: [Date], now: Date) -> Date? {
        // Skip timestamps the backend has not rolled forward yet, so an expired
        // window cannot prevent the other window's future reset from refreshing.
        resetDates.map { $0.addingTimeInterval(2) }
            .filter { $0 > now }
            .min()
    }
}
