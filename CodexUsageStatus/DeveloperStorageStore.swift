import Foundation

@MainActor
final class DeveloperStorageStore: ObservableObject {
    // Scans are reused for this long before another walk is started.
    static let cacheInterval: TimeInterval = 300

    @Published private(set) var snapshots: [DeveloperStorageKind: DeveloperStorageSnapshot] = [:]
    @Published private(set) var refreshing: Set<DeveloperStorageKind> = []
    @Published private(set) var refreshErrors: [DeveloperStorageKind: String] = [:]
    @Published private(set) var permissionDeniedKinds: Set<DeveloperStorageKind> = []
    @Published private(set) var cleaningEntryID: String?
    @Published private(set) var operationMessage: String?
    @Published private(set) var operationFailed = false
    @Published var pendingConfirmation: StorageCleanupRequest?
    @Published private(set) var selection: [String: DeveloperStorageEntry] = [:]
    @Published private(set) var cleanupProgress: String?
    @Published private(set) var preparingEntryID: String?
    @Published private(set) var cleanupCandidates: [String: [DeveloperStorageEntry]] = [:]
    @Published private(set) var candidateErrors: [String: String] = [:]

    private let service: any DeveloperStorageProviding
    private let now: () -> Date
    private var refreshTasks: [DeveloperStorageKind: Task<Void, Never>] = [:]
    private var cleanupTask: Task<Void, Never>?
    private var confirmationRequest: StorageCleanupRequest?
    private var entriesByKind: [DeveloperStorageKind: [String: DeveloperStorageEntry]] = [:]
    private var operationResultGeneration = UUID()

    var isBusy: Bool { cleaningEntryID != nil || preparingEntryID != nil || !refreshing.isEmpty }

    var selectedEntries: [DeveloperStorageEntry] {
        selection.values.sorted {
            $0.kind == $1.kind ? $0.path < $1.path : $0.kind.rawValue < $1.kind.rawValue
        }
    }

    init(service: any DeveloperStorageProviding = DeveloperStorageService(), now: @escaping () -> Date = Date.init) {
        self.service = service
        self.now = now
    }

    func refreshIfNeeded() {
        for kind in DeveloperStorageKind.allCases {
            if snapshots[kind].map({ now().timeIntervalSince($0.scannedAt) >= Self.cacheInterval }) ?? true {
                refresh(kind)
            }
        }
    }

    func isStale(_ kind: DeveloperStorageKind) -> Bool {
        refreshErrors[kind] != nil || snapshots[kind].map { now().timeIntervalSince($0.scannedAt) >= Self.cacheInterval } == true
    }

    func refresh(_ kind: DeveloperStorageKind) {
        guard refreshTasks[kind] == nil, cleaningEntryID == nil, preparingEntryID == nil, pendingConfirmation == nil else { return }
        refreshing.insert(kind)
        refreshTasks[kind] = Task { [weak self, service] in
            let snapshot = await service.scan(kind)
            guard let self else { return }
            accept(snapshot)
            refreshing.remove(kind)
            refreshTasks[kind] = nil
        }
    }

    func refreshPermissionDeniedDirectories() {
        for kind in permissionDeniedKinds { refresh(kind) }
    }

    private func accept(_ snapshot: DeveloperStorageSnapshot) {
        let kind = snapshot.kind
        // Keep current permission failures even when displaying a retained,
        // previously readable snapshot. Never persist a guessed authorization.
        if snapshot.permissionDeniedPaths.isEmpty { permissionDeniedKinds.remove(kind) }
        else { permissionDeniedKinds.insert(kind) }
        if kind == .codexData {
            cleanupCandidates = [:]
            candidateErrors = [:]
        }
        let currentEntries = Dictionary(uniqueKeysWithValues: snapshot.entries.map { ($0.id, $0) })
        entriesByKind[kind] = currentEntries
        selection = selection.filter { _, entry in
            entry.kind != kind || (entry == currentEntries[entry.id] && entry.canClean)
        }
        // Retain a previously measured result after a read failure, but make it
        // visibly stale and revoke cleanup until a successful new scan.
        if snapshot.allocatedBytes == nil, !snapshot.isMissing, snapshots[kind]?.allocatedBytes != nil {
            refreshErrors[kind] = snapshot.issues.joined(separator: "\n")
        } else {
            snapshots[kind] = snapshot
            refreshErrors[kind] = nil
        }
    }

    func canClean(_ entry: DeveloperStorageEntry) -> Bool {
        guard entry.canClean, !isBusy, !isStale(entry.kind), let current = entriesByKind[entry.kind]?[entry.id] else { return false }
        if case .runtime = entry.cleanupAction { return current.withManifest(nil) == entry.withManifest(nil) }
        return current == entry
    }

    func requestCleanup(_ entry: DeveloperStorageEntry) {
        if case .runtime = entry.cleanupAction {
            guard canClean(entry), pendingConfirmation == nil else { return }
            preparingEntryID = entry.id
            let generation = operationResultGeneration
            Task { [weak self, service] in
                do {
                    let prepared = try await service.prepareCleanup(entry)
                    guard let self else { return }
                    preparingEntryID = nil
                    guard generation == operationResultGeneration else { return }
                    requestCleanup([prepared])
                } catch {
                    guard let self else { return }
                    preparingEntryID = nil
                    guard generation == operationResultGeneration else { return }
                    operationMessage = "无法准备卸载：\(error.localizedDescription) 请刷新或在 Xcode 中管理。"
                    operationFailed = true
                }
            }
            return
        }
        requestCleanup([entry])
    }

    func loadCleanupCandidates(_ parent: DeveloperStorageEntry) {
        guard parent.canListCleanupCandidates, !isBusy, pendingConfirmation == nil,
              !isStale(.codexData), entriesByKind[.codexData]?[parent.id] == parent else { return }
        if let previous = cleanupCandidates[parent.id] {
            let previousIDs = Set(previous.map(\.id))
            selection = selection.filter { !previousIDs.contains($0.key) }
            for entry in previous { entriesByKind[.codexData]?[entry.id] = nil }
        }
        cleanupCandidates[parent.id] = nil
        candidateErrors[parent.id] = nil
        preparingEntryID = parent.id
        Task { [weak self, service] in
            do {
                let entries = try await service.cleanupCandidates(in: parent)
                guard let self else { return }
                cleanupCandidates[parent.id] = entries
                for entry in entries { entriesByKind[.codexData]?[entry.id] = entry }
            } catch {
                self?.candidateErrors[parent.id] = error.localizedDescription
            }
            self?.preparingEntryID = nil
        }
    }

    func selectableEntries(_ kind: DeveloperStorageKind) -> [DeveloperStorageEntry] {
        kind == .codexData ? cleanupCandidates.values.flatMap { $0 } : snapshots[kind]?.entries ?? []
    }

    func isSelected(_ entry: DeveloperStorageEntry) -> Bool { selection[entry.id] == entry }

    func setSelected(_ selected: Bool, entry: DeveloperStorageEntry) {
        guard !isBusy, pendingConfirmation == nil else { return }
        if selected {
            guard canClean(entry), entry.allowsSelection else { return }
            selection[entry.id] = entry
        } else {
            selection[entry.id] = nil
        }
    }

    func selectAll(_ kind: DeveloperStorageKind) {
        guard !isBusy, pendingConfirmation == nil else { return }
        var updated = selection
        for entry in selectableEntries(kind) where canClean(entry) && entry.allowsSelection {
            updated[entry.id] = entry
        }
        selection = updated
    }

    func deselectAll(_ kind: DeveloperStorageKind? = nil) {
        guard !isBusy, pendingConfirmation == nil else { return }
        if let kind { selection = selection.filter { $0.value.kind != kind } }
        else { selection = [:] }
    }

    var canCleanSelection: Bool {
        !selection.isEmpty && selection.values.allSatisfy { canClean($0) }
    }

    func requestSelectedCleanup() {
        requestCleanup(selectedEntries)
    }

    private func requestCleanup(_ entries: [DeveloperStorageEntry]) {
        guard pendingConfirmation == nil, !entries.isEmpty, entries.allSatisfy({ canClean($0) }) else { return }
        guard entries.count == 1 || entries.allSatisfy({ $0.allowsSelection }) else { return }
        let request = StorageCleanupRequest(entries: entries)
        confirmationRequest = request
        pendingConfirmation = request
    }

    func cancelCleanup() {
        confirmationRequest = nil
        pendingConfirmation = nil
    }

    func dismissOperationResult() {
        // Closing the panel or changing its disclosure state also dismisses any
        // later result from the in-flight operation, without canceling cleanup.
        operationResultGeneration = UUID()
        operationMessage = nil
        operationFailed = false
    }

    func confirmCleanup(_ request: StorageCleanupRequest) {
        // SwiftUI may clear the presentation binding before invoking the dialog's
        // action. Keep the selected immutable object separately until consumed.
        guard confirmationRequest == request, request.entries.allSatisfy({ canClean($0) }) else {
            cancelCleanup()
            operationMessage = "清理清单已失效，请刷新后重新选择并确认。"
            operationFailed = true
            return
        }
        cancelCleanup()
        cleaningEntryID = request.entries.first?.id
        let consumedIDs = Set(request.entries.map(\.id))
        selection = selection.filter { !consumedIDs.contains($0.key) }
        dismissOperationResult()
        let resultGeneration = operationResultGeneration
        cleanupProgress = "正在准备清理 \(request.entries.count) 个项目…"
        cleanupTask = Task { [weak self, service] in
            let result = await service.cleanBatch(request.entries) { [weak self] progress in
                await self?.updateCleanupProgress(progress)
            }
            guard let self else { return }
            for snapshot in result.snapshots { accept(snapshot) }
            if resultGeneration == operationResultGeneration {
                operationMessage = result.message
                operationFailed = result.hasFailures
            }
            cleaningEntryID = nil
            cleanupProgress = nil
            cleanupTask = nil
        }
    }

    private func updateCleanupProgress(_ progress: StorageCleanupProgress) {
        cleaningEntryID = progress.entry.id
        cleanupProgress = "正在清理 \(progress.index)/\(progress.total)：\(StoragePathLabel.string(progress.entry.displayName))"
    }
}
