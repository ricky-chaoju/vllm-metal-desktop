import os

/// Unified logging categories for the app and core.
///
/// Categories mirror the subsystems in docs/PLAN.md §7 so log streams can be
/// filtered with `log stream --predicate 'subsystem == "…"'` and surfaced in the
/// in-app log viewer.
public enum VMDLog {
    /// Matches the app bundle identifier.
    public static let subsystem = "com.infinirc.vllm-metal-desktop"

    /// Engine provisioning: preflight, uv/venv, downloads, compilation.
    public static let installer = Logger(subsystem: subsystem, category: "installer")
    /// Engine lifecycle: start/stop/recover, health, process supervision.
    public static let engine = Logger(subsystem: subsystem, category: "engine")
    /// Outbound HTTP: HuggingFace Hub, GitHub releases, OpenAI-compatible API.
    public static let http = Logger(subsystem: subsystem, category: "http")
    /// General app / UI lifecycle.
    public static let app = Logger(subsystem: subsystem, category: "app")
}
