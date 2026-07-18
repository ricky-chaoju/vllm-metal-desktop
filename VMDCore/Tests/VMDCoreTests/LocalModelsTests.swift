import Testing
@testable import VMDCore

@Suite("LocalModels")
struct LocalModelsTests {
    @Test("decodes hub cache dir names into model ids")
    func decode() {
        #expect(LocalModels.modelID(fromCacheEntry: "models--Qwen--Qwen3-0.6B") == "Qwen/Qwen3-0.6B")
        #expect(LocalModels.modelID(fromCacheEntry: "models--mlx-community--Qwen3-0.6B-4bit")
            == "mlx-community/Qwen3-0.6B-4bit")
    }

    @Test("ignores non-model cache entries")
    func ignores() {
        #expect(LocalModels.modelID(fromCacheEntry: "datasets--foo--bar") == nil)
        #expect(LocalModels.modelID(fromCacheEntry: "version.txt") == nil)
        #expect(LocalModels.modelID(fromCacheEntry: "models--") == nil)
    }
}
