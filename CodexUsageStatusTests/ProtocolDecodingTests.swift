import XCTest
@testable import CodexUsageStatus

final class ProtocolDecodingTests: XCTestCase {
    func testDecodesFiveHourAndWeeklyWindows() throws {
        let data = Data(
            """
            {
              "rateLimits": {
                "limitId": "codex",
                "primary": {
                  "usedPercent": 80,
                  "windowDurationMins": 300,
                  "resetsAt": 1800
                },
                "secondary": {
                  "usedPercent": 25,
                  "windowDurationMins": 10080,
                  "resetsAt": 2000
                }
              }
            }
            """.utf8
        )
        let response = try JSONDecoder().decode(GetAccountRateLimitsResponse.self, from: data)
        let snapshot = try UsageSnapshotBuilder.makeSnapshot(
            from: response, now: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertEqual(snapshot.fiveHourWindow?.remainingPercent, 20)
        XCTAssertEqual(snapshot.fiveHourWindow?.resetsAt, Date(timeIntervalSince1970: 1_800))
        XCTAssertEqual(snapshot.weeklyWindow?.remainingPercent, 75)
        XCTAssertEqual(snapshot.weeklyWindow?.resetsAt, Date(timeIntervalSince1970: 2_000))
    }

    func testDecodesMultiBucketResponseAndAuthoritativeResetCount() throws {
        let data = Data(
            """
            {
              "rateLimits": {
                "limitId": "codex",
                "limitName": null,
                "primary": {
                  "usedPercent": 25,
                  "windowDurationMins": 10080,
                  "resetsAt": 1785813494
                },
                "secondary": null,
                "unknownFutureField": true
              },
              "rateLimitsByLimitId": {
                "codex": {
                  "limitId": "codex",
                  "primary": {
                    "usedPercent": 25,
                    "windowDurationMins": 10080,
                    "resetsAt": 1785813494
                  },
                  "secondary": null
                },
                "codex_other": {
                  "limitId": "codex_other",
                  "primary": {
                    "usedPercent": 0,
                    "windowDurationMins": 10080,
                    "resetsAt": 1785817415
                  },
                  "secondary": null
                }
              },
              "rateLimitResetCredits": {
                "availableCount": 4,
                "credits": [
                  { "id": "opaque", "status": "available" }
                ]
              }
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(
            GetAccountRateLimitsResponse.self,
            from: data
        )

        XCTAssertEqual(response.rateLimits.limitId, "codex")
        XCTAssertEqual(response.rateLimitsByLimitId?.count, 2)
        XCTAssertEqual(response.rateLimitResetCredits?.availableCount, 4)
    }

    func testMissingResetCreditsRemainUnknown() throws {
        let data = Data(
            """
            {
              "rateLimits": {
                "limitId": "codex",
                "primary": {
                  "usedPercent": 5,
                  "windowDurationMins": 10080,
                  "resetsAt": null
                },
                "secondary": null
              }
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(
            GetAccountRateLimitsResponse.self,
            from: data
        )
        let snapshot = try UsageSnapshotBuilder.makeSnapshot(
            from: response,
            now: Date(timeIntervalSince1970: 0)
        )

        XCTAssertNil(snapshot.resetCreditCount)
        XCTAssertNil(snapshot.weeklyWindow?.resetsAt)
        XCTAssertNil(snapshot.fiveHourWindow)
    }

    func testDecodesChatGPTAccount() throws {
        let data = Data(
            """
            {
              "account": {
                "type": "chatgpt",
                "email": "user@example.com",
                "planType": "plus"
              },
              "requiresOpenaiAuth": true
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(
            AccountReadResponse.self,
            from: data
        )

        XCTAssertEqual(response.account?.type, "chatgpt")
        XCTAssertEqual(response.account?.planType, "plus")
    }

    func testLiveCodexAppServerWhenEnabled() async throws {
#if !CODEX_INTEGRATION_TESTS
        throw XCTSkip(
            "Build with CODEX_INTEGRATION_TESTS to test the local Codex CLI"
        )
#else
        let executableURL = try CodexExecutableResolver.resolve(
            preferredPath: ""
        )
        let client = CodexAppServerClient(
            executableURL: executableURL,
            requestTimeout: 15
        )

        do {
            try await client.start()
            let account = try await client.readAccount()
            let response = try await client.readRateLimits()

            XCTAssertEqual(account.account?.type, "chatgpt")
            let snapshot = try UsageSnapshotBuilder.makeSnapshot(from: response, now: Date())
            XCTAssertTrue(snapshot.weeklyWindow != nil || snapshot.fiveHourWindow != nil)
            let codexLimits = response.rateLimitsByLimitId?["codex"] ?? response.rateLimits
            if [codexLimits.primary, codexLimits.secondary]
                .compactMap({ $0 })
                .contains(where: { $0.windowDurationMins == 300 }) {
                XCTAssertNotNil(snapshot.fiveHourWindow)
            }
            await client.stop()
        } catch {
            await client.stop()
            throw error
        }
#endif
    }
}
