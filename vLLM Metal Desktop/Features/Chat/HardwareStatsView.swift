import Combine
import SwiftUI
import VMDCore

/// Live hardware usage in the top bar: RAM used, CPU and GPU utilization.
/// GPU % comes from the IOAccelerator IORegistry stats; exact temperature isn't
/// available via public macOS APIs.
struct HardwareStatsView: View {
    @State private var usage = SystemUsage()
    private let monitor = SystemUsageMonitor()
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 14) {
            stat("CPU", value: String(format: "%.0f%%", usage.cpuPercent), color: usageColor(usage.cpuPercent))
            stat("GPU", value: String(format: "%.0f%%", usage.gpuPercent), color: usageColor(usage.gpuPercent))
            stat("RAM", value: HardwareInfo.gibString(usage.memoryUsedBytes), color: usageColor(usage.memoryFraction * 100))
                .help("RAM used \(HardwareInfo.gibString(usage.memoryUsedBytes)) of \(HardwareInfo.gibString(usage.memoryTotalBytes))")
        }
        .scaledFont(.caption)
        .padding(.horizontal, 8)
        .onAppear { usage = monitor.sample() }
        .onReceive(timer) { _ in usage = monitor.sample() }
    }

    private func stat(_ label: String, value: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            Text(value).foregroundStyle(color).monospacedDigit()
        }
    }

    private func usageColor(_ percent: Double) -> Color {
        switch percent {
        case ..<70: .green
        case ..<90: .orange
        default: .red
        }
    }
}
