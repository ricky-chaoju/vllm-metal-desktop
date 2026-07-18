import SwiftUI
import VMDCore

/// The Server page's "+" flow: pick a downloaded model, tune the serve
/// configuration, deploy. One sheet — a newcomer never has to know the gear
/// sheet exists.
struct DeploySheet: View {
    @Environment(ServeController.self) private var serve
    @Environment(\.dismiss) private var dismiss
    /// Called with the started deployment so the sidebar can select it.
    let onDeploy: (ServeDeployment) -> Void

    @State private var flags: ServeFlags
    @State private var models: [String] = []
    @State private var selectedModel: String?

    init(flags: ServeFlags, onDeploy: @escaping (ServeDeployment) -> Void) {
        _flags = State(initialValue: flags)
        self.onDeploy = onDeploy
    }

    var body: some View {
        // Hand-built chrome, matching ServeFlagsSheet (sheets neither cap
        // their height nor draw a distinct bar on their own).
        VStack(spacing: 0) {
            HStack {
                Text("Deploy a Model").scaledFont(.headline)
                Spacer()
                Button("Reset") { flags = ServeFlags() }
                    .controlSize(.small)
            }
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            Form {
                Section {
                    if models.isEmpty {
                        Text("No downloaded models yet — grab one on the Models page.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Model", selection: $selectedModel) {
                            ForEach(models, id: \.self) { model in
                                Text(model).tag(String?.some(model))
                            }
                        }
                    }
                } header: {
                    Text("Model")
                }

                ServeFlagsForm(flags: $flags)
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Deploy") { deploy() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedModel == nil)
            }
            .padding(Theme.Spacing.m)
            .background(.bar)
        }
        .frame(width: 540, height: 640)
        .presentationBackground(.ultraThinMaterial)
        .onAppear {
            models = LocalModels().cachedModelIDs()
            // Preselect something sensible: the last model typed/run, else the
            // first downloaded one.
            if selectedModel == nil {
                selectedModel = models.contains(serve.modelInput) ? serve.modelInput : models.first
            }
        }
    }

    private func deploy() {
        guard let model = selectedModel else { return }
        serve.applyFlags(flags)
        serve.modelInput = model
        serve.run()
        if let started = serve.active { onDeploy(started) }
        dismiss()
    }
}
