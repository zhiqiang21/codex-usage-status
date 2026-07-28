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

        XCTAssertEqual(result.remainingPercent, 75)
        XCTAssertEqual(result.resetsAt, Date(timeIntervalSince1970: 2_000))
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

        XCTAssertEqual(result.remainingPercent, 90)
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

        XCTAssertEqual(result.remainingPercent, 60)
    }

    func testDoesNotGuessNonWeeklyWindow() {
        let response = response(
            rateLimits: snapshot(
                limitID: "codex",
                primary: window(used: 50, duration: 300)
            )
        )

        XCTAssertThrowsError(
            try UsageSnapshotBuilder.makeSnapshot(from: response, now: now)
        ) { error in
            XCTAssertEqual(
                error as? UsageSelectionError,
                .weeklyWindowUnavailable
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
            ).remainingPercent,
            0
        )
        XCTAssertEqual(
            try UsageSnapshotBuilder.makeSnapshot(
                from: negativeUsage,
                now: now
            ).remainingPercent,
            100
        )
    }

    func testSparseUpdatePreservesCreditCountAndMissingResetTime() {
        let original = UsageSnapshot(
            remainingPercent: 75,
            resetsAt: Date(timeIntervalSince1970: 2_000),
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

        XCTAssertEqual(merged.remainingPercent, 70)
        XCTAssertEqual(merged.resetsAt, original.resetsAt)
        XCTAssertEqual(merged.resetCreditCount, 2)
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
