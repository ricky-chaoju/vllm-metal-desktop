import Foundation
import IOKit

/// A live snapshot of system resource usage.
public struct SystemUsage: Sendable, Equatable {
    public var memoryUsedBytes: Int64
    public var memoryTotalBytes: Int64
    public var cpuPercent: Double // 0...100
    public var gpuPercent: Double // 0...100

    public init(memoryUsedBytes: Int64 = 0, memoryTotalBytes: Int64 = 0, cpuPercent: Double = 0, gpuPercent: Double = 0) {
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryTotalBytes = memoryTotalBytes
        self.cpuPercent = cpuPercent
        self.gpuPercent = gpuPercent
    }

    public var memoryFraction: Double {
        memoryTotalBytes > 0 ? Double(memoryUsedBytes) / Double(memoryTotalBytes) : 0
    }
}

/// Samples CPU + memory usage. CPU% needs the delta between two samples, so this
/// is a stateful object (use on one thread — the UI timer). Note: actual CPU/GPU
/// temperature is not available through public macOS APIs; callers should use
/// `ProcessInfo.thermalState` as a thermal proxy.
public final class SystemUsageMonitor: @unchecked Sendable {
    private var previousTicks: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?

    public init() {}

    public func sample() -> SystemUsage {
        SystemUsage(
            memoryUsedBytes: Self.memoryUsedBytes(),
            memoryTotalBytes: Int64(ProcessInfo.processInfo.physicalMemory),
            cpuPercent: cpuPercent(),
            gpuPercent: Self.gpuPercent()
        )
    }

    /// GPU utilization via the IOAccelerator's PerformanceStatistics in the
    /// IORegistry (the same source iStat Menus/asitop use; IOKit, not SMC).
    public static func gpuPercent() -> Double {
        guard let matching = IOServiceMatching("IOAccelerator") else { return 0 }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(iterator) }

        var best: Double = 0
        var service = IOIteratorNext(iterator)
        while service != 0 {
            var properties: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = properties?.takeRetainedValue() as? [String: Any],
               let perf = dict["PerformanceStatistics"] as? [String: Any] {
                for key in ["Device Utilization %", "GPU Activity(%)", "Renderer Utilization %"] {
                    if let number = perf[key] as? NSNumber {
                        best = max(best, number.doubleValue)
                        break
                    }
                }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return best
    }

    private func cpuPercent() -> Double {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }

        let user = info.cpu_ticks.0
        let system = info.cpu_ticks.1
        let idle = info.cpu_ticks.2
        let nice = info.cpu_ticks.3
        defer { previousTicks = (user, system, idle, nice) }

        guard let previous = previousTicks else { return 0 }
        let userDelta = Double(user &- previous.user)
        let systemDelta = Double(system &- previous.system)
        let idleDelta = Double(idle &- previous.idle)
        let niceDelta = Double(nice &- previous.nice)
        let total = userDelta + systemDelta + idleDelta + niceDelta
        guard total > 0 else { return 0 }
        return (userDelta + systemDelta + niceDelta) / total * 100.0
    }

    private static func memoryUsedBytes() -> Int64 {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let pageSize = Int64(getpagesize())
        // Activity Monitor's "Memory Used": App Memory (internal − purgeable)
        // + wired + compressed. `active` alone badly undercounts — anonymous
        // pages that have gone inactive (e.g. loaded model weights) are still
        // in use but not "active".
        let usedPages = Int64(stats.internal_page_count)
            - Int64(stats.purgeable_count)
            + Int64(stats.wire_count)
            + Int64(stats.compressor_page_count)
        return max(0, usedPages) * pageSize
    }
}
