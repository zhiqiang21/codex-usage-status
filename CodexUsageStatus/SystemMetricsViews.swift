import AppKit
import SwiftUI

// A MenuBarExtra window can be hidden while SwiftUI keeps its content mounted.
// Observe the hosting window so details-only sampling follows actual visibility.
struct SystemMetricsVisibilityObserver: NSViewRepresentable {
    let onVisibilityChange: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> SystemMetricsVisibilityView {
        SystemMetricsVisibilityView(onVisibilityChange: onVisibilityChange)
    }

    func updateNSView(_ view: SystemMetricsVisibilityView, context: Context) {
        view.onVisibilityChange = onVisibilityChange
    }

    static func dismantleNSView(_ view: SystemMetricsVisibilityView, coordinator: ()) {
        view.stopObserving()
        view.onVisibilityChange(false)
    }
}

@MainActor
final class SystemMetricsVisibilityView: NSView {
    var onVisibilityChange: @MainActor (Bool) -> Void
    private var visibilityObservation: NSKeyValueObservation?
    private var pendingUpdate: Task<Void, Never>?
    private var observationGeneration = 0

    init(onVisibilityChange: @escaping @MainActor (Bool) -> Void) {
        self.onVisibilityChange = onVisibilityChange
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        let epoch = observationGeneration
        visibilityObservation = window?.observe(\.isVisible, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.observationGeneration == epoch else { return }
                self.scheduleUpdate()
            }
        }
        scheduleUpdate()
    }

    private func scheduleUpdate() {
        pendingUpdate?.cancel()
        pendingUpdate = Task { @MainActor [weak self] in
            guard !Task.isCancelled, let self else { return }
            onVisibilityChange(window?.isVisible == true)
        }
    }

    func stopObserving() {
        observationGeneration += 1
        visibilityObservation = nil
        pendingUpdate?.cancel()
        pendingUpdate = nil
    }
}

struct SystemMetricsDetailView: View {
    @ObservedObject var store: SystemMetricsStore
    @ObservedObject var settings: UserSettings
    var showsHeader = true

    var body: some View {
        if !settings.systemMonitor.details.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if showsHeader {
                    Label("系统状态", systemImage: "desktopcomputer")
                        .font(.subheadline.weight(.medium))
                }
                ForEach(SystemMetric.allCases.filter { settings.systemMonitor.details.contains($0) }) { metric in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Label(metric.title, systemImage: metric.systemImage)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(store.snapshot.text(for: metric).detailText)
                                .monospacedDigit()
                                .multilineTextAlignment(.trailing)
                        }
                        .accessibilityElement(children: .combine)
                        capacityDetails(for: metric)
                    }
                    .font(.caption)
                }
                if !settings.systemMonitor.details.isDisjoint(with: [.upload, .download]),
                   case let .value(network) = store.snapshot.network {
                    Text("网络接口：\(network.interface)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if settings.systemMonitor.details.contains(.memory) {
                    Text("内存为已用估算：匿名内存扣除可清除部分，加 wired 与压缩器实际占用。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func capacityDetails(for metric: SystemMetric) -> some View {
        let reading: MetricReading<CapacityUsage>? = switch metric {
        case .disk: store.snapshot.disk
        case .memory: store.snapshot.memory
        default: nil
        }
        if case let .value(capacity) = reading {
            ProgressView(value: capacity.percent, total: 100)
            Text("已用 \(SystemMetricFormatter.capacity(capacity.usedBytes)) / 共 \(SystemMetricFormatter.capacity(capacity.totalBytes))")
                .foregroundStyle(.secondary)
            if metric == .disk {
                Text("可用 \(SystemMetricFormatter.capacity(capacity.availableBytes)) · 系统盘")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct SystemMonitorSettingsView: View {
    @ObservedObject var settings: UserSettings
    var showsHeader = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsHeader {
                Text("系统监控设置").font(.subheadline.weight(.medium))
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("指标")
                    Text("菜单栏")
                    Text("详情")
                }
                .font(.caption).foregroundStyle(.secondary)
                ForEach(SystemMetric.allCases) { metric in
                    GridRow {
                        Label(metric.title, systemImage: metric.systemImage)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        visibilityToggle(metric, at: .menuBar)
                        visibilityToggle(metric, at: .details)
                    }
                }
            }
            Text("系统刷新频率").font(.caption).foregroundStyle(.secondary)
            Picker("系统刷新频率", selection: Binding(
                get: { settings.systemMonitor.interval },
                set: { settings.setSystemRefreshInterval($0) }
            )) {
                ForEach(SystemRefreshInterval.allCases) { interval in
                    Text(interval.title).tag(interval)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            Text("磁盘容量每 30 秒更新；系统刷新独立于 Codex 用量刷新。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func visibilityToggle(_ metric: SystemMetric, at location: SystemMetricLocation) -> some View {
        Toggle("\(metric.title)\(location == .menuBar ? "菜单栏" : "详情")显示", isOn: Binding(
            get: { settings.systemMonitor.contains(metric, at: location) },
            set: { settings.setSystemMetric(metric, at: location, visible: $0) }
        ))
        .labelsHidden()
        .toggleStyle(.checkbox)
        .accessibilityLabel("\(metric.title)\(location == .menuBar ? "菜单栏" : "详情")显示")
    }
}

extension MetricReading where Value == String {
    var compactText: String {
        switch self {
        case .waiting: "…"
        case let .value(value): value
        case .unavailable, .disconnected: "--"
        }
    }
    var detailText: String {
        switch self {
        case .waiting: "等待采样…"
        case let .value(value): value
        case let .unavailable(message): "不可用：\(message)"
        case .disconnected: "未连接"
        }
    }
}
