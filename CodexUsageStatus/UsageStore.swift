import AppKit
import Foundation

@MainActor
final class UsageStore: ObservableObject {
    typealias ProviderFactory = (URL) -> any RateLimitProviding

    private enum RefreshReason {
        case initial
        case scheduled
        case manual
        case settingsChanged
        case wake
        case resetReached
        case recovery
    }

    private static let reconnectDelays: [UInt64] = [1, 2, 5, 10, 30]

    @Published private(set) var state: UsageViewState
    @Published private(set) var isRefreshing = false
    @Published private(set) var nextRefreshAt: Date?
    @Published private(set) var resolvedExecutablePath: String?
    @Published private(set) var menuBarNow: Date

    let settings: UserSettings

    private let providerFactory: ProviderFactory
    private let now: () -> Date

    private var provider: (any RateLimitProviding)?
    private var eventTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var periodicTask: Task<Void, Never>?
    private var resetTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var menuBarClockTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var refreshQueued = false
    private var started = false
    private var lastFullRefreshAt: Date?
    private var reconnectAttempt = 0

    init(
        settings: UserSettings,
        initialState: UsageViewState = .idle,
        providerFactory: @escaping ProviderFactory = {
            CodexAppServerClient(executableURL: $0)
        },
        now: @escaping () -> Date = Date.init
    ) {
        self.settings = settings
        state = initialState
        menuBarNow = now()
        self.providerFactory = providerFactory
        self.now = now
    }

    func start() {
        guard !started else { return }
        started = true
        observeSystemWake()
        startMenuBarClock()
        state = .loading
        enqueueRefresh(reason: .initial)
    }

    func stop() async {
        started = false
        refreshTask?.cancel()
        refreshTask = nil
        periodicTask?.cancel()
        periodicTask = nil
        resetTask?.cancel()
        resetTask = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        menuBarClockTask?.cancel()
        menuBarClockTask = nil
        eventTask?.cancel()
        eventTask = nil

        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }

        if let provider {
            await provider.stop()
            self.provider = nil
        }
    }

    func refreshManually() {
        reconnectAttempt = 0
        recoveryTask?.cancel()
        recoveryTask = nil
        enqueueRefresh(reason: .manual)
    }

    func refreshIfNeeded() {
        guard shouldRefresh(at: now()) else { return }
        enqueueRefresh(reason: .scheduled)
    }

    func setRefreshInterval(_ interval: RefreshInterval) {
        settings.setRefreshInterval(interval)
        schedulePeriodicRefresh(from: now())
    }

    func setExecutablePath(_ path: String?) {
        settings.setExecutablePath(path)
        Task { [weak self] in
            await self?.restartForExecutableChange()
        }
    }

    private func restartForExecutableChange() async {
        periodicTask?.cancel()
        resetTask?.cancel()
        recoveryTask?.cancel()
        eventTask?.cancel()
        refreshTask?.cancel()
        refreshTask = nil
        refreshQueued = false
        reconnectAttempt = 0
        lastFullRefreshAt = nil
        nextRefreshAt = nil
        resolvedExecutablePath = nil

        if let provider {
            await provider.stop()
            self.provider = nil
        }

        state = .loading
        enqueueRefresh(reason: .settingsChanged)
    }

    private func enqueueRefresh(reason: RefreshReason) {
        guard started else { return }

        if refreshTask != nil {
            refreshQueued = true
            return
        }

        refreshTask = Task { [weak self] in
            guard let self else { return }

            var currentReason = reason
            repeat {
                self.refreshQueued = false
                await self.performFullRefresh(reason: currentReason)
                currentReason = .scheduled
            } while self.refreshQueued && !Task.isCancelled

            self.refreshTask = nil
        }
    }

    private func performFullRefresh(reason: RefreshReason) async {
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let provider = try await ensureConnected()
            let response = try await provider.readRateLimits()
            let refreshDate = now()
            let snapshot = try UsageSnapshotBuilder.makeSnapshot(
                from: response,
                now: refreshDate
            )

            state = .loaded(snapshot: snapshot, isStale: false, message: nil)
            lastFullRefreshAt = refreshDate
            reconnectAttempt = 0
            recoveryTask?.cancel()
            recoveryTask = nil
            schedulePeriodicRefresh(from: refreshDate)
            scheduleResetRefresh(for: snapshot.resetDates)
        } catch is CancellationError {
            return
        } catch {
            await handleRefreshFailure(error, reason: reason)
        }
    }

    private func ensureConnected() async throws -> any RateLimitProviding {
        if let provider {
            return provider
        }

        let executableURL = try CodexExecutableResolver.resolve(
            preferredPath: settings.executablePath
        )
        resolvedExecutablePath = executableURL.path

        let provider = providerFactory(executableURL)
        do {
            try await provider.start()
            let account = try await provider.readAccount()
            try validateAccount(account)
        } catch {
            await provider.stop()
            throw error
        }

        self.provider = provider
        listenForEvents(from: provider)
        return provider
    }

    private func validateAccount(_ response: AccountReadResponse) throws {
        guard let account = response.account else {
            if response.requiresOpenaiAuth {
                throw CodexAppServerError.notAuthenticated
            }
            return
        }

        let unsupportedTypes = ["apiKey", "amazonBedrock"]
        if unsupportedTypes.contains(account.type) {
            throw CodexAppServerError.unsupportedAccount(account.type)
        }
    }

    private func listenForEvents(from provider: any RateLimitProviding) {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            let stream = await provider.events()
            for await event in stream {
                guard !Task.isCancelled else { return }
                self?.handle(event)
            }
        }
    }

    private func handle(_ event: CodexAppServerEvent) {
        switch event {
        case let .rateLimitsUpdated(update):
            guard let snapshot = state.snapshot else { return }
            let merged = UsageSnapshotBuilder.merging(
                update,
                into: snapshot,
                now: now()
            )

            if merged != snapshot {
                state = .loaded(
                    snapshot: merged,
                    isStale: false,
                    message: nil
                )
                scheduleResetRefresh(for: merged.resetDates)
            }

        case let .disconnected(exitCode):
            provider = nil
            markCurrentDataStale(
                message: CodexAppServerError.disconnected(exitCode).localizedDescription
            )
            scheduleRecovery()
        }
    }

    private func handleRefreshFailure(
        _ error: any Error,
        reason: RefreshReason
    ) async {
        let message = (error as? LocalizedError)?.errorDescription
            ?? "刷新 Codex 用量失败"
        markCurrentDataStale(message: message)

        let shouldRecover = isRecoverable(error)
        if shouldRecover {
            eventTask?.cancel()
            eventTask = nil
            if let provider {
                await provider.stop()
                self.provider = nil
            }
            scheduleRecovery()
        } else if state.snapshot != nil {
            schedulePeriodicRefresh(from: now())
        }

        if reason == .manual, !shouldRecover {
            reconnectAttempt = 0
        }
    }

    private func isRecoverable(_ error: any Error) -> Bool {
        guard let error = error as? CodexAppServerError else { return false }
        return switch error {
        case .launchFailed, .disconnected, .requestTimedOut:
            true
        case .executableNotFound,
             .executableNotRunnable,
             .server,
             .invalidResponse,
             .notAuthenticated,
             .unsupportedAccount:
            false
        }
    }

    private func markCurrentDataStale(message: String) {
        if let snapshot = state.snapshot {
            state = .loaded(
                snapshot: snapshot,
                isStale: true,
                message: message
            )
        } else {
            state = .failed(message: message)
        }
    }

    private func schedulePeriodicRefresh(from date: Date) {
        periodicTask?.cancel()
        let interval = settings.refreshInterval.timeInterval
        let targetDate = RefreshPolicy.nextRefreshDate(
            after: date,
            interval: settings.refreshInterval
        )
        nextRefreshAt = targetDate

        periodicTask = Task { [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: Self.nanoseconds(for: interval)
                )
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.enqueueRefresh(reason: .scheduled)
        }
    }

    private func scheduleResetRefresh(for resetDates: [Date]) {
        resetTask?.cancel()
        resetTask = nil

        guard let targetDate = RefreshPolicy.resetRefreshDate(for: resetDates, now: now()) else {
            return
        }
        let delay = targetDate.timeIntervalSince(now())

        // A full response can briefly keep the previous reset timestamp while
        // the backend rolls the window. Do not create an immediate refresh
        // loop; the periodic/wake paths will reconcile it again.
        guard delay > 0 else { return }

        resetTask = Task { [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: Self.nanoseconds(for: delay)
                )
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.enqueueRefresh(reason: .resetReached)
        }
    }

    private func scheduleRecovery() {
        guard recoveryTask == nil,
              reconnectAttempt < Self.reconnectDelays.count
        else {
            return
        }

        periodicTask?.cancel()
        periodicTask = nil
        nextRefreshAt = nil

        let delay = Self.reconnectDelays[reconnectAttempt]
        reconnectAttempt += 1
        recoveryTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay * 1_000_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.recoveryTask = nil
            self?.enqueueRefresh(reason: .recovery)
        }
    }

    private func shouldRefresh(at date: Date) -> Bool {
        RefreshPolicy.shouldRefresh(
            lastFullRefreshAt: lastFullRefreshAt,
            resetDates: state.snapshot?.resetDates ?? [],
            now: date,
            interval: settings.refreshInterval
        )
    }

    private func observeSystemWake() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.shouldRefresh(at: self.now()) else { return }
                self.enqueueRefresh(reason: .wake)
            }
        }
    }

    private func startMenuBarClock() {
        menuBarClockTask?.cancel()
        menuBarNow = now()

        menuBarClockTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                } catch {
                    return
                }

                guard !Task.isCancelled, let self else { return }
                self.menuBarNow = self.now()
            }
        }
    }

    private static func nanoseconds(for interval: TimeInterval) -> UInt64 {
        guard interval > 0 else { return 0 }
        let capped = min(interval, TimeInterval(UInt64.max) / 1_000_000_000)
        return UInt64(capped * 1_000_000_000)
    }

#if DEBUG
    static func preview(state: UsageViewState) -> UsageStore {
        UsageStore(
            settings: UserSettings(),
            initialState: state
        )
    }
#endif
}
