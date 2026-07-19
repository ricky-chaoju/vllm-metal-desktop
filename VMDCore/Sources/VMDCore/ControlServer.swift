import Foundation
import Network

/// A deliberately tiny HTTP/1.1 responder for app-to-app control on the local
/// network (cluster pairing, join/leave, model coordination). One request per
/// connection, JSON in/out, no keep-alive — the peers are two copies of this
/// app exchanging small messages, not browsers.
///
/// The listener doubles as the Bonjour advertisement: callers set `service`
/// so the control port travels with the discovery record.
public struct ControlRequest: Sendable {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }
}

public struct ControlResponse: Sendable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data = Data()) {
        self.status = status
        self.body = body
    }

    public static func json(_ object: some Encodable, status: Int = 200) -> ControlResponse {
        ControlResponse(status: status, body: (try? JSONEncoder().encode(object)) ?? Data())
    }

    public static func error(_ status: Int) -> ControlResponse {
        ControlResponse(status: status)
    }
}

public final class ControlServer: @unchecked Sendable {
    public typealias Handler = @Sendable (ControlRequest) async -> ControlResponse

    private let listener: NWListener
    private let handler: Handler

    /// The bound port (available after `start`).
    public var port: UInt16? { listener.port?.rawValue }

    /// `service` is registered on the same listener so discovery and control
    /// share one port.
    public init(service: NWListener.Service?, handler: @escaping Handler) throws {
        listener = try NWListener(using: .tcp)
        listener.service = service
        self.handler = handler
    }

    public func start(queue: DispatchQueue = .main) {
        listener.newConnectionHandler = { [handler] connection in
            Task { await Self.serve(connection, on: queue, handler: handler) }
        }
        listener.start(queue: queue)
    }

    public func updateService(_ service: NWListener.Service?) {
        listener.service = service
    }

    public func stop() {
        listener.cancel()
    }

    // MARK: One connection

    private static func serve(_ connection: NWConnection, on queue: DispatchQueue, handler: Handler) async {
        connection.start(queue: queue)
        guard let request = await readRequest(connection) else {
            connection.cancel()
            return
        }
        let response = await handler(request)
        await write(response, to: connection)
        connection.cancel()
    }

    /// Reads one HTTP request: headers, then exactly Content-Length body bytes.
    private static func readRequest(_ connection: NWConnection) async -> ControlRequest? {
        var buffer = Data()
        // Header phase.
        while !buffer.contains(headerTerminator) {
            guard buffer.count < 64 * 1024, let chunk = await receive(connection) else { return nil }
            buffer.append(chunk)
        }
        guard let headerRange = buffer.range(of: headerTerminator),
              var request = parseHead(buffer[..<headerRange.lowerBound]) else { return nil }

        // Body phase.
        let contentLength = request.headers["content-length"].flatMap(Int.init) ?? 0
        guard contentLength <= 8 * 1024 * 1024 else { return nil }
        var body = Data(buffer[headerRange.upperBound...])
        while body.count < contentLength {
            guard let chunk = await receive(connection) else { return nil }
            body.append(chunk)
        }
        request.body = body.prefix(contentLength)
        return request
    }

    /// Parses the request line + header block (without the terminator).
    /// Internal for unit tests.
    static func parseHead(_ data: Data) -> ControlRequest? {
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        return ControlRequest(
            method: String(requestLine[0]),
            path: String(requestLine[1]),
            headers: headers
        )
    }

    private static let headerTerminator = Data("\r\n\r\n".utf8)

    private static func receive(_ connection: NWConnection) async -> Data? {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete || error != nil {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private static func write(_ response: ControlResponse, to connection: NWConnection) async {
        let reason = response.status == 200 ? "OK" : "Error"
        var head = "HTTP/1.1 \(response.status) \(reason)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(response.body)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: payload, completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
    }
}

// MARK: - Client

/// The matching client: one JSON request to a peer's control server.
public enum ControlClient {
    public static func request(
        host: String,
        port: Int,
        method: String,
        path: String,
        token: String? = nil,
        body: Data? = nil,
        timeout: TimeInterval = 10
    ) async throws -> (status: Int, body: Data) {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        components.path = path
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let token { request.setValue(token, forHTTPHeaderField: "X-VMD-Token") }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (status, data)
    }
}
