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
import VMDCore

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
    /// App-lifetime cluster brain: discovery/pairing/cluster state must
    /// survive page switches (and answer pair requests from any page).
    @State private var clusterController = ClusterController()
    @State private var navigation = AppNavigation()
    @AppStorage("vmdAppearance") private var appearance = AppAppearance.system
    @AppStorage("vmdTextSize") private var textSize = AppTextSize.medium

    var body: some Scene {
        WindowGroup {
            RootView()
                .tint(Theme.accent)
                .frame(minWidth: 720, minHeight: 480)
                .environment(serveController)
                .environment(clusterController)
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
                .task {
                    // The cluster page reports what the cluster serves; the
                    // serve controller owns those processes. Cluster-mode
                    // deployments are recognized by their arguments.
                    clusterController.deploymentsProvider = {
                        serveController.deployments.compactMap { deployment in
                            guard let flags = deployment.flags,
                                  let mode = ClusterServeCommand.detectMode(
                                    inArguments: flags.extraArguments
                                  ) else { return nil }
                            return ClusterDeploymentSummary(
                                model: deployment.model,
                                port: deployment.port,
                                state: .init(deployment.status),
                                mode: mode
                            )
                        }
                    }
                    // The worker's Cluster page tails the head's engine log
                    // over the control channel; this answers those requests.
                    clusterController.logsProvider = { port, after in
                        guard let deployment = serveController.deployments
                            .first(where: { $0.port == port }) else { return [] }
                        let logs = deployment.logs
                        // A restarted engine restarts its line ids at 0 — a
                        // cursor beyond the current tail means the log the
                        // caller was following is gone; resend from scratch
                        // (the worker detects the id reset and replaces).
                        let cursor = (logs.last?.id ?? -1) >= after ? after : -1
                        return logs
                            .filter { $0.id > cursor }
                            .suffix(500)
                            .map { LogLinePayload(id: $0.id, text: $0.text) }
                    }
                    clusterController.start()
                }
        }
        .modelContainer(modelContainer)
        .defaultSize(width: 1100, height: 720)
        .windowToolbarStyle(.unified)
    }
}
