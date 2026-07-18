//
//  vLLM_Metal_DesktopApp.swift
//  vLLM Metal Desktop
//
//  The app shell. A native, non-sandboxed SwiftUI app (Developer ID + notarized)
//  that installs, runs, and updates the vllm-metal engine. See docs/PLAN.md.
//

import AppKit
import SwiftData
import SwiftUI

@main
struct vLLM_Metal_DesktopApp: App {
    /// The SwiftData store backing models, deployments, and conversations.
    /// Schema mirrors the lmstack subset described in docs/PLAN.md §3.
    let modelContainer: ModelContainer = {
        do {
            return try ModelContainer(
                for: ChatFolder.self, Conversation.self, ChatMessage.self
            )
        } catch {
            fatalError("Failed to create SwiftData ModelContainer: \(error)")
        }
    }()

    /// Shared across Chat and Engine; re-adopts a running engine on launch.
    @State private var serveController = ServeController()
    @State private var navigation = AppNavigation()
    @AppStorage("vmdAppearance") private var appearance = AppAppearance.system
    @AppStorage("vmdTextSize") private var textSize = AppTextSize.medium

    var body: some Scene {
        WindowGroup {
            RootView()
                .tint(Theme.accent)
                .frame(minWidth: 720, minHeight: 480)
                .environment(serveController)
                .environment(navigation)
                // Inner-to-outer: the default body font reads the scale that
                // `appTextScale` installs just outside it, so unstyled text
                // follows the Text size setting everywhere.
                .scaledFont(.body)
                .appTextScale(textSize.scale)
                .onChange(of: appearance, initial: true) { _, mode in
                    // NSApp-level so the whole app (sheets, menus) flips at once,
                    // and returning to System is instant.
                    NSApp.appearance = mode.nsAppearance
                }
                .task { await serveController.recover() }
        }
        .modelContainer(modelContainer)
        .defaultSize(width: 1100, height: 720)
        .windowToolbarStyle(.unified)
    }
}
