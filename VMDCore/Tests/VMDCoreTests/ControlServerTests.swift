import Foundation
import Testing
@testable import VMDCore

@Suite("ControlServer")
struct ControlServerTests {
    @Test("parses a request head with headers")
    func parseHead() throws {
        let head = "POST /pair HTTP/1.1\r\nHost: x\r\nContent-Length: 12\r\nX-VMD-Token: abc"
        let request = try #require(ControlServer.parseHead(Data(head.utf8)))
        #expect(request.method == "POST")
        #expect(request.path == "/pair")
        #expect(request.headers["content-length"] == "12")
        #expect(request.headers["x-vmd-token"] == "abc")
    }

    @Test("rejects a garbled request line")
    func rejectsGarbage() {
        #expect(ControlServer.parseHead(Data("NONSENSE".utf8)) == nil)
    }

    @Test("serves a JSON round-trip over loopback", .timeLimit(.minutes(1)))
    func loopbackRoundTrip() async throws {
        struct Ping: Codable, Equatable { var message: String }

        let server = try ControlServer(service: nil) { request in
            guard request.method == "POST", request.path == "/echo" else {
                return .error(404)
            }
            return ControlResponse(status: 200, body: request.body)
        }
        server.start(queue: DispatchQueue(label: "test-control"))
        defer { server.stop() }

        // The listener binds asynchronously; wait generously — a loaded CI
        // runner can take a while to get the listener scheduled.
        var port: UInt16?
        for _ in 0..<500 {
            if let bound = server.port, bound > 0 { port = bound; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let boundPort = try #require(port)

        let payload = try JSONEncoder().encode(Ping(message: "hello cluster"))
        let (status, body) = try await ControlClient.request(
            host: "127.0.0.1", port: Int(boundPort), method: "POST", path: "/echo", body: payload
        )
        #expect(status == 200)
        #expect(try JSONDecoder().decode(Ping.self, from: body) == Ping(message: "hello cluster"))

        let miss = try await ControlClient.request(
            host: "127.0.0.1", port: Int(boundPort), method: "GET", path: "/nope"
        )
        #expect(miss.status == 404)
    }
}
