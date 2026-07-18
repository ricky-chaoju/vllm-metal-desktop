import Foundation
import Testing
@testable import VMDCore

@Suite("ModelDownloader helper protocol")
struct ModelDownloaderTests {
    @Test("decodes a progress line")
    func progressLine() {
        let parsed = ModelDownloader.parse(#"{"type": "progress", "downloaded": 123, "total": 999}"#)
        #expect(parsed == .progress(downloaded: 123, total: 999))
    }

    @Test("missing counters default to zero (indeterminate)")
    func progressDefaults() {
        let parsed = ModelDownloader.parse(#"{"type": "progress"}"#)
        #expect(parsed == .progress(downloaded: 0, total: 0))
    }

    @Test("decodes the terminal done line")
    func doneLine() {
        let parsed = ModelDownloader.parse(#"{"type": "done", "path": "/tmp/snapshot"}"#)
        #expect(parsed == .finished(path: "/tmp/snapshot"))
    }

    @Test("decodes an error line")
    func errorLine() {
        let parsed = ModelDownloader.parse(#"{"type": "error", "message": "401 unauthorized"}"#)
        #expect(parsed == .failed(reason: "401 unauthorized"))
    }

    @Test("unknown event types and non-JSON lines are ignored")
    func garbage() {
        #expect(ModelDownloader.parse(#"{"type": "telemetry", "x": 1}"#) == nil)
        #expect(ModelDownloader.parse("Requirement already satisfied: tqdm") == nil)
        #expect(ModelDownloader.parse("") == nil)
    }

    @Test("the bundled python helper ships with the module")
    func helperResourceExists() throws {
        let url = try #require(ModelDownloader.helperScriptURL)
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.contains("snapshot_download"))
    }
}
