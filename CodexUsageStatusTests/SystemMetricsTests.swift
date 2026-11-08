import AppKit
import Combine
import Foundation
import SwiftUI
import XCTest
@testable import CodexUsageStatus

final class SystemMetricsCalculationTests: XCTestCase {
    func testCPUUsesDeltasAcrossAllStatesAndResetsOnCounterRollback() {
        let first = CPUTicks(user: 100, system: 100, idle: 100, nice: 100)
        XCTAssertEqual(CPUTicks(user: 120, system: 110, idle: 160, nice: 110).percent(since: first), 40)
        XCTAssertNil(first.percent(since: first))
        XCTAssertNil(CPUTicks(user: 0, system: 0, idle: 0, nice: 0).percent(since: first))
    }

    func testMemoryUsesResidentCompressedPagesSignedArithmeticAndBounds() {
        let usage = CapacityUsage.memory(totalBytes: 10_000, pageSize: 10,
                                         anonymous: 300, purgeable: 50, wired: 100, compressed: 20)
        XCTAssertEqual(usage.usedBytes, 3_700)
        XCTAssertEqual(usage.percent, 37)
        XCTAssertEqual(CapacityUsage.memory(totalBytes: 100, pageSize: 10,
                                            anonymous: 0, purgeable: 100, wired: 0, compressed: 0).usedBytes, 0)
        XCTAssertEqual(CapacityUsage.memory(totalBytes: 100, pageSize: 10,
                                            anonymous: .max, purgeable: 0, wired: .max, compressed: .max).usedBytes, 100)
    }

    func testDiskCapacityAndFormatting() {
        let usage = CapacityUsage(totalBytes: 1_000, availableBytes: 250)
        XCTAssertEqual(usage.usedBytes, 750)
        XCTAssertEqual(usage.availableBytes, 250)
        XCTAssertEqual(usage.percent, 75)
        XCTAssertEqual(CapacityUsage(totalBytes: 100, availableBytes: 200).usedBytes, 0)
        XCTAssertEqual(SystemMetricFormatter.percent(75.4), "75%")
        XCTAssertEqual(SystemMetricFormatter.speed(999), "999 B/s")
        XCTAssertEqual(SystemMetricFormatter.speed(1_000), "1.0 KB/s")
        XCTAssertEqual(SystemMetricFormatter.speed(1_500_000), "1.5 MB/s")
        XCTAssertEqual(SystemMetricFormatter.speed(2_000_000_000), "2.0 GB/s")
    }

    private func sample(time: Double, interface: String = "en0", index: UInt32 = 1,
                        received: UInt64 = 100, sent: UInt64 = 100) -> SystemMetricsSample {
        SystemMetricsSample(sampledAt: time, network: .value(NetworkCounters(
            interface: interface, interfaceIndex: index, received: received, sent: sent
        )))
    }

    func testNetworkUsesActualElapsedTimeAndRebaselinesOnInterfaceChanges() {
        var accumulator = SystemMetricsAccumulator()
        let metrics: Set<SystemMetric> = [.upload, .download]
        accumulator.accept(sample(time: 1), metrics: metrics)
        XCTAssertEqual(accumulator.snapshot.network, .waiting)
        accumulator.accept(sample(time: 3.5, received: 600, sent: 350), metrics: metrics)
        XCTAssertEqual(accumulator.snapshot.network, .value(NetworkSpeed(interface: "en0", upload: 100, download: 200)))
        accumulator.accept(sample(time: 4, interface: "en1", index: 2), metrics: metrics)
        XCTAssertEqual(accumulator.snapshot.network, .waiting)
        accumulator.accept(sample(time: 5, interface: "en1", index: 3), metrics: metrics)
        XCTAssertEqual(accumulator.snapshot.network, .waiting)
    }

    func testNetworkResetsAfterRollbackNonpositiveTimeDisconnectionAndFailure() {
        var accumulator = SystemMetricsAccumulator()
        let metrics: Set<SystemMetric> = [.upload]
        accumulator.accept(sample(time: 1, received: 500), metrics: metrics)
        accumulator.accept(sample(time: 2, received: 400), metrics: metrics)
        XCTAssertEqual(accumulator.snapshot.network, .waiting)
        accumulator.accept(sample(time: 2, received: 450), metrics: metrics)
        XCTAssertEqual(accumulator.snapshot.network, .waiting)
        accumulator.accept(SystemMetricsSample(sampledAt: 3, network: .disconnected), metrics: metrics)
        XCTAssertEqual(accumulator.snapshot.network, .disconnected)
        accumulator.accept(sample(time: 4), metrics: metrics)
        XCTAssertEqual(accumulator.snapshot.network, .waiting)
        accumulator.accept(SystemMetricsSample(sampledAt: 5, network: .unavailable("test failure")), metrics: metrics)
        XCTAssertEqual(accumulator.snapshot.network, .unavailable("test failure"))
        accumulator.accept(sample(time: 6), metrics: metrics)
        XCTAssertEqual(accumulator.snapshot.network, .waiting)
    }

    func testFailureReplacesOldValueAndLeavesOtherMetricsAvailable() {
        var accumulator = SystemMetricsAccumulator()
        let capacity = CapacityUsage(totalBytes: 100, availableBytes: 40)
        accumulator.accept(SystemMetricsSample(sampledAt: 1, disk: .value(capacity), memory: .value(capacity)),
                           metrics: [.disk, .memory])
        accumulator.accept(SystemMetricsSample(sampledAt: 2, memory: .unavailable("Mach error")), metrics: [.memory])
        XCTAssertEqual(accumulator.snapshot.disk, .value(capacity))
        XCTAssertEqual(accumulator.snapshot.memory, .unavailable("Mach error"))
    }

    func testNativeServiceReturnsRequestedMetricsAndReasonableValues() async throws {
        let service = SystemMetricsService()
        let sample = await service.sample(Set(SystemMetric.allCases))
        guard case let .value(disk) = sample.disk else { return XCTFail("Disk: \(sample.disk)") }
        guard case let .value(memory) = sample.memory else { return XCTFail("Memory: \(sample.memory)") }
        guard case .value = sample.cpu else { return XCTFail("CPU: \(sample.cpu)") }
        XCTAssertGreaterThan(disk.totalBytes, 0)
        XCTAssertLessThanOrEqual(disk.usedBytes, disk.totalBytes)
        XCTAssertEqual(memory.totalBytes, ProcessInfo.processInfo.physicalMemory)
        XCTAssertLessThanOrEqual(memory.usedBytes, memory.totalBytes)
        switch sample.network {
        case let .value(counters): XCTAssertFalse(counters.interface.isEmpty)
        case .disconnected: break // A disconnected host is a valid integration environment.
        default: XCTFail("Network: \(sample.network)")
        }
        let none = await service.sample([])
        XCTAssertEqual(none.disk, .waiting)
        XCTAssertEqual(none.memory, .waiting)
        XCTAssertEqual(none.cpu, .waiting)
        XCTAssertEqual(none.network, .waiting)
    }
}

// All cross-actor access to this test clock is protected by the lock.
private final class MetricsTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 0
    func now() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return time }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; time += seconds }
}

private actor MetricsTestSleeper {
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private(set) var delays: [TimeInterval] = []
    func sleep(_ seconds: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters[id] = continuation; delays.append(seconds) }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }
    func advance() {
        let current = waiters.values
        waiters.removeAll()
        for continuation in current { continuation.resume() }
    }
    private func cancel(_ id: UUID) { waiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
}

private actor MetricsTestProvider: SystemMetricsProviding {
    let clock: MetricsTestClock
    let holdsFirst: Bool
    private var firstRead: CheckedContinuation<Void, Never>?
    private(set) var calls: [Set<SystemMetric>] = []
    private var active = 0
    private(set) var maximumConcurrentReads = 0
    init(clock: MetricsTestClock, holdsFirst: Bool = false) { self.clock = clock; self.holdsFirst = holdsFirst }
    func sample(_ metrics: Set<SystemMetric>) async -> SystemMetricsSample {
        calls.append(metrics)
        let call = UInt32(calls.count)
        active += 1
        maximumConcurrentReads = max(maximumConcurrentReads, active)
        defer { active -= 1 }
        if holdsFirst, calls.count == 1 {
            // Deliberately ignores cancellation to exercise stale-result protection.
            await withCheckedContinuation { firstRead = $0 }
        }
        return SystemMetricsSample(
            sampledAt: clock.now(),
            disk: .value(CapacityUsage(totalBytes: 100, availableBytes: 40)),
            memory: .value(CapacityUsage(totalBytes: 100, availableBytes: 60)),
            cpu: .value(CPUTicks(user: call * 10, system: 0, idle: call * 10, nice: 0)),
            network: .value(NetworkCounters(interface: "en0", interfaceIndex: 1,
                                            received: UInt64(call) * 200, sent: UInt64(call) * 100))
        )
    }
    func releaseFirst() { firstRead?.resume(); firstRead = nil }
}

@MainActor
final class SystemMetricsSettingsTests: XCTestCase {
    private func defaults() throws -> UserDefaults {
        let name = "SystemMetricsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testDefaultVisibilityAndIntervalAndUnknownIntervalFallback() throws {
        let defaults = try defaults()
        let settings = UserSettings(defaults: defaults)
        XCTAssertEqual(settings.systemMonitor.menuBar, [])
        XCTAssertEqual(settings.systemMonitor.details, Set(SystemMetric.allCases))
        XCTAssertEqual(settings.systemMonitor.interval, .twoSeconds)
        defaults.set(999, forKey: SystemMonitorSettings.intervalKey)
        XCTAssertEqual(UserSettings(defaults: defaults).systemMonitor.interval, .twoSeconds)
    }

    func testAllTogglesPersistIndependentlyWithoutChangingCodexSettings() throws {
        let defaults = try defaults()
        let settings = UserSettings(defaults: defaults)
        settings.setRefreshInterval(.oneHour)
        settings.setMenuBarDisplayMode(.weekly)
        for metric in SystemMetric.allCases {
            settings.setSystemMetric(metric, at: .menuBar, visible: true)
            settings.setSystemMetric(metric, at: .details, visible: false)
            let restored = UserSettings(defaults: defaults)
            XCTAssertTrue(restored.systemMonitor.menuBar.contains(metric))
            XCTAssertFalse(restored.systemMonitor.details.contains(metric))
            XCTAssertEqual(restored.systemMonitor, settings.systemMonitor)
        }
        for interval in SystemRefreshInterval.allCases {
            settings.setSystemRefreshInterval(interval)
            XCTAssertEqual(UserSettings(defaults: defaults).systemMonitor.interval, interval)
        }
        settings.setSystemMetric(.cpu, at: .menuBar, visible: false)
        settings.setSystemMetric(.cpu, at: .details, visible: true)
        XCTAssertFalse(settings.systemMonitor.menuBar.contains(.cpu))
        XCTAssertTrue(settings.systemMonitor.details.contains(.cpu))
        XCTAssertTrue(settings.systemMonitor.menuBar.contains(.memory))
        XCTAssertFalse(settings.systemMonitor.details.contains(.memory))
        XCTAssertEqual(settings.refreshInterval, .oneHour)
        XCTAssertEqual(settings.menuBarDisplayMode, .weekly)
    }
}

@MainActor
final class SystemMetricsStoreTests: XCTestCase {
    private func settings() throws -> UserSettings {
        let name = "SystemMetricsStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return UserSettings(defaults: defaults)
    }

    private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { XCTFail("Timed out waiting for test synchronization"); return }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    func testDetailsOnlySamplingStopsWhenClosedAndMenuBarSamplingContinues() async throws {
        let settings = try settings()
        let clock = MetricsTestClock()
        let provider = MetricsTestProvider(clock: clock)
        let sleeper = MetricsTestSleeper()
        let store = SystemMetricsStore(settings: settings, provider: provider, now: clock.now, sleep: sleeper.sleep)
        store.start()
        XCTAssertFalse(store.isSampling)
        let hasNoInitialReads = await provider.calls.isEmpty
        XCTAssertTrue(hasNoInitialReads)
        store.setDetailsVisible(true)
        try await waitUntil { await sleeper.delays.count == 1 }
        let initialMetrics = await provider.calls.first
        XCTAssertEqual(initialMetrics, Set(SystemMetric.allCases))
        XCTAssertEqual(store.snapshot.cpu, .waiting)
        XCTAssertEqual(store.snapshot.network, .waiting)
        clock.advance(2)
        await sleeper.advance()
        try await waitUntil { await sleeper.delays.count == 2 }
        XCTAssertEqual(store.snapshot.cpu, .value(50))
        XCTAssertEqual(store.snapshot.network, .value(NetworkSpeed(interface: "en0", upload: 50, download: 100)))
        let fastMetrics = await provider.calls.last
        XCTAssertEqual(fastMetrics, [.memory, .cpu, .upload, .download])
        store.setDetailsVisible(false)
        XCTAssertFalse(store.isSampling)
        settings.setSystemMetric(.cpu, at: .menuBar, visible: true)
        try await waitUntil { await provider.calls.count == 3 }
        let menuBarOnlyMetrics = await provider.calls.last
        XCTAssertEqual(menuBarOnlyMetrics, [.cpu])
        XCTAssertTrue(store.isSampling)
        settings.setSystemMetric(.cpu, at: .menuBar, visible: false)
        XCTAssertFalse(store.isSampling)
        await store.stop()
    }

    func testDiskUsesThirtySecondScheduleAndUploadDownloadShareOneRead() async throws {
        let settings = try settings()
        settings.setSystemMetric(.disk, at: .menuBar, visible: true)
        let clock = MetricsTestClock()
        let provider = MetricsTestProvider(clock: clock)
        let sleeper = MetricsTestSleeper()
        let store = SystemMetricsStore(settings: settings, provider: provider, now: clock.now, sleep: sleeper.sleep)
        store.start()
        try await waitUntil { await sleeper.delays.count == 1 }
        let diskRefreshDelay = await sleeper.delays.last
        XCTAssertEqual(diskRefreshDelay, 30)
        clock.advance(30)
        await sleeper.advance()
        try await waitUntil { await sleeper.delays.count == 2 }
        let diskOnlyReads = await provider.calls
        XCTAssertEqual(diskOnlyReads, [[.disk], [.disk]])
        settings.setSystemMetric(.upload, at: .menuBar, visible: true)
        settings.setSystemMetric(.download, at: .menuBar, visible: true)
        try await waitUntil { await sleeper.delays.count == 3 }
        let combinedMetrics = await provider.calls.last
        XCTAssertEqual(combinedMetrics, [.disk, .upload, .download])
        clock.advance(2)
        await sleeper.advance()
        try await waitUntil { await sleeper.delays.count == 4 }
        let networkOnlyMetrics = await provider.calls.last
        XCTAssertEqual(networkOnlyMetrics, [.upload, .download])
        clock.advance(28)
        await sleeper.advance()
        try await waitUntil { await sleeper.delays.count == 5 }
        let metricsAfterDiskDeadline = await provider.calls.last
        XCTAssertEqual(metricsAfterDiskDeadline, [.disk, .upload, .download])
        await store.stop()
    }

    func testChangingIntervalAndWakeRebaselineAndDoNotAcceptCancelledReads() async throws {
        let settings = try settings()
        settings.setSystemMetric(.cpu, at: .menuBar, visible: true)
        let clock = MetricsTestClock()
        let provider = MetricsTestProvider(clock: clock, holdsFirst: true)
        let sleeper = MetricsTestSleeper()
        let store = SystemMetricsStore(settings: settings, provider: provider, now: clock.now, sleep: sleeper.sleep)
        store.start()
        try await waitUntil { await provider.calls.count == 1 }
        settings.setSystemMetric(.cpu, at: .menuBar, visible: false)
        settings.setSystemMetric(.memory, at: .menuBar, visible: true)
        settings.setSystemRefreshInterval(.fiveSeconds)
        XCTAssertEqual(store.snapshot.memory, .waiting)
        await provider.releaseFirst()
        try await waitUntil { await sleeper.delays.count == 1 }
        let completedReadCount = await provider.calls.count
        XCTAssertEqual(completedReadCount, 2)
        let maximumConcurrentReads = await provider.maximumConcurrentReads
        XCTAssertEqual(maximumConcurrentReads, 1)
        let metricsAfterSettingsChange = await provider.calls.last
        XCTAssertEqual(metricsAfterSettingsChange, [.memory])
        XCTAssertEqual(store.snapshot.cpu, .waiting)
        XCTAssertEqual(store.snapshot.memory, .value(CapacityUsage(totalBytes: 100, availableBytes: 60)))
        let updatedRefreshDelay = await sleeper.delays.last
        XCTAssertEqual(updatedRefreshDelay, 5)
        store.setSleeping(true)
        XCTAssertFalse(store.isSampling)
        XCTAssertEqual(store.snapshot.memory, .waiting)
        store.setSleeping(false)
        try await waitUntil { await sleeper.delays.count == 2 }
        XCTAssertTrue(store.isSampling)
        await store.stop()
    }

    func testWakeStartsNewCPUAndNetworkBaselinesAndStopIsIdempotent() async throws {
        let settings = try settings()
        for metric in [SystemMetric.cpu, .upload] { settings.setSystemMetric(metric, at: .menuBar, visible: true) }
        let clock = MetricsTestClock()
        let provider = MetricsTestProvider(clock: clock)
        let sleeper = MetricsTestSleeper()
        let store = SystemMetricsStore(settings: settings, provider: provider, now: clock.now, sleep: sleeper.sleep)
        store.start()
        store.start()
        try await waitUntil { await sleeper.delays.count == 1 }
        clock.advance(2)
        await sleeper.advance()
        try await waitUntil { await sleeper.delays.count == 2 }
        XCTAssertEqual(store.snapshot.cpu, .value(50))
        store.setSleeping(true)
        clock.advance(3_600)
        store.setSleeping(false)
        try await waitUntil { await sleeper.delays.count == 3 }
        XCTAssertEqual(store.snapshot.cpu, .waiting)
        XCTAssertEqual(store.snapshot.network, .waiting)
        await store.stop()
        await store.stop()
        XCTAssertFalse(store.isSampling)
    }

    func testCancelledSampleNeverPublishesItsCompletedValues() async throws {
        let settings = try settings()
        settings.setSystemMetric(.disk, at: .menuBar, visible: true)
        let clock = MetricsTestClock()
        let provider = MetricsTestProvider(clock: clock, holdsFirst: true)
        let sleeper = MetricsTestSleeper()
        let store = SystemMetricsStore(settings: settings, provider: provider, now: clock.now, sleep: sleeper.sleep)
        var published: [SystemMetricsSnapshot] = []
        let observation = store.$snapshot.sink { published.append($0) }
        defer { observation.cancel() }
        store.start()
        try await waitUntil { await provider.calls.count == 1 }
        settings.setSystemMetric(.disk, at: .menuBar, visible: false)
        settings.setSystemMetric(.memory, at: .menuBar, visible: true)
        await provider.releaseFirst()
        try await waitUntil { await sleeper.delays.count == 1 }
        XCTAssertTrue(published.allSatisfy { $0.disk == .waiting })
        XCTAssertEqual(store.snapshot.memory, .value(CapacityUsage(totalBytes: 100, availableBytes: 60)))
        await store.stop()
    }

    func testStartDuringPendingStopStillSerializesReads() async throws {
        let settings = try settings()
        settings.setSystemMetric(.memory, at: .menuBar, visible: true)
        let clock = MetricsTestClock()
        let provider = MetricsTestProvider(clock: clock, holdsFirst: true)
        let sleeper = MetricsTestSleeper()
        let store = SystemMetricsStore(settings: settings, provider: provider, now: clock.now, sleep: sleeper.sleep)
        store.start()
        try await waitUntil { await provider.calls.count == 1 }
        let stopping = Task { await store.stop() }
        try await waitUntil { !store.isSampling }
        store.start()
        await provider.releaseFirst()
        await stopping.value
        try await waitUntil { await sleeper.delays.count == 1 }
        let maximumConcurrentReads = await provider.maximumConcurrentReads
        XCTAssertEqual(maximumConcurrentReads, 1)
        XCTAssertTrue(store.isSampling)
        XCTAssertEqual(store.snapshot.memory, .value(CapacityUsage(totalBytes: 100, availableBytes: 60)))
        await store.stop()
    }
}

// Simulate window visibility without presenting any test windows on the desktop.
@MainActor
private final class MetricsTestWindow: NSWindow {
    private var simulatedVisible = false
    override var isVisible: Bool { simulatedVisible }

    func simulateVisibility(_ value: Bool) {
        willChangeValue(forKey: #keyPath(NSWindow.isVisible))
        simulatedVisible = value
        didChangeValue(forKey: #keyPath(NSWindow.isVisible))
    }
}

@MainActor
final class SystemMetricsViewTests: XCTestCase {
    func testNativeMenuBarImageIncludesSystemMetricsWhenCodexIsUnavailable() throws {
        let presentation = UsageMenuBarPresentation.make(from: .failed(message: "离线"), now: Date())
        let capacity = CapacityUsage(totalBytes: 100, availableBytes: 40)
        var snapshot = SystemMetricsSnapshot(
            disk: .value(capacity), memory: .value(capacity), cpu: .value(23),
            network: .value(NetworkSpeed(interface: "en0", upload: 1_200, download: 2_400_000))
        )
        let baseline = try XCTUnwrap(UsageMenuBarGraphic.render(
            presentation: presentation, displayMode: .both, showsResetCredits: false
        ))
        for metric in SystemMetric.allCases {
            let image = try XCTUnwrap(UsageMenuBarGraphic.render(
                presentation: presentation, displayMode: .both, showsResetCredits: false,
                systemSnapshot: snapshot, systemMetrics: [metric]
            ))
            XCTAssertGreaterThan(image.size.width, baseline.size.width)
            XCTAssertEqual(image.size.height, 22)
        }
        let first = try XCTUnwrap(UsageMenuBarGraphic.render(
            presentation: presentation, displayMode: .both, showsResetCredits: false,
            systemSnapshot: snapshot, systemMetrics: [.cpu]
        ))
        snapshot.cpu = .value(87)
        let updated = try XCTUnwrap(UsageMenuBarGraphic.render(
            presentation: presentation, displayMode: .both, showsResetCredits: false,
            systemSnapshot: snapshot, systemMetrics: [.cpu]
        ))
        XCTAssertNotEqual(try XCTUnwrap(first.tiffRepresentation), try XCTUnwrap(updated.tiffRepresentation))
        for scheme in [ColorScheme.light, .dark] {
            let image = try XCTUnwrap(UsageMenuBarGraphic.render(
                presentation: presentation, displayMode: .both, showsResetCredits: false,
                colorScheme: scheme, systemSnapshot: snapshot, systemMetrics: Set(SystemMetric.allCases)
            ))
            let attachment = XCTAttachment(image: image)
            attachment.name = "System monitoring - \(scheme)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testWindowVisibilityDrivesSamplingEvenWhileContentRemainsMounted() async throws {
        let window = MetricsTestWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        var visible: Bool?
        let probe = SystemMetricsVisibilityView { visible = $0 }
        window.contentView = probe
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        for expected in [false, true, false, true] {
            window.simulateVisibility(expected)
            while visible != expected, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            XCTAssertEqual(visible, expected)
        }
        window.contentView = nil
        while visible != false, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(visible, false)
        probe.stopObserving()
    }

    func testSettingsAndMenuBarFitWithEveryMetricEnabled() async throws {
        let name = "SystemMetricsViewTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = UserSettings(defaults: defaults)
        let metricsStore = SystemMetricsStore(settings: settings)
        let controller = NSHostingController(rootView: SystemMonitorSettingsView(settings: settings))
        let size = controller.sizeThatFits(in: CGSize(width: 308, height: 1_000))
        XCTAssertLessThanOrEqual(size.width, 308)
        XCTAssertGreaterThan(size.height, 100)

        let usageStore = UsageStore(settings: settings, initialState: .loaded(snapshot: .preview, isStale: false, message: nil))
        let menuBar = NSHostingController(rootView: UsageMenuBarLabel(
            store: usageStore, settings: settings, systemMetricsStore: metricsStore
        ))
        let initialSize = menuBar.sizeThatFits(in: CGSize(width: 2_000, height: 32))
        for metric in SystemMetric.allCases { settings.setSystemMetric(metric, at: .menuBar, visible: true) }
        // ObservableObject invalidation is applied on the next SwiftUI update.
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        var enabledSize = menuBar.sizeThatFits(in: CGSize(width: 2_000, height: 32))
        while enabledSize.width <= initialSize.width, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
            enabledSize = menuBar.sizeThatFits(in: CGSize(width: 2_000, height: 32))
        }
        XCTAssertGreaterThan(enabledSize.width, initialSize.width)
        XCTAssertLessThanOrEqual(enabledSize.height, 32)
        XCTAssertLessThan(enabledSize.width, 800)
    }
}
