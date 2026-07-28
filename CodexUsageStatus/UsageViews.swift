import AppKit
import SwiftUI

struct UsageMenuBarLabel: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        content(at: store.menuBarNow)
            .accessibilityLabel(accessibilityText)
    }

    private func content(at date: Date) -> some View {
        let presentation = UsageMenuBarPresentation.make(
            from: store.state,
            now: date
        )

        return HStack(spacing: 5) {
            metric(
                value: presentation.remainingText,
                label: "LEFT",
                minimumWidth: 32
            )

            separator

            metric(
                value: presentation.resetText,
                label: "RESET",
                minimumWidth: 42
            )

            if let resetCreditText = presentation.resetCreditText {
                separator
                metric(
                    value: resetCreditText,
                    label: "CARDS",
                    minimumWidth: 27
                )
            }
        }
        .fixedSize()
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(.white)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.01, green: 0.53, blue: 0.76),
                    Color(red: 0.03, green: 0.24, blue: 0.46),
                ],
                startPoint: .top,
                endPoint: .bottom
            ),
            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 0.5)
        }
    }

    private func metric(
        value: String,
        label: String,
        minimumWidth: CGFloat
    ) -> some View {
        VStack(spacing: -1) {
            Text(value)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text(label)
                .font(.system(size: 7, weight: .semibold, design: .rounded))
                .tracking(0.35)
                .opacity(0.92)
        }
        .frame(minWidth: minimumWidth)
    }

    private var separator: some View {
        Rectangle()
            .fill(.white.opacity(0.72))
            .frame(width: 1, height: 19)
    }

    private var accessibilityText: String {
        guard let snapshot = store.state.snapshot else {
            return "Codex 用量暂不可用"
        }

        var parts = ["Codex 本周剩余 \(snapshot.remainingPercent)%"]
        if let resetsAt = snapshot.resetsAt {
            parts.append("重置时间 \(resetsAt.formatted())")
        }
        if let count = snapshot.resetCreditCount, count > 0 {
            parts.append("\(count) 张重置卡")
        }
        return parts.joined(separator: "，")
    }
}

struct UsagePopoverView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: UserSettings
    @ObservedObject var launchAtLoginController: LaunchAtLoginController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            switch store.state {
            case .idle, .loading:
                loadingContent
            case let .loaded(snapshot, isStale, message):
                loadedContent(
                    snapshot: snapshot,
                    isStale: isStale,
                    message: message
                )
            case let .failed(message):
                failedContent(message: message)
            }

            Divider()
            refreshSettings

            Divider()
            appSettings

            footer
        }
        .padding(16)
        .frame(width: 340)
        .task {
            store.refreshIfNeeded()
            launchAtLoginController.refreshStatus()
        }
    }

    private var header: some View {
        HStack {
            Label("Codex 用量", systemImage: "gauge.with.dots.needle.50percent")
                .font(.headline)
            Spacer()
            Button {
                store.refreshManually()
            } label: {
                if store.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.plain)
            .disabled(store.isRefreshing)
            .help("立即刷新")
            .accessibilityLabel("立即刷新")
        }
    }

    private var loadingContent: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("正在读取 Codex 用量…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
    }

    private func loadedContent(
        snapshot: UsageSnapshot,
        isStale: Bool,
        message: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    Text("本周剩余")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(snapshot.remainingPercent)%")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }

                ProgressView(
                    value: Double(snapshot.remainingPercent),
                    total: 100
                )
                .tint(progressColor(for: snapshot.remainingPercent))
            }

            metricRow(
                title: "重置时间",
                systemImage: "clock",
                content: resetTimeView(snapshot.resetsAt)
            )

            metricRow(
                title: "重置卡",
                systemImage: "arrow.counterclockwise.circle",
                content: Text(
                    snapshot.resetCreditCount.map { "\($0) 张" } ?? "未知"
                )
                .monospacedDigit()
            )

            if isStale || message != nil {
                statusMessage(
                    message ?? "数据可能已过期",
                    color: .orange
                )
            }

            HStack {
                Text("更新于 \(shortTime(snapshot.updatedAt))")
                Spacer()
                if let nextRefreshAt = store.nextRefreshAt {
                    Text("下次 \(shortTime(nextRefreshAt))")
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
    }

    private func failedContent(message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            statusMessage(message, color: .red)
            Button("重试") {
                store.refreshManually()
            }
            .disabled(store.isRefreshing)
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
    }

    private var refreshSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("自动刷新")
                .font(.subheadline.weight(.medium))

            Picker(
                "自动刷新频率",
                selection: Binding(
                    get: { settings.refreshInterval },
                    set: { store.setRefreshInterval($0) }
                )
            ) {
                ForEach(RefreshInterval.allCases) { interval in
                    Text(interval.title).tag(interval)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
    }

    private var appSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(
                "登录时启动",
                isOn: Binding(
                    get: { launchAtLoginController.isEnabled },
                    set: { launchAtLoginController.setEnabled($0) }
                )
            )

            if launchAtLoginController.requiresApproval {
                HStack {
                    Text("需要在系统设置中批准登录项")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("打开设置") {
                        launchAtLoginController.openSystemSettings()
                    }
                    .controlSize(.small)
                }
            }

            if let errorMessage = launchAtLoginController.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Codex CLI")
                    .font(.subheadline.weight(.medium))

                Text(executablePathText)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(executablePathText)

                HStack {
                    Button("自动检测") {
                        store.setExecutablePath(nil)
                    }
                    .controlSize(.small)

                    Button("选择…") {
                        chooseCodexExecutable()
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("只读模式")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
            Button("退出") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }

    private var executablePathText: String {
        if !settings.executablePath.isEmpty {
            return settings.executablePath
        }
        return store.resolvedExecutablePath ?? "自动检测"
    }

    @ViewBuilder
    private func resetTimeView(_ resetDate: Date?) -> some View {
        if let resetDate {
            VStack(alignment: .trailing, spacing: 2) {
                Text(resetDate, style: .relative)
                Text(resetDate.formatted(
                    .dateTime
                        .month(.abbreviated)
                        .day()
                        .hour()
                        .minute()
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        } else {
            Text("未知")
        }
    }

    private func metricRow<Content: View>(
        title: String,
        systemImage: String,
        content: Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(title, systemImage: systemImage)
                .foregroundStyle(.secondary)
            Spacer()
            content
        }
    }

    private func statusMessage(_ message: String, color: Color) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func progressColor(for remainingPercent: Int) -> Color {
        switch remainingPercent {
        case 0..<20:
            .red
        case 20..<40:
            .orange
        default:
            .accentColor
        }
    }

    private func shortTime(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute())
    }

    private func chooseCodexExecutable() {
        let panel = NSOpenPanel()
        panel.title = "选择 Codex CLI"
        panel.message = "请选择 codex 可执行文件"
        panel.prompt = "选择"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                store.setExecutablePath(url.path)
            }
        }
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
        settings: UserSettings(),
        launchAtLoginController: LaunchAtLoginController()
    )
}

#Preview("Error") {
    UsagePopoverView(
        store: .preview(
            state: .failed(message: "未找到 Codex CLI")
        ),
        settings: UserSettings(),
        launchAtLoginController: LaunchAtLoginController()
    )
}
#endif
