import SwiftUI
import UniformTypeIdentifiers
import VMDCore

/// Shows this Mac's hardware — chip, cores, unified memory, Metal GPU budget,
/// OS, disk — with one-button copy for bug reports. Unified memory and the Metal
/// budget are the numbers that decide which models fit (docs/PLAN.md §5).
struct HardwareView: View {
    @State private var info: HardwareInfo?
    @State private var copied = false

    var body: some View {
        Form {
            if let info {
                Section("Mac") {
                    // The product image macOS itself ships for this exact model.
                    HStack(spacing: Theme.Spacing.m) {
                        if let image = Self.modelImage(for: info.modelIdentifier) {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 64, height: 64)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(info.marketingName ?? info.modelIdentifier)
                                .scaledFont(.headline)
                            if info.marketingName != nil {
                                Text(info.modelIdentifier)
                                    .scaledFont(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                    LabeledContent("Chip", value: info.chip)
                    LabeledContent("CPU", value: info.cpuDescription)
                    if let gpu = info.gpuName {
                        LabeledContent("GPU (Metal)", value: gpu)
                    }
                }

                Section("Memory") {
                    LabeledContent("Unified memory", value: HardwareInfo.gibString(info.unifiedMemoryBytes))
                    if let budget = info.metalBudgetBytes {
                        LabeledContent("Metal budget", value: HardwareInfo.gibString(budget))
                    }
                }

                Section("System") {
                    LabeledContent("Architecture", value: info.isAppleSilicon ? "arm64 (Apple Silicon)" : "Intel")
                    LabeledContent("macOS", value: info.osVersion)
                    LabeledContent("Disk") {
                        Text("\(HardwareInfo.gbString(info.freeDiskBytes)) free of \(HardwareInfo.gbString(info.totalDiskBytes))")
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button { copy(info) } label: {
                        Label(copied ? "Copied!" : "Copy Hardware Info",
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                }
            } else {
                HStack(spacing: Theme.Spacing.s) {
                    ProgressView().controlSize(.small)
                    Text("Reading hardware…")
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .pageWidth()
        .navigationTitle("Hardware")
        .task {
            if info == nil {
                info = HardwareInfo.current(
                    appVersion: "\(Bundle.main.appShortVersion) (\(Bundle.main.appBuildNumber))"
                )
            }
        }
        .toolbar {
            if let info {
                Button { copy(info) } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("Copy hardware info")
            }
        }
    }

    /// The system's own product image for a model identifier (e.g. "Mac14,8" →
    /// the Mac Pro 2023 tower), via the device-model-code UTType. `nil` when the
    /// system has no specific artwork.
    private static func modelImage(for identifier: String) -> NSImage? {
        guard let type = UTType(
            tag: identifier,
            tagClass: UTTagClass(rawValue: "com.apple.device-model-code"),
            conformingTo: nil
        ) else { return nil }
        return NSWorkspace.shared.icon(for: type)
    }

    private func copy(_ info: HardwareInfo) {
        Pasteboard.copy(info.formattedReport())
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

#Preview {
    NavigationStack { HardwareView() }
}
