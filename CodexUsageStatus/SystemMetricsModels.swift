import Foundation

enum SystemMetric: String, CaseIterable, Identifiable, Sendable {
    case disk, memory, cpu, upload, download

    var id: String { rawValue }
    var title: String {
        switch self {
        case .disk: "磁盘"
        case .memory: "内存"
        case .cpu: "CPU"
        case .upload: "上传"
        case .download: "下载"
        }
    }
    var systemImage: String {
        switch self {
        case .disk: "internaldrive"
        case .memory: "memorychip"
        case .cpu: "cpu"
        case .upload: "arrow.up"
        case .download: "arrow.down"
        }
    }
}

enum SystemMetricLocation: String, Sendable {
    case menuBar, details
}

enum SystemRefreshInterval: Int, CaseIterable, Identifiable, Sendable {
    case oneSecond = 1, twoSeconds = 2, fiveSeconds = 5
    var id: Int { rawValue }
    var title: String { "\(rawValue) 秒" }
}

struct SystemMonitorSettings: Equatable, Sendable {
    var menuBar: Set<SystemMetric> = []
    var details: Set<SystemMetric> = Set(SystemMetric.allCases)
    var interval: SystemRefreshInterval = .twoSeconds

    func contains(_ metric: SystemMetric, at location: SystemMetricLocation) -> Bool {
        (location == .menuBar ? menuBar : details).contains(metric)
    }

    func activeMetrics(detailsVisible: Bool) -> Set<SystemMetric> {
        menuBar.union(detailsVisible ? details : [])
    }

    static func visibilityKey(_ metric: SystemMetric, at location: SystemMetricLocation) -> String {
        "systemMetrics.\(location.rawValue).\(metric.rawValue)"
    }
    static let intervalKey = "systemMetrics.refreshInterval"

    init() {}

    init(defaults: UserDefaults) {
        menuBar = Set(SystemMetric.allCases.filter {
            defaults.object(forKey: Self.visibilityKey($0, at: .menuBar)) as? Bool ?? false
        })
        details = Set(SystemMetric.allCases.filter {
            defaults.object(forKey: Self.visibilityKey($0, at: .details)) as? Bool ?? true
        })
        interval = SystemRefreshInterval(rawValue: defaults.integer(forKey: Self.intervalKey)) ?? .twoSeconds
    }
}

enum MetricReading<Value: Equatable & Sendable>: Equatable, Sendable {
    case waiting
    case value(Value)
    case unavailable(String)
    case disconnected

    func map<Output>(_ transform: (Value) -> Output) -> MetricReading<Output> {
        switch self {
        case .waiting: .waiting
        case let .value(value): .value(transform(value))
        case let .unavailable(message): .unavailable(message)
        case .disconnected: .disconnected
        }
    }
}

struct CapacityUsage: Equatable, Sendable {
    let totalBytes: UInt64
    let usedBytes: UInt64
    var availableBytes: UInt64 { totalBytes - usedBytes }
    var percent: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) * 100 : 0 }

    init(totalBytes: UInt64, availableBytes: UInt64) {
        self.totalBytes = totalBytes
        usedBytes = totalBytes - min(availableBytes, totalBytes)
    }

    static func memory(
        totalBytes: UInt64, pageSize: UInt64, anonymous: UInt32,
        purgeable: UInt32, wired: UInt32, compressed: UInt32
    ) -> CapacityUsage {
        // Page counts overlap: purgeable pages are part of anonymous memory.
        // Use signed arithmetic before clamping; compressed means resident size.
        let usedPages = Int64(anonymous) - Int64(purgeable) + Int64(wired) + Int64(compressed)
        let used = UInt64(min(Double(totalBytes), max(0, Double(usedPages) * Double(pageSize))))
        return CapacityUsage(totalBytes: totalBytes, availableBytes: totalBytes - used)
    }
}

struct CPUTicks: Equatable, Sendable {
    let user: UInt32
    let system: UInt32
    let idle: UInt32
    let nice: UInt32

    func percent(since previous: CPUTicks) -> Double? {
        let current = [user, system, idle, nice]
        let old = [previous.user, previous.system, previous.idle, previous.nice]
        guard zip(current, old).allSatisfy({ $0 >= $1 }) else { return nil }
        let delta = zip(current, old).map { UInt64($0) - UInt64($1) }
        let total = delta.reduce(0, +)
        guard total > 0 else { return nil }
        return Double(total - delta[2]) / Double(total) * 100
    }
}

struct NetworkCounters: Equatable, Sendable {
    let interface: String
    let interfaceIndex: UInt32
    let received: UInt64
    let sent: UInt64
}

struct NetworkSpeed: Equatable, Sendable {
    let interface: String
    let upload: Double
    let download: Double
}

struct SystemMetricsSample: Sendable {
    var sampledAt: TimeInterval
    var disk: MetricReading<CapacityUsage> = .waiting
    var memory: MetricReading<CapacityUsage> = .waiting
    var cpu: MetricReading<CPUTicks> = .waiting
    var network: MetricReading<NetworkCounters> = .waiting
}

struct SystemMetricsSnapshot: Equatable, Sendable {
    var disk: MetricReading<CapacityUsage> = .waiting
    var memory: MetricReading<CapacityUsage> = .waiting
    var cpu: MetricReading<Double> = .waiting
    var network: MetricReading<NetworkSpeed> = .waiting

    func text(for metric: SystemMetric) -> MetricReading<String> {
        switch metric {
        case .disk: disk.map { SystemMetricFormatter.percent($0.percent) }
        case .memory: memory.map { SystemMetricFormatter.percent($0.percent) }
        case .cpu: cpu.map(SystemMetricFormatter.percent)
        case .upload: network.map { SystemMetricFormatter.speed($0.upload) }
        case .download: network.map { SystemMetricFormatter.speed($0.download) }
        }
    }
}

struct SystemMetricsAccumulator {
    private var previousCPU: CPUTicks?
    private var previousNetwork: (counters: NetworkCounters, time: TimeInterval)?
    private(set) var snapshot = SystemMetricsSnapshot()

    mutating func accept(_ sample: SystemMetricsSample, metrics: Set<SystemMetric>) {
        if metrics.contains(.disk) { snapshot.disk = sample.disk }
        if metrics.contains(.memory) { snapshot.memory = sample.memory }
        if metrics.contains(.cpu) {
            if case let .value(ticks) = sample.cpu {
                snapshot.cpu = previousCPU.flatMap { ticks.percent(since: $0) }.map(MetricReading.value) ?? .waiting
                previousCPU = ticks
            } else {
                snapshot.cpu = sample.cpu.map { _ in 0 }
                previousCPU = nil
            }
        }
        if !metrics.isDisjoint(with: [.upload, .download]) {
            if case let .value(counters) = sample.network {
                if let previous = previousNetwork,
                   previous.counters.interface == counters.interface,
                   previous.counters.interfaceIndex == counters.interfaceIndex,
                   counters.received >= previous.counters.received,
                   counters.sent >= previous.counters.sent,
                   sample.sampledAt > previous.time {
                    let elapsed = sample.sampledAt - previous.time
                    snapshot.network = .value(NetworkSpeed(
                        interface: counters.interface,
                        upload: Double(counters.sent - previous.counters.sent) / elapsed,
                        download: Double(counters.received - previous.counters.received) / elapsed
                    ))
                } else {
                    snapshot.network = .waiting
                }
                previousNetwork = (counters, sample.sampledAt)
            } else {
                snapshot.network = sample.network.map { NetworkSpeed(interface: $0.interface, upload: 0, download: 0) }
                previousNetwork = nil
            }
        }
    }
}

enum SystemMetricFormatter {
    static func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }
    static func capacity(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .decimal)
    }
    static func speed(_ bytesPerSecond: Double) -> String {
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var value = max(0, bytesPerSecond)
        var index = 0
        while value >= 1_000, index < units.count - 1 {
            value /= 1_000
            index += 1
        }
        return String(format: index == 0 ? "%.0f %@" : "%.1f %@", value, units[index])
    }
}

enum SystemMetricsClock {
    private static let origin = ContinuousClock.now
    static func now() -> TimeInterval {
        let components = origin.duration(to: .now).components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
