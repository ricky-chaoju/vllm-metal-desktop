import Foundation
import Testing
@testable import VMDCore

@Suite("EngineLogLine")
struct EngineLogLineTests {
    @Test("parses vLLM's level + context + message shape")
    func vllmShape() {
        let line = EngineLogLine.parse("INFO 07-17 10:41:29 [api_server.py:123] Started server on port 8000")
        #expect(line.level == .info)
        #expect(line.context == "07-17 10:41:29 [api_server.py:123]")
        #expect(line.message == "Started server on port 8000")
    }

    @Test("level without a bracket context still splits")
    func noBracket() {
        let line = EngineLogLine.parse("WARNING something looks off")
        #expect(line.level == .warning)
        #expect(line.context == "")
        #expect(line.message == "something looks off")
    }

    @Test("plain lines pass through unleveled")
    func plain() {
        let line = EngineLogLine.parse("Traceback (most recent call last):")
        #expect(line.level == nil)
        #expect(line.message == "Traceback (most recent call last):")
    }

    @Test("ANSI escapes are stripped before parsing")
    func ansi() {
        #expect(EngineLogLine.stripANSI("\u{1B}[32mINFO\u{1B}[0m hello") == "INFO hello")
        let line = EngineLogLine.parse("\u{1B}[31mERROR\u{1B}[0m 07-17 [x.py:1] boom")
        #expect(line.level == .error)
        #expect(line.message == "boom")
    }

    @Test("multi-process tag is split off and the level still detected")
    func processTag() {
        let line = EngineLogLine.parse("(APIServer pid=19997) INFO 07-17 14:54:00 [api_utils.py:339] ready")
        #expect(line.processTag == "(APIServer pid=19997)")
        #expect(line.level == .info)
        #expect(line.context == "07-17 14:54:00 [api_utils.py:339]")
        #expect(line.message == "ready")
    }
}

@Suite("ANSIParser")
struct ANSIParserTests {
    @Test("plain text is one default segment")
    func plain() {
        #expect(ANSIParser.parse("hello") == [.init(text: "hello")])
    }

    @Test("SGR colors split segments (vLLM banner shape)")
    func bannerColors() {
        let segments = ANSIParser.parse("\u{1B}[93m▄▄\u{1B}[0m \u{1B}[94m▄█\u{1B}[0m plain")
        #expect(segments == [
            .init(text: "▄▄", colorCode: 93),
            .init(text: " "),
            .init(text: "▄█", colorCode: 94),
            .init(text: " plain"),
        ])
    }

    @Test("bold combines with color and resets")
    func boldAndReset() {
        let segments = ANSIParser.parse("\u{1B}[97;1mwhite bold\u{1B}[m normal")
        #expect(segments == [
            .init(text: "white bold", colorCode: 97, isBold: true),
            .init(text: " normal"),
        ])
    }

    @Test("non-SGR escapes are dropped from the text")
    func nonSGR() {
        #expect(ANSIParser.parse("a\u{1B}[2Kb") == [.init(text: "ab")])
    }
}

@Suite("FileTailer")
struct FileTailerTests {
    @Test("snapshot returns trailing complete lines and the resume offset")
    func snapshot() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "tailer-test-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }
        try "one\ntwo\nthree\npart".write(to: url, atomically: true, encoding: .utf8)

        let (lines, offset) = FileTailer(url: url).snapshot(maxLines: 2)
        #expect(lines == ["two", "three"])
        // Offset stops before the trailing partial line.
        #expect(offset == UInt64("one\ntwo\nthree\n".utf8.count))
    }

    @Test("lines(fromOffset:) follows appends", .timeLimit(.minutes(1)))
    func follows() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "tailer-test-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }
        try "old\n".write(to: url, atomically: true, encoding: .utf8)

        let tailer = FileTailer(url: url, pollInterval: .milliseconds(30))
        let reader = Task { () -> [String] in
            var received: [String] = []
            for await line in tailer.lines(fromOffset: 0) {
                received.append(line)
                if received.count == 3 { break }
            }
            return received
        }
        try await Task.sleep(for: .milliseconds(100))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("new1\nnew2\n".utf8))
        try handle.close()

        let received = await reader.value
        #expect(received == ["old", "new1", "new2"])
    }
}
