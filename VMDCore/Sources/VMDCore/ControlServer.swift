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
    /// The caller's IP as seen on the connection — how a Mac paired via
    /// manual IP learns its peer's address without discovery.
    public var remoteHost: String?

    public init(method: String, path: String, headers: [String: String] = [:], body: Data = Data(), remoteHost: String? = nil) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
        self.remoteHost = remoteHost
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
    /// True once the listener is accepting connections. A fixed-port
    /// listener reports its port before binding — wait for this.
    public private(set) var ready = false
    /// True once the listener failed — e.g. the preferred port is already
    /// taken (a second app instance); the owner retries with an ephemeral
    /// port.
    public private(set) var failed = false

    /// `service` is registered on the same listener so discovery and control
    /// share one port. `preferredPort` requests a stable port — off-LAN
    /// setups (EC2 security groups, manual entries) need an address that
    /// survives relaunches; nil binds an ephemeral one.
    public init(service: NWListener.Service?, preferredPort: UInt16? = nil, handler: @escaping Handler) throws {
        if let preferredPort, let fixed = NWEndpoint.Port(rawValue: preferredPort) {
            listener = try NWListener(using: .tcp, on: fixed)
        } else {
            listener = try NWListener(using: .tcp)
        }
        listener.service = service
        self.handler = handler
    }

    public func start(queue: DispatchQueue = .main) {
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.ready = true
            case .failed: self?.failed = true
            default: break
            }
        }
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
        guard var request = await readRequest(connection) else {
            connection.cancel()
            return
        }
        request.remoteHost = remoteHost(of: connection)
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
        guard let contentLength = declaredBodyLength(request.headers["content-length"]) else {
            return nil
        }
        var body = Data(buffer[headerRange.upperBound...])
        while body.count < contentLength {
            guard let chunk = await receive(connection) else { return nil }
            body.append(chunk)
        }
        request.body = body.prefix(contentLength)
        return request
    }

    /// The dotted/colon-form address of the connection's remote end.
    private static func remoteHost(of connection: NWConnection) -> String? {
        guard case .hostPort(let host, _) = connection.endpoint else { return nil }
        let text: String
        switch host {
        case .ipv4(let address): text = "\(address)"
        case .ipv6(let address): text = "\(address)"
        case .name(let name, _): text = name
        @unknown default: return nil
        }
        // Scoped addresses carry an interface suffix peers can't dial.
        return text.split(separator: "%").first.map(String.init)
    }

    /// The validated body length a request declares: absent means 0, and a
    /// malformed, negative, or oversized value rejects the request — this
    /// runs before authentication, so a hostile header must never reach
    /// `Data.prefix`'s nonnegative precondition. Internal for unit tests.
    static func declaredBodyLength(_ header: String?) -> Int? {
        guard let header else { return 0 }
        guard let length = Int(header), (0...8 * 1024 * 1024).contains(length) else { return nil }
        return length
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
