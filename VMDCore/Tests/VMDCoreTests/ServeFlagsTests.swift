import Foundation
import Testing
@testable import VMDCore

@Suite("ServeFlags")
struct ServeFlagsTests {
    @Test("emits only values that differ from the flag default")
    func differsFromDefault() {
        var flags = ServeFlags()
        flags.values["max-model-len"] = .int(4096)
        flags.values["dtype"] = .string("auto")           // == default, omitted
        flags.values["revision"] = .string("refs/pr/7")   // != default, emitted
        let args = flags.cliArguments()
        #expect(args.contains("--max-model-len"))
        #expect(args.contains("4096"))
        #expect(!args.contains("--dtype"))
        #expect(args.contains("--revision"))
        #expect(args.contains("refs/pr/7"))
    }

    @Test("number flags emit only when moved off the default")
    func numberFlags() {
        var flags = ServeFlags()
        flags.values["gpu-memory-utilization"] = .double(0.92)  // == default, omitted
        #expect(!flags.cliArguments().contains("--gpu-memory-utilization"))
        flags.values["gpu-memory-utilization"] = .double(0.8)
        let args = flags.cliArguments()
        #expect(args.contains("--gpu-memory-utilization"))
        #expect(args.contains("0.80"))
    }

    @Test("toggles emit enable/disable based on their default")
    func toggles() {
        var flags = ServeFlags()
        flags.values["trust-remote-code"] = .bool(true)      // default false → --trust-remote-code
        flags.values["enable-prefix-caching"] = .bool(false) // default true → --no-enable-prefix-caching
        let args = flags.cliArguments()
        #expect(args.contains("--trust-remote-code"))
        #expect(args.contains("--no-enable-prefix-caching"))

        var noChange = ServeFlags()
        noChange.values["trust-remote-code"] = .bool(false)  // == default → nothing
        #expect(!noChange.cliArguments().contains("--trust-remote-code"))
    }

    @Test("appends raw extra arguments")
    func extraArguments() {
        let flags = ServeFlags(extraArguments: "--limit-mm-per-prompt image=2  --foo bar")
        let args = flags.cliArguments()
        #expect(args.contains("--limit-mm-per-prompt"))
        #expect(args.contains("image=2"))
        #expect(args.contains("--foo"))
        #expect(args.contains("bar"))
    }

    @Test("environment carries Metal tunings, defaults staying minimal")
    func environment() {
        let defaults = ServeFlags()
        #expect(defaults.environment["VLLM_METAL_MEMORY_FRACTION"] == "auto")
        #expect(defaults.environment["VLLM_METAL_USE_MLX"] == "1")
        // Defaults don't emit redundant overrides.
        #expect(defaults.environment["VLLM_METAL_USE_PAGED_ATTENTION"] == nil)
        #expect(defaults.environment["VLLM_METAL_DEBUG"] == nil)

        let tuned = ServeFlags(usePagedAttention: false, debugLogging: true)
        #expect(tuned.environment["VLLM_METAL_USE_PAGED_ATTENTION"] == "0")
        #expect(tuned.environment["VLLM_METAL_DEBUG"] == "1")
    }

    @Test("decodes configurations saved before the newer fields existed")
    func backwardCompatibleDecoding() throws {
        let legacy = #"{"values":{"max-model-len":{"int":{"_0":8192}}},"memoryFraction":"0.85","useMLX":true,"extraArguments":""}"#
        let decoded = try JSONDecoder().decode(ServeFlags.self, from: Data(legacy.utf8))
        #expect(decoded.memoryFraction == "0.85")
        #expect(decoded.usePagedAttention == true)   // new field defaults in
        #expect(decoded.debugLogging == false)
        #expect(decoded.values["max-model-len"] == .int(8192))
    }

    @Test("catalog groups are non-empty, keys unique, and Metal-hostile flags absent")
    func catalog() {
        let grouped = ServeFlagCatalog.grouped()
        #expect(!grouped.isEmpty)
        let keys = ServeFlagCatalog.all.map(\.key)
        #expect(Set(keys).count == keys.count)
        // Audited out: no-ops (enforce-eager, block-size, quantization) and
        // actively-rejected flags (kv-cache-dtype fp8) must not be offered.
        for banned in ["enforce-eager", "block-size", "quantization", "kv-cache-dtype", "async-scheduling"] {
            #expect(ServeFlagCatalog.flag(forKey: banned) == nil, "\(banned) should not be in the catalog")
        }
    }
}
