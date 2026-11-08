import Darwin
import Foundation
import SystemConfiguration

protocol SystemMetricsProviding: Sendable {
    func sample(_ metrics: Set<SystemMetric>) async -> SystemMetricsSample
}

private struct SystemMetricsError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

actor SystemMetricsService: SystemMetricsProviding {
    func sample(_ metrics: Set<SystemMetric>) -> SystemMetricsSample {
        var sample = SystemMetricsSample(sampledAt: SystemMetricsClock.now())
        if metrics.contains(.disk) { sample.disk = read { try diskUsage() } }
        if metrics.contains(.memory) { sample.memory = read { try memoryUsage() } }
        if metrics.contains(.cpu) { sample.cpu = read { try cpuTicks() } }
        if !metrics.isDisjoint(with: [.upload, .download]) {
            sample.network = read {
                guard let interface = try primaryInterface() else { return nil }
                return try networkCounters(interface: interface)
            }.flatNetworkReading
        }
        // Timestamp next to the counter read, rather than the previous UI update.
        sample.sampledAt = SystemMetricsClock.now()
        return sample
    }

    private func read<T>(_ operation: () throws -> T) -> MetricReading<T> {
        do { return .value(try operation()) }
        catch { return .unavailable(error.localizedDescription) }
    }

    private func diskUsage() throws -> CapacityUsage {
        let url = URL(fileURLWithPath: "/System/Volumes/Data", isDirectory: true)
        let values = try url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        guard let total = values.volumeTotalCapacity, total > 0,
              let available = values.volumeAvailableCapacity, available >= 0 else {
            throw SystemMetricsError(message: "无法读取系统盘容量")
        }
        return CapacityUsage(totalBytes: UInt64(total), availableBytes: UInt64(available))
    }

    private func memoryUsage() throws -> CapacityUsage {
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            throw SystemMetricsError(message: "读取内存失败（Mach \(result)）")
        }
        var pageSize: vm_size_t = 0
        let pageResult = host_page_size(host, &pageSize)
        guard pageResult == KERN_SUCCESS, pageSize > 0 else {
            throw SystemMetricsError(message: "读取内存页大小失败（Mach \(pageResult)）")
        }
        return .memory(
            totalBytes: ProcessInfo.processInfo.physicalMemory, pageSize: UInt64(pageSize),
            anonymous: info.internal_page_count, purgeable: info.purgeable_count,
            wired: info.wire_count, compressed: info.compressor_page_count
        )
    }

    private func cpuTicks() throws -> CPUTicks {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            throw SystemMetricsError(message: "读取 CPU 失败（Mach \(result)）")
        }
        return CPUTicks(user: info.cpu_ticks.0, system: info.cpu_ticks.1, idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
    }

    private func primaryInterface() throws -> String? {
        guard let store = SCDynamicStoreCreate(nil, "CodexUsageStatus.SystemMetrics" as CFString, nil, nil) else {
            throw SystemMetricsError(message: "无法读取主要网络接口（SystemConfiguration \(SCError())）")
        }
        for family in ["IPv4", "IPv6"] {
            if let state = SCDynamicStoreCopyValue(store, "State:/Network/Global/\(family)" as CFString) as? [String: Any],
               let name = state[kSCDynamicStorePropNetPrimaryInterface as String] as? String, !name.isEmpty {
                return name
            }
        }
        return nil
    }

    private func networkCounters(interface: String) throws -> NetworkCounters {
        let index = if_nametoindex(interface)
        guard index > 0 else { throw SystemMetricsError(message: "网络接口 \(interface) 已不可用") }
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, Int32(index)]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0 else {
            throw SystemMetricsError(message: "读取网络计数大小失败（errno \(errno)）")
        }
        var data = Data(count: length)
        let result = data.withUnsafeMutableBytes {
            sysctl(&mib, u_int(mib.count), $0.baseAddress, &length, nil, 0)
        }
        guard result == 0 else {
            throw SystemMetricsError(message: "读取网络计数失败（errno \(errno)）")
        }
        return try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = bytes.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let messageLength = Int(header.ifm_msglen)
                guard messageLength >= MemoryLayout<if_msghdr>.size,
                      messageLength <= length - offset else { break }
                if header.ifm_type == RTM_IFINFO2, messageLength >= MemoryLayout<if_msghdr2>.size {
                    let info = bytes.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if UInt32(info.ifm_index) == index {
                        guard info.ifm_flags & IFF_UP != 0 else {
                            throw SystemMetricsError(message: "网络接口 \(interface) 未启用")
                        }
                        return NetworkCounters(interface: interface, interfaceIndex: index,
                                               received: info.ifm_data.ifi_ibytes, sent: info.ifm_data.ifi_obytes)
                    }
                }
                offset += messageLength
            }
            throw SystemMetricsError(message: "未找到网络接口 \(interface) 的计数")
        }
    }
}

private extension MetricReading where Value == NetworkCounters? {
    var flatNetworkReading: MetricReading<NetworkCounters> {
        switch self {
        case let .value(counters): counters.map(MetricReading<NetworkCounters>.value) ?? .disconnected
        case .waiting: .waiting
        case let .unavailable(message): .unavailable(message)
        case .disconnected: .disconnected
        }
    }
}
