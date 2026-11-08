import SwiftUI
import Vision
import XCTest
@testable import CodexUsageStatus

@MainActor
final class RefreshIntervalTests: XCTestCase {
    func testPopoverKeepsVisibleHeightWhenHostProposesZeroHeight() throws {
        let suiteName = "CodexUsageStatusTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = UserSettings(defaults: defaults)

        let states: [UsageViewState] = [
            .loading,
            .loaded(snapshot: .preview, isStale: false, message: nil),
            .failed(message: "离线"),
        ]
        for state in states {
            for mode in MenuBarDisplayMode.allCases {
                settings.setMenuBarDisplayMode(mode)
                let controller = NSHostingController(rootView: UsagePopoverView(
                    store: UsageStore(settings: settings, initialState: state),
                    settings: settings,
                    launchAtLoginController: LaunchAtLoginController()
                ))

                let size = controller.sizeThatFits(in: CGSize(width: 340, height: 0))

                XCTAssertEqual(size.width, 340)
                XCTAssertGreaterThan(size.height, 0, "Popover collapsed in \(mode.rawValue) mode")
                XCTAssertLessThanOrEqual(size.height, 480)
                XCTAssertLessThanOrEqual(size.height, NSScreen.main?.visibleFrame.height ?? 800)
            }
        }
    }

    func testIntervalsMapToExpectedDurations() {
        XCTAssertEqual(RefreshInterval.fiveMinutes.timeInterval, 300)
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

        for interval in RefreshInterval.allCases {
            settings.setRefreshInterval(interval)
            let restored = UserSettings(defaults: defaults)
            XCTAssertEqual(restored.refreshInterval, interval)
        }
    }

    func testFiveMinuteRefreshUsesTheFullInterval() {
        let start = Date(timeIntervalSince1970: 10_000)

        XCTAssertEqual(
            RefreshPolicy.nextRefreshDate(after: start, interval: .fiveMinutes),
            start.addingTimeInterval(300)
        )
        XCTAssertFalse(RefreshPolicy.shouldRefresh(
            lastFullRefreshAt: start, resetDates: [],
            now: start.addingTimeInterval(299), interval: .fiveMinutes
        ))
        XCTAssertTrue(RefreshPolicy.shouldRefresh(
            lastFullRefreshAt: start, resetDates: [],
            now: start.addingTimeInterval(300), interval: .fiveMinutes
        ))
    }

    func testRenderedMenuBarContainsPercentagesForEachSelectedWindow() throws {
        let presentation = UsageMenuBarPresentation(
            remainingText: "76%", resetText: "11.08",
            fiveHourRemainingText: "42%", fiveHourResetText: "18:00",
            resetCreditText: nil
        )
        var widths: [MenuBarDisplayMode: CGFloat] = [:]

        for mode in MenuBarDisplayMode.allCases {
            let image = try XCTUnwrap(UsageMenuBarGraphic.render(
                presentation: presentation, displayMode: mode, showsResetCredits: true
            ))
            XCTAssertEqual(image.size.height, 22)
            XCTAssertFalse(image.isTemplate, "The glass tint and border must retain their colors")
            widths[mode] = image.size.width
            let attachment = XCTAttachment(image: image)
            attachment.name = "Menu bar - \(mode.rawValue)"
            attachment.lifetime = .keepAlways
            add(attachment)

            let source = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
            // Give Vision the same background as a light menu bar instead of an
            // undefined alpha fill behind the translucent glass surface.
            let context = try XCTUnwrap(CGContext(
                data: nil, width: source.width, height: source.height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            let bounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(bounds)
            context.draw(source, in: bounds)
            let cgImage = try XCTUnwrap(context.makeImage())
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
            let text = (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined()
                .replacingOccurrences(of: " ", with: "")

            switch mode {
            case .fiveHour:
                XCTAssertTrue(text.contains("42%"), text)
                XCTAssertFalse(text.contains("76%"), text)
                XCTAssertTrue(text.contains("18:00"), text)
                XCTAssertFalse(text.contains("11.08"), text)
            case .weekly:
                XCTAssertTrue(text.contains("76%"), text)
                XCTAssertFalse(text.contains("42%"), text)
                XCTAssertTrue(text.contains("11.08"), text)
                XCTAssertFalse(text.contains("18:00"), text)
            case .both:
                XCTAssertTrue(text.contains("42%"), text)
                XCTAssertTrue(text.contains("76%"), text)
                XCTAssertTrue(text.contains("18:00"), text)
                XCTAssertTrue(text.contains("11.08"), text)
            }
        }

        let combinedWidth = try XCTUnwrap(widths[.both])
        XCTAssertGreaterThan(combinedWidth, try XCTUnwrap(widths[.fiveHour]))
        XCTAssertGreaterThan(combinedWidth, try XCTUnwrap(widths[.weekly]))
        XCTAssertLessThan(combinedWidth, 180, "Both quota windows should fit a compact two-line item")
    }

    func testGlassMenuBarRendersSeparateLightAndDarkAppearances() throws {
        let presentation = UsageMenuBarPresentation(
            remainingText: "76%", resetText: "11.08",
            fiveHourRemainingText: "42%", fiveHourResetText: "18:00",
            resetCreditText: "2"
        )
        let light = try XCTUnwrap(UsageMenuBarGraphic.render(
            presentation: presentation, displayMode: .both,
            showsResetCredits: true, colorScheme: .light
        ))
        let dark = try XCTUnwrap(UsageMenuBarGraphic.render(
            presentation: presentation, displayMode: .both,
            showsResetCredits: true, colorScheme: .dark
        ))
        XCTAssertEqual(light.size, dark.size)
        XCTAssertEqual(light.size.height, 22)
        XCTAssertFalse(light.isTemplate)
        XCTAssertFalse(dark.isTemplate)
        XCTAssertNotEqual(try XCTUnwrap(light.tiffRepresentation), try XCTUnwrap(dark.tiffRepresentation))
        for scheme in [ColorScheme.light, .dark] {
            let renderer = ImageRenderer(content: UsageMenuBarGraphic(
                presentation: presentation, displayMode: .both,
                showsResetCredits: true, colorScheme: scheme
            )
            .padding(8)
            .background(scheme == .light ? Color(white: 0.9) : Color(white: 0.12)))
            renderer.scale = 2
            let attachment = XCTAttachment(image: try XCTUnwrap(renderer.nsImage))
            let name = scheme == .light ? "light" : "dark"
            attachment.name = "Glass menu bar - \(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testCompactPopoverRendersInLightAndDarkAppearance() throws {
        let suiteName = "CodexUsageStatusTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = UserSettings(defaults: defaults)
        settings.setRefreshInterval(.fiveMinutes)
        let now = Date()
        let snapshot = UsageSnapshot(
            weeklyWindow: UsageWindowSnapshot(
                remainingPercent: 76, resetsAt: now.addingTimeInterval(26 * 3_600)
            ),
            fiveHourWindow: UsageWindowSnapshot(
                remainingPercent: 42, resetsAt: now.addingTimeInterval(135 * 60)
            ),
            resetCreditCount: 2,
            updatedAt: now
        )

        for scheme in [ColorScheme.light, .dark] {
            let view = UsagePopoverView(
                store: UsageStore(
                    settings: settings,
                    initialState: .loaded(snapshot: snapshot, isStale: false, message: nil),
                    now: { now }
                ),
                settings: settings,
                launchAtLoginController: LaunchAtLoginController()
            )
            .environment(\.colorScheme, scheme)
            .environment(\.locale, Locale(identifier: "zh_CN"))
            .environment(\.controlActiveState, .key)

            let controller = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: controller)
            window.isReleasedWhenClosed = false
            let appearance = try XCTUnwrap(NSAppearance(named: scheme == .light ? .aqua : .darkAqua))
            window.appearance = appearance
            window.setContentSize(NSSize(width: 340, height: 460))
            let content = controller.view
            content.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            appearance.performAsCurrentDrawingAppearance {
                content.cacheDisplay(in: content.bounds, to: bitmap)
            }
            let source = try XCTUnwrap(bitmap.cgImage)
            let context = try XCTUnwrap(CGContext(
                data: nil, width: source.width, height: source.height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            let bounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
            appearance.performAsCurrentDrawingAppearance {
                context.setFillColor(NSColor.windowBackgroundColor.cgColor)
                context.fill(bounds)
            }
            context.draw(source, in: bounds)
            let image = NSImage(cgImage: try XCTUnwrap(context.makeImage()), size: content.bounds.size)
            let attachment = XCTAttachment(image: image)
            attachment.name = "Compact popover - \(scheme == .light ? "light" : "dark")"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertEqual(content.bounds.size, NSSize(width: 340, height: 460))
            window.close()
        }
    }

    func testMenuBarDisplayModeDefaultsToBothAndPersistsEachSelection() throws {
        let suiteName = "CodexUsageStatusTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = UserSettings(defaults: defaults)
        XCTAssertEqual(settings.menuBarDisplayMode, .both)
        settings.setRefreshInterval(.thirtyMinutes)

        for mode in MenuBarDisplayMode.allCases {
            settings.setMenuBarDisplayMode(mode)

            XCTAssertEqual(settings.menuBarDisplayMode, mode)
            let restored = UserSettings(defaults: defaults)
            XCTAssertEqual(restored.menuBarDisplayMode, mode)
            XCTAssertEqual(restored.refreshInterval, .thirtyMinutes)
        }
    }

    func testUnknownMenuBarDisplayModeFallsBackToBoth() throws {
        let suiteName = "CodexUsageStatusTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("unknown-mode", forKey: "menuBarDisplayMode")

        XCTAssertEqual(UserSettings(defaults: defaults).menuBarDisplayMode, .both)
    }

    func testResetCreditVisibilityDefaultsToShownAndPersistsIndependently() throws {
        let suiteName = "CodexUsageStatusTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = UserSettings(defaults: defaults)
        XCTAssertTrue(settings.showsResetCreditsInMenuBar)
        settings.setMenuBarDisplayMode(.weekly)

        for isShown in [false, true] {
            settings.setShowsResetCreditsInMenuBar(isShown)
            let restored = UserSettings(defaults: defaults)
            XCTAssertEqual(restored.showsResetCreditsInMenuBar, isShown)
            XCTAssertEqual(restored.menuBarDisplayMode, .weekly)
        }
    }

    func testHidingResetCreditsRemovesTheWholeColumnInEveryDisplayMode() throws {
        let withCredits = UsageMenuBarPresentation(
            remainingText: "76%", resetText: "11.08",
            fiveHourRemainingText: "42%", fiveHourResetText: "18:00",
            resetCreditText: "8"
        )
        let withoutCredits = UsageMenuBarPresentation(
            remainingText: "76%", resetText: "11.08",
            fiveHourRemainingText: "42%", fiveHourResetText: "18:00",
            resetCreditText: nil
        )
        for mode in MenuBarDisplayMode.allCases {
            let shown = try XCTUnwrap(UsageMenuBarGraphic.render(
                presentation: withCredits, displayMode: mode, showsResetCredits: true
            ))
            let hidden = try XCTUnwrap(UsageMenuBarGraphic.render(
                presentation: withCredits, displayMode: mode, showsResetCredits: false
            ))
            let absent = try XCTUnwrap(UsageMenuBarGraphic.render(
                presentation: withoutCredits, displayMode: mode, showsResetCredits: true
            ))

            XCTAssertEqual(hidden.size, absent.size)
            XCTAssertGreaterThan(shown.size.width, hidden.size.width)
            XCTAssertEqual(shown.size.height, hidden.size.height)
        }
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
                resetDates: [],
                now: Date(timeIntervalSince1970: 11_799),
                interval: .thirtyMinutes
            )
        )
        XCTAssertTrue(
            RefreshPolicy.shouldRefresh(
                lastFullRefreshAt: start,
                resetDates: [],
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
                resetDates: [Date(timeIntervalSince1970: 10_100)],
                now: Date(timeIntervalSince1970: 10_101),
                interval: .oneHour
            )
        )
        XCTAssertEqual(
            RefreshPolicy.resetRefreshDate(
                for: [Date(timeIntervalSince1970: 10_100)],
                now: start
            ),
            Date(timeIntervalSince1970: 10_102)
        )
    }

    func testResetRefreshSelectsEarliestWindowAndSkipsExpiredTargets() {
        let now = Date(timeIntervalSince1970: 10_000)
        let weeklyReset = now.addingTimeInterval(3_600)
        let fiveHourReset = now.addingTimeInterval(60)

        XCTAssertEqual(
            RefreshPolicy.resetRefreshDate(for: [weeklyReset, fiveHourReset], now: now),
            fiveHourReset.addingTimeInterval(2)
        )
        XCTAssertEqual(
            RefreshPolicy.resetRefreshDate(
                for: [fiveHourReset, weeklyReset],
                now: fiveHourReset.addingTimeInterval(3)
            ),
            weeklyReset.addingTimeInterval(2)
        )
        XCTAssertNil(RefreshPolicy.resetRefreshDate(for: [], now: now))
        XCTAssertNil(RefreshPolicy.resetRefreshDate(for: [now.addingTimeInterval(-3)], now: now))
    }

    func testEitherWindowResetTriggersRefreshBeforePollingInterval() {
        let now = Date(timeIntervalSince1970: 10_000)
        for resetDates in [
            [now.addingTimeInterval(3_600), now.addingTimeInterval(-1)],
            [now.addingTimeInterval(-1), now.addingTimeInterval(3_600)],
        ] {
            XCTAssertTrue(RefreshPolicy.shouldRefresh(
                lastFullRefreshAt: now.addingTimeInterval(-10),
                resetDates: resetDates,
                now: now,
                interval: .oneHour
            ))
        }
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

        XCTAssertEqual(store.state.snapshot?.weeklyWindow?.remainingPercent, 75)
        let startCallCount = await provider.startCallCount
        XCTAssertEqual(startCallCount, 1)
        await store.stop()
    }

    func testMenuBarPresentationIncludesLocalResetLabelsAndPositiveCredits() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let snapshot = UsageSnapshot(
            weeklyWindow: UsageWindowSnapshot(
                remainingPercent: 76,
                resetsAt: now.addingTimeInterval(26 * 60 * 60 + 30 * 60)
            ),
            fiveHourWindow: UsageWindowSnapshot(
                remainingPercent: 42,
                resetsAt: now.addingTimeInterval(2 * 60 * 60 + 15 * 60)
            ),
            resetCreditCount: 2,
            updatedAt: now
        )

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let presentation = UsageMenuBarPresentation.make(
            from: .loaded(snapshot: snapshot, isStale: false, message: nil),
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(presentation.remainingText, "76%")
        XCTAssertEqual(presentation.resetText, "01.02")
        XCTAssertEqual(presentation.resetCreditText, "2")
        XCTAssertEqual(presentation.fiveHourRemainingText, "42%")
        XCTAssertEqual(presentation.fiveHourResetText, "05:01")
    }

    func testMenuBarPresentationHidesZeroOrUnknownCredits() {
        let now = Date(timeIntervalSince1970: 10_000)

        for resetCreditCount in [0, nil] {
            let snapshot = UsageSnapshot(
                weeklyWindow: UsageWindowSnapshot(
                    remainingPercent: 76,
                    resetsAt: now.addingTimeInterval(30 * 60)
                ),
                fiveHourWindow: nil,
                resetCreditCount: resetCreditCount,
                updatedAt: now
            )
            let presentation = UsageMenuBarPresentation.make(
                from: .loaded(snapshot: snapshot, isStale: false, message: nil),
                now: now
            )

            XCTAssertNil(presentation.resetCreditText)
            XCTAssertEqual(presentation.fiveHourRemainingText, "--%")
            XCTAssertEqual(presentation.fiveHourResetText, "--")
        }
    }

    func testResetLabelsUseTheSelectedTimeZoneAnd24HourClock() throws {
        for (zone, time) in [("Asia/Shanghai", "18:00"), ("UTC", "10:00"), ("America/Los_Angeles", "02:00")] {
            let presentation = try resetPresentation(
                now: "2026-11-08T09:00:00Z",
                fiveHourReset: "2026-11-08T10:00:00Z",
                weeklyReset: "2026-11-15T10:00:00Z",
                timeZone: zone
            )
            XCTAssertEqual(presentation.fiveHourResetText, time)
            XCTAssertEqual(presentation.resetText, "11.15")
        }
    }

    func testTomorrowResetIsMarkedAcrossTheYearBoundary() throws {
        let presentation = try resetPresentation(
            now: "2026-12-31T15:00:00Z",
            fiveHourReset: "2026-12-31T17:00:00Z",
            weeklyReset: "2027-01-03T10:00:00Z",
            timeZone: "Asia/Shanghai"
        )
        XCTAssertEqual(presentation.fiveHourResetText, "明 01:00")
        XCTAssertEqual(presentation.resetText, "01.03")
    }

    func testResetClockHandlesTheDaylightSavingFallBack() throws {
        let presentation = try resetPresentation(
            now: "2026-11-01T07:30:00Z",
            fiveHourReset: "2026-11-01T09:30:00Z",
            weeklyReset: "2026-11-08T10:00:00Z",
            timeZone: "America/Los_Angeles"
        )
        XCTAssertEqual(presentation.fiveHourResetText, "01:30")
        XCTAssertEqual(presentation.resetText, "11.08")
    }

    func testMissingAndExpiredResetLabelsRemainDistinct() throws {
        let presentation = try resetPresentation(
            now: "2026-11-08T09:00:00Z",
            fiveHourReset: nil,
            weeklyReset: "2026-11-08T08:00:00Z",
            timeZone: "Asia/Shanghai"
        )
        XCTAssertEqual(presentation.fiveHourResetText, "--")
        XCTAssertEqual(presentation.resetText, "待重置")
    }

    private func resetPresentation(
        now: String,
        fiveHourReset: String?,
        weeklyReset: String?,
        timeZone: String
    ) throws -> UsageMenuBarPresentation {
        let formatter = ISO8601DateFormatter()
        let now = try XCTUnwrap(formatter.date(from: now))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: timeZone))
        let snapshot = UsageSnapshot(
            weeklyWindow: UsageWindowSnapshot(
                remainingPercent: 50,
                resetsAt: try weeklyReset.map { try XCTUnwrap(formatter.date(from: $0)) }
            ),
            fiveHourWindow: UsageWindowSnapshot(
                remainingPercent: 79,
                resetsAt: try fiveHourReset.map { try XCTUnwrap(formatter.date(from: $0)) }
            ),
            resetCreditCount: nil, updatedAt: now
        )
        return UsageMenuBarPresentation.make(
            from: .loaded(snapshot: snapshot, isStale: false, message: nil),
            now: now, calendar: calendar
        )
    }

    func testMenuBarPresentationSupportsFiveHourOnlyAndReachedReset() {
        let now = Date(timeIntervalSince1970: 10_000)
        let snapshot = UsageSnapshot(
            weeklyWindow: nil,
            fiveHourWindow: UsageWindowSnapshot(remainingPercent: 0, resetsAt: now),
            resetCreditCount: nil,
            updatedAt: now
        )

        let presentation = UsageMenuBarPresentation.make(
            from: .loaded(snapshot: snapshot, isStale: false, message: nil), now: now
        )

        XCTAssertEqual(presentation.remainingText, "--%")
        XCTAssertEqual(presentation.resetText, "--")
        XCTAssertEqual(presentation.fiveHourRemainingText, "0%")
        XCTAssertEqual(presentation.fiveHourResetText, "待重置")
    }

    func testMenuBarPresentationUsesStableUnavailableStates() {
        let now = Date(timeIntervalSince1970: 10_000)

        XCTAssertEqual(
            UsageMenuBarPresentation.make(from: .loading, now: now),
            UsageMenuBarPresentation(
                remainingText: "…",
                resetText: "…",
                fiveHourRemainingText: "…",
                fiveHourResetText: "…",
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
                fiveHourRemainingText: "--%",
                fiveHourResetText: "--",
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
