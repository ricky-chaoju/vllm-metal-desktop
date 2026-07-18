import Foundation
import Observation
import VMDCore

/// One line of install output with a stable identity, so trimming the ring
/// buffer doesn't reshuffle SwiftUI row identities.
struct LogLine: Identifiable, Equatable {
    let id: Int
    let text: String
}

/// Drives `EngineView`: preflight, installed/available versions, and the
/// streaming install/update run.
///
/// Explicitly `@MainActor`: the install stream is produced on a background task
/// inside `ProcessSession`, and consuming it here must hop back to the main
/// actor before mutating `@Observable` state — otherwise those mutations race.
@MainActor
@Observable
final class EngineViewModel {
    enum InstallPhase: Equatable {
        case idle
        case running(stepTitle: String, index: Int, total: Int)
        case failed(String)
        case completed
    }

    // Collaborators (all from VMDCore).
    private let paths = EnginePaths.standard
    private let releaseClient = GitHubReleaseClient()
    private let installed = InstalledEngine()

    // Observable state.
    var preflight: [PreflightItem] = []
    var isCheckingPreflight = false
    var installedVersion: EngineVersion?
    /// The compiled vLLM base (`vllm.__version__`) — what `vllm serve` banners show.
    var installedCoreVersion: EngineVersion?
    var releases: [ReleaseInfo] = []
    var isCheckingUpdates = false
    /// False until the first release check finishes — the empty state must not
    /// flash while preflight runs ahead of the network call.
    var hasCompletedUpdateCheck = false
    var updateError: String?
    var selectedTag: String?
    var phase: InstallPhase = .idle
    var logLines: [LogLine] = []

    private var nextLogID = 0
    private var isRunningInstall = false
    private var lastUpdateCheck: Date?

    /// Skip re-fetching releases when the last check is this recent (the view's
    /// `.task` re-runs on every appearance; don't burn API quota on tab switches).
    private static let updateCheckStaleness: TimeInterval = 300

    var isInstalled: Bool { installed.isInstalled }

    /// Newest stable release (prereleases stay selectable but don't define "latest").
    var latestRelease: ReleaseInfo? {
        releases.first { !$0.isPrerelease } ?? releases.first
    }

    /// The release the user picked to install — the latest unless chosen otherwise.
    var selectedRelease: ReleaseInfo? {
        selectedTag.flatMap { tag in releases.first { $0.tag == tag } } ?? latestRelease
    }

    var preflightPassed: Bool {
        !preflight.isEmpty && preflight.allSatisfy { $0.status.isOK }
    }

    var isBusy: Bool {
        if case .running = phase { return true }
        return false
    }

    var updateAvailable: Bool {
        EngineVersion.isUpgrade(from: installedVersion, to: latestRelease?.version)
    }

    /// Whether a working engine is importable (not just a venv on disk — a failed
    /// first install leaves the venv without the `vllm_metal` package).
    var hasWorkingEngine: Bool { installedVersion != nil }

    /// Primary action title, phrased for the *selected* release vs. what's installed.
    var primaryActionTitle: String {
        guard hasWorkingEngine, let installedVersion else { return "Install Engine" }
        guard let selected = selectedRelease else { return "Reinstall Engine" }
        let label = selected.version?.description ?? selected.tag
        guard let selectedVersion = selected.version else {
            // Unparseable tag — we can't relate it to the installed version, so
            // promise exactly what will happen instead of guessing "Reinstall".
            return "Install \(label)"
        }
        if selectedVersion > installedVersion { return "Update to \(label)" }
        if selectedVersion < installedVersion { return "Switch to \(label)" }
        return "Reinstall \(label)"
    }

    // MARK: Actions

    /// Full refresh: preflight, installed version, and (auto) the release feed.
    func refresh(forceUpdateCheck: Bool = false) async {
        await runPreflight()
        await loadInstalledVersion()
        await checkForUpdates(force: forceUpdateCheck)
    }

    func runPreflight() async {
        isCheckingPreflight = true
        preflight = await Preflight(paths: paths).run()
        isCheckingPreflight = false
    }

    func loadInstalledVersion() async {
        installedVersion = await installed.installedVersion()
        installedCoreVersion = await installed.installedCoreVersion()
    }

    /// Fetches the recent releases (newest first). Automatic on refresh; a fresh
    /// result within the staleness window is reused unless `force`d.
    func checkForUpdates(force: Bool = false) async {
        if !force, !releases.isEmpty, let last = lastUpdateCheck,
           Date.now.timeIntervalSince(last) < Self.updateCheckStaleness {
            return
        }
        isCheckingUpdates = true
        updateError = nil
        do {
            releases = try await releaseClient.fetchReleases(count: 10)
            lastUpdateCheck = .now
            // Drop a stale selection if that release left the feed window.
            if let selectedTag, !releases.contains(where: { $0.tag == selectedTag }) {
                self.selectedTag = nil
            }
        } catch {
            updateError = Self.friendlyMessage(for: error)
        }
        isCheckingUpdates = false
        hasCompletedUpdateCheck = true
    }

    /// Human-readable failure text — never a raw Swift error dump.
    static func friendlyMessage(for error: Error) -> String {
        if let urlError = error as? URLError {
            return urlError.localizedDescription  // e.g. "The Internet connection appears to be offline."
        }
        if let localized = (error as? LocalizedError)?.errorDescription {
            return localized
        }
        return error.localizedDescription
    }

    func runFix(_ launch: ProcessLaunch) async {
        _ = try? await ProcessSession.run(launch)
        await runPreflight()
    }

    /// Primary action: installs the *selected* release — a wheel-only swap when a
    /// working engine is importable (upgrade, downgrade, or reinstall), a fresh
    /// provision otherwise. A half-provisioned venv (failed first install) must go
    /// through `.fresh`; a wheel swap into it can never succeed.
    func installOrUpdate() async {
        await runInstall(mode: hasWorkingEngine ? .update : .fresh)
    }

    /// Nuke-and-rebuild: recreate the venv and recompile vLLM core from scratch.
    func rebuild() async {
        await runInstall(mode: .fresh)
    }

    /// Removes the venv (weights in the HF cache stay). Re-arms onboarding so a
    /// fresh launch walks through setup again.
    func uninstall() async {
        do {
            try installed.uninstall()
            installedVersion = nil
            installedCoreVersion = nil
            phase = .idle
            logLines.removeAll()
            UserDefaults.standard.set(false, forKey: "vmdOnboardingDone")
        } catch {
            phase = .failed("Couldn't uninstall: \(error.localizedDescription)")
        }
        await runPreflight()
    }

    private func runInstall(mode: EngineInstaller.InstallMode) async {
        guard !isRunningInstall else { return }
        isRunningInstall = true
        defer { isRunningInstall = false }

        if releases.isEmpty {
            await checkForUpdates(force: true)
            if let updateError {
                phase = .failed(updateError)
                return
            }
        }
        guard let release = selectedRelease else {
            phase = .failed("No releases found — check your connection, then refresh.")
            return
        }
        guard let wheelURL = release.wheelURL() else {
            phase = .failed("\(release.tag) has no compatible engine wheel yet — its assets may still be uploading. Refresh and try again.")
            return
        }

        logLines.removeAll()
        nextLogID = 0
        phase = .running(stepTitle: "Starting…", index: 0, total: 1)

        // The wheel is a thin layer over a compiled vLLM core. Resolve the base
        // this release was built against; if it differs from what's compiled in
        // the venv, a wheel swap would leave the old core running — escalate to
        // a full rebuild against the right base.
        var mode = mode
        var config = EngineInstallConfig()
        let requiredBase = try? await releaseClient.fetchRequiredVLLMBase(tag: release.tag)
        if let requiredBase {
            config.vllmVersion = requiredBase.description
            appendLog("Release \(release.tag) targets vLLM core \(requiredBase).")
        }
        if mode == .update {
            let core = await installed.installedCoreVersion()
            if EngineInstaller.needsCoreRebuild(requiredBase: requiredBase, installedCore: core) {
                appendLog("Installed vLLM core is \(core?.description ?? "unknown") — rebuilding the core, a wheel-only update would keep the old base.")
                mode = .fresh
            }
        }
        let installer = EngineInstaller(paths: paths, config: config)

        for await event in installer.install(wheelURL: wheelURL, mode: mode) {
            switch event {
            case .started(let total):
                phase = .running(stepTitle: "Starting…", index: 0, total: total)
            case .stepStarted(_, let title, let index):
                phase = .running(stepTitle: title, index: index, total: currentTotal)
            case .log(let line):
                appendLog(line)
            case .stepFinished:
                break
            case .failed(let stepID, let code):
                phase = .failed("Step “\(stepID)” failed (exit code \(code)). See the log below.")
            case .completed:
                phase = .completed
                await loadInstalledVersion()
            }
        }
    }

    private var currentTotal: Int {
        if case .running(_, _, let total) = phase { return total }
        return 1
    }

    private func appendLog(_ line: String) {
        logLines.append(LogLine(id: nextLogID, text: line))
        nextLogID += 1
        let cap = 600
        if logLines.count > cap { logLines.removeFirst(logLines.count - cap) }
    }
}
