import Foundation

/// A parsed `vllm-metal` engine version.
///
/// `vllm-metal` is published only via GitHub Releases (not PyPI) and uses a
/// PEP 440 dev-release scheme: a base release `X.Y.Z` optionally followed by a
/// timestamped dev segment, e.g. `0.3.0.dev20260620073347` (tag `v0.3.0.dev…`).
/// A dev release sorts *before* the corresponding final release, and two dev
/// releases of the same base are ordered by their timestamp.
///
/// String comparison is therefore wrong (`"0.3.0.dev9" > "0.3.0.dev10"`); update
/// detection must use this type's semantic ordering. See docs/PLAN.md §2.3.
public struct EngineVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    /// Numeric release components, e.g. `[0, 3, 0]`. Never empty.
    public let release: [Int]
    /// The `.devN` timestamp/counter, or `nil` for a final release.
    public let dev: Int?
    /// The original (trimmed) string this was parsed from.
    public let raw: String

    /// Parses a version string. Accepts an optional leading `v`/`V`, a dotted
    /// numeric release, an optional `.devN` segment, and ignores any `+local`
    /// build-metadata suffix (e.g. the `0.0.0+unknown` runtime fallback).
    /// Returns `nil` for anything that isn't a recognizable version.
    public init?(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var body = Substring(trimmed)
        if let first = body.first, first == "v" || first == "V" {
            body = body.dropFirst()
        }
        // Drop local/build metadata: everything from the first '+'.
        if let plus = body.firstIndex(of: "+") {
            body = body[body.startIndex..<plus]
        }

        // Split off the dev segment, if present.
        var devValue: Int?
        if let devRange = body.range(of: ".dev") {
            let devDigits = body[devRange.upperBound...]
            guard !devDigits.isEmpty, let n = Int(devDigits), n >= 0 else { return nil }
            devValue = n
            body = body[body.startIndex..<devRange.lowerBound]
        }

        let comps = body.split(separator: ".", omittingEmptySubsequences: false)
        guard !comps.isEmpty else { return nil }
        var rel: [Int] = []
        rel.reserveCapacity(comps.count)
        for c in comps {
            guard let n = Int(c), n >= 0 else { return nil }
            rel.append(n)
        }

        self.release = rel
        self.dev = devValue
        self.raw = trimmed
    }

    /// Whether this is a dev (pre-release) build.
    public var isDev: Bool { dev != nil }

    /// The dotted release string without the dev segment, e.g. `"0.3.0"`.
    public var releaseString: String { release.map(String.init).joined(separator: ".") }

    public var description: String { raw }

    // MARK: Comparable

    public static func < (lhs: EngineVersion, rhs: EngineVersion) -> Bool {
        let count = max(lhs.release.count, rhs.release.count)
        for i in 0..<count {
            let l = i < lhs.release.count ? lhs.release[i] : 0
            let r = i < rhs.release.count ? rhs.release[i] : 0
            if l != r { return l < r }
        }
        // Same numeric release: a dev build precedes the final; otherwise compare devs.
        switch (lhs.dev, rhs.dev) {
        case let (l?, r?): return l < r
        case (.some, .none): return true   // dev < final
        case (.none, .some): return false  // final > dev
        case (.none, .none): return false
        }
    }

    /// Equality follows the semantic ordering (ignoring `raw` and trailing
    /// release zeros), so `0.3` == `0.3.0`.
    public static func == (lhs: EngineVersion, rhs: EngineVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    public func hash(into hasher: inout Hasher) {
        // Hash a normalized form (strip trailing zeros) consistent with `==`.
        var normalized = release
        while normalized.count > 1, normalized.last == 0 { normalized.removeLast() }
        hasher.combine(normalized)
        hasher.combine(dev)
    }
}

public extension EngineVersion {
    /// Whether `candidate` represents an upgrade over `installed`. `nil` inputs
    /// (unparseable versions) yield `false` — never offer an update we can't reason about.
    static func isUpgrade(from installed: EngineVersion?, to candidate: EngineVersion?) -> Bool {
        guard let installed, let candidate else { return false }
        return candidate > installed
    }
}
