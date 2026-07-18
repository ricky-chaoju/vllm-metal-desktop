import Foundation
import Testing
@testable import VMDCore

@Suite("ProcessSession")
struct ProcessSessionTests {
    @Test("captures stdout and a zero exit")
    func echoStdout() async throws {
        let result = try await ProcessSession.run(
            .init(executableURL: URL(filePath: "/bin/echo"), arguments: ["hello world"])
        )
        #expect(result.exitCode == 0)
        #expect(result.standardOutput == "hello world")
        #expect(result.didSucceed)
    }

    @Test("separates stderr and propagates a non-zero exit")
    func stderrAndExit() async throws {
        let result = try await ProcessSession.run(
            .init(
                executableURL: URL(filePath: "/bin/sh"),
                arguments: ["-c", "echo out; echo err 1>&2; exit 3"]
            )
        )
        #expect(result.exitCode == 3)
        #expect(result.standardOutput == "out")
        #expect(result.standardError == "err")
        #expect(!result.didSucceed)
    }

    @Test("passes a custom environment to the child")
    func environment() async throws {
        let result = try await ProcessSession.run(
            .init(
                executableURL: URL(filePath: "/bin/sh"),
                arguments: ["-c", "printf '%s' \"$VMD_TEST\""],
                environment: ["VMD_TEST": "xyz", "PATH": "/usr/bin:/bin"]
            )
        )
        #expect(result.standardOutput == "xyz")
    }

    @Test("streams multiple lines in order, then exactly one exit", .timeLimit(.minutes(1)))
    func streaming() async throws {
        let session = ProcessSession()
        var lines: [String] = []
        var exits: [Int32] = []
        for await event in try session.start(
            .init(executableURL: URL(filePath: "/bin/sh"), arguments: ["-c", "echo a; echo b; echo c"])
        ) {
            switch event {
            case .stdout(let line): lines.append(line)
            case .stderr: break
            case .exit(let code): exits.append(code)
            }
        }
        #expect(lines == ["a", "b", "c"])
        #expect(exits == [0])
    }

    @Test("throws when the executable does not exist")
    func missingExecutable() {
        let session = ProcessSession()
        #expect(throws: (any Error).self) {
            _ = try session.start(.init(executableURL: URL(filePath: "/nonexistent/xyzzy-vmd")))
        }
    }

    @Test("low-rate output arrives live, not batched at process exit", .timeLimit(.minutes(1)))
    func lowRateOutputStreamsLive() async throws {
        // Regression guard: FileHandle.bytes buffered pipe reads in large
        // chunks, so sparse output (download progress lines) reached the app
        // only when the process exited. Streamed delivery shows as a real gap
        // between the two lines; the batching bug collapses both to the same
        // instant at exit. The relative gap is machine-speed-independent, so
        // it can't flake on a loaded CI runner the way a wall-clock budget can.
        let session = ProcessSession()
        var firstLineAt: Duration?
        var secondLineAt: Duration?
        let start = ContinuousClock.now
        for await event in try session.start(
            .init(executableURL: URL(filePath: "/bin/sh"), arguments: ["-c", "echo first; sleep 2; echo second"])
        ) {
            if case .stdout(let line) = event {
                if line == "first" { firstLineAt = ContinuousClock.now - start }
                if line == "second" { secondLineAt = ContinuousClock.now - start }
            }
        }
        let gap = try #require(secondLineAt) - (try #require(firstLineAt))
        #expect(gap >= .seconds(1), "lines arrived \(gap) apart — output is being batched, not streamed")
    }

    @Test("a session is single-use — a second start throws instead of crashing")
    func secondStartThrows() async throws {
        let session = ProcessSession()
        for await _ in try session.start(
            .init(executableURL: URL(filePath: "/bin/echo"), arguments: ["once"])
        ) {}
        #expect(throws: (any Error).self) {
            _ = try session.start(.init(executableURL: URL(filePath: "/bin/echo"), arguments: ["twice"]))
        }
    }
}
