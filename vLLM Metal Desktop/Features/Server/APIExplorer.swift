import SwiftUI

/// Native API explorer — everything Swagger's `/docs` page offers, in the
/// app's own design language: endpoint rows expand into an editable request
/// body and a Send that hits the local server, with the pretty-printed
/// response inline. Reference-only (rows don't expand) while no server runs.
struct APIExplorer: View {
    /// e.g. `http://127.0.0.1:8002` while the deployment runs; nil → reference only.
    let baseURL: String?
    /// Substituted into the request examples.
    let model: String

    @Environment(\.openURL) private var openURL
    @State private var expanded: Set<String> = []
    @State private var editedBodies: [String: String] = [:]
    @State private var responses: [String: TryResponse] = [:]
    @State private var inFlight: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            ForEach(Array(Self.groups.enumerated()), id: \.element.name) { index, group in
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    HStack {
                        Text(group.name)
                            .scaledFont(.headline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if index == 0, let docsURL {
                            Button {
                                openURL(docsURL)
                            } label: {
                                Image(systemName: "arrow.up.right.square")
                            }
                            .buttonStyle(.plain)
                            .controlSize(.small)
                            .pointingHandCursor()
                            .help("Open Swagger UI in browser")
                        }
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(group.endpoints) { endpoint in
                            if endpoint.id != group.endpoints.first?.id {
                                Divider().padding(.leading, 14)
                            }
                            row(endpoint)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
        .onAppear {
            // Debug/UI-test hook: `-VMDExpandEndpoint "POST /v1/chat/completions"`.
            if let id = UserDefaults.standard.string(forKey: "VMDExpandEndpoint") {
                expanded.insert(id)
            }
        }
    }

    private var docsURL: URL? {
        baseURL.flatMap { URL(string: "\($0)/docs") }
    }

    // MARK: Rows

    private func row(_ endpoint: Endpoint) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard baseURL != nil else { return }
                if expanded.contains(endpoint.id) {
                    expanded.remove(endpoint.id)
                } else {
                    expanded.insert(endpoint.id)
                }
            } label: {
                HStack(spacing: Theme.Spacing.s) {
                    methodChip(endpoint.method)
                    Text(endpoint.path)
                        .scaledFont(.callout, design: .monospaced)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(endpoint.note)
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if baseURL != nil {
                        Image(systemName: "chevron.right")
                            .scaledFont(.caption2, weight: .semibold)
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(expanded.contains(endpoint.id) ? 90 : 0))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if baseURL != nil && expanded.contains(endpoint.id) {
                tryItOut(endpoint)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
        }
        .animation(.easeOut(duration: 0.15), value: expanded)
    }

    private func methodChip(_ method: String) -> some View {
        Text(method)
            .scaledFont(.caption2, weight: .bold, design: .monospaced)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(
                (method == "GET" ? Color.green : Color.accentColor).opacity(0.18),
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .foregroundStyle(method == "GET" ? Color.green : Color.accentColor)
            .frame(width: 44, alignment: .center)
    }

    // MARK: Try it out

    @ViewBuilder
    private func tryItOut(_ endpoint: Endpoint) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            if endpoint.bodyTemplate != nil {
                TextEditor(text: bodyBinding(endpoint))
                    .scaledFont(.caption, design: .monospaced)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 60, maxHeight: 170)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(6)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            HStack(spacing: Theme.Spacing.s) {
                Button("Send") { Task { await send(endpoint) } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(inFlight.contains(endpoint.id))
                if inFlight.contains(endpoint.id) {
                    ProgressView().controlSize(.small)
                }
                if let response = responses[endpoint.id] {
                    statusChip(response)
                    if let seconds = response.seconds {
                        Text(String(format: "%.2fs", seconds))
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Spacer()
                if let response = responses[endpoint.id] {
                    Button {
                        Pasteboard.copy(response.text)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .controlSize(.small)
                    .help("Copy response")
                }
            }

            if let response = responses[endpoint.id] {
                ScrollView {
                    Text(response.text)
                        .scaledFont(.caption, design: .monospaced)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 280)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private func statusChip(_ response: TryResponse) -> some View {
        let (label, color): (String, Color) = {
            guard let status = response.status else { return ("Error", .red) }
            let color: Color = status < 300 ? .green : (status < 500 ? .orange : .red)
            return ("\(status)", color)
        }()
        return Text(label)
            .scaledFont(.caption2, weight: .bold, design: .monospaced)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .foregroundStyle(color)
    }

    private func bodyBinding(_ endpoint: Endpoint) -> Binding<String> {
        Binding(
            get: { editedBodies[endpoint.id] ?? filledTemplate(endpoint) },
            set: { editedBodies[endpoint.id] = $0 }
        )
    }

    private func filledTemplate(_ endpoint: Endpoint) -> String {
        endpoint.bodyTemplate?.replacingOccurrences(of: "{MODEL}", with: model) ?? ""
    }

    private func send(_ endpoint: Endpoint) async {
        guard let baseURL, let url = URL(string: baseURL + endpoint.path) else { return }
        inFlight.insert(endpoint.id)
        defer { inFlight.remove(endpoint.id) }

        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method
        request.timeoutInterval = 300
        if endpoint.bodyTemplate != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data((editedBodies[endpoint.id] ?? filledTemplate(endpoint)).utf8)
        }

        let started = Date.now
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            responses[endpoint.id] = TryResponse(
                status: (response as? HTTPURLResponse)?.statusCode,
                seconds: Date.now.timeIntervalSince(started),
                text: Self.pretty(data)
            )
        } catch {
            responses[endpoint.id] = TryResponse(
                status: nil,
                seconds: Date.now.timeIntervalSince(started),
                text: error.localizedDescription
            )
        }
    }

    /// Pretty-printed JSON when it is JSON, raw text otherwise; capped so a
    /// runaway response (e.g. /metrics) can't swamp the view.
    private static func pretty(_ data: Data) -> String {
        let text: String
        if let object = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            text = String(decoding: pretty, as: UTF8.self)
        } else {
            text = String(decoding: data, as: UTF8.self)
        }
        return text.count > 20_000 ? text.prefix(20_000) + "\n…" : text
    }

    struct TryResponse {
        let status: Int?
        let seconds: TimeInterval?
        let text: String
    }

    // MARK: Catalog

    private struct Endpoint: Identifiable {
        let method: String
        let path: String
        let note: String
        var bodyTemplate: String?
        var id: String { "\(method) \(path)" }
    }

    private static let groups: [(name: String, endpoints: [Endpoint])] = [
        ("OpenAI-compatible", [
            Endpoint(method: "GET", path: "/v1/models", note: "List served models"),
            Endpoint(method: "POST", path: "/v1/chat/completions", note: "Chat (streaming supported)", bodyTemplate: """
            {
              "model": "{MODEL}",
              "messages": [
                {"role": "user", "content": "Hello!"}
              ],
              "max_tokens": 128
            }
            """),
            Endpoint(method: "POST", path: "/v1/completions", note: "Text completion", bodyTemplate: """
            {
              "model": "{MODEL}",
              "prompt": "Hello, my name is",
              "max_tokens": 64
            }
            """),
            Endpoint(method: "POST", path: "/v1/responses", note: "Responses API", bodyTemplate: """
            {
              "model": "{MODEL}",
              "input": "Hello!"
            }
            """),
        ]),
        ("Anthropic-compatible", [
            Endpoint(method: "POST", path: "/v1/messages", note: "Messages API", bodyTemplate: """
            {
              "model": "{MODEL}",
              "max_tokens": 128,
              "messages": [
                {"role": "user", "content": "Hello!"}
              ]
            }
            """),
            Endpoint(method: "POST", path: "/v1/messages/count_tokens", note: "Token counting", bodyTemplate: """
            {
              "model": "{MODEL}",
              "messages": [
                {"role": "user", "content": "Hello!"}
              ]
            }
            """),
        ]),
        ("Utilities", [
            Endpoint(method: "POST", path: "/tokenize", note: "Tokenize text", bodyTemplate: """
            {
              "model": "{MODEL}",
              "prompt": "Hello world"
            }
            """),
            Endpoint(method: "POST", path: "/detokenize", note: "Detokenize ids", bodyTemplate: """
            {
              "model": "{MODEL}",
              "tokens": [9707, 1879]
            }
            """),
            Endpoint(method: "GET", path: "/health", note: "Health probe"),
            Endpoint(method: "GET", path: "/version", note: "Engine version"),
            Endpoint(method: "GET", path: "/metrics", note: "Prometheus metrics"),
        ]),
    ]
}
