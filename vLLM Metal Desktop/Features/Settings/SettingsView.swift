import AppKit
import SwiftUI
import VMDCore

/// App settings & about. The **App Updates** channel here is deliberately
/// separate from engine updates (handled on the Engine tab) — docs/PLAN.md §4.
struct SettingsView: View {
    private let paths = EnginePaths.standard

    @State private var appUpdate: AppUpdateResult?
    @State private var isCheckingApp = false

    @AppStorage("vmdAppearance") private var appearance = AppAppearance.system
    @AppStorage("vmdTextSize") private var textSize = AppTextSize.medium

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                Picker("Text size", selection: $textSize) {
                    ForEach(AppTextSize.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
            }

            Section("App") {
                LabeledContent("Version", value: "\(Bundle.main.appShortVersion) (\(Bundle.main.appBuildNumber))")
                if let appUpdate {
                    appUpdateRow(appUpdate)
                }
                Button {
                    Task { await checkApp() }
                } label: {
                    if isCheckingApp {
                        HStack { ProgressView().controlSize(.small); Text("Checking…") }
                    } else {
                        Text("Check for App Updates")
                    }
                }
                .disabled(isCheckingApp)
            }

            Section {
                LabeledContent("Virtualenv") {
                    Text(paths.venvRoot.path)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                LabeledContent("Model cache") {
                    Text(paths.huggingFaceCache.path)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Engine")
            } footer: {
                Text("Engine version and updates are managed on the Engine tab, independently of app updates.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .pageWidth()
        .navigationTitle("Settings")
    }

    @ViewBuilder
    private func appUpdateRow(_ result: AppUpdateResult) -> some View {
        switch result {
        case .upToDate:
            Label("Up to date", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .updateAvailable(let version, let url):
            HStack {
                Label("Update available: \(version)", systemImage: "arrow.down.circle.fill")
                    .foregroundStyle(.blue)
                Spacer()
                if let url { Link("Open Release", destination: url) }
            }
        case .unknown(let message):
            Text("Couldn't check for updates.")
                .foregroundStyle(.secondary)
                .help(message)
        }
    }

    private func checkApp() async {
        isCheckingApp = true
        appUpdate = await AppUpdateChecker().check(currentVersion: Bundle.main.appShortVersion)
        isCheckingApp = false
    }
}

/// Theme override: follow the system, or force light/dark.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// Applied to `NSApp.appearance` — unlike `preferredColorScheme`, switching
    /// back to `.system` takes effect instantly instead of after a beat.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// App-wide text sizing, applied as a multiplier via `scaledFont` (macOS has
/// no user-facing Dynamic Type). Body text becomes 12 / 13 / 15 / 17 pt.
enum AppTextSize: String, CaseIterable, Identifiable {
    case small, medium, large, extraLarge
    var id: String { rawValue }

    var label: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        case .extraLarge: "Extra Large"
        }
    }

    var scale: CGFloat {
        switch self {
        case .small: 12.0 / 13.0
        case .medium: 1
        case .large: 15.0 / 13.0
        case .extraLarge: 17.0 / 13.0
        }
    }
}

#Preview {
    NavigationStack { SettingsView() }
}
