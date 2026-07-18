import Foundation
import Observation

/// App-level navigation state, shared so features can switch tabs (e.g. Models
/// "Run" hands off to Chat).
@MainActor
@Observable
final class AppNavigation {
    var section: AppSection? = AppNavigation.initialSection

    /// Debug/UI-test override: launch with `-VMDInitialSection engine` to open on
    /// a specific page (reads the argument-domain default). Defaults to Chat.
    private static var initialSection: AppSection {
        guard let raw = UserDefaults.standard.string(forKey: "VMDInitialSection"),
              let section = AppSection(rawValue: raw) else { return .chat }
        return section
    }
}
