import Foundation
import Testing
@testable import VMDCore

@Suite("HuggingFaceClient parsing")
struct HuggingFaceTests {
    let modelInfoJSON = """
    {
      "id": "Qwen/Qwen3-0.6B",
      "downloads": 1234567,
      "likes": 890,
      "pipeline_tag": "text-generation",
      "gated": false,
      "tags": ["text-generation", "qwen3", "safetensors"],
      "safetensors": {"total": 596049920},
      "config": {"model_type": "qwen3", "num_hidden_layers": 28, "hidden_size": 1024},
      "siblings": [
        {"rfilename": "config.json"},
        {"rfilename": "model.safetensors"},
        {"rfilename": "tokenizer.json"}
      ]
    }
    """.data(using: .utf8)!

    @Test("parses model info incl. params, config, files")
    func parseInfo() throws {
        let info = try HuggingFaceClient.parseModelInfo(modelInfoJSON)
        #expect(info.id == "Qwen/Qwen3-0.6B")
        #expect(info.parameterCount == 596_049_920)
        #expect(info.numLayers == 28)
        #expect(info.hiddenSize == 1024)
        #expect(info.modelType == "qwen3")
        #expect(info.hasSafetensors)
        #expect(!info.hasGGUF)
        #expect(!info.gated.isGated)
    }

    @Test("decodes gated as bool or string")
    func gatedDecoding() throws {
        func gated(_ value: String) throws -> HFGated {
            let json = "{\"id\":\"x\",\"gated\":\(value)}".data(using: .utf8)!
            return try HuggingFaceClient.parseModelInfo(json).gated
        }
        #expect(try gated("false") == .no)
        #expect(try gated("\"auto\"") == .auto)
        #expect(try gated("\"manual\"") == .manual)
    }

    @Test("MLX-ready heuristic")
    func mlxReady() throws {
        let json = """
        {"id":"mlx-community/Qwen3-0.6B-4bit","tags":["mlx"],"siblings":[{"rfilename":"model.safetensors"}]}
        """.data(using: .utf8)!
        let info = try HuggingFaceClient.parseModelInfo(json)
        #expect(info.isMLXReady)
    }

    @Test("parses a search results array")
    func parseSearch() throws {
        let json = """
        [{"id":"Qwen/Qwen3-0.6B","downloads":100,"likes":5,"pipeline_tag":"text-generation"},
         {"id":"meta-llama/Llama-3.2-1B"}]
        """.data(using: .utf8)!
        let results = try JSONDecoder().decode([HFModelSummary].self, from: json)
        #expect(results.count == 2)
        #expect(results[0].id == "Qwen/Qwen3-0.6B")
        #expect(results[0].pipelineTag == "text-generation")
    }
}

@Suite("VRAMEstimator")
struct VRAMEstimatorTests {
    @Test("precision inference from id/tags")
    func precision() {
        #expect(WeightPrecision.infer(modelID: "mlx-community/Qwen3-30B-A3B-4bit") == .int4)
        #expect(WeightPrecision.infer(modelID: "mlx-community/Qwen3-30B-8bit") == .int8)
        #expect(WeightPrecision.infer(modelID: "Qwen/Qwen3-0.6B") == .fp16)
        #expect(WeightPrecision.infer(modelID: "x", tags: ["q4"]) == .int4)
    }

    @Test("weights scale with precision")
    func weights() {
        let fp16 = VRAMEstimator.estimate(parameterCount: 1_000_000_000, precision: .fp16, contextLength: 4096)
        let int4 = VRAMEstimator.estimate(parameterCount: 1_000_000_000, precision: .int4, contextLength: 4096)
        #expect(fp16.weightsBytes == 2_000_000_000)
        #expect(int4.weightsBytes == 500_000_000)
    }

    @Test("kv cache uses config when available")
    func kvFromConfig() {
        let withConfig = VRAMEstimator.estimate(
            parameterCount: 600_000_000, precision: .fp16, contextLength: 4096,
            hiddenSize: 1024, numLayers: 28
        )
        // No GQA facts → MHA assumption: 2 * 28 * 1024 * 4096 * 2 bytes
        #expect(withConfig.kvCacheBytes == Int64(2 * 28 * 1024 * 4096 * 2))
    }

    @Test("GQA shrinks the kv cache by the head ratio")
    func kvWithGQA() {
        // Qwen2.5-1.5B-Instruct's real config: hidden 1536, 28 layers,
        // 12 attention heads, 2 KV heads → head_dim 128, KV width 256.
        let gqa = VRAMEstimator.estimate(
            parameterCount: 1_540_000_000, precision: .fp16, contextLength: 4096,
            hiddenSize: 1536, numLayers: 28,
            numAttentionHeads: 12, numKeyValueHeads: 2
        )
        #expect(gqa.kvCacheBytes == Int64(2 * 28 * 256 * 4096 * 2)) // ≈117 MB
        // An explicit head_dim (some configs carry one) wins over hidden/heads.
        let explicit = VRAMEstimator.estimate(
            parameterCount: 1_540_000_000, precision: .fp16, contextLength: 4096,
            hiddenSize: 1536, numLayers: 28,
            numAttentionHeads: 12, numKeyValueHeads: 2, headDim: 64
        )
        #expect(explicit.kvCacheBytes == Int64(2 * 28 * 128 * 4096 * 2))
    }

    @Test("raw config.json parsing, flat and VL-nested")
    func configParsing() throws {
        let flat = try HuggingFaceClient.parseModelConfig(Data("""
        {"hidden_size": 1536, "num_hidden_layers": 28,
         "num_attention_heads": 12, "num_key_value_heads": 2}
        """.utf8))
        #expect(flat == HFModelConfig(
            hiddenSize: 1536, numHiddenLayers: 28,
            numAttentionHeads: 12, numKeyValueHeads: 2
        ))

        // Multimodal repos nest the language model under text_config.
        let nested = try HuggingFaceClient.parseModelConfig(Data("""
        {"model_type": "qwen3_vl",
         "text_config": {"hidden_size": 2048, "num_hidden_layers": 36,
                         "num_attention_heads": 16, "num_key_value_heads": 8,
                         "head_dim": 128}}
        """.utf8))
        #expect(nested == HFModelConfig(
            hiddenSize: 2048, numHiddenLayers: 36,
            numAttentionHeads: 16, numKeyValueHeads: 8, headDim: 128
        ))
    }

    @Test("fit verdict against a memory budget")
    func fit() {
        // A 0.6B fp16 model fits comfortably on 192 GB.
        let small = VRAMEstimator.estimate(parameterCount: 600_000_000, precision: .fp16, contextLength: 4096)
        #expect(VRAMEstimator.fits(estimate: small, unifiedMemoryBytes: 192 * 1_073_741_824) == .fits)

        // A 70B fp16 model (~140 GB weights) is too large for an 8 GB Mac.
        let large = VRAMEstimator.estimate(parameterCount: 70_000_000_000, precision: .fp16, contextLength: 4096)
        #expect(VRAMEstimator.fits(estimate: large, unifiedMemoryBytes: 8 * 1_073_741_824) == .tooLarge)
    }
}
