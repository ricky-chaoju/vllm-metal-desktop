import Foundation

public enum OpenAIClientError: Error, Sendable, Equatable {
    case notHTTP
    case httpStatus(Int)
}

/// Talks to a local vllm-metal server over its OpenAI-compatible API.
public struct OpenAIClient: Sendable {
    public var baseURL: URL
    public var session: URLSession

    /// - Parameter port: the local server port (host is pinned to 127.0.0.1).
    public init(port: Int, session: URLSession = .shared) {
        self.baseURL = URL(string: "http://127.0.0.1:\(port)")!
        self.session = session
    }

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public var modelsURL: URL { baseURL.appending(path: "v1/models") }
    public var chatURL: URL { baseURL.appending(path: "v1/chat/completions") }

    /// Whether `/v1/models` answers 200 — the readiness signal (docs/PLAN.md §3).
    public func isReady() async -> Bool {
        var request = URLRequest(url: modelsURL)
        request.timeoutInterval = 2
        guard
            let (_, response) = try? await session.data(for: request),
            let http = response as? HTTPURLResponse
        else { return false }
        return http.statusCode == 200
    }

    /// Polls readiness until ready or the timeout elapses (or the task is cancelled).
    public func waitUntilReady(timeout: Duration, pollInterval: Duration = .milliseconds(500)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if Task.isCancelled { return false }
            if await isReady() { return true }
            try? await Task.sleep(for: pollInterval)
        }
        return await isReady()
    }

    public func listModels() async throws -> [String] {
        let request = URLRequest(url: modelsURL)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OpenAIClientError.notHTTP }
        guard http.statusCode == 200 else { throw OpenAIClientError.httpStatus(http.statusCode) }
        return try JSONDecoder().decode(ModelsResponse.self, from: data).data.map(\.id)
    }

    /// One event from a streaming chat completion.
    public enum ChatStreamEvent: Sendable, Equatable {
        case delta(String)
        /// Real token accounting; arrives once, last, when the request set
        /// `stream_options.include_usage`.
        case usage(ChatUsage)
    }

    /// Streams assistant content deltas (and a final usage event when requested)
    /// for a chat completion. The stream finishes on `[DONE]` or end of body, and
    /// throws on transport/HTTP errors.
    public func chatCompletionStream(_ request: ChatCompletionRequest) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var urlRequest = URLRequest(url: chatURL)
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    var streamed = request
                    streamed.stream = true
                    urlRequest.httpBody = try JSONEncoder().encode(streamed)

                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    guard let http = response as? HTTPURLResponse else { throw OpenAIClientError.notHTTP }
                    guard http.statusCode == 200 else { throw OpenAIClientError.httpStatus(http.statusCode) }

                    for try await line in bytes.lines {
                        switch SSEChatParser.parse(line: line) {
                        case .delta(let content): continuation.yield(.delta(content))
                        case .usage(let usage): continuation.yield(.usage(usage))
                        case .done: continuation.finish(); return
                        case .ignore: continue
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
