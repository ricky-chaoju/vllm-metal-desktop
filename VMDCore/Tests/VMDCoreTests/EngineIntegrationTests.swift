import Foundation
import Testing
@testable import VMDCore

/// Real end-to-end test against the installed engine + a cached model. Skipped
/// unless `VMD_INTEGRATION=1` (it loads a model and takes ~1 minute). Validates
/// the full Swift path — EngineSupervisor launch/readiness and OpenAIClient SSE
/// streaming — against an actual `vllm serve`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VMD_INTEGRATION"] == "1"))
struct EngineIntegrationTests {
    @Test("serve a cached model and stream a chat reply", .timeLimit(.minutes(4)))
    func endToEnd() async throws {
        let supervisor = EngineSupervisor()
        let port = try #require(PortFinder.findFree())
        let config = ServeConfig(model: "Qwen/Qwen3-0.6B", port: port)

        // Keep `events` alive for the whole test so the supervisor isn't torn down.
        let events = supervisor.start(config, readinessTimeout: .seconds(200))

        var becameReady = false
        for await event in events {
            switch event {
            case .status(.running):
                becameReady = true
            case .status(.failed(let message)):
                Issue.record("serve failed: \(message)")
            default:
                break
            }
            if becameReady { break }
        }
        #expect(becameReady)

        let client = OpenAIClient(port: port)
        var reply = ""
        for try await event in client.chatCompletionStream(
            ChatCompletionRequest(
                model: config.effectiveModelName,
                messages: [.init(role: "user", content: "Reply with exactly: pong")],
                stream: true,
                maxTokens: 16
            )
        ) {
            if case .delta(let delta) = event { reply += delta }
        }
        #expect(!reply.isEmpty)

        await supervisor.stop()
        _ = events  // retain until here
    }
}
