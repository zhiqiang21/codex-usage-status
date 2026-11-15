import AppKit
import SwiftUI

struct UsageMenuBarLabel: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: UserSettings
    @ObservedObject var systemMetricsStore: SystemMetricsStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let presentation = UsageMenuBarPresentation.make(
            from: store.state,
            now: store.menuBarNow
        )

        if let image = UsageMenuBarGraphic.render(
            presentation: presentation,
            displayMode: settings.menuBarDisplayMode,
            showsResetCredits: settings.showsResetCreditsInMenuBar,
            colorScheme: colorScheme,
            systemSnapshot: systemMetricsStore.snapshot,
            systemMetrics: settings.systemMonitor.menuBar
        ) {
            // Preserve the full metric layout as a single native status-item image.
            Image(nsImage: image)
                .renderingMode(.original)
                .accessibilityLabel(accessibilityText)
                .help(accessibilityText)
        } else {
            Text(L10n.tr("Codex usage unavailable"))
        }
    }

    private var accessibilityText: String {
        let metrics = SystemMetric.allCases.filter { settings.systemMonitor.menuBar.contains($0) }.map {
            L10n.tr("%@: %@", $0.title, systemMetricsStore.snapshot.text(for: $0).detailText)
        }
        return ([quotaAccessibilityText] + metrics).joined(separator: L10n.tr(", "))
    }

    private var quotaAccessibilityText: String {
        guard let snapshot = store.state.snapshot else {
            return L10n.tr("Codex usage is temporarily unavailable")
        }

        var parts = [L10n.tr("Codex Usage")]
        for (title, window, isVisible) in [
            (L10n.tr("5 hours"), snapshot.fiveHourWindow, settings.menuBarDisplayMode.showsFiveHour),
            (L10n.tr("7 days"), snapshot.weeklyWindow, settings.menuBarDisplayMode.showsWeekly),
        ] where isVisible {
            if let window {
                parts.append(L10n.tr("%@ remaining: %@%%", "\(title)", "\(window.remainingPercent)"))
                if let resetsAt = window.resetsAt {
                    parts.append(L10n.tr("%@ resets at %@", "\(title)", "\(resetsAt.formatted())"))
                }
            } else {
                parts.append(L10n.tr("%@ usage is temporarily unavailable", "\(title)"))
            }
        }
        if settings.showsResetCreditsInMenuBar,
           let count = snapshot.resetCreditCount, count > 0 {
            parts.append(L10n.tr("Reset credits: %@", "\(count)"))
            if let expiresAt = snapshot.nextResetCreditExpiration(after: store.menuBarNow) {
                parts.append(L10n.tr("Next reset credit expires on %@", "\(expiresAt.formatted(date: .numeric, time: .omitted))"))
            } else {
                parts.append(L10n.tr("No reset credit expiration available"))
            }
        }
        return parts.joined(separator: L10n.tr(", "))
    }
}

struct UsageMenuBarGraphic: View {
    let presentation: UsageMenuBarPresentation
    let displayMode: MenuBarDisplayMode
    let showsResetCredits: Bool
    let colorScheme: ColorScheme
    var systemSnapshot = SystemMetricsSnapshot()
    var systemMetrics: Set<SystemMetric> = []

    @MainActor
    static func render(
        presentation: UsageMenuBarPresentation,
        displayMode: MenuBarDisplayMode,
        showsResetCredits: Bool,
        colorScheme: ColorScheme = .light,
        systemSnapshot: SystemMetricsSnapshot = SystemMetricsSnapshot(),
        systemMetrics: Set<SystemMetric> = []
    ) -> NSImage? {
        let renderer = ImageRenderer(content: UsageMenuBarGraphic(
            presentation: presentation,
            displayMode: displayMode,
            showsResetCredits: showsResetCredits,
            colorScheme: colorScheme,
            systemSnapshot: systemSnapshot,
            systemMetrics: systemMetrics
        ))
        // Keep text sharp on Retina displays while preserving the 22-point size.
        renderer.scale = max(NSScreen.screens.map(\.backingScaleFactor).max() ?? 1, 2)
        return renderer.nsImage
    }

    var body: some View {
        HStack(alignment: .center, spacing: 7) {
            if displayMode.showsFiveHour {
                metric(
                    value: presentation.fiveHourRemainingText,
                    secondaryText: presentation.fiveHourResetText,
                    systemImage: "clock"
                )
            }

            if displayMode.showsWeekly {
                if displayMode.showsFiveHour { separator }
                metric(
                    value: presentation.remainingText,
                    secondaryText: presentation.resetText,
                    systemImage: "calendar"
                )
            }

            if showsResetCredits, let resetCreditText = presentation.resetCreditText {
                separator
                metric(
                    value: resetCreditText,
                    secondaryText: presentation.resetCreditExpirationText,
                    systemImage: "creditcard",
                    minimumWidth: 30
                )
            }
            ForEach(SystemMetric.allCases.filter {
                systemMetrics.contains($0) && $0 != .upload && $0 != .download
            }) { metric in
                separator
                self.metric(
                    value: systemSnapshot.text(for: metric).compactText,
                    secondaryText: metric.title,
                    systemImage: metric.systemImage,
                    minimumWidth: 38
                )
            }
            if !systemMetrics.isDisjoint(with: [.upload, .download]) {
                separator
                networkSpeeds
            }
        }
        .fixedSize()
        .padding(.horizontal, 8)
        .frame(height: 22)
        .foregroundStyle(colorScheme == .dark ? .white : .black.opacity(0.9))
    }

    private var networkSpeeds: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach([SystemMetric.upload, .download].filter { systemMetrics.contains($0) }) { metric in
                HStack(spacing: 3) {
                    Image(systemName: metric.systemImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 9, height: 9)
                        .accessibilityHidden(true)
                    Text(systemSnapshot.text(for: metric).compactText)
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .frame(height: 10)
            }
        }
        .frame(minWidth: 66, alignment: .leading)
    }

    private func metric(
        value: String,
        secondaryText: String,
        systemImage: String,
        minimumWidth: CGFloat = 44
    ) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 3) {
                Image(systemName: systemImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 11, height: 11)
                    .accessibilityHidden(true)
                Text(value)
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .frame(height: 12)

            Text(secondaryText)
                .font(.system(size: 7.5, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .opacity(0.8)
                .frame(height: 8)
        }
        .frame(minWidth: minimumWidth)
    }

    private var separator: some View {
        Rectangle()
            .fill(colorScheme == .dark ? .white.opacity(0.22) : .black.opacity(0.12))
            .frame(width: 0.5, height: 16)
    }
}

struct UsagePopoverView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var storageStore: DeveloperStorageStore
    @ObservedObject var settings: UserSettings
    let systemMetricsStore: SystemMetricsStore
    @ObservedObject var launchAtLoginController: LaunchAtLoginController

    @State private var isStorageExpanded = false
    @State private var isSystemMetricsExpanded = false
    @State private var isSystemMonitorSettingsExpanded = false
    @State private var showsConnectionSettings = false

    private let windowColumnWidth: CGFloat = 78
    private let remainingColumnWidth: CGFloat = 76

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()

                switch store.state {
                case .idle, .loading:
                    loadingContent
                case let .loaded(snapshot, isStale, message):
                    loadedContent(snapshot: snapshot, isStale: isStale, message: message)
                case let .failed(message):
                    failedContent(message: message)
                }

                Divider()
                storageSection
                systemMetricsSection
                systemMonitorSettingsSection
                menuBarSettings
                Divider()
                refreshSettings
                appSettings
                Divider()
                footer
            }
            .padding(16)
        }
        // A scroll viewport needs an explicit height when MenuBarExtra measures
        // its window. Expanded storage and connection settings scroll within it.
        .frame(width: 380, height: min(460, (NSScreen.main?.visibleFrame.height ?? 800) - 80))
        .background {
            SystemMetricsVisibilityObserver { systemMetricsStore.setDetailsVisible($0) }
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .tint(.indigo)
        .background(UsagePopoverDismissObserver {
            storageStore.dismissOperationResult()
            // 面板关闭时折叠各区块，下次打开恢复初始状态
            isStorageExpanded = false
            isSystemMetricsExpanded = false
            isSystemMonitorSettingsExpanded = false
        })
        .task {
            store.refreshIfNeeded()
            storageStore.refreshIfNeeded()
            launchAtLoginController.refreshStatus()
        }
        .onDisappear {
            storageStore.dismissOperationResult()
        }
    }

    private var header: some View {
        HStack {
            Text(L10n.tr("Codex Usage"))
                .font(.system(size: 17, weight: .semibold))
            Spacer()
            Button {
                store.refreshManually()
            } label: {
                if store.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 15))
                }
            }
            .buttonStyle(.plain)
            .frame(width: 24, height: 24)
            .disabled(store.isRefreshing)
            .help(L10n.tr("Refresh now"))
            .accessibilityLabel(L10n.tr("Refresh now"))
        }
        .padding(.bottom, 12)
    }

    private var loadingContent: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(L10n.tr("Loading Codex usage…"))
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 13))
        .frame(maxWidth: .infinity, minHeight: 130, alignment: .leading)
    }

    private func loadedContent(
        snapshot: UsageSnapshot,
        isStale: Bool,
        message: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(L10n.tr("Window")).frame(width: windowColumnWidth, alignment: .leading)
                Text(L10n.tr("Remaining")).frame(width: remainingColumnWidth, alignment: .leading)
                Text(L10n.tr("Resets in")).frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.vertical, 10)

            Divider()
            quotaRow(title: L10n.tr("5 hours"), systemImage: "clock", window: snapshot.fiveHourWindow)
            Divider().opacity(0.5)
            quotaRow(title: L10n.tr("Weekly"), systemImage: "calendar", window: snapshot.weeklyWindow)

            if snapshot.resetCreditCount != 0 {
                Divider()
                HStack {
                    Label(L10n.tr("Reset credits"), systemImage: "creditcard")
                    Spacer()
                    Text(snapshot.resetCreditCount.map { L10n.tr("Credits: %@", "\($0)") } ?? L10n.tr("Unknown"))
                        .monospacedDigit()
                }
                .font(.system(size: 13))
                .padding(.vertical, 12)
            }

            if isStale || message != nil {
                statusMessage(message ?? L10n.tr("Data may be out of date"), color: .orange)
                    .padding(.bottom, 10)
            }
        }
    }

    private func quotaRow(
        title: String,
        systemImage: String,
        window: UsageWindowSnapshot?
    ) -> some View {
        HStack(spacing: 10) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage).frame(width: 16)
            }
            .font(.system(size: 13))
            .frame(width: windowColumnWidth, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text(window.map { "\($0.remainingPercent)%" } ?? "--%")
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
                if let window {
                    ProgressView(value: Double(window.remainingPercent), total: 100)
                        .progressViewStyle(.linear)
                        .tint(progressColor(for: window.remainingPercent))
                        .frame(height: 3)
                        .accessibilityLabel(L10n.tr("%@ remaining quota", "\(title)"))
                }
            }
            .frame(width: remainingColumnWidth, alignment: .leading)

            Text(resetTimeText(window?.resetsAt))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(window?.resetsAt?.formatted() ?? L10n.tr("Codex did not return a reset time"))
        }
        .frame(minHeight: 50)
        .help(window == nil ? L10n.tr("Codex did not return the %@ usage window", "\(title)") : L10n.tr("%@ usage", "\(title)"))
    }

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            disclosureHeader(L10n.tr("Developer Storage"), systemImage: "internaldrive", isExpanded: $isStorageExpanded) {
                storageStore.dismissOperationResult()
            }

            if isStorageExpanded {
                DeveloperStorageView(store: storageStore, showsHeader: false)
                    .padding(.top, 4)
                    .padding(.bottom, 12)
            }
            Divider()
        }
    }

    @ViewBuilder
    private var systemMetricsSection: some View {
        if !settings.systemMonitor.details.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                disclosureHeader(L10n.tr("System Status"), systemImage: "desktopcomputer", isExpanded: $isSystemMetricsExpanded)

                if isSystemMetricsExpanded {
                    SystemMetricsDetailView(store: systemMetricsStore, settings: settings, showsHeader: false)
                        .padding(.top, 4)
                        .padding(.bottom, 12)
                }
                Divider()
            }
        }
    }

    private var systemMonitorSettingsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            disclosureHeader(L10n.tr("System Monitoring Settings"), systemImage: "slider.horizontal.3", isExpanded: $isSystemMonitorSettingsExpanded)

            if isSystemMonitorSettingsExpanded {
                SystemMonitorSettingsView(settings: settings, showsHeader: false)
                    .padding(.top, 4)
                    .padding(.bottom, 12)
            }
            Divider()
        }
    }

    /// 可折叠区块的统一标题行：图标 + 标题 + 折叠指示箭头
    private func disclosureHeader(
        _ title: String,
        systemImage: String,
        isExpanded: Binding<Bool>,
        onToggle: (() -> Void)? = nil
    ) -> some View {
        Button {
            isExpanded.wrappedValue.toggle()
            onToggle?()
        } label: {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 13))
            .frame(minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded.wrappedValue ? L10n.tr("Collapse %@", title) : L10n.tr("Expand %@", title))
    }

    private var menuBarSettings: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.tr("Display mode"))
                Spacer(minLength: 8)
                Picker(L10n.tr("Menu bar usage window"), selection: Binding(
                    get: { settings.menuBarDisplayMode },
                    set: { settings.setMenuBarDisplayMode($0) }
                )) {
                    ForEach(MenuBarDisplayMode.allCases) { mode in
                        Text(mode == .both ? L10n.tr("All") : mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(width: 196)
            }
            .frame(minHeight: 42)

            HStack {
                Text(L10n.tr("Show reset credits"))
                Spacer()
                Toggle(L10n.tr("Show reset credits"), isOn: Binding(
                    get: { settings.showsResetCreditsInMenuBar },
                    set: { settings.setShowsResetCreditsInMenuBar($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
            }
            .frame(minHeight: 34)
        }
        .font(.system(size: 13))
    }

    private var refreshSettings: some View {
        HStack {
            Text(L10n.tr("Automatic refresh"))
            Spacer()
            Picker(L10n.tr("Automatic refresh interval"), selection: Binding(
                get: { settings.refreshInterval },
                set: { store.setRefreshInterval($0) }
            )) {
                ForEach(RefreshInterval.allCases) { interval in
                    Text(interval.title).tag(interval)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(width: 100)
        }
        .font(.system(size: 13))
        .frame(minHeight: 34)
    }

    private var appSettings: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.tr("Launch at login"))
                Spacer()
                Toggle(L10n.tr("Launch at login"), isOn: Binding(
                    get: { launchAtLoginController.isEnabled },
                    set: { launchAtLoginController.setEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
            }
            .frame(minHeight: 34)

            if launchAtLoginController.requiresApproval {
                HStack {
                    Text(L10n.tr("Approve the login item in System Settings"))
                        .foregroundStyle(.orange)
                    Spacer()
                    Button(L10n.tr("Open Settings")) { launchAtLoginController.openSystemSettings() }
                        .controlSize(.small)
                }
                .font(.caption)
                .padding(.bottom, 8)
            }

            if let errorMessage = launchAtLoginController.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.bottom, 8)
            }

            if showsConnectionSettings {
                connectionSettings
                    .padding(.vertical, 10)
            }
        }
        .font(.system(size: 13))
        .padding(.bottom, 6)
    }

    private var connectionSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Codex CLI").font(.subheadline.weight(.medium))
            Text(executablePathText)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(executablePathText)
            HStack {
                Button(L10n.tr("Auto-detect")) { store.setExecutablePath(nil) }
                Button(L10n.tr("Choose…")) { chooseCodexExecutable() }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Circle().fill(statusColor).frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(updateText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .help(store.nextRefreshAt.map { L10n.tr("Next refresh %@", "\(shortTime($0))") } ?? L10n.tr("Waiting to refresh"))
            Spacer()
            Button {
                showsConnectionSettings.toggle()
            } label: {
                Image(systemName: "gearshape")
            }
            .help(L10n.tr("Codex CLI Settings"))
            .accessibilityLabel(L10n.tr("Codex CLI Settings"))
            .accessibilityValue(showsConnectionSettings ? L10n.tr("Expanded") : L10n.tr("Collapsed"))

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help(L10n.tr("Quit Codex Usage Status"))
            .accessibilityLabel(L10n.tr("Quit"))
            .keyboardShortcut("q")
        }
        .font(.system(size: 13))
        .buttonStyle(.plain)
        .padding(.top, 12)
    }

    private var updateText: String {
        guard let snapshot = store.state.snapshot else {
            return store.isRefreshing ? L10n.tr("Refreshing…") : L10n.tr("Usage unavailable")
        }
        if store.menuBarNow.timeIntervalSince(snapshot.updatedAt) < 60 {
            return L10n.tr("Updated just now")
        }
        return L10n.tr("Updated at %@", "\(shortTime(snapshot.updatedAt))")
    }

    private var statusColor: Color {
        switch store.state {
        case let .loaded(_, isStale, _): isStale ? .orange : .green
        case .failed: .red
        case .idle, .loading: .secondary
        }
    }

    private var executablePathText: String {
        if !settings.executablePath.isEmpty { return settings.executablePath }
        return store.resolvedExecutablePath ?? L10n.tr("Auto-detect")
    }

    private func resetTimeText(_ resetDate: Date?) -> String {
        guard let resetDate else { return L10n.tr("Unknown") }
        let seconds = resetDate.timeIntervalSince(store.menuBarNow)
        guard seconds > 0 else { return L10n.tr("Reset due") }
        let totalMinutes = max(Int(ceil(seconds / 60)), 1)
        let days = totalMinutes / 1_440
        let hours = totalMinutes % 1_440 / 60
        let minutes = totalMinutes % 60
        if days > 0 { return hours > 0 ? L10n.tr("%@d %@h", "\(days)", "\(hours)") : L10n.tr("%@d", "\(days)") }
        if hours > 0 { return minutes > 0 ? L10n.tr("%@h %@m", "\(hours)", "\(minutes)") : L10n.tr("%@h", "\(hours)") }
        return L10n.tr("%@m", "\(minutes)")
    }

    private func failedContent(message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            statusMessage(message, color: .red)
            Button(L10n.tr("Retry")) { store.refreshManually() }
                .disabled(store.isRefreshing)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, minHeight: 130, alignment: .leading)
    }

    private func statusMessage(_ message: String, color: Color) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func progressColor(for remainingPercent: Int) -> Color {
        switch remainingPercent {
        case 0..<20: .red
        case 20..<40: .orange
        default: .indigo
        }
    }

    private func shortTime(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute())
    }

    private func chooseCodexExecutable() {
        let panel = NSOpenPanel()
        panel.title = L10n.tr("Choose Codex CLI")
        panel.message = L10n.tr("Select the codex executable")
        panel.prompt = L10n.tr("Choose")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in store.setExecutablePath(url.path) }
        }
    }
}

// A window-style MenuBarExtra can retain its content while hiding the window.
// Observe only this view's host window, rather than unrelated app windows.
struct UsagePopoverDismissObserver: NSViewRepresentable {
    let onDismiss: () -> Void

    func makeNSView(context: Context) -> UsagePopoverDismissView {
        let view = UsagePopoverDismissView()
        view.onDismiss = onDismiss
        return view
    }

    func updateNSView(_ nsView: UsagePopoverDismissView, context: Context) {
        nsView.onDismiss = onDismiss
    }

    static func dismantleNSView(_ nsView: UsagePopoverDismissView, coordinator: ()) {
        nsView.stopObserving()
        nsView.onDismiss = nil
    }
}

final class UsagePopoverDismissView: NSView {
    var onDismiss: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        guard let window else { return }
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification,
                     NSWindow.didChangeOcclusionStateNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(windowChanged(_:)), name: name, object: window)
        }
    }

    func stopObserving() {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func windowChanged(_ notification: Notification) {
        guard let window else { return }
        if notification.name == NSWindow.didChangeOcclusionStateNotification {
            guard !window.isVisible else { return }
        } else if notification.name == NSWindow.didResignKeyNotification, window.attachedSheet != nil {
            return
        }
        onDismiss?()
    }
}

#if DEBUG
#Preview("Loaded") {
    UsagePopoverView(
        store: .preview(
            state: .loaded(
                snapshot: .preview,
                isStale: false,
                message: nil
            )
        ),
        storageStore: DeveloperStorageStore(),
        settings: UserSettings(),
        systemMetricsStore: SystemMetricsStore(settings: UserSettings()),
        launchAtLoginController: LaunchAtLoginController()
    )
}

#Preview("Error") {
    UsagePopoverView(
        store: .preview(
            state: .failed(message: L10n.tr("Codex CLI not found"))
        ),
        storageStore: DeveloperStorageStore(),
        settings: UserSettings(),
        systemMetricsStore: SystemMetricsStore(settings: UserSettings()),
        launchAtLoginController: LaunchAtLoginController()
    )
}
#endif
