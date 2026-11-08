import XCTest
@testable import CodexUsageStatus

final class WeeklyWindowSelectorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    func testBuildsSnapshotFromCodexWeeklyWindow() throws {
        let response = response(
            rateLimits: snapshot(
                limitID: "codex",
                primary: window(used: 25, duration: 10_080, resetsAt: 2_000)
            ),
            resetCount: 3
        )

        let result = try UsageSnapshotBuilder.makeSnapshot(
            from: response,
            now: now
        )

        XCTAssertEqual(result.weeklyWindow?.remainingPercent, 75)
        XCTAssertEqual(result.weeklyWindow?.resetsAt, Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(result.resetCreditCount, 3)
        XCTAssertEqual(result.updatedAt, now)
    }

    func testPrefersCodexBucketOverBackwardCompatibleSnapshot() throws {
        let response = GetAccountRateLimitsResponse(
            rateLimits: snapshot(
                limitID: "legacy",
                primary: window(used: 80, duration: 10_080)
            ),
            rateLimitsByLimitId: [
                "codex": snapshot(
                    limitID: "codex",
                    primary: window(used: 10, duration: 10_080)
                ),
                "codex_other": snapshot(
                    limitID: "codex_other",
                    primary: window(used: 95, duration: 10_080)
                ),
            ],
            rateLimitResetCredits: nil
        )

        let result = try UsageSnapshotBuilder.makeSnapshot(
            from: response,
            now: now
        )

        XCTAssertEqual(result.weeklyWindow?.remainingPercent, 90)
    }

    func testFindsWeeklyWindowInSecondarySlot() throws {
        let response = response(
            rateLimits: snapshot(
                limitID: "codex",
                primary: window(used: 50, duration: 300),
                secondary: window(used: 40, duration: 10_080)
            )
        )

        let result = try UsageSnapshotBuilder.makeSnapshot(
            from: response,
            now: now
        )

        XCTAssertEqual(result.weeklyWindow?.remainingPercent, 60)
        XCTAssertEqual(result.fiveHourWindow?.remainingPercent, 50)
    }

    func testFindsFiveHourWindowInEitherSlot() throws {
        let shortWindow = window(used: 65, duration: 300, resetsAt: 1_800)
        let weeklyWindow = window(used: 10, duration: 10_080, resetsAt: 2_000)

        for (primary, secondary) in [(shortWindow, weeklyWindow), (weeklyWindow, shortWindow)] {
            let result = try UsageSnapshotBuilder.makeSnapshot(
                from: response(rateLimits: snapshot(
                    limitID: "codex", primary: primary, secondary: secondary
                )),
                now: now
            )

            XCTAssertEqual(result.fiveHourWindow?.remainingPercent, 35)
            XCTAssertEqual(result.fiveHourWindow?.resetsAt, Date(timeIntervalSince1970: 1_800))
            XCTAssertEqual(result.weeklyWindow?.remainingPercent, 90)
            XCTAssertEqual(result.weeklyWindow?.resetsAt, Date(timeIntervalSince1970: 2_000))
        }
    }

    func testSupportsFiveHourWindowWithoutWeeklyWindow() throws {
        let result = try UsageSnapshotBuilder.makeSnapshot(
            from: response(rateLimits: snapshot(
                limitID: "codex", primary: window(used: 100, duration: 300)
            )),
            now: now
        )

        XCTAssertNil(result.weeklyWindow)
        XCTAssertEqual(result.fiveHourWindow?.remainingPercent, 0)
        XCTAssertNil(result.fiveHourWindow?.resetsAt)
    }

    func testMissingFiveHourWindowRemainsUnavailable() throws {
        let result = try UsageSnapshotBuilder.makeSnapshot(
            from: response(rateLimits: snapshot(
                limitID: "codex", primary: window(used: 20, duration: 10_080)
            )),
            now: now
        )

        XCTAssertEqual(result.weeklyWindow?.remainingPercent, 80)
        XCTAssertNil(result.fiveHourWindow)
    }

    func testPrefersCodexBucketForFiveHourWindow() throws {
        let response = GetAccountRateLimitsResponse(
            rateLimits: snapshot(limitID: "legacy", primary: window(used: 90, duration: 300)),
            rateLimitsByLimitId: [
                "codex": snapshot(limitID: "codex", primary: window(used: 15, duration: 300)),
                "codex_other": snapshot(limitID: "codex_other", primary: window(used: 70, duration: 300)),
            ],
            rateLimitResetCredits: nil
        )

        let result = try UsageSnapshotBuilder.makeSnapshot(from: response, now: now)

        XCTAssertEqual(result.fiveHourWindow?.remainingPercent, 85)
    }

    func testDoesNotGuessWindowWithMissingDuration() {
        let response = response(rateLimits: snapshot(
            limitID: "codex",
            primary: RateLimitWindow(usedPercent: 10, windowDurationMins: nil, resetsAt: 2_000)
        ))

        XCTAssertThrowsError(try UsageSnapshotBuilder.makeSnapshot(from: response, now: now))
    }

    func testDoesNotGuessUnsupportedWindow() {
        let response = response(
            rateLimits: snapshot(
                limitID: "codex",
                primary: window(used: 50, duration: 60)
            )
        )

        XCTAssertThrowsError(
            try UsageSnapshotBuilder.makeSnapshot(from: response, now: now)
        ) { error in
            XCTAssertEqual(
                error as? UsageSelectionError,
                .usageWindowsUnavailable
            )
        }
    }

    func testClampsRemainingPercent() throws {
        let overused = response(
            rateLimits: snapshot(
                limitID: "codex",
                primary: window(used: 125, duration: 10_080)
            )
        )
        let negativeUsage = response(
            rateLimits: snapshot(
                limitID: "codex",
                primary: window(used: -5, duration: 10_080)
            )
        )

        XCTAssertEqual(
            try UsageSnapshotBuilder.makeSnapshot(
                from: overused,
                now: now
            ).weeklyWindow?.remainingPercent,
            0
        )
        XCTAssertEqual(
            try UsageSnapshotBuilder.makeSnapshot(
                from: negativeUsage,
                now: now
            ).weeklyWindow?.remainingPercent,
            100
        )
    }

    func testSparseUpdatePreservesCreditCountAndMissingResetTime() {
        let original = UsageSnapshot(
            weeklyWindow: UsageWindowSnapshot(
                remainingPercent: 75,
                resetsAt: Date(timeIntervalSince1970: 2_000)
            ),
            fiveHourWindow: UsageWindowSnapshot(remainingPercent: 40, resetsAt: nil),
            resetCreditCount: 2,
            updatedAt: now
        )
        let update = AccountRateLimitsUpdatedNotification(
            rateLimits: snapshot(
                limitID: "codex",
                primary: window(
                    used: 30,
                    duration: 10_080,
                    resetsAt: nil
                )
            )
        )

        let merged = UsageSnapshotBuilder.merging(
            update,
            into: original,
            now: Date(timeIntervalSince1970: 1_100)
        )

        XCTAssertEqual(merged.weeklyWindow?.remainingPercent, 70)
        XCTAssertEqual(merged.weeklyWindow?.resetsAt, original.weeklyWindow?.resetsAt)
        XCTAssertEqual(merged.resetCreditCount, 2)
        XCTAssertEqual(merged.fiveHourWindow, original.fiveHourWindow)
    }

    func testFiveHourOnlyUpdatePreservesWeeklyWindowAndCredits() {
        let original = UsageSnapshot(
            weeklyWindow: UsageWindowSnapshot(remainingPercent: 75, resetsAt: nil),
            fiveHourWindow: UsageWindowSnapshot(
                remainingPercent: 80, resetsAt: Date(timeIntervalSince1970: 2_000)
            ),
            resetCreditCount: 2,
            updatedAt: now
        )
        let update = AccountRateLimitsUpdatedNotification(rateLimits: snapshot(
            limitID: "codex", primary: window(used: 90, duration: 300)
        ))
        let updateTime = now.addingTimeInterval(10)

        let merged = UsageSnapshotBuilder.merging(update, into: original, now: updateTime)

        XCTAssertEqual(merged.fiveHourWindow?.remainingPercent, 10)
        XCTAssertEqual(merged.fiveHourWindow?.resetsAt, original.fiveHourWindow?.resetsAt)
        XCTAssertEqual(merged.weeklyWindow, original.weeklyWindow)
        XCTAssertEqual(merged.resetCreditCount, 2)
        XCTAssertEqual(merged.updatedAt, updateTime)
    }

    func testUpdateCanAddFiveHourWindowAndUpdateBothWindows() {
        let original = UsageSnapshot(
            weeklyWindow: UsageWindowSnapshot(remainingPercent: 75, resetsAt: nil),
            fiveHourWindow: nil,
            resetCreditCount: nil,
            updatedAt: now
        )
        let update = AccountRateLimitsUpdatedNotification(rateLimits: snapshot(
            limitID: "codex",
            primary: window(used: 120, duration: 300, resetsAt: 1_800),
            secondary: window(used: 40, duration: 10_080, resetsAt: 2_000)
        ))

        let merged = UsageSnapshotBuilder.merging(update, into: original, now: now)

        XCTAssertEqual(merged.fiveHourWindow?.remainingPercent, 0)
        XCTAssertEqual(merged.fiveHourWindow?.resetsAt, Date(timeIntervalSince1970: 1_800))
        XCTAssertEqual(merged.weeklyWindow?.remainingPercent, 60)
        XCTAssertEqual(merged.weeklyWindow?.resetsAt, Date(timeIntervalSince1970: 2_000))
    }

    func testIgnoresUpdatesForOtherBucketsAndUnsupportedWindows() {
        let original = UsageSnapshot.preview
        for rateLimits in [
            snapshot(limitID: "codex_other", primary: window(used: 100, duration: 300)),
            snapshot(limitID: "codex", primary: window(used: 100, duration: 60)),
        ] {
            let merged = UsageSnapshotBuilder.merging(
                AccountRateLimitsUpdatedNotification(rateLimits: rateLimits),
                into: original,
                now: now
            )
            XCTAssertEqual(merged, original)
        }
    }

    private func response(
        rateLimits: RateLimitSnapshot,
        resetCount: Int64? = nil
    ) -> GetAccountRateLimitsResponse {
        GetAccountRateLimitsResponse(
            rateLimits: rateLimits,
            rateLimitsByLimitId: nil,
            rateLimitResetCredits: resetCount.map {
                RateLimitResetCreditsSummary(availableCount: $0)
            }
        )
    }

    private func snapshot(
        limitID: String,
        primary: RateLimitWindow?,
        secondary: RateLimitWindow? = nil
    ) -> RateLimitSnapshot {
        RateLimitSnapshot(
            limitId: limitID,
            limitName: nil,
            primary: primary,
            secondary: secondary
        )
    }

    private func window(
        used: Int,
        duration: Int64,
        resetsAt: Int64? = nil
    ) -> RateLimitWindow {
        RateLimitWindow(
            usedPercent: used,
            windowDurationMins: duration,
            resetsAt: resetsAt
        )
    }
}
