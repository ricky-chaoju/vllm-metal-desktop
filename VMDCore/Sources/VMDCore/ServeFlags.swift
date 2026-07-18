import Foundation

/// Grouping of serve flags, mirroring vLLM's own `--help` config groups.
public enum ServeFlagGroup: String, Sendable, CaseIterable, Codable {
    case model = "Model"
    case memory = "Memory & KV Cache"
    case server = "Server"
}

/// The control type + bounds/default for a flag.
public enum ServeFlagKind: Sendable, Equatable {
    case toggle(default: Bool)
    case integer(default: Int?, min: Int?, max: Int?)
    case number(default: Double, min: Double, max: Double)
    case text(default: String)
    case choice(default: String, options: [String])
}

/// One curated `vllm serve` flag with display metadata.
public struct ServeFlag: Sendable, Identifiable {
    public let key: String           // bare name, e.g. "max-model-len"
    public let label: String
    public let group: ServeFlagGroup
    public let help: String
    public let kind: ServeFlagKind
    /// Example value shown dimmed while unset (unset = engine default).
    public let example: String?

    public init(
        key: String,
        label: String,
        group: ServeFlagGroup,
        help: String,
        kind: ServeFlagKind,
        example: String? = nil
    ) {
        self.key = key
        self.label = label
        self.group = group
        self.help = help
        self.kind = kind
        self.example = example
    }

    public var id: String { key }
    public var argument: String { "--\(key)" }
}

/// A flag value, persisted as part of a serve configuration.
public enum ServeFlagValue: Codable, Sendable, Equatable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    public var stringValue: String {
        switch self {
        case .bool(let value): String(value)
        case .int(let value): String(value)
        case .double(let value): String(value)
        case .string(let value): value
        }
    }
}

/// Curated subset of `vllm serve` flags — only ones verified meaningful on the
/// Metal backend (audited against vllm-metal's platform.py/cache_policy.py; flags
/// that are no-ops there, like `--enforce-eager`, or actively rejected, like
/// `--kv-cache-dtype fp8`, are deliberately absent). Everything else remains
/// reachable via raw extra arguments.
public enum ServeFlagCatalog {
    public static let all: [ServeFlag] = [
        ServeFlag(key: "dtype", label: "Compute dtype", group: .model,
                  help: "Weight/compute precision. Also used for the KV cache. MLX-quantized checkpoints keep their own quantization.",
                  kind: .choice(default: "auto", options: ["auto", "bfloat16", "float16", "float32"])),
        ServeFlag(key: "trust-remote-code", label: "Trust remote code", group: .model,
                  help: "Allow executing custom model code from the repo.",
                  kind: .toggle(default: false)),
        ServeFlag(key: "revision", label: "Revision", group: .model,
                  help: "Model branch, tag, or commit.",
                  kind: .text(default: ""), example: "main"),
        ServeFlag(key: "seed", label: "Seed", group: .model,
                  help: "Random seed for reproducibility.",
                  kind: .integer(default: nil, min: 0, max: nil), example: "0"),

        ServeFlag(key: "max-model-len", label: "Max context length", group: .memory,
                  help: "Maximum context window in tokens — the primary memory lever. Lower it to fit bigger models.",
                  kind: .integer(default: nil, min: 1, max: nil), example: "8192"),
        ServeFlag(key: "gpu-memory-utilization", label: "GPU memory utilization", group: .memory,
                  help: "Fraction of Metal's recommended working set the engine may use (weights + KV cache).",
                  kind: .number(default: 0.92, min: 0.30, max: 0.95)),
        ServeFlag(key: "enable-prefix-caching", label: "Prefix caching", group: .memory,
                  help: "Reuse KV cache across shared prompt prefixes. Not supported on hybrid GDN models (e.g. Qwen3-Next) — turn off there.",
                  kind: .toggle(default: true)),
        ServeFlag(key: "max-num-seqs", label: "Max concurrent sequences", group: .memory,
                  help: "Maximum sequences processed in parallel.",
                  kind: .integer(default: nil, min: 1, max: nil), example: "256"),
        ServeFlag(key: "max-num-batched-tokens", label: "Max batched tokens", group: .memory,
                  help: "Maximum tokens per scheduler batch.",
                  kind: .integer(default: nil, min: 1, max: nil), example: "8192"),

        ServeFlag(key: "api-key", label: "API key", group: .server,
                  help: "Require this key on incoming requests.",
                  kind: .text(default: ""), example: "none"),
    ]

    public static func grouped() -> [(group: ServeFlagGroup, flags: [ServeFlag])] {
        ServeFlagGroup.allCases.compactMap { group in
            let flags = all.filter { $0.group == group }
            return flags.isEmpty ? nil : (group, flags)
        }
    }

    public static func flag(forKey key: String) -> ServeFlag? {
        all.first { $0.key == key }
    }
}

/// User-configured serve flag values + Metal env tunings. Persisted per app.
public struct ServeFlags: Codable, Sendable, Equatable {
    public var values: [String: ServeFlagValue]
    /// `VLLM_METAL_MEMORY_FRACTION`: "auto" (defer to --gpu-memory-utilization) or
    /// a fraction. The GUI keeps this on "auto" — one memory control, the flag.
    public var memoryFraction: String
    /// `VLLM_METAL_USE_MLX`. On is the supported configuration; no UI toggle.
    public var useMLX: Bool
    /// `VLLM_METAL_USE_PAGED_ATTENTION` — the modern KV path (chunked prefill,
    /// TurboQuant, spec-decode). Off is a legacy escape hatch.
    public var usePagedAttention: Bool
    /// `VLLM_METAL_DEBUG` — verbose engine-side logging.
    public var debugLogging: Bool
    /// Preferred server port. Stable across runs so other apps can point at one
    /// address; when it's taken by another process, a free port is used instead.
    public var serverPort: Int
    /// Free-form extra `vllm serve` arguments for power users.
    public var extraArguments: String

    /// The vLLM convention.
    public static let defaultServerPort = 8000

    public init(
        values: [String: ServeFlagValue] = [:],
        memoryFraction: String = "auto",
        useMLX: Bool = true,
        usePagedAttention: Bool = true,
        debugLogging: Bool = false,
        serverPort: Int = ServeFlags.defaultServerPort,
        extraArguments: String = ""
    ) {
        self.values = values
        self.memoryFraction = memoryFraction
        self.useMLX = useMLX
        self.usePagedAttention = usePagedAttention
        self.debugLogging = debugLogging
        self.serverPort = serverPort
        self.extraArguments = extraArguments
    }

    /// Tolerant decoding so configurations saved by older app versions (without
    /// the newer fields) keep their values instead of resetting to defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        values = try container.decodeIfPresent([String: ServeFlagValue].self, forKey: .values) ?? [:]
        memoryFraction = try container.decodeIfPresent(String.self, forKey: .memoryFraction) ?? "auto"
        useMLX = try container.decodeIfPresent(Bool.self, forKey: .useMLX) ?? true
        usePagedAttention = try container.decodeIfPresent(Bool.self, forKey: .usePagedAttention) ?? true
        debugLogging = try container.decodeIfPresent(Bool.self, forKey: .debugLogging) ?? false
        serverPort = try container.decodeIfPresent(Int.self, forKey: .serverPort) ?? Self.defaultServerPort
        extraArguments = try container.decodeIfPresent(String.self, forKey: .extraArguments) ?? ""
    }

    /// Builds the `--flag value` list, emitting only values that differ from the
    /// flag's default (so we never pass redundant flags).
    public func cliArguments(catalog: [ServeFlag] = ServeFlagCatalog.all) -> [String] {
        var args: [String] = []
        for flag in catalog {
            guard let value = values[flag.key] else { continue }
            switch flag.kind {
            case .toggle(let defaultValue):
                if case .bool(let on) = value, on != defaultValue {
                    args.append(on ? flag.argument : "--no-\(flag.key)")
                }
            case .integer:
                let string = value.stringValue
                if !string.isEmpty { args.append(contentsOf: [flag.argument, string]) }
            case .number(let defaultValue, _, _):
                if case .double(let number) = value, number != defaultValue {
                    args.append(contentsOf: [flag.argument, String(format: "%.2f", number)])
                }
            case .text(let defaultValue):
                let string = value.stringValue
                if !string.isEmpty, string != defaultValue { args.append(contentsOf: [flag.argument, string]) }
            case .choice(let defaultValue, _):
                let string = value.stringValue
                if !string.isEmpty, string != defaultValue { args.append(contentsOf: [flag.argument, string]) }
            }
        }
        // Raw extra arguments, whitespace-split.
        args.append(contentsOf: extraArguments.split(whereSeparator: \.isWhitespace).map(String.init))
        return args
    }

    /// Metal-specific environment overrides for `vllm serve`.
    public var environment: [String: String] {
        var env = [
            "VLLM_METAL_MEMORY_FRACTION": memoryFraction.isEmpty ? "auto" : memoryFraction,
            "VLLM_METAL_USE_MLX": useMLX ? "1" : "0",
        ]
        if !usePagedAttention { env["VLLM_METAL_USE_PAGED_ATTENTION"] = "0" }
        if debugLogging { env["VLLM_METAL_DEBUG"] = "1" }
        return env
    }
}
