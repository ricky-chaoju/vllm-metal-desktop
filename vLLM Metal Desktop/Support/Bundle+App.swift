import Foundation

extension Bundle {
    /// Marketing version, e.g. "1.0".
    var appShortVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    /// Build number, e.g. "1".
    var appBuildNumber: String {
        infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }
}
