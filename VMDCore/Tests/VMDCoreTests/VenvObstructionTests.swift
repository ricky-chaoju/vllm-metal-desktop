import Foundation
import Testing
@testable import VMDCore

@Suite("VenvObstruction")
struct VenvObstructionTests {
    /// The temporary directory is `/var/folders/…`, a symlink into `/private`,
    /// and the directory walk reports the resolved form while
    /// `resolvingSymlinksInPath()` normalizes the other way. Compare on one
    /// canonical spelling instead of picking a side.
    /// Works on a bare path or on a command that embeds one.
    func canonical(_ text: String) -> String {
        text.replacingOccurrences(of: "/private/var/", with: "/var/")
    }

    /// Verbatim from uv 0.9.18 when a root-owned `__pycache__` sits in the venv.
    static let uvDenial = """
    Using CPython 3.12.12
    Creating virtual environment with seed packages at: /Users/me/.venv-vllm-metal
    error: Failed to create virtual environment
      Caused by: failed to remove directory `/Users/me/.venv-vllm-metal/lib`: Permission denied (os error 13)
    """

    @Test("recognizes uv refusing to clear the venv")
    func recognizesDenial() {
        #expect(VenvObstruction.isVenvRemovalDenied(stepID: "create-venv", output: Self.uvDenial))
    }

    @Test("does not claim unrelated failures")
    func ignoresOtherFailures() {
        // Right step, different error.
        #expect(!VenvObstruction.isVenvRemovalDenied(
            stepID: "create-venv",
            output: "error: Failed to create virtual environment\n  Caused by: No space left on device"
        ))
        // Right error text, but a step that never clears the venv — a wheel
        // install hitting a read-only site-packages is a different problem.
        #expect(!VenvObstruction.isVenvRemovalDenied(stepID: "install-vllm-metal", output: Self.uvDenial))
    }

    @Test("quotes paths so the command survives spaces and apostrophes")
    func quoting() {
        #expect(VenvObstruction.shellQuoted("/Users/me/.venv-vllm-metal") == "'/Users/me/.venv-vllm-metal'")
        #expect(VenvObstruction.shellQuoted("/Users/my name/x") == "'/Users/my name/x'")
        #expect(VenvObstruction.shellQuoted("/Users/o'brien/x") == #"'/Users/o'\''brien/x'"#)
    }

    @Test("no venv on disk means nothing to blame")
    func missingVenv() {
        let paths = EnginePaths(home: URL(filePath: "/Users/definitely-not-a-real-home"))
        #expect(VenvObstruction(paths: paths).blockingDirectories().isEmpty)
        #expect(VenvObstruction(paths: paths).removalCommand() == nil)
    }

    /// The real scan: a directory the owner has removed write permission from
    /// blocks removal exactly like a root-owned one, so it reproduces the
    /// failure without needing root.
    @Test("finds the unwritable directory and builds the command that clears it")
    func findsBlockingDirectory() throws {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "vmd-venv-obstruction-\(UUID().uuidString)", directoryHint: .isDirectory)
        let paths = EnginePaths(home: home)
        let blocked = paths.venvRoot.appending(path: "lib/python3.12/site-packages/pkg/__pycache__", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: paths.venvRoot.appending(path: "bin", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: blocked.appending(path: "mod.pyc").path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: blocked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blocked.path)
            try? FileManager.default.removeItem(at: home)
        }

        let obstruction = VenvObstruction(paths: paths)
        #expect(obstruction.blockingDirectories().map { canonical($0.path) } == [canonical(blocked.path)])
        #expect(obstruction.removalCommand().map(canonical)
            == "sudo rm -rf \(VenvObstruction.shellQuoted(blocked.path))")
    }

    /// Past the cap the individual paths stop being readable, so the command
    /// falls back to the venv root — which the install was replacing anyway.
    @Test("many blocked directories collapse to the venv root")
    func collapsesToRoot() throws {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "vmd-venv-obstruction-\(UUID().uuidString)", directoryHint: .isDirectory)
        let paths = EnginePaths(home: home)
        let blocked = (0..<6).map {
            paths.venvRoot.appending(path: "lib/pkg\($0)/__pycache__", directoryHint: .isDirectory)
        }
        for url in blocked {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: url.path)
        }
        defer {
            for url in blocked {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
            try? FileManager.default.removeItem(at: home)
        }

        #expect(VenvObstruction(paths: paths).removalCommand()
            == "sudo rm -rf \(VenvObstruction.shellQuoted(paths.venvRoot.path))")
    }
}
