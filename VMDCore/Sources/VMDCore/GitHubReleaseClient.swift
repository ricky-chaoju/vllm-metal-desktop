import Foundation

public struct GitHubAsset: Sendable, Equatable, Decodable {
    public let name: String
    public let browserDownloadURL: URL

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

private struct GitHubReleasePayload: Decodable {
    let tagName: String
    let htmlURL: URL?
    let body: String?
    let publishedAt: String?
    let prerelease: Bool?
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case body
        case publishedAt = "published_at"
        case prerelease
        case assets
    }
}

/// One merged change from a release's generated notes
/// (`* <summary> by @<author> in <pull-request URL>`).
public struct ReleaseChange: Sendable, Equatable, Identifiable {
    public let summary: String
    /// GitHub login of the change's author (without the `@`).
    public let author: String
    public let pullRequestURL: URL?

    /// Includes the PR URL: one author can land two identically-titled PRs in a
    /// release (reverts, re-lands, bot bumps), and those must not collide.
    public var id: String { "\(author)|\(summary)|\(pullRequestURL?.absoluteString ?? "")" }

    /// The PR number, when the link is a conventional `…/pull/<n>` URL.
    public var pullRequestNumber: Int? {
        guard let url = pullRequestURL,
              url.pathComponents.dropLast().last == "pull" else { return nil }
        return Int(url.lastPathComponent)
    }

    /// The author's GitHub avatar. Served by github.com directly — no API quota.
    public var authorAvatarURL: URL? {
        URL(string: "https://github.com/\(author).png?size=80")
    }
}

/// A parsed GitHub release: its tag, the version that tag denotes, the release
/// page, publication metadata, downloadable assets, and the changes/contributors
/// extracted from its generated notes. vllm-metal releases are published by CI
/// (`github-actions[bot]`), so the meaningful attribution is the PR authors in
/// the notes, not the release's `author` field.
public struct ReleaseInfo: Sendable, Equatable, Identifiable {
    public let tag: String
    public let version: EngineVersion?
    public let htmlURL: URL?
    public let publishedAt: Date?
    public let isPrerelease: Bool
    public let assets: [GitHubAsset]
    public let changes: [ReleaseChange]

    public var id: String { tag }

    public init(
        tag: String,
        version: EngineVersion?,
        htmlURL: URL?,
        publishedAt: Date? = nil,
        isPrerelease: Bool = false,
        assets: [GitHubAsset] = [],
        changes: [ReleaseChange] = []
    ) {
        self.tag = tag
        self.version = version
        self.htmlURL = htmlURL
        self.publishedAt = publishedAt
        self.isPrerelease = isPrerelease
        self.assets = assets
        self.changes = changes
    }

    /// Unique change authors, in first-appearance order.
    public var contributors: [String] {
        var seen = Set<String>()
        return changes.compactMap { seen.insert($0.author).inserted ? $0.author : nil }
    }

    /// The best-matching wheel for the given CPython tag (defaults to cp312).
    public func wheelURL(pythonTag: String = "cp312") -> URL? {
        GitHubReleaseClient.pickWheel(assets: assets, pythonTag: pythonTag)
    }
}

public enum GitHubReleaseError: Error, Sendable, Equatable {
    case notHTTP
    case httpStatus(Int)
}

extension GitHubReleaseError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notHTTP:
            "Unexpected response from GitHub."
        case .httpStatus(403), .httpStatus(429):
            "GitHub API rate limit reached — try again in a few minutes."
        case .httpStatus(let code):
            "GitHub returned HTTP \(code)."
        }
    }
}

/// Queries GitHub Releases for the engine's update channel. vllm-metal is *not*
/// on PyPI, so this is the only source of truth for "is there a newer engine?"
/// (docs/PLAN.md §2.3). Parsing is pure and unit-tested against fixtures; only
/// the `fetch*` methods touch the network.
public struct GitHubReleaseClient: Sendable {
    /// Shared: `ISO8601DateFormatter` is expensive to build and documented
    /// thread-safe (hence the `nonisolated(unsafe)` — it is never mutated).
    private nonisolated(unsafe) static let iso8601 = ISO8601DateFormatter()

    public var owner: String
    public var repo: String
    public var session: URLSession

    public init(owner: String = "vllm-project", repo: String = "vllm-metal", session: URLSession = .shared) {
        self.owner = owner
        self.repo = repo
        self.session = session
    }

    public var latestReleaseURL: URL {
        URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
    }

    public func releasesURL(count: Int) -> URL {
        URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases?per_page=\(count)")!
    }

    /// The newest release (GitHub's `releases/latest`, which excludes prereleases).
    public func fetchLatest() async throws -> ReleaseInfo {
        try Self.parse(await get(latestReleaseURL))
    }

    /// The most recent releases, newest first (includes prereleases, not drafts).
    public func fetchReleases(count: Int = 10) async throws -> [ReleaseInfo] {
        try Self.parseList(await get(releasesURL(count: count)))
    }

    /// One file in the repository's `docs/` directory.
    public struct DocEntry: Sendable, Equatable, Identifiable {
        public let name: String
        public let downloadURL: URL
        public var id: String { name }

        public init(name: String, downloadURL: URL) {
            self.name = name
            self.downloadURL = downloadURL
        }

        /// "sglang_deploy_guide.md" → "Sglang Deploy Guide", with overrides for
        /// names that don't title-case well.
        public var title: String {
            let base = name.replacingOccurrences(of: ".md", with: "").lowercased()
            if let override = Self.titleOverrides[base] { return override }
            return base
                .split(separator: "_")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }

        private static let titleOverrides: [String: String] = [
            "index": "Overview",
            "stt": "Speech-to-Text",
            "faq": "FAQ",
            "sglang_deploy_guide": "SGLang Deploy Guide",
            "vllm_deploy_guide": "vLLM Deploy Guide",
        ]
    }

    private struct ContentsPayload: Decodable {
        let name: String
        let type: String
        let downloadURL: URL?

        enum CodingKeys: String, CodingKey {
            case name, type
            case downloadURL = "download_url"
        }
    }

    /// Markdown files in the repo's `docs/` directory (default branch).
    public func fetchDocEntries() async throws -> [DocEntry] {
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/contents/docs")!
        return try Self.parseDocEntries(await get(url))
    }

    /// Reading order for the docs sidebar: overview → setup → capabilities.
    /// The API returns alphabetical, which buries the index mid-list.
    private static let docOrder: [String] = [
        "index.md", "installation.md", "configuration.md", "supported_models.md",
        "turboquant.md", "speculative_decoding.md", "distributed.md",
        "text_embedding_pooling.md", "stt.md", "profiling.md",
    ]

    public static func parseDocEntries(_ data: Data) throws -> [DocEntry] {
        let entries = try JSONDecoder().decode([ContentsPayload].self, from: data)
            .compactMap { item -> DocEntry? in
                guard item.type == "file", item.name.hasSuffix(".md"),
                      let url = item.downloadURL else { return nil }
                return DocEntry(name: item.name, downloadURL: url)
            }
        return entries.sorted { lhs, rhs in
            let left = docOrder.firstIndex(of: lhs.name.lowercased()) ?? docOrder.count
            let right = docOrder.firstIndex(of: rhs.name.lowercased()) ?? docOrder.count
            if left != right { return left < right }
            return lhs.name.lowercased() < rhs.name.lowercased()
        }
    }

    /// Raw markdown of one doc file.
    public func fetchDoc(_ entry: DocEntry) async throws -> String {
        String(decoding: try await get(entry.downloadURL), as: UTF8.self)
    }

    /// The vLLM *core* version a release was built against, read from that tag's
    /// `install.sh` (`local vllm_v="X.Y.Z"`). The engine wheel is a thin layer over
    /// a compiled vLLM base — when upstream bumps the base, a wheel-only update
    /// isn't enough and the caller must rebuild the core.
    public func fetchRequiredVLLMBase(tag: String) async throws -> EngineVersion? {
        let url = URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/\(tag)/install.sh")!
        return Self.parseVLLMBase(fromInstallScript: String(decoding: try await get(url), as: UTF8.self))
    }

    /// Extracts the pinned base version from install.sh content (pure).
    public static func parseVLLMBase(fromInstallScript script: String) -> EngineVersion? {
        guard let regex = try? NSRegularExpression(pattern: #"vllm_v="([0-9][0-9.]*)""#),
              let match = regex.firstMatch(in: script, range: NSRange(script.startIndex..., in: script)),
              let range = Range(match.range(at: 1), in: script) else { return nil }
        return EngineVersion(String(script[range]))
    }

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("vLLM-Metal-Desktop", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GitHubReleaseError.notHTTP }
        guard http.statusCode == 200 else { throw GitHubReleaseError.httpStatus(http.statusCode) }
        return data
    }

    // MARK: - Parsing (pure)

    public static func parse(_ data: Data) throws -> ReleaseInfo {
        releaseInfo(from: try JSONDecoder().decode(GitHubReleasePayload.self, from: data))
    }

    public static func parseList(_ data: Data) throws -> [ReleaseInfo] {
        try JSONDecoder().decode([GitHubReleasePayload].self, from: data).map(releaseInfo(from:))
    }

    private static func releaseInfo(from payload: GitHubReleasePayload) -> ReleaseInfo {
        ReleaseInfo(
            tag: payload.tagName,
            version: EngineVersion(payload.tagName),
            htmlURL: payload.htmlURL,
            publishedAt: payload.publishedAt.flatMap { Self.iso8601.date(from: $0) },
            isPrerelease: payload.prerelease ?? false,
            assets: payload.assets,
            changes: parseChanges(fromNotes: payload.body ?? "")
        )
    }

    /// Extracts the merged changes from GitHub's generated release notes.
    ///
    /// Generated notes list one bullet per merged PR under "## What's Changed":
    /// `* <summary> by @<login> in <PR URL>`. Bullets without an author (hand
    /// written notes) are ignored; the "## New Contributors" section repeats
    /// authors and is skipped by requiring the `by @… in …` shape not to start
    /// with `@` (its bullets read `* @login made their first contribution…`).
    public static func parseChanges(fromNotes notes: String) -> [ReleaseChange] {
        guard !notes.isEmpty,
              let regex = try? NSRegularExpression(
                pattern: #"^[*-]\s+(?!@)(.+?)\s+by\s+@([A-Za-z0-9-]+(?:\[bot\])?)\s+in\s+(\S+)\s*$"#
              ) else { return [] }

        return notes.components(separatedBy: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            guard let match = regex.firstMatch(in: trimmed, range: range),
                  let summaryRange = Range(match.range(at: 1), in: trimmed),
                  let authorRange = Range(match.range(at: 2), in: trimmed),
                  let urlRange = Range(match.range(at: 3), in: trimmed) else { return nil }
            return ReleaseChange(
                summary: String(trimmed[summaryRange]),
                author: String(trimmed[authorRange]),
                pullRequestURL: linkURL(fromToken: String(trimmed[urlRange]))
            )
        }
    }

    /// Turns the captured link token into an openable URL, or `nil`.
    ///
    /// Hand-edited notes produce tokens `URL(string:)` happily accepts but that
    /// are useless to open — `#123` (fragment-only), `pull/12.` with sentence
    /// punctuation glued on. Require an absolute http(s) URL and shed trailing
    /// punctuation first.
    private static func linkURL(fromToken token: String) -> URL? {
        var trimmed = Substring(token)
        while let last = trimmed.last, ".,;:!?)]>".contains(last) {
            trimmed = trimmed.dropLast()
        }
        guard let url = URL(string: String(trimmed)),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    /// Picks the wheel matching the CPython tag and arm64, with sensible fallbacks.
    public static func pickWheel(assets: [GitHubAsset], pythonTag: String = "cp312") -> URL? {
        let wheels = assets.filter { $0.name.hasSuffix(".whl") }
        if let exact = wheels.first(where: { $0.name.contains(pythonTag) && $0.name.contains("arm64") }) {
            return exact.browserDownloadURL
        }
        if let arm = wheels.first(where: { $0.name.contains("arm64") }) {
            return arm.browserDownloadURL
        }
        return wheels.first?.browserDownloadURL
    }
}
