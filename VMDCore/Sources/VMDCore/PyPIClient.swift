import Foundation

/// The version catalog of a PyPI package — how the app knows whether the
/// venv's Ray is current and which versions exist to pin to (cluster nodes
/// must match exactly, so downgrades matter as much as upgrades).
public struct PyPIVersions: Sendable, Equatable {
    /// PyPI's own "latest" (stable) version.
    public var latest: String
    /// Stable releases, newest first (pre/dev releases filtered out).
    public var stable: [String]

    public init(latest: String, stable: [String]) {
        self.latest = latest
        self.stable = stable
    }
}

public struct PyPIClient: Sendable {
    public var session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func versions(package: String) async throws -> PyPIVersions {
        let url = URL(string: "https://pypi.org/pypi")!
            .appending(path: package)
            .appending(path: "json")
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try Self.parse(data)
    }

    /// Parses the PyPI JSON API payload (pure; unit-tested): keeps only
    /// numeric dotted versions (drops rc/dev/post releases) sorted descending.
    public static func parse(_ data: Data) throws -> PyPIVersions {
        struct Payload: Decodable {
            struct Info: Decodable { let version: String }
            let info: Info
            let releases: [String: [FileEntry]]
            struct FileEntry: Decodable {}
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        let stable = payload.releases.keys
            .filter { version in
                let parts = version.split(separator: ".")
                return !parts.isEmpty && parts.allSatisfy { $0.allSatisfy(\.isNumber) }
            }
            .sorted { lhs, rhs in
                let l = lhs.split(separator: ".").map { Int($0) ?? 0 }
                let r = rhs.split(separator: ".").map { Int($0) ?? 0 }
                for (a, b) in zip(l, r) where a != b { return a > b }
                return l.count > r.count
            }
        return PyPIVersions(latest: payload.info.version, stable: stable)
    }
}
