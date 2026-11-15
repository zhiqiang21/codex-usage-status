import AppKit
import SwiftUI

struct DeveloperStorageView: View {
    @ObservedObject var store: DeveloperStorageStore
    var showsHeader = true
    @State private var expanded: Set<DeveloperStorageKind> = []
    @State private var accessSettingsError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsHeader {
                Label(L10n.tr("Developer Storage"), systemImage: "internaldrive")
                    .font(.subheadline.weight(.medium))
            }
            if !store.permissionDeniedKinds.isEmpty { diskAccessGuidance }
            if let historyWarning = store.historyWarning { warning(historyWarning) }
            ForEach(DeveloperStorageKind.allCases) { kind in
                directory(kind)
            }
            if !store.selection.isEmpty {
                HStack {
                    Text(L10n.tr("%@ items selected", "\(store.selection.count)")).font(.caption)
                    Spacer(minLength: 4)
                    Button(L10n.tr("Delete Selected"), role: .destructive) { store.requestSelectedCleanup() }
                        .disabled(!store.canCleanSelection || store.pendingConfirmation != nil)
                }
                .controlSize(.small)
            }
            if let progress = store.cleanupProgress {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(progress).font(.caption).foregroundStyle(.secondary)
                }
            }
            if store.preparingEntryID != nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(L10n.tr("Verifying cleanup targets…")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(L10n.tr("Disk usage is an estimate. APFS shared blocks and snapshots may affect the space actually reclaimed."))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if let message = store.operationMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(store.operationFailed ? Color.red : Color.secondary)
                    .textSelection(.enabled)
            }
        }
        .task { store.refreshIfNeeded() }
        .sheet(item: $store.pendingConfirmation, onDismiss: { store.cancelCleanup() }) { request in
            StorageCleanupConfirmationView(
                request: request,
                cancel: { store.cancelCleanup() },
                confirm: { store.confirmCleanup(request) }
            )
        }
    }

    private var diskAccessGuidance: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L10n.tr("Access to some directories is restricted"), systemImage: "lock.shield")
                .font(.caption.weight(.medium))
            Text(L10n.tr("If macOS privacy protections restrict a directory, add and enable this app in System Settings → Privacy & Security → Full Disk Access. The system remembers this permission; scans do not require repeated authorization. You may need to quit and reopen the app after granting access. File permissions may still prevent reading."))
                .font(.caption2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Button(L10n.tr("Open Privacy Settings")) { openDiskAccessSettings() }
                Button(L10n.tr("Show This App in Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                }
            }
            Button(L10n.tr("Rescan After Authorization")) { store.refreshPermissionDeniedDirectories() }
                .disabled(store.isBusy || store.pendingConfirmation != nil)
            if let accessSettingsError { warning(accessSettingsError) }
        }
        .controlSize(.mini)
        .padding(8)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
    }

    private func openDiskAccessSettings() {
        accessSettingsError = nil
        // This is a navigation hint, not an authorization API. Fall back to the
        // Settings app if a system version does not accept the pane URL.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"),
           NSWorkspace.shared.open(url) { return }
        if let settings = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences"),
           NSWorkspace.shared.open(settings) { return }
        accessSettingsError = L10n.tr("Unable to open System Settings. Use the Apple menu to open Privacy & Security → Full Disk Access.")
    }

    private func directory(_ kind: DeveloperStorageKind) -> some View {
        let snapshot = store.snapshots[kind]
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    store.dismissOperationResult()
                    if expanded.contains(kind) { expanded.remove(kind) }
                    else { expanded.insert(kind) }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: expanded.contains(kind) ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                        Text(kind.title)
                        Spacer(minLength: 2)
                        Text(snapshot?.sizeText ?? L10n.tr("Not scanned yet"))
                            .monospacedDigit()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded.contains(kind) ? L10n.tr("Collapse %@", kind.title) : L10n.tr("Expand %@", kind.title))

                Button { store.refresh(kind) } label: {
                    if store.refreshing.contains(kind) {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.plain)
                .disabled(store.refreshing.contains(kind) || store.cleaningEntryID != nil || store.preparingEntryID != nil || store.pendingConfirmation != nil)
                .help(L10n.tr("Refresh %@", "\(kind.title)"))
                .accessibilityLabel(L10n.tr("Refresh %@", "\(kind.title)"))
            }
            .font(.caption.weight(.medium))

            Text(kind.displayPath)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if expanded.contains(kind) {
                StorageTrendView(kind: kind, snapshot: store.trendSnapshots[kind] ?? .empty)
                    .equatable()
            }
            if let description = kind.monitoringDescription {
                Text(description).font(.caption2).foregroundStyle(.secondary)
            }
            if kind == .simulatorRuntimes {
                Button(L10n.tr("Manage in Xcode")) {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.mini)
                .help(L10n.tr("Open Xcode, then go to Settings → Components to manage runtimes"))
                .disabled(NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode") == nil)
            }

            if let snapshot {
                HStack {
                    Text(L10n.tr("Items: %@", "\(snapshot.entries.count)"))
                    Spacer()
                    Text(L10n.tr("Scanned at %@", "\(snapshot.scannedAt.formatted(.dateTime.hour().minute()))"))
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                if store.isStale(kind) {
                    Text(L10n.tr("Data is out of date. Refresh before cleanup"))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                if let error = store.refreshErrors[kind] {
                    warning(L10n.tr("Refresh failed: %@", "\(error)"))
                }
                if let notice = snapshot.notice { warning(notice) }
                if !snapshot.issues.isEmpty {
                    warning(L10n.tr("Incomplete scan: %@", "\(snapshot.issues.prefix(3).joined(separator: "\n"))"))
                    if snapshot.issues.count > 3 {
                        Text(L10n.tr("%@ more locations could not be read", "\(snapshot.issues.count - 3)"))
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
                if expanded.contains(kind) {
                    if snapshot.entries.isEmpty {
                        Text(snapshot.isMissing ? L10n.tr("Directory not found") : snapshot.isComplete ? L10n.tr("Directory is empty") : L10n.tr("No readable entries"))
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        if kind.showsBatchSelection || (kind == .codexData && !store.selectableEntries(kind).isEmpty) {
                            selectionControls(kind)
                        }
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(snapshot.entries) { entry in
                                entryRow(entry)
                            }
                        }
                    }
                }
            } else if store.refreshing.contains(kind) {
                Text(L10n.tr("Calculating disk usage…"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
    }

    private func entryRow(_ entry: DeveloperStorageEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            HStack(alignment: .firstTextBaseline) {
                if entry.kind.showsBatchSelection || entry.allowsSelection {
                    Toggle(L10n.tr("Select %@", "\(StoragePathLabel.string(entry.displayName))"), isOn: Binding(
                        get: { store.isSelected(entry) },
                        set: { store.setSelected($0, entry: entry) }
                    ))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(!store.canClean(entry) || store.pendingConfirmation != nil)
                }
                Text(StoragePathLabel.string(entry.displayName)).fontWeight(.medium)
                Spacer(minLength: 4)
                Text(entry.sizeText).monospacedDigit()
            }
            if let device = entry.device {
                Text("\(StoragePathLabel.string(device.runtimeTitle)) · \(device.stateTitle)\(device.availabilityTitle)")
                    .foregroundStyle(.secondary)
                Text("UDID: \(device.udid)").font(.caption2.monospaced()).textSelection(.enabled)
            }
            if let date = entry.modifiedAt {
                Text(L10n.tr("Modified at %@", "\(date.formatted(.dateTime.year().month().day().hour().minute()))"))
                    .foregroundStyle(.secondary)
            }
            Text(StoragePathLabel.string(entry.path))
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if entry.kind != .codexData, let reason = entry.cleanupUnavailableReason {
                Text(reason).font(.caption2).foregroundStyle(.secondary)
            }
            if let mark = entry.safetyMark, entry.cleanupUnavailableReason == nil {
                Text(mark).font(.caption2).foregroundStyle(.green)
            }
            if !entry.issues.isEmpty { warning(entry.issues.prefix(2).joined(separator: "\n")) }
            HStack {
                Button(L10n.tr("Show in Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
                }
                if entry.kind.showsBatchSelection || entry.cleanupAction != nil {
                    Spacer(minLength: 2)
                    if store.cleaningEntryID == entry.id {
                        ProgressView().controlSize(.mini)
                        Text(L10n.tr("Cleaning…")).foregroundStyle(.secondary)
                    } else {
                        Button(entry.cleanupTitle, role: .destructive) { store.requestCleanup(entry) }
                            .disabled(!store.canClean(entry) || store.pendingConfirmation != nil)
                    }
                }
            }
            .controlSize(.mini)
            if entry.canListCleanupCandidates {
                Button(L10n.tr("View Cleanup Candidates")) { store.loadCleanupCandidates(entry) }
                    .controlSize(.mini)
                    .disabled(store.isBusy || store.pendingConfirmation != nil || store.isStale(.codexData))
                if let error = store.candidateErrors[entry.id] { warning(error) }
                if let candidates = store.cleanupCandidates[entry.id] {
                    if candidates.isEmpty {
                        Text(L10n.tr("No files match the allowlist or log retention period")).font(.caption2).foregroundStyle(.secondary)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(candidates) { file in cleanupFileRow(file) }
                        }
                    }
                }
            }
        }
        .font(.caption)
    }

    private func warning(_ text: String) -> some View {
        Text(text).font(.caption2).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func selectionControls(_ kind: DeveloperStorageKind) -> some View {
        let entries = store.selectableEntries(kind)
        let selectedCount = entries.filter { store.isSelected($0) }.count
        return HStack(spacing: 8) {
            Button(L10n.tr("Select All")) { store.selectAll(kind) }
                .disabled(!entries.contains { store.canClean($0) && !store.isSelected($0) })
            Button(L10n.tr("Deselect All")) { store.deselectAll(kind) }
                .disabled(selectedCount == 0)
            Spacer(minLength: 0)
            Text(L10n.tr("%@ selected", "\(selectedCount)")).foregroundStyle(.secondary)
        }
        .font(.caption)
        .controlSize(.mini)
        .disabled(store.isBusy || store.pendingConfirmation != nil)
    }

    private func cleanupFileRow(_ entry: DeveloperStorageEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Toggle(L10n.tr("Select %@", "\(StoragePathLabel.string(entry.name))"), isOn: Binding(
                    get: { store.isSelected(entry) }, set: { store.setSelected($0, entry: entry) }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                Text(StoragePathLabel.string(entry.name)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 2)
                Text(entry.sizeText).monospacedDigit()
            }
            Text(StoragePathLabel.string(entry.path)).font(.caption2.monospaced()).textSelection(.enabled)
            if let modifiedAt = entry.modifiedAt {
                Text(L10n.tr("Modified at %@", "\(modifiedAt.formatted())")).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(L10n.tr("Delete Permanently"), role: .destructive) { store.requestCleanup(entry) }
                    .controlSize(.mini)
            }
        }
        .font(.caption2)
        .padding(6)
        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
        .disabled(!store.canClean(entry) || store.pendingConfirmation != nil)
    }
}

private struct StorageCleanupConfirmationView: View {
    let request: StorageCleanupRequest
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.title).font(.headline)
            Text(L10n.tr("Review the exact items below. This operation cannot be undone. Each item is checked again before cleanup. Failed items will not be retried automatically."))
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(request.entries.enumerated()), id: \.element.id) { index, entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(index + 1). \(entry.kind.title)").fontWeight(.medium)
                            Text(entry.confirmationMessage).textSelection(.enabled)
                            Divider()
                        }
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            HStack {
                Spacer()
                Button(L10n.tr("Cancel"), action: cancel).keyboardShortcut(.cancelAction)
                Button(request.actionTitle, role: .destructive, action: confirm)
            }
        }
        .padding(16)
        .frame(width: 420, height: min(500, (NSScreen.main?.visibleFrame.height ?? 800) - 120))
    }
}
