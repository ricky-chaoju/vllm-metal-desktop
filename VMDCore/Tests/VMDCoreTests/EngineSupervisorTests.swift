import Foundation
import Testing
@testable import VMDCore

@Suite("EngineSupervisor")
struct EngineSupervisorTests {
    @Test("serve environment targets the venv")
    func environment() {
        let supervisor = EngineSupervisor(paths: EnginePaths(home: URL(filePath: "/Users/test")))
        let env = supervisor.serveEnvironment
        #expect(env["VIRTUAL_ENV"] == "/Users/test/.venv-vllm-metal")
        #expect((env["PATH"] ?? "").hasPrefix("/Users/test/.venv-vllm-metal/bin:"))
    }

    @Test("process lifecycle reports starting → log → stopped", .timeLimit(.minutes(1)))
    func lifecycle() async {
        let supervisor = EngineSupervisor()
        let launch = ProcessLaunch(
            executableURL: URL(filePath: "/bin/sh"),
            arguments: ["-c", "echo serving; sleep 1"]
        )
        var statuses: [ServeStatus] = []
        var logs: [String] = []
        for await event in supervisor.start(launch: launch, port: 1, readinessTimeout: .milliseconds(200)) {
            switch event {
            case .status(let status): statuses.append(status)
            case .log(let line): logs.append(line)
            }
        }
        #expect(statuses.first == .starting)
        #expect(statuses.last == .stopped)
        #expect(logs.contains("serving"))
    }

    @Test("a user-requested stop reports stopped, not failed", .timeLimit(.minutes(1)))
    func userStopIsClean() async {
        let supervisor = EngineSupervisor()
        let launch = ProcessLaunch(
            executableURL: URL(filePath: "/bin/sh"),
            arguments: ["-c", "echo up; sleep 30"]
        )
        let events = supervisor.start(launch: launch, port: 1, readinessTimeout: .milliseconds(100))

        // Stop shortly after it starts.
        let stopper = Task {
            try? await Task.sleep(for: .milliseconds(300))
            await supervisor.stop(graceSeconds: 3)
        }

        var last: ServeStatus?
        for await event in events {
            if case .status(let status) = event { last = status }
        }
        await stopper.value
        #expect(last == .stopped)
    }
}
