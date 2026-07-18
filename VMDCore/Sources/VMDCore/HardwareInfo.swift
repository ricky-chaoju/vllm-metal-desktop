import Foundation
import IOKit
import Metal

/// A snapshot of the Mac's hardware relevant to running local models — chip,
/// cores, unified memory, the Metal GPU and its working-set budget, OS, and disk.
///
/// `current()` probes the live system (sysctl + Metal). `formattedReport()` is
/// pure and unit-tested; it's what the "Copy Hardware Info" button puts on the
/// clipboard for bug reports.
public struct HardwareInfo: Sendable, Equatable {
    public var modelIdentifier: String
    /// The marketing name from the device tree (e.g. "Mac Pro (2023)"); `nil`
    /// when the platform doesn't expose one.
    public var marketingName: String?
    public var chip: String
    public var totalCPUCores: Int
    public var performanceCores: Int
    public var efficiencyCores: Int
    public var gpuName: String?
    public var unifiedMemoryBytes: Int64
    /// Metal's recommended max working-set size — a practical ceiling for how
    /// much memory a model + KV cache can use on this GPU.
    public var metalBudgetBytes: Int64?
    public var hasUnifiedMemory: Bool
    public var isAppleSilicon: Bool
    public var osVersion: String
    public var appVersion: String?
    public var freeDiskBytes: Int64
    public var totalDiskBytes: Int64

    public init(
        modelIdentifier: String,
        marketingName: String? = nil,
        chip: String,
        totalCPUCores: Int,
        performanceCores: Int,
        efficiencyCores: Int,
        gpuName: String?,
        unifiedMemoryBytes: Int64,
        metalBudgetBytes: Int64?,
        hasUnifiedMemory: Bool,
        isAppleSilicon: Bool,
        osVersion: String,
        appVersion: String? = nil,
        freeDiskBytes: Int64,
        totalDiskBytes: Int64
    ) {
        self.modelIdentifier = modelIdentifier
        self.marketingName = marketingName
        self.chip = chip
        self.totalCPUCores = totalCPUCores
        self.performanceCores = performanceCores
        self.efficiencyCores = efficiencyCores
        self.gpuName = gpuName
        self.unifiedMemoryBytes = unifiedMemoryBytes
        self.metalBudgetBytes = metalBudgetBytes
        self.hasUnifiedMemory = hasUnifiedMemory
        self.isAppleSilicon = isAppleSilicon
        self.osVersion = osVersion
        self.appVersion = appVersion
        self.freeDiskBytes = freeDiskBytes
        self.totalDiskBytes = totalDiskBytes
    }

    // MARK: Formatting (pure)

    /// Binary GiB string (RAM/Metal budget are reported in powers of two).
    public static func gibString(_ bytes: Int64) -> String {
        let value = Double(bytes) / 1_073_741_824
        return value == value.rounded()
            ? String(format: "%.0f GB", value)
            : String(format: "%.1f GB", value)
    }

    /// Decimal GB string (disk, as shown by Finder).
    public static func gbString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    public var cpuDescription: String {
        if performanceCores > 0 || efficiencyCores > 0 {
            return "\(totalCPUCores) cores (\(performanceCores) performance + \(efficiencyCores) efficiency)"
        }
        return "\(totalCPUCores) cores"
    }

    /// The user-facing model line: marketing name when known, identifier as detail.
    public var modelDescription: String {
        marketingName.map { "\($0) — \(modelIdentifier)" } ?? modelIdentifier
    }

    /// A clipboard-friendly, stable plain-text report. Values align in a single
    /// column regardless of which optional rows are present.
    public func formattedReport() -> String {
        var rows: [(String, String)] = []
        if let appVersion { rows.append(("App", appVersion)) }
        rows.append(("Model", modelDescription))
        rows.append(("Chip", chip))
        rows.append(("CPU", cpuDescription))
        if let gpuName { rows.append(("GPU (Metal)", gpuName)) }
        rows.append(("Unified memory", Self.gibString(unifiedMemoryBytes)))
        if let metalBudgetBytes {
            rows.append(("Metal budget", Self.gibString(metalBudgetBytes)))
        }
        rows.append(("Architecture", isAppleSilicon ? "arm64 (Apple Silicon)" : "not Apple Silicon"))
        rows.append(("macOS", osVersion))
        rows.append(("Disk", "\(Self.gbString(freeDiskBytes)) free of \(Self.gbString(totalDiskBytes))"))

        let width = rows.map { $0.0.count + 1 }.max() ?? 0  // label + ":"
        let body = rows.map { label, value in
            ("\(label):").padding(toLength: width + 2, withPad: " ", startingAt: 0) + value
        }
        return (["vLLM Metal Desktop — Hardware"] + body).joined(separator: "\n")
    }

    // MARK: Probing (live system)

    public static func current(appVersion: String? = nil) -> HardwareInfo {
        let device = MTLCreateSystemDefaultDevice()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let disk = try? home.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ])
        let os = ProcessInfo.processInfo.operatingSystemVersion

        return HardwareInfo(
            modelIdentifier: sysctlString("hw.model") ?? "Unknown",
            marketingName: productMarketingName(),
            chip: sysctlString("machdep.cpu.brand_string") ?? "Unknown",
            totalCPUCores: sysctlInt("hw.physicalcpu") ?? 0,
            performanceCores: sysctlInt("hw.perflevel0.physicalcpu") ?? 0,
            efficiencyCores: sysctlInt("hw.perflevel1.physicalcpu") ?? 0,
            gpuName: device?.name,
            unifiedMemoryBytes: Int64(sysctlInt("hw.memsize") ?? 0),
            metalBudgetBytes: device.map { Int64($0.recommendedMaxWorkingSetSize) },
            hasUnifiedMemory: device?.hasUnifiedMemory ?? false,
            isAppleSilicon: Preflight.detectAppleSilicon(),
            osVersion: "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            appVersion: appVersion,
            freeDiskBytes: Int64(disk?.volumeAvailableCapacityForImportantUsage ?? 0),
            totalDiskBytes: Int64(disk?.volumeTotalCapacity ?? 0)
        )
    }

    /// The marketing name from the Apple Silicon device tree ("Mac Pro (2023)").
    /// `IODeviceTree:/product` carries `product-name` as NUL-terminated bytes;
    /// absent on Intel/virtualized systems, in which case this returns `nil`.
    private static func productMarketingName() -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard entry != MACH_PORT_NULL else { return nil }
        defer { IOObjectRelease(entry) }
        guard let value = IORegistryEntryCreateCFProperty(
            entry, "product-name" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? Data else { return nil }
        return parseProductName(value)
    }

    /// Decodes a device-tree string property (pure; unit-tested).
    public static func parseProductName(_ data: Data) -> String? {
        let trimmed = data.prefix { $0 != 0 }
        guard !trimmed.isEmpty, let name = String(bytes: trimmed, encoding: .utf8) else { return nil }
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        if size == 4 {
            var value: UInt32 = 0
            guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
            return Int(value)
        }
        var value: Int64 = 0
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }
}
