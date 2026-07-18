import Foundation

/// Outcome of a single preflight check.
public enum PreflightStatus: Sendable, Equatable {
    case ok
    case failed(String)

    public var isOK: Bool {
        if case .ok = self { return true }
        return false
    }
}

/// One row in the install preflight checklist.
public struct PreflightItem: Sendable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        case architecture
        case operatingSystem
        case diskSpace
        case commandLineTools
    }

    public let kind: Kind
    public var title: String
    public var status: PreflightStatus
    public var detail: String?
    /// A shell remedy the UI can offer (e.g. `xcode-select --install`).
    public var fix: ProcessLaunch?

    public var id: String { kind.rawValue }

    public init(
        kind: Kind,
        title: String,
        status: PreflightStatus,
        detail: String? = nil,
        fix: ProcessLaunch? = nil
    ) {
        self.kind = kind
        self.title = title
        self.status = status
        self.detail = detail
        self.fix = fix
    }
}

/// Gates engine installation on hard requirements (docs/PLAN.md §4 step 1):
/// Apple Silicon, macOS version, free disk, and Xcode Command Line Tools.
///
/// Evaluation logic is split into pure `static` functions (unit-tested) from the
/// system probing (`run()`), which reads the live machine.
public struct Preflight: Sendable {
    public var paths: EnginePaths
    public var minimumFreeBytes: Int64
    public var minimumOSMajor: Int

    public init(
        paths: EnginePaths = .standard,
        minimumFreeBytes: Int64 = 6 * 1_000_000_000,
        minimumOSMajor: Int = 14
    ) {
        self.paths = paths
        self.minimumFreeBytes = minimumFreeBytes
        self.minimumOSMajor = minimumOSMajor
    }

    // MARK: Pure evaluators

    public static func evaluateArchitecture(isAppleSilicon: Bool) -> PreflightStatus {
        isAppleSilicon
            ? .ok
            : .failed("Requires Apple Silicon (arm64). vllm-metal does not run on Intel Macs.")
    }

    public static func evaluateOS(major: Int, minimum: Int) -> PreflightStatus {
        major >= minimum ? .ok : .failed("Requires macOS \(minimum) or later.")
    }

    public static func evaluateDisk(freeBytes: Int64, requiredBytes: Int64) -> PreflightStatus {
        if freeBytes >= requiredBytes { return .ok }
        let need = ByteCountFormatter.string(fromByteCount: requiredBytes, countStyle: .file)
        let have = ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)
        return .failed("Needs about \(need) free; only \(have) available.")
    }

    // MARK: System probes

    public static func detectAppleSilicon() -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        return result == 0 && value == 1
    }

    public func freeDiskBytes() -> Int64 {
        if let values = try? paths.home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let bytes = values.volumeAvailableCapacityForImportantUsage {
            return Int64(bytes)
        }
        if let values = try? paths.home.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
           let bytes = values.volumeAvailableCapacity {
            return Int64(bytes)
        }
        // Probe failed — don't block the install on an unreadable volume; the
        // install itself will surface a real out-of-space error if there is one.
        return .max
    }

    /// Runs every check against the live system.
    public func run() async -> [PreflightItem] {
        var items: [PreflightItem] = []

        let isArm = Self.detectAppleSilicon()
        items.append(PreflightItem(
            kind: .architecture,
            title: "Apple Silicon",
            status: Self.evaluateArchitecture(isAppleSilicon: isArm),
            detail: isArm ? "arm64" : "not arm64"
        ))

        let os = ProcessInfo.processInfo.operatingSystemVersion
        items.append(PreflightItem(
            kind: .operatingSystem,
            title: "macOS \(minimumOSMajor) or later",
            status: Self.evaluateOS(major: os.majorVersion, minimum: minimumOSMajor),
            detail: "macOS \(os.majorVersion).\(os.minorVersion)"
        ))

        let free = freeDiskBytes()
        items.append(PreflightItem(
            kind: .diskSpace,
            title: "Free disk space",
            status: Self.evaluateDisk(freeBytes: free, requiredBytes: minimumFreeBytes),
            detail: "\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) available"
        ))

        items.append(await checkCommandLineTools())
        return items
    }

    private func checkCommandLineTools() async -> PreflightItem {
        let fix = ProcessLaunch(
            executableURL: URL(filePath: "/usr/bin/xcode-select"),
            arguments: ["--install"]
        )
        if let result = try? await ProcessSession.run(
            .init(executableURL: URL(filePath: "/usr/bin/xcode-select"), arguments: ["-p"])
        ), result.didSucceed {
            return PreflightItem(
                kind: .commandLineTools,
                title: "Xcode Command Line Tools",
                status: .ok,
                detail: result.standardOutput
            )
        }
        return PreflightItem(
            kind: .commandLineTools,
            title: "Xcode Command Line Tools",
            status: .failed("Required to compile vLLM core. Install, then re-check."),
            fix: fix
        )
    }
}
