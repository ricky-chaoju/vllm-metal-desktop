import Foundation

/// Diagnoses the one install failure whose tool output leaves the user with
/// nothing to act on: `uv venv --clear` cannot replace the existing venv,
/// reports `failed to remove directory …: Permission denied (os error 13)`,
/// and every retry fails identically at the same step.
///
/// The mechanism is ordinary POSIX rather than anything uv does: unlinking a
/// file needs write permission on its *parent* directory, so one directory the
/// user can't write into — typically a `__pycache__` written by root when the
/// venv's Python was run under `sudo` — makes the whole tree unremovable, no
/// matter who owns the files inside it.
///
/// Clearing that needs root, so the app can't fix it: what it can do is name
/// the exact directories and hand over the command to run.
public struct VenvObstruction: Sendable {
    public var paths: EnginePaths

    public init(paths: EnginePaths = .standard) {
        self.paths = paths
    }

    /// Whether a failed step is uv giving up on removing the old venv. Pure —
    /// the caller passes the output collected for that step. Anchored to
    /// `create-venv` because that is the only step that clears the venv; an
    /// unrecognized failure just keeps the generic message.
    public static func isVenvRemovalDenied(stepID: String, output: String) -> Bool {
        guard stepID == "create-venv" else { return false }
        return output.contains("failed to remove") && output.contains("Permission denied")
    }

    /// Directories inside the venv this process cannot write into — the ones
    /// that actually block removal. Each result is the top of an unremovable
    /// subtree (descendants are skipped: clearing the top clears them), sorted
    /// shallowest-first so the list is stable and reads sensibly.
    ///
    /// Bounded by `limit`: the answer only has to be actionable, and the scan
    /// runs over a multi-gigabyte tree.
    public func blockingDirectories(limit: Int = 5) -> [URL] {
        let manager = FileManager.default
        guard limit > 0, manager.fileExists(atPath: paths.venvRoot.path) else { return [] }
        guard let walk = manager.enumerator(
            at: paths.venvRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isWritableKey]
        ) else { return [] }

        var found: [URL] = []
        for case let url as URL in walk {
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isWritableKey]),
                  values.isDirectory == true, values.isWritable == false else { continue }
            found.append(url)
            walk.skipDescendants()
            if found.count >= limit { break }
        }
        return found.sorted { ($0.pathComponents.count, $0.path) < ($1.pathComponents.count, $1.path) }
    }

    /// A command that clears the obstruction, or `nil` when nothing in the venv
    /// is blocking — in which case the failure was something else and the
    /// caller should keep its generic message.
    ///
    /// Naming the individual directories keeps the command as narrow as it can
    /// be. Past a handful, the venv root is shorter to read and no more
    /// destructive: the install was about to replace it wholesale anyway.
    public func removalCommand(maxPaths: Int = 4) -> String? {
        let blocking = blockingDirectories(limit: maxPaths + 1)
        guard !blocking.isEmpty else { return nil }
        let targets = blocking.count > maxPaths ? [paths.venvRoot] : blocking
        return "sudo rm -rf " + targets.map { Self.shellQuoted($0.path) }.joined(separator: " ")
    }

    /// Single-quoted for `sh`, embedded quotes escaped — a home directory can
    /// contain spaces, and the command is meant to be pasted as-is.
    static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
