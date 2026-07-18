import SwiftUI
import VMDCore

/// Grouped editor for curated `vllm serve` flags + Metal tunings + raw extras.
struct ServeFlagsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var flags: ServeFlags
    private let initialFlags: ServeFlags
    /// When set (e.g. "Redeploy" for a live deployment), the primary button
    /// takes this title once the flags differ from what they were — making it
    /// obvious that saving restarts the engine.
    let changedActionTitle: String?
    let onSave: (ServeFlags) -> Void

    init(flags: ServeFlags, changedActionTitle: String? = nil, onSave: @escaping (ServeFlags) -> Void) {
        _flags = State(initialValue: flags)
        self.initialFlags = flags
        self.changedActionTitle = changedActionTitle
        self.onSave = onSave
    }

    private var primaryTitle: String {
        if let changedActionTitle, flags != initialFlags { return changedActionTitle }
        return "Done"
    }

    var body: some View {
        // Hand-built chrome: NavigationStack sheets neither cap their height (the
        // form's ideal height overflowed short windows) nor draw a distinct bar.
        VStack(spacing: 0) {
            HStack {
                Text("Serve Configuration").scaledFont(.headline)
                Spacer()
                Button("Reset") { flags = ServeFlags() }
                    .controlSize(.small)
            }
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            Form {
                ServeFlagsForm(flags: $flags)
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(primaryTitle) { onSave(flags); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(Theme.Spacing.m)
            .background(.bar)
        }
        .frame(width: 540, height: 600)
        // Translucent glass-like sheet: the window shows through, blurred.
        .presentationBackground(.ultraThinMaterial)
    }

}

/// The serve-configuration form sections (Metal tunings, port, curated flags,
/// raw extras) — embedded in the gear sheet and the Deploy sheet alike. Emits
/// `Section`s, so it must live inside a `Form`.
struct ServeFlagsForm: View {
    @Binding var flags: ServeFlags

    var body: some View {
        metalSection

        ForEach(ServeFlagCatalog.grouped(), id: \.group) { entry in
            Section(entry.group.rawValue) {
                ForEach(entry.flags) { flag in
                    FlagControl(flag: flag, flags: $flags)
                }
            }
        }

        Section {
            TextField("e.g. --limit-mm-per-prompt image=2", text: $flags.extraArguments, axis: .vertical)
                .lineLimit(2...5)
                .scaledFont(.callout, design: .monospaced)
        } header: {
            Text("Advanced — Raw Arguments")
        } footer: {
            Text("Passed verbatim to `vllm serve`. The flags above are the ones verified meaningful on the Metal backend; anything else (TurboQuant, speculative decoding, LoRA, …) goes here.")
        }
    }

    /// Digits-only editing of the port; commits only valid TCP ports so the
    /// stored value never goes bad mid-keystroke.
    private var portText: Binding<String> {
        Binding(
            get: { String(flags.serverPort) },
            set: { newValue in
                let digits = newValue.filter(\.isNumber)
                if let port = Int(digits), (1...65535).contains(port) {
                    flags.serverPort = port
                }
            }
        )
    }

    @ViewBuilder
    private var metalSection: some View {
        Section {
            Toggle(isOn: $flags.usePagedAttention) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Paged attention")
                    Text("The modern KV path — chunked prefill, TurboQuant, speculative decoding. Turn off only as a compatibility escape hatch.")
                        .scaledFont(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: $flags.debugLogging) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Debug logging")
                    Text("Verbose engine-side logs (VLLM_METAL_DEBUG).")
                        .scaledFont(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Metal")
        } footer: {
            Text("Memory is controlled by GPU memory utilization below — one lever, applied to Metal's recommended working set.")
        }

        Section {
            LabeledContent("Port") {
                // No placeholder: the port always has a value, and an interpolated
                // Int placeholder gets locale-formatted ("8,000") and rendered
                // alongside the value by the grouped form style.
                TextField("", text: portText)
                    .multilineTextAlignment(.trailing)
                    .scaledFont(.body, monospacedDigit: true)
                    .frame(maxWidth: 80)
            }
        } header: {
            Text("Server")
        } footer: {
            Text("Stays the same across runs so other apps can keep pointing at one address. If it's taken, a free port is used for that run.")
        }
    }
}

/// Renders the appropriate control for one flag, reading/writing the flag values
/// dictionary so unset flags fall back to vLLM's own defaults.
private struct FlagControl: View {
    let flag: ServeFlag
    @Binding var flags: ServeFlags

    var body: some View {
        control.help(flag.help)
    }

    @ViewBuilder
    private var control: some View {
        switch flag.kind {
        case .toggle(let defaultValue):
            Toggle(flag.label, isOn: boolBinding(default: defaultValue))
        case .integer:
            LabeledContent(flag.label) {
                // Empty = engine default; the dim example hints at the shape.
                TextField("", text: intBinding, prompt: examplePrompt)
                    .multilineTextAlignment(.trailing)
                    .scaledFont(.body, monospacedDigit: true)
                    .frame(width: 130, alignment: .trailing)
            }
        case .number(let defaultValue, let lower, let upper):
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(flag.label)
                    Spacer()
                    Text(String(format: "%.2f", currentDouble(default: defaultValue)))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: doubleBinding(default: defaultValue), in: lower...upper)
            }
        case .text:
            LabeledContent(flag.label) {
                TextField("", text: textBinding, prompt: examplePrompt)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 130, alignment: .trailing)
            }
        case .choice(let defaultValue, let options):
            Picker(flag.label, selection: choiceBinding(default: defaultValue)) {
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
        }
    }

    /// Dim example placeholder ("e.g. 8192") — verbatim, so numbers never pick up
    /// locale formatting like "8,192".
    private var examplePrompt: Text? {
        flag.example.map { Text(verbatim: "e.g. \($0)") }
    }

    // MARK: Bindings into the values dictionary

    private func boolBinding(default defaultValue: Bool) -> Binding<Bool> {
        Binding(
            get: { if case .bool(let value)? = flags.values[flag.key] { value } else { defaultValue } },
            set: { flags.values[flag.key] = .bool($0) }
        )
    }

    private var intBinding: Binding<String> {
        Binding(
            get: { if case .int(let value)? = flags.values[flag.key] { String(value) } else { "" } },
            set: { newValue in
                if let int = Int(newValue) {
                    flags.values[flag.key] = .int(int)
                } else if newValue.isEmpty {
                    flags.values[flag.key] = nil
                }
            }
        )
    }

    private var textBinding: Binding<String> {
        Binding(
            get: { if case .string(let value)? = flags.values[flag.key] { value } else { "" } },
            set: { flags.values[flag.key] = $0.isEmpty ? nil : .string($0) }
        )
    }

    private func choiceBinding(default defaultValue: String) -> Binding<String> {
        Binding(
            get: { if case .string(let value)? = flags.values[flag.key] { value } else { defaultValue } },
            set: { flags.values[flag.key] = .string($0) }
        )
    }

    private func doubleBinding(default defaultValue: Double) -> Binding<Double> {
        Binding(
            get: { currentDouble(default: defaultValue) },
            set: { flags.values[flag.key] = .double($0) }
        )
    }

    private func currentDouble(default defaultValue: Double) -> Double {
        if case .double(let value)? = flags.values[flag.key] { value } else { defaultValue }
    }
}
