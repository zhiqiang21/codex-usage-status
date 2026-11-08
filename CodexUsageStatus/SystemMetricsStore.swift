import AppKit
import Combine
import Foundation

@MainActor
final class SystemMetricsStore: ObservableObject {
    typealias Sleeper = @Sendable (TimeInterval) async throws -> Void

    @Published private(set) var snapshot = SystemMetricsSnapshot()
    private(set) var detailsVisible = false
    private(set) var isSampling = false

    private let settings: UserSettings
    private let provider: any SystemMetricsProviding
    private let now: @Sendable () -> TimeInterval
    private let sleep: Sleeper
    private var configuration: SystemMonitorSettings
    private var settingsObserver: AnyCancellable?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var pollingTask: Task<Void, Never>?
    private var generation = 0
    private var started = false
    private var sleeping = false

    init(
        settings: UserSettings,
        provider: any SystemMetricsProviding = SystemMetricsService(),
        now: @escaping @Sendable () -> TimeInterval = SystemMetricsClock.now,
        sleep: @escaping Sleeper = { seconds in try await Task.sleep(for: .seconds(seconds)) }
    ) {
        self.settings = settings
        self.provider = provider
        self.now = now
        self.sleep = sleep
        configuration = settings.systemMonitor
    }

    func start() {
        guard !started else { return }
        started = true
        configuration = settings.systemMonitor
        settingsObserver = settings.$systemMonitor.dropFirst().sink { [weak self] configuration in
            guard let self else { return }
            self.configuration = configuration
            self.restart()
        }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.setSleeping(true) }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.setSleeping(false) }
            },
        ]
        restart()
    }

    func stop() async {
        started = false
        generation += 1
        let epoch = generation
        settingsObserver = nil
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers.removeAll()
        let task = pollingTask
        task?.cancel()
        isSampling = false
        snapshot = SystemMetricsSnapshot()
        // Keep the cancelled task available for a concurrent start() to join.
        await task?.value
        if generation == epoch { pollingTask = nil }
    }

    func setDetailsVisible(_ visible: Bool) {
        guard detailsVisible != visible else { return }
        let previous = configuration.activeMetrics(detailsVisible: detailsVisible)
        detailsVisible = visible
        if previous != configuration.activeMetrics(detailsVisible: visible) { restart() }
    }

    func setSleeping(_ value: Bool) {
        guard sleeping != value else { return }
        sleeping = value
        restart()
    }

    private func restart() {
        generation += 1
        let epoch = generation
        let previous = pollingTask
        previous?.cancel()
        let metrics = configuration.activeMetrics(detailsVisible: detailsVisible)
        let interval = TimeInterval(configuration.interval.rawValue)
        snapshot = SystemMetricsSnapshot()
        isSampling = started && !sleeping && !metrics.isEmpty
        // Wait for the previous read even if a provider ignores cancellation.
        // This serializes reads across rapid setting changes and wake events.
        pollingTask = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled, let self, self.isSampling, self.generation == epoch else { return }
            await self.poll(metrics: metrics, interval: interval, epoch: epoch)
        }
    }

    private func poll(metrics: Set<SystemMetric>, interval: TimeInterval, epoch: Int) async {
        var accumulator = SystemMetricsAccumulator()
        var lastDiskRead: TimeInterval?
        while !Task.isCancelled, started, !sleeping, generation == epoch {
            var requested = metrics
            if let lastDiskRead, now() - lastDiskRead < 30 { requested.remove(.disk) }
            if !requested.isEmpty {
                let sample = await provider.sample(requested)
                guard !Task.isCancelled, generation == epoch else { return }
                accumulator.accept(sample, metrics: requested)
                snapshot = accumulator.snapshot
                if requested.contains(.disk) { lastDiskRead = now() }
            }
            let hasFastMetrics = !metrics.subtracting([.disk]).isEmpty
            let diskDelay = lastDiskRead.map { max(0.001, 30 - (now() - $0)) } ?? 30
            let delay = metrics.contains(.disk) ? min(hasFastMetrics ? interval : 30, diskDelay) : interval
            do { try await sleep(delay) }
            catch { return }
        }
    }
}
