import Foundation

/// Discovers models already in the HuggingFace cache, for the model picker.
public struct LocalModels: Sendable {
    public var paths: EnginePaths

    public init(paths: EnginePaths = .standard) {
        self.paths = paths
    }

    /// Model ids found under `~/.cache/huggingface/hub` (dirs named `models--Org--Name`).
    public func cachedModelIDs() -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: paths.huggingFaceCache.path) else {
            return []
        }
        return entries.compactMap(Self.modelID(fromCacheEntry:)).sorted()
    }

    /// Decodes a hub cache directory name back into a model id (pure; unit-tested).
    public static func modelID(fromCacheEntry entry: String) -> String? {
        guard entry.hasPrefix("models--") else { return nil }
        let body = String(entry.dropFirst("models--".count))
        guard !body.isEmpty else { return nil }
        return body.replacingOccurrences(of: "--", with: "/")
    }

    /// The hub cache directory for a model id (`~/.cache/huggingface/hub/models--Org--Name`).
    public func cacheDirectory(forModelID id: String) -> URL {
        let name = "models--" + id.replacingOccurrences(of: "/", with: "--")
        return paths.huggingFaceCache.appending(path: name, directoryHint: .isDirectory)
    }

    /// Deletes a cached model (frees its disk space).
    public func delete(modelID id: String) throws {
        let directory = cacheDirectory(forModelID: id)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    /// The cached `config.json` for a model, from any snapshot. `nil` when the
    /// model (or its config) isn't downloaded.
    public func configJSON(forModelID id: String) -> Data? {
        let snapshots = cacheDirectory(forModelID: id).appending(path: "snapshots", directoryHint: .isDirectory)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: snapshots.path) else { return nil }
        for entry in entries {
            let config = snapshots
                .appending(path: entry, directoryHint: .isDirectory)
                .appending(path: "config.json", directoryHint: .notDirectory)
            if let data = try? Data(contentsOf: config) { return data }
        }
        return nil
    }

    /// Whether the model accepts image input, judged from its config: a
    /// `vision_config` block or a vision/VL architecture name (pure; unit-tested).
    public static func supportsVision(configJSON data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        if json["vision_config"] != nil { return true }
        let architectures = (json["architectures"] as? [String]) ?? []
        return architectures.contains { name in
            name.contains("VL") || name.lowercased().contains("vision")
        }
    }

    /// The cached chat template for a model: `tokenizer_config.json`'s
    /// `chat_template` (string or named-template list), falling back to a
    /// standalone `chat_template.jinja`. `nil` when not downloaded.
    public func chatTemplate(forModelID id: String) -> String? {
        let snapshots = cacheDirectory(forModelID: id).appending(path: "snapshots", directoryHint: .isDirectory)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: snapshots.path) else { return nil }
        for entry in entries {
            let snapshot = snapshots.appending(path: entry, directoryHint: .isDirectory)
            let tokenizerConfig = snapshot.appending(path: "tokenizer_config.json", directoryHint: .notDirectory)
            if let data = try? Data(contentsOf: tokenizerConfig),
               let template = Self.chatTemplate(fromTokenizerConfig: data) {
                return template
            }
            let jinja = snapshot.appending(path: "chat_template.jinja", directoryHint: .notDirectory)
            if let data = try? Data(contentsOf: jinja) {
                return String(decoding: data, as: UTF8.self)
            }
        }
        return nil
    }

    /// Extracts `chat_template` from tokenizer_config.json data — either a plain
    /// string or HF's list-of-named-templates form (pure; unit-tested).
    public static func chatTemplate(fromTokenizerConfig data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let template = json["chat_template"] as? String { return template }
        if let list = json["chat_template"] as? [[String: Any]] {
            let named = list.compactMap { entry -> (String, String)? in
                guard let name = entry["name"] as? String, let template = entry["template"] as? String else { return nil }
                return (name, template)
            }
            return (named.first { $0.0 == "default" } ?? named.first)?.1
        }
        return nil
    }
}
