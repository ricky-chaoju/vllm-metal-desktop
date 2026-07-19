import Foundation
import Testing
@testable import VMDCore

@Suite("ClusterServeCommand")
struct ClusterServeCommandTests {
    @Test("pipeline parallel sizes to the node count")
    func pipelineArguments() {
        let args = ClusterServeCommand.arguments(
            mode: .pipelineParallel, nodeCount: 3, headIP: "10.0.0.1"
        )
        #expect(args.firstRange(of: ["--pipeline-parallel-size", "3"]) != nil)
        #expect(args.firstRange(of: ["--tensor-parallel-size", "1"]) != nil)
        #expect(args.contains("--no-async-scheduling"))
        #expect(args.firstRange(of: ["--distributed-executor-backend", "ray"]) != nil)
    }

    @Test("data parallel sizes to the node count with one local replica")
    func dataParallelArguments() {
        let args = ClusterServeCommand.arguments(
            mode: .dataParallel, nodeCount: 4, headIP: "10.0.0.1"
        )
        #expect(args.firstRange(of: ["--data-parallel-size", "4"]) != nil)
        #expect(args.firstRange(of: ["--data-parallel-size-local", "1"]) != nil)
        #expect(args.firstRange(of: ["--data-parallel-address", "10.0.0.1"]) != nil)
        #expect(!args.contains("--no-async-scheduling"))
    }

    @Test("a degenerate node count still produces a two-node command")
    func nodeCountClamped() {
        for count in [0, 1] {
            let args = ClusterServeCommand.arguments(
                mode: .pipelineParallel, nodeCount: count, headIP: "10.0.0.1"
            )
            #expect(args.firstRange(of: ["--pipeline-parallel-size", "2"]) != nil)
        }
    }

    @Test("environment attaches to Ray and pins the inter-node address")
    func environment() {
        let env = ClusterServeCommand.environment(headIP: "10.0.0.1")
        #expect(env == ["RAY_ADDRESS": "auto", "VLLM_HOST_IP": "10.0.0.1"])
    }

    @Test("mode detection round-trips through the argument string")
    func detectModeRoundTrip() {
        for mode in ClusterServeMode.allCases {
            let joined = ClusterServeCommand
                .arguments(mode: mode, nodeCount: 2, headIP: "10.0.0.1")
                .joined(separator: " ")
            #expect(ClusterServeCommand.detectMode(inArguments: "--seed 0 " + joined) == mode)
        }
    }

    @Test("plain single-Mac arguments detect as no mode")
    func detectModeSingleMac() {
        #expect(ClusterServeCommand.detectMode(inArguments: "") == nil)
        #expect(ClusterServeCommand.detectMode(
            inArguments: "--max-model-len 8192 --gpu-memory-utilization 0.9"
        ) == nil)
    }
}

@Suite("ClusterDeploymentSummary")
struct ClusterDeploymentSummaryTests {
    @Test("round-trips through JSON")
    func jsonRoundTrip() throws {
        let summary = ClusterDeploymentSummary(
            model: "Qwen/Qwen3-0.6B", port: 8002, state: .running, mode: .pipelineParallel
        )
        let decoded = try JSONDecoder().decode(
            ClusterDeploymentSummary.self,
            from: JSONEncoder().encode(summary)
        )
        #expect(decoded == summary)
    }

    @Test("serve status collapses to the remote view")
    func stateFromServeStatus() {
        #expect(ClusterDeploymentSummary.State(.starting) == .starting)
        #expect(ClusterDeploymentSummary.State(.running) == .running)
        #expect(ClusterDeploymentSummary.State(.idle) == .stopped)
        #expect(ClusterDeploymentSummary.State(.stopping) == .stopped)
        #expect(ClusterDeploymentSummary.State(.stopped) == .stopped)
        #expect(ClusterDeploymentSummary.State(.failed("boom")) == .failed)
    }

    @Test("endpoint renders the caller's view of the host")
    func endpoint() {
        let summary = ClusterDeploymentSummary(
            model: "m", port: 8002, state: .running, mode: .dataParallel
        )
        #expect(summary.endpoint(host: "10.0.0.1") == "http://10.0.0.1:8002/v1")
    }
}
