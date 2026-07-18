import Foundation

/// Weight precision and its bytes-per-parameter.
public enum WeightPrecision: String, Sendable, CaseIterable {
    case fp32, fp16, bf16, int8, int4

    public var bytesPerParameter: Double {
        switch self {
        case .fp32: 4
        case .fp16, .bf16: 2
        case .int8: 1
        case .int4: 0.5
        }
    }

    public var label: String {
        switch self {
        case .fp32: "FP32"
        case .fp16: "FP16"
        case .bf16: "BF16"
        case .int8: "8-bit"
        case .int4: "4-bit"
        }
    }

    /// Infers precision from a model id / quant tags (e.g. mlx-community `…-4bit`).
    public static func infer(modelID: String, tags: [String] = []) -> WeightPrecision {
        let haystack = (modelID + " " + tags.joined(separator: " ")).lowercased()
        if haystack.contains("4bit") || haystack.contains("int4") || haystack.contains("q4") || haystack.contains("4-bit") {
            return .int4
        }
        if haystack.contains("8bit") || haystack.contains("int8") || haystack.contains("q8") || haystack.contains("8-bit") {
            return .int8
        }
        if haystack.contains("bf16") { return .bf16 }
        return .fp16
    }
}

/// A memory breakdown for serving a model.
public struct VRAMEstimate: Sendable, Equatable {
    public var weightsBytes: Int64
    public var kvCacheBytes: Int64
    public var overheadBytes: Int64

    public var totalBytes: Int64 { weightsBytes + kvCacheBytes + overheadBytes }
}

/// Whether a model fits this Mac's memory.
public enum FitVerdict: Sendable, Equatable {
    case fits
    case tight
    case tooLarge
}

/// Estimates the unified memory needed to serve a model and whether it fits.
/// Heuristic but grounded; a native reimplementation of lmstack's VRAM estimate
/// (docs/PLAN.md §5). Pure and unit-tested.
public enum VRAMEstimator {
    public static func estimate(
        parameterCount: Int,
        precision: WeightPrecision,
        contextLength: Int,
        hiddenSize: Int? = nil,
        numLayers: Int? = nil,
        numAttentionHeads: Int? = nil,
        numKeyValueHeads: Int? = nil,
        headDim: Int? = nil
    ) -> VRAMEstimate {
        let weights = Int64(Double(parameterCount) * precision.bytesPerParameter)

        let kv: Int64
        if let numLayers, numLayers > 0,
           let kvDim = kvDimension(
               hiddenSize: hiddenSize,
               numAttentionHeads: numAttentionHeads,
               numKeyValueHeads: numKeyValueHeads,
               headDim: headDim
           ) {
            // K and V, fp16 (2 bytes), across every layer and context position.
            kv = Int64(2 * numLayers * kvDim * contextLength * 2)
        } else {
            // Fallback: scale a fraction of the weights by the context window.
            kv = Int64(Double(weights) * 0.2 * Double(contextLength) / 4096.0)
        }

        // Runtime/activation overhead: at least 1 GiB, or 10% of weights.
        let overhead = max(Int64(1_073_741_824), Int64(Double(weights) * 0.1))

        return VRAMEstimate(weightsBytes: weights, kvCacheBytes: kv, overheadBytes: overhead)
    }

    /// The per-position K (or V) width in elements. Modern models use GQA —
    /// far fewer KV heads than attention heads — so `head_dim × kv_heads` is
    /// several times smaller than `hidden_size`; assuming MHA would overestimate
    /// the KV cache by exactly that ratio.
    private static func kvDimension(
        hiddenSize: Int?,
        numAttentionHeads: Int?,
        numKeyValueHeads: Int?,
        headDim: Int?
    ) -> Int? {
        let resolvedHeadDim: Int? = headDim ?? {
            guard let hiddenSize, let numAttentionHeads, numAttentionHeads > 0 else { return nil }
            return hiddenSize / numAttentionHeads
        }()
        if let resolvedHeadDim, let numKeyValueHeads, numKeyValueHeads > 0 {
            return resolvedHeadDim * numKeyValueHeads
        }
        // No GQA facts — assume MHA (KV width == hidden size).
        if let hiddenSize, hiddenSize > 0 { return hiddenSize }
        return nil
    }

    /// Compares an estimate to the Metal working-set budget (falls back to ~75%
    /// of unified memory when the Metal budget is unknown).
    public static func fits(
        estimate: VRAMEstimate,
        unifiedMemoryBytes: Int64,
        metalBudgetBytes: Int64? = nil
    ) -> FitVerdict {
        let budget = metalBudgetBytes ?? Int64(Double(unifiedMemoryBytes) * 0.75)
        guard budget > 0 else { return .tooLarge }
        let total = estimate.totalBytes
        if total <= budget * 8 / 10 { return .fits }
        if total <= budget { return .tight }
        return .tooLarge
    }
}
