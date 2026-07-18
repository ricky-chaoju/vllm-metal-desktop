import SwiftData
import SwiftUI
import VMDCore

/// The app root: an always-visible icon rail (never collapses, even on small
/// windows) + the selected destination. Hover a rail icon for its name.
struct RootView: View {
    @Environment(AppNavigation.self) private var navigation
    @Environment(ServeController.self) private var serve
    @Environment(\.colorScheme) private var colorScheme
    @State private var imageZoom = ImageZoomModel()
    @State private var updateMonitor = EngineUpdateMonitor()
    @AppStorage("vmdOnboardingDone") private var onboardingDone = false
    @State private var showOnboarding = false

    var body: some View {
        @Bindable var navigation = navigation
        ZStack {
            // One full-window backdrop, shared by the floating rail and the pages,
            // so the glass has the brand glows behind it to refract.
            AppBackground()

            HStack(spacing: 0) {
                IconRail(selection: $navigation.section)
                    // The layout slot stays rail-width; the expanded rail
                    // overflows and floats over the content instead of
                    // reflowing the whole page on every hover.
                    .frame(width: IconRail.collapsedWidth, alignment: .leading)
                    .zIndex(1)
                    .padding(.leading, 10)
                    .padding(.vertical, 10)
                NavigationStack {
                    detail(for: navigation.section ?? .chat)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        // One continuous surface: the backdrop's glow runs up
                        // under the title bar instead of stopping at a solid strip.
                        .toolbarBackground(.hidden, for: .windowToolbar)
                        // The page name renders centered (below) instead of
                        // crowding the brand label at the leading edge; the
                        // navigationTitle still names the window itself.
                        .modifier(HideToolbarTitle())
                        .toolbar {
                            // Brand identity, leading. Not a control — hide the
                            // glass capsule macOS 26 wraps toolbar items in.
                            if #available(macOS 26.0, *) {
                                ToolbarItem(placement: .navigation) { brandLabel }
                                    .sharedBackgroundVisibility(.hidden)
                                ToolbarItem(placement: .principal) { pageTitle }
                                    .sharedBackgroundVisibility(.hidden)
                            } else {
                                ToolbarItem(placement: .navigation) { brandLabel }
                                ToolbarItem(placement: .principal) { pageTitle }
                            }
                            // Only present when an update exists — no empty
                            // glass capsule lingering in the toolbar otherwise.
                            // Its glass cell is hidden too: merging with the
                            // page's own trailing capsule leaves a bulging seam.
                            if let version = updateMonitor.availableVersion {
                                if #available(macOS 26.0, *) {
                                    ToolbarItem(placement: .primaryAction) {
                                        updatePill(version)
                                    }
                                    .sharedBackgroundVisibility(.hidden)
                                } else {
                                    ToolbarItem(placement: .primaryAction) {
                                        updatePill(version)
                                    }
                                }
                            }
                        }
                }
            }

            if let url = imageZoom.url {
                ImageLightbox(url: url) { imageZoom.dismiss() }
            }
        }
        .environment(imageZoom)
        .environment(updateMonitor)
        .animation(.easeInOut(duration: 0.15), value: imageZoom.url)
        .task { await updateMonitor.start() }
        .onAppear {
            applyDockIcon(for: colorScheme)
            applyDebugWindowSize()
            // First launch with no engine → guided setup. Returning users who
            // already installed one never see it.
            if !onboardingDone {
                if serve.engineInstalled {
                    onboardingDone = true
                } else {
                    showOnboarding = true
                }
            }
        }
        .sheet(isPresented: $showOnboarding) { OnboardingSheet() }
        .onChange(of: colorScheme) { _, scheme in applyDockIcon(for: scheme) }
    }

    /// Classic .appiconset files can't carry appearance variants (only the new
    /// Icon Composer format can), so the running app follows the system look by
    /// swapping its Dock icon: light appearance → light slab, dark → the bundled
    /// dark icon (also what Finder shows; it reads well on both).
    private func applyDockIcon(for scheme: ColorScheme) {
        NSApp.applicationIconImage = scheme == .light ? NSImage(named: "AppIconLight") : nil
    }

    /// Debug/UI-test override: `-VMDWindowSize 1800x1000` forces the window
    /// frame (screenshot verification of wide/narrow layouts).
    private func applyDebugWindowSize() {
        guard let raw = UserDefaults.standard.string(forKey: "VMDWindowSize") else { return }
        let parts = raw.lowercased().split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, let window = NSApp.windows.first(where: \.isVisible) ?? NSApp.windows.first else { return }
        window.setFrame(NSRect(x: window.frame.minX, y: window.frame.maxY - parts[1], width: parts[0], height: parts[1]), display: true)
    }

    /// The current page's name, centered in the toolbar so it never crowds
    /// the brand label on the left.
    private var pageTitle: some View {
        Text((navigation.section ?? .chat).title)
            .font(.system(size: 13, weight: .semibold))
    }

    /// The app's brand label: the official vLLM mark plus the app name.
    private var brandLabel: some View {
        HStack(spacing: 7) {
            Image("VLLMLogo")
                .resizable()
                .scaledToFit()
                .frame(height: 18)
            Text("vLLM Metal Desktop")
                .font(.system(size: 13, weight: .semibold))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("vLLM Metal Desktop")
    }

    /// An "Update available" pill (toolbar trailing) that jumps to the Engine
    /// page whenever a newer engine release is out.
    private func updatePill(_ version: EngineVersion) -> some View {
        Button {
            navigation.section = .engine
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.down.circle.fill").scaledFont(.caption)
                Text("Update available").scaledFont(.caption, weight: .semibold)
            }
            .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help("Engine \(version) is available — open the Engine page to update")
    }

    @ViewBuilder
    private func detail(for section: AppSection) -> some View {
        switch section {
        case .chat: ChatView()
        case .models: ModelsView()
        case .server: ServerView()
        case .engine: EngineView()
        case .hardware: HardwareView()
        case .settings: SettingsView()
        }
    }
}

/// Hides the system toolbar title (macOS 15 API; earlier systems keep it,
/// which merely doubles the page name next to the brand label).
private struct HideToolbarTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbar(removing: .title)
        } else {
            content
        }
    }
}

/// A floating Liquid-Glass icon rail (Apple Music-style sidebar): a rounded glass
/// slab inset from the window edges, refracting the backdrop behind it. Workspace
/// icons at the top, Settings pinned at the bottom. Hovering expands it in place
/// (floating over the content) to reveal the section names.
private struct IconRail: View {
    static let collapsedWidth: CGFloat = 56
    static let expandedWidth: CGFloat = 176

    @Binding var selection: AppSection?
    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 6) {
            ForEach(AppSection.workspace) { section in
                railButton(section)
            }
            Spacer(minLength: 0)
            // System cluster: engine + hardware live just above Settings —
            // one click away, without crowding the daily-workflow group.
            ForEach(AppSection.system) { section in
                railButton(section)
            }
            railButton(.settings)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 9)
        .frame(width: isExpanded ? Self.expandedWidth : Self.collapsedWidth, alignment: .leading)
        .frame(maxHeight: .infinity)
        .glassSidebar(cornerRadius: 18)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.18)) { isExpanded = hovering }
        }
    }

    private func railButton(_ section: AppSection) -> some View {
        let isSelected = selection == section
        return Button {
            selection = section
        } label: {
            HStack(spacing: 10) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 22)
                if isExpanded {
                    Text(section.title)
                        .scaledFont(.callout, weight: .medium)
                        .lineLimit(1)
                        .fixedSize()
                        .transition(.opacity)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(isSelected ? Color.white : Color.secondary)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear))
                    .shadow(color: isSelected ? Color.accentColor.opacity(0.4) : .clear, radius: 6)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help(section.title)
    }
}

#Preview {
    RootView()
        .environment(AppNavigation())
        .environment(ServeController())
        .modelContainer(for: [ChatFolder.self, Conversation.self, ChatMessage.self], inMemory: true)
}
