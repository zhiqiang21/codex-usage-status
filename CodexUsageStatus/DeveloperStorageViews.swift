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
                Label("开发存储", systemImage: "internaldrive")
                    .font(.subheadline.weight(.medium))
            }
            if !store.permissionDeniedKinds.isEmpty { diskAccessGuidance }
            if let historyWarning = store.historyWarning { warning(historyWarning) }
            ForEach(DeveloperStorageKind.allCases) { kind in
                directory(kind)
            }
            if !store.selection.isEmpty {
                HStack {
                    Text("共选 \(store.selection.count) 个项目").font(.caption)
                    Spacer(minLength: 4)
                    Button("删除所选", role: .destructive) { store.requestSelectedCleanup() }
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
                    Text("正在核实清理目标…").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("磁盘占用为估计值；APFS 共享块及快照可能影响实际释放空间。")
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
            Label("部分目录访问受限", systemImage: "lock.shield")
                .font(.caption.weight(.medium))
            Text("若目录受 macOS 隐私保护限制，请在系统设置 → 隐私与安全性 → 完全磁盘访问权限中添加并开启本应用。授权由系统保存，无需每次扫描重新授权；授权后可能需要退出并重新打开应用。文件自身的权限限制仍可能阻止读取。")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack {
                Button("打开授权设置") { openDiskAccessSettings() }
                Button("在 Finder 显示本应用") {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                }
            }
            Button("授权后重新扫描") { store.refreshPermissionDeniedDirectories() }
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
        accessSettingsError = "无法打开系统设置，请从苹果菜单进入隐私与安全性 → 完全磁盘访问权限。"
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
                        Text(snapshot?.sizeText ?? "尚未扫描")
                            .monospacedDigit()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(expanded.contains(kind) ? "折叠" : "展开")\(kind.title)")

                Button { store.refresh(kind) } label: {
                    if store.refreshing.contains(kind) {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.plain)
                .disabled(store.refreshing.contains(kind) || store.cleaningEntryID != nil || store.preparingEntryID != nil || store.pendingConfirmation != nil)
                .help("刷新\(kind.title)")
                .accessibilityLabel("刷新\(kind.title)")
            }
            .font(.caption.weight(.medium))

            Text(kind.displayPath)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let description = kind.monitoringDescription {
                Text(description).font(.caption2).foregroundStyle(.secondary)
            }
            if kind == .simulatorRuntimes {
                Button("在 Xcode 中管理") {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.mini)
                .help("打开 Xcode 后，前往 Settings → Components 管理运行时")
                .disabled(NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode") == nil)
            }

            if let snapshot {
                HStack {
                    Text("\(snapshot.entries.count) 个条目")
                    Spacer()
                    Text("扫描于 \(snapshot.scannedAt.formatted(.dateTime.hour().minute()))")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                if store.isStale(kind) {
                    Text("数据已过期，请刷新后清理")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                if let error = store.refreshErrors[kind] {
                    warning("刷新失败：\(error)")
                }
                if let notice = snapshot.notice { warning(notice) }
                if !snapshot.issues.isEmpty {
                    warning("扫描不完整：\(snapshot.issues.prefix(3).joined(separator: "\n"))")
                    if snapshot.issues.count > 3 {
                        Text("另有 \(snapshot.issues.count - 3) 处无法读取")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
                if expanded.contains(kind) {
                    if snapshot.entries.isEmpty {
                        Text(snapshot.isMissing ? "目录不存在" : snapshot.isComplete ? "目录为空" : "暂无可读取的条目")
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
                Text("正在统计磁盘占用…")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if expanded.contains(kind) {
                StorageTrendView(kind: kind, snapshot: store.trendSnapshots[kind] ?? .empty)
                    .equatable()
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
                    Toggle("选择 \(StoragePathLabel.string(entry.displayName))", isOn: Binding(
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
                Text("UDID：\(device.udid)").font(.caption2.monospaced()).textSelection(.enabled)
            }
            if let date = entry.modifiedAt {
                Text("修改于 \(date.formatted(.dateTime.year().month().day().hour().minute()))")
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
                Button("在 Finder 显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
                }
                if entry.kind.showsBatchSelection || entry.cleanupAction != nil {
                    Spacer(minLength: 2)
                    if store.cleaningEntryID == entry.id {
                        ProgressView().controlSize(.mini)
                        Text("正在清理…").foregroundStyle(.secondary)
                    } else {
                        Button(entry.cleanupTitle, role: .destructive) { store.requestCleanup(entry) }
                            .disabled(!store.canClean(entry) || store.pendingConfirmation != nil)
                    }
                }
            }
            .controlSize(.mini)
            if entry.canListCleanupCandidates {
                Button("查看可清理项") { store.loadCleanupCandidates(entry) }
                    .controlSize(.mini)
                    .disabled(store.isBusy || store.pendingConfirmation != nil || store.isStale(.codexData))
                if let error = store.candidateErrors[entry.id] { warning(error) }
                if let candidates = store.cleanupCandidates[entry.id] {
                    if candidates.isEmpty {
                        Text("没有符合白名单或日志保留期的可清理文件").font(.caption2).foregroundStyle(.secondary)
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
            Button("全选") { store.selectAll(kind) }
                .disabled(!entries.contains { store.canClean($0) && !store.isSelected($0) })
            Button("全部取消") { store.deselectAll(kind) }
                .disabled(selectedCount == 0)
            Spacer(minLength: 0)
            Text("已选 \(selectedCount) 项").foregroundStyle(.secondary)
        }
        .font(.caption)
        .controlSize(.mini)
        .disabled(store.isBusy || store.pendingConfirmation != nil)
    }

    private func cleanupFileRow(_ entry: DeveloperStorageEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Toggle("选择 \(StoragePathLabel.string(entry.name))", isOn: Binding(
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
                Text("修改于 \(modifiedAt.formatted())").foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("永久删除", role: .destructive) { store.requestCleanup(entry) }
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
            Text("请核对以下具体条目。操作不可恢复，每项执行前都会重新检查；失败项不会自动重试。")
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
                Button("取消", action: cancel).keyboardShortcut(.cancelAction)
                Button(request.actionTitle, role: .destructive, action: confirm)
            }
        }
        .padding(16)
        .frame(width: 420, height: min(500, (NSScreen.main?.visibleFrame.height ?? 800) - 120))
    }
}
