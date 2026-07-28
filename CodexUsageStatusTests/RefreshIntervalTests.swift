import XCTest
@testable import CodexUsageStatus

@MainActor
final class RefreshIntervalTests: XCTestCase {
    func testIntervalsMapToExpectedDurations() {
        XCTAssertEqual(RefreshInterval.tenMinutes.timeInterval, 600)
        XCTAssertEqual(RefreshInterval.thirtyMinutes.timeInterval, 1_800)
        XCTAssertEqual(RefreshInterval.oneHour.timeInterval, 3_600)
    }

    func testSettingsDefaultToTenMinutesAndPersistSelection() {
        let suiteName = "CodexUsageStatusTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = UserSettings(defaults: defaults)
        XCTAssertEqual(settings.refreshInterval, .tenMinutes)

        settings.setRefreshInterval(.oneHour)
        let restored = UserSettings(defaults: defaults)
        XCTAssertEqual(restored.refreshInterval, .oneHour)
    }

    func testRefreshPolicyUsesSelectedInterval() {
        let start = Date(timeIntervalSince1970: 10_000)

        XCTAssertEqual(
            RefreshPolicy.nextRefreshDate(after: start, interval: .thirtyMinutes),
            Date(timeIntervalSince1970: 11_800)
        )
        XCTAssertFalse(
            RefreshPolicy.shouldRefresh(
                lastFullRefreshAt: start,
                resetDate: nil,
                now: Date(timeIntervalSince1970: 11_799),
                interval: .thirtyMinutes
            )
        )
        XCTAssertTrue(
            RefreshPolicy.shouldRefresh(
                lastFullRefreshAt: start,
                resetDate: nil,
                now: Date(timeIntervalSince1970: 11_800),
                interval: .thirtyMinutes
            )
        )
    }

    func testReachedResetTimeOverridesPollingInterval() {
        let start = Date(timeIntervalSince1970: 10_000)

        XCTAssertTrue(
            RefreshPolicy.shouldRefresh(
                lastFullRefreshAt: start,
                resetDate: Date(timeIntervalSince1970: 10_100),
                now: Date(timeIntervalSince1970: 10_101),
                interval: .oneHour
            )
        )
        XCTAssertEqual(
            RefreshPolicy.resetRefreshDate(
                for: Date(timeIntervalSince1970: 10_100)
            ),
            Date(timeIntervalSince1970: 10_102)
        )
    }

    func testStoreStartsLoadingWithoutWaitingForPopover() async throws {
        let suiteName = "CodexUsageStatusTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = UserSettings(defaults: defaults)
        settings.setExecutablePath("/usr/bin/true")
        let provider = ImmediateRateLimitProvider()
        let store = UsageStore(
            settings: settings,
            providerFactory: { _ in provider }
        )

        store.start()

        for _ in 0..<100 where store.state.snapshot == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(store.state.snapshot?.remainingPercent, 75)
        let startCallCount = await provider.startCallCount
        XCTAssertEqual(startCallCount, 1)
        await store.stop()
    }

    func testMenuBarPresentationIncludesResetTimeAndPositiveCredits() {
        let now = Date(timeIntervalSince1970: 10_000)
        let snapshot = UsageSnapshot(
            remainingPercent: 76,
            resetsAt: now.addingTimeInterval(26 * 60 * 60 + 30 * 60),
            resetCreditCount: 2,
            updatedAt: now
        )

        let presentation = UsageMenuBarPresentation.make(
            from: .loaded(snapshot: snapshot, isStale: false, message: nil),
            now: now
        )

        XCTAssertEqual(presentation.remainingText, "76%")
        XCTAssertEqual(presentation.resetText, "1d 2h")
        XCTAssertEqual(presentation.resetCreditText, "2")
    }

    func testMenuBarPresentationHidesZeroOrUnknownCredits() {
        let now = Date(timeIntervalSince1970: 10_000)

        for resetCreditCount in [0, nil] {
            let snapshot = UsageSnapshot(
                remainingPercent: 76,
                resetsAt: now.addingTimeInterval(30 * 60),
                resetCreditCount: resetCreditCount,
                updatedAt: now
            )
            let presentation = UsageMenuBarPresentation.make(
                from: .loaded(snapshot: snapshot, isStale: false, message: nil),
                now: now
            )

            XCTAssertNil(presentation.resetCreditText)
        }
    }

    func testMenuBarPresentationUsesStableUnavailableStates() {
        let now = Date(timeIntervalSince1970: 10_000)

        XCTAssertEqual(
            UsageMenuBarPresentation.make(from: .loading, now: now),
            UsageMenuBarPresentation(
                remainingText: "…",
                resetText: "…",
                resetCreditText: nil
            )
        )
        XCTAssertEqual(
            UsageMenuBarPresentation.make(
                from: .failed(message: "offline"),
                now: now
            ),
            UsageMenuBarPresentation(
                remainingText: "--%",
                resetText: "--",
                resetCreditText: nil
            )
        )
    }
}

private actor ImmediateRateLimitProvider: RateLimitProviding {
    private(set) var startCallCount = 0

    func start() {
        startCallCount += 1
    }

    func readAccount() -> AccountReadResponse {
        AccountReadResponse(
            account: AccountInfo(
                type: "chatgpt",
                email: nil,
                planType: "plus"
            ),
            requiresOpenaiAuth: true
        )
    }

    func readRateLimits() -> GetAccountRateLimitsResponse {
        GetAccountRateLimitsResponse(
            rateLimits: RateLimitSnapshot(
                limitId: "codex",
                limitName: nil,
                primary: RateLimitWindow(
                    usedPercent: 25,
                    windowDurationMins: 10_080,
                    resetsAt: nil
                ),
                secondary: nil
            ),
            rateLimitsByLimitId: nil,
            rateLimitResetCredits: RateLimitResetCreditsSummary(
                availableCount: 2
            )
        )
    }

    func events() -> AsyncStream<CodexAppServerEvent> {
        AsyncStream { _ in }
    }

    func stop() {}
}
