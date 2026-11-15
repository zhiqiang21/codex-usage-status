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
                    Label(L10n.tr("System Status"), systemImage: "desktopcomputer")
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
                    Text(L10n.tr("Network interface: %@", "\(network.interface)"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if settings.systemMonitor.details.contains(.memory) {
                    Text(L10n.tr("Memory is an estimate: anonymous memory minus purgeable pages, plus wired and actual compressor usage."))
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
            Text(L10n.tr("Used %@ / Total %@", "\(SystemMetricFormatter.capacity(capacity.usedBytes))", "\(SystemMetricFormatter.capacity(capacity.totalBytes))"))
                .foregroundStyle(.secondary)
            if metric == .disk {
                Text(L10n.tr("Available %@ · Startup disk", "\(SystemMetricFormatter.capacity(capacity.availableBytes))"))
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
                Text(L10n.tr("System Monitoring Settings")).font(.subheadline.weight(.medium))
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text(L10n.tr("Metric"))
                    Text(L10n.tr("Menu Bar"))
                    Text(L10n.tr("Details"))
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
            Text(L10n.tr("System refresh interval")).font(.caption).foregroundStyle(.secondary)
            Picker(L10n.tr("System refresh interval"), selection: Binding(
                get: { settings.systemMonitor.interval },
                set: { settings.setSystemRefreshInterval($0) }
            )) {
                ForEach(SystemRefreshInterval.allCases) { interval in
                    Text(interval.title).tag(interval)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            Text(L10n.tr("Disk capacity updates every 30 seconds. System monitoring refreshes independently of Codex usage."))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func visibilityToggle(_ metric: SystemMetric, at location: SystemMetricLocation) -> some View {
        Toggle(L10n.tr("Show %@ in %@", "\(metric.title)", "\(location == .menuBar ? L10n.tr("Menu Bar") : L10n.tr("Details"))"), isOn: Binding(
            get: { settings.systemMonitor.contains(metric, at: location) },
            set: { settings.setSystemMetric(metric, at: location, visible: $0) }
        ))
        .labelsHidden()
        .toggleStyle(.checkbox)
        .accessibilityLabel(L10n.tr("Show %@ in %@", "\(metric.title)", "\(location == .menuBar ? L10n.tr("Menu Bar") : L10n.tr("Details"))"))
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
        case .waiting: L10n.tr("Waiting for sample…")
        case let .value(value): value
        case let .unavailable(message): L10n.tr("Unavailable: %@", "\(message)")
        case .disconnected: L10n.tr("Disconnected")
        }
    }
}
