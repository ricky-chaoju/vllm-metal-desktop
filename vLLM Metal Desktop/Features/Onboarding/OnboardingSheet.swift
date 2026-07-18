import SwiftUI
import VMDCore

/// First-launch checklist: install the engine, grab a starter model, chat.
/// Everything happens inline (install progress, download progress) so a
/// newcomer never has to guess which page comes first. Never shown again once
/// finished or skipped.
struct OnboardingSheet: View {
    static let recommendedModel = ServeController.recommendedModel

    @Environment(ServeController.self) private var serve
    @Environment(\.dismiss) private var dismiss
    @AppStorage("vmdOnboardingDone") private var onboardingDone = false

    @State private var engine = EngineViewModel()
    @State private var models = ModelsViewModel()
    @State private var hasRecommendedModel = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Image("VLLMLogo")
                    .resizable().scaledToFit().frame(height: 40)
                Text("Welcome to vLLM Metal Desktop")
                    .scaledFont(.title2, weight: .semibold)
                Text("Three steps and you're chatting with a local model.")
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 28)
            .padding(.bottom, 20)

            VStack(spacing: Theme.Spacing.m) {
                stepRow(
                    number: 1,
                    title: "Install the engine",
                    subtitle: engineSubtitle,
                    done: engine.hasWorkingEngine
                ) {
                    if engine.isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Install") { Task { await installEngine() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(!engine.preflightPassed && !engine.preflight.isEmpty)
                    }
                }

                stepRow(
                    number: 2,
                    title: "Download a starter model",
                    subtitle: modelSubtitle,
                    done: hasRecommendedModel
                ) {
                    if models.downloadingModel != nil {
                        ProgressView(value: models.downloadPercent ?? 0, total: 100)
                            .frame(width: 120)
                    } else {
                        Button("Download") { models.download(Self.recommendedModel) }
                            .buttonStyle(.borderedProminent)
                            .disabled(!engine.hasWorkingEngine)
                    }
                }

                stepRow(
                    number: 3,
                    title: "Start chatting",
                    subtitle: "Deploys \(Self.recommendedModel) and opens Chat.",
                    done: false
                ) {
                    Button("Start") {
                        serve.modelInput = Self.recommendedModel
                        serve.run()
                        finish()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!engine.hasWorkingEngine || !hasRecommendedModel)
                }
            }
            .padding(.horizontal, 28)

            // Live install output — the compile takes minutes; show the work.
            if engine.isBusy || !engine.logLines.isEmpty {
                installLog
                    .padding(.horizontal, 28)
                    .padding(.top, Theme.Spacing.m)
            }

            Spacer(minLength: 16)

            HStack {
                Button("Skip for now") { finish() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Spacer()
                if case .running(let step, let index, let total) = engine.phase {
                    Text(verbatim: "Step \(min(index + 1, total)) of \(total): \(step)")
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 20)
        }
        .frame(width: 520, height: showsLog ? 640 : 470)
        .animation(.easeOut(duration: 0.2), value: showsLog)
        .task {
            await engine.refresh()
            refreshModelState()
        }
        .onChange(of: models.downloadingModel) { _, downloading in
            if downloading == nil { refreshModelState() }
        }
    }

    private var showsLog: Bool {
        engine.isBusy || !engine.logLines.isEmpty
    }

    /// Compact live install log (auto-scrolls; whole log selectable).
    private var installLog: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(engine.logLines.map(\.text).joined(separator: "\n"))
                    .scaledFont(.caption2, design: .monospaced)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Spacing.s)
                Color.clear.frame(height: 1).id("onboarding-log-bottom")
            }
            .onChange(of: engine.logLines.last?.id) { _, _ in
                proxy.scrollTo("onboarding-log-bottom", anchor: .bottom)
            }
            .onAppear { proxy.scrollTo("onboarding-log-bottom", anchor: .bottom) }
        }
        .frame(height: 150)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var engineSubtitle: String {
        if engine.hasWorkingEngine { return "Installed ✓" }
        if case .failed(let message) = engine.phase { return message }
        if case .running(let step, _, _) = engine.phase { return step }
        return "Downloads and compiles the vllm-metal engine (a few minutes)."
    }

    private var modelSubtitle: String {
        if hasRecommendedModel { return "\(Self.recommendedModel) is ready." }
        if models.downloadingModel != nil { return models.downloadProgress }
        return "\(Self.recommendedModel) — small and fast (~1 GB)."
    }

    private func stepRow(
        number: Int,
        title: String,
        subtitle: String,
        done: Bool,
        @ViewBuilder trailing: () -> some View
    ) -> some View {
        HStack(spacing: Theme.Spacing.m) {
            ZStack {
                Circle()
                    .fill(done ? Color.green.opacity(0.2) : Color.accentColor.opacity(0.15))
                    .frame(width: 30, height: 30)
                if done {
                    Image(systemName: "checkmark").scaledFont(.footnote, weight: .bold).foregroundStyle(.green)
                } else {
                    Text(verbatim: "\(number)").scaledFont(.callout, weight: .bold).foregroundStyle(Color.accentColor)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).scaledFont(.body, weight: .medium)
                Text(subtitle).scaledFont(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if !done { trailing() }
        }
        .padding(Theme.Spacing.m)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func installEngine() async {
        await engine.installOrUpdate()
        refreshModelState()
    }

    private func refreshModelState() {
        hasRecommendedModel = LocalModels().cachedModelIDs().contains(Self.recommendedModel)
    }

    private func finish() {
        onboardingDone = true
        dismiss()
    }
}
