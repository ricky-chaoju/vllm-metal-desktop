import SwiftUI

/// Top-level navigation destinations, shown in the sidebar.
enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case chat
    case models
    case server
    case engine
    case hardware
    case settings

    var id: String { rawValue }

    /// Daily-workflow destinations (top of the rail).
    static let workspace: [AppSection] = [.chat, .models, .server]
    /// System/maintenance destinations (bottom cluster, above Settings).
    static let system: [AppSection] = [.engine, .hardware]

    var title: String {
        switch self {
        case .chat: "Chat"
        case .models: "Models"
        case .server: "Server"
        case .engine: "Engine"
        case .hardware: "Hardware"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .chat: "bubble.left.and.bubble.right"
        case .models: "square.stack.3d.up"
        case .server: "server.rack"
        case .engine: "cpu"
        case .hardware: "memorychip"
        case .settings: "gearshape"
        }
    }
}
