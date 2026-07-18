import Foundation

/// Result of checking for an app update.
public enum AppUpdateResult: Sendable, Equatable {
    case upToDate
    case updateAvailable(version: String, url: URL?)
    case unknown(String)
}

/// Checks for updates to the *app itself* via its GitHub releases — a channel
/// completely separate from the engine's update channel (docs/PLAN.md §4: engine
/// updates ≠ app updates). Full auto-install (Sparkle) is a later upgrade; this
/// surfaces availability and links to the release.
public struct AppUpdateChecker: Sendable {
    public var releaseClient: GitHubReleaseClient

    public init(owner: String = "ricky-chaoju", repo: String = "vllm-metal-desktop", session: URLSession = .shared) {
        self.releaseClient = GitHubReleaseClient(owner: owner, repo: repo, session: session)
    }

    public func check(currentVersion: String) async -> AppUpdateResult {
        do {
            let latest = try await releaseClient.fetchLatest()
            return Self.decide(currentVersion: currentVersion, latest: latest)
        } catch {
            return .unknown(String(describing: error))
        }
    }

    /// Pure decision (unit-tested) comparing the running app version to the latest release.
    public static func decide(currentVersion: String, latest: ReleaseInfo?) -> AppUpdateResult {
        guard let latest, let latestVersion = latest.version else {
            return .unknown("No parseable release")
        }
        if EngineVersion.isUpgrade(from: EngineVersion(currentVersion), to: latestVersion) {
            return .updateAvailable(version: latest.tag, url: latest.htmlURL)
        }
        return .upToDate
    }
}
