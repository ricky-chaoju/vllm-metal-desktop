import Foundation
import Observation
import VMDCore

/// App-wide engine-update awareness: drives the "Update available" badge in the
/// window toolbar (the Engine page has its own, richer release feed).
///
/// Checks once at launch and then periodically; the Engine page also pushes its
/// fresher knowledge here (after a check or an install) so the badge never lags
/// what that page is showing.
@MainActor
@Observable
final class EngineUpdateMonitor {
    /// The upgrade target, when the latest release is newer than what's installed.
    private(set) var availableVersion: EngineVersion?

    private let releaseClient = GitHubReleaseClient()
    private let installed = InstalledEngine()
    private var periodicTask: Task<Void, Never>?

    private static let recheckInterval: Duration = .seconds(6 * 60 * 60)

    /// One immediate check, then a low-frequency loop. The loop is a detached
    /// task owned by this object (not the caller's `.task`), so it outlives the
    /// observing view; the root view calls this once and the monitor lives for
    /// the app's lifetime.
    func start() async {
        await checkNow()
        periodicTask?.cancel()
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.recheckInterval)
                await self?.checkNow()
            }
        }
    }

    func checkNow() async {
        let installedVersion = await installed.installedVersion()
        guard let latest = try? await releaseClient.fetchLatest() else { return }
        reconcile(installed: installedVersion, latest: latest.version)
    }

    /// Cheap sync from fresher state (the Engine page's feed / a finished install).
    func reconcile(installed: EngineVersion?, latest: EngineVersion?) {
        availableVersion = EngineVersion.isUpgrade(from: installed, to: latest) ? latest : nil
    }
}
