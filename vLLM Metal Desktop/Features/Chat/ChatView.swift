import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import VMDCore

/// LM Studio–style chat: a conversation list (folders + search) on the left, a
/// model picker + transcript + composer on the right. Conversations persist.
struct ChatView: View {
    @Environment(ServeController.self) private var serve
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.modelContext) private var context

    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]
    @Query(sort: \ChatFolder.createdAt) private var folders: [ChatFolder]

    @State private var chat = ChatViewModel()
    @State private var selection: Conversation?
    @State private var search = ""
    @State private var showLog = false
    @State private var showParametersPopover = false
    @State private var showAttachPicker = false
    @State private var isDropTargeted = false
    @State private var attachmentNotice: String?
    @State private var noticeDismissTask: Task<Void, Never>?
    @FocusState private var renameFieldFocused: Bool
    @State private var collapsedFolders: Set<PersistentIdentifier> = []
    @State private var renamingFolder: ChatFolder?
    @State private var renamingConversation: Conversation?
    @State private var renameText = ""
    @State private var selectedFolder: ChatFolder?

    var body: some View {
        HSplitView {
            conversationPanel
                .frame(minWidth: 160, idealWidth: 240, maxWidth: 320, maxHeight: .infinity)
            chatArea
                .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Chat")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button { showParametersPopover.toggle() } label: {
                    Image(systemName: "dial.medium")
                }
                .help("Sampling parameters")
                .popover(isPresented: $showParametersPopover, arrowEdge: .bottom) {
                    parametersForm.frame(width: 340, height: 430)
                }
            }
            ToolbarItem(placement: .automatic) {
                Button { showLog.toggle() } label: { Image(systemName: "terminal") }
                    .help("Engine log")
            }
        }
        .onChange(of: serve.status) { _, status in
            if status == .starting { showLog = true }
        }
        // The Thinking control follows the active model's template abilities.
        .onAppear { syncThinkingSupport() }
        .onChange(of: serve.activeID) { _, _ in syncThinkingSupport() }
        .onChange(of: serve.servedModelName) { _, _ in syncThinkingSupport() }
    }

    /// Reads the active model's cached chat template and updates what the
    /// Thinking picker may do (resetting a now-impossible forced mode).
    private func syncThinkingSupport() {
        let model = serve.servedModelName ?? serve.modelInput
        chat.thinkingSupport = ThinkingParser.templateSupport(LocalModels().chatTemplate(forModelID: model))
        if chat.thinkingSupport != .toggleable {
            chat.thinkingMode = .modelDefault
        }
    }

    private var isFailed: Bool {
        if case .failed = serve.status { return true }
        return false
    }

    private var messages: [ChatMessage] {
        (selection?.messages ?? [])
            .filter { $0.role != .system }
            .sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: Conversation panel

    private var conversationPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Spacing.s) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).scaledFont(.caption)
                    TextField("Search chats", text: $search).textFieldStyle(.plain)
                }
                .padding(.horizontal, 11).padding(.vertical, 7)
                .glassCapsule()

                Button { newFolder() } label: { Image(systemName: "folder.badge.plus") }
                    .buttonStyle(.borderless).help("New folder")
                Button { newChat(in: selectedFolder) } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.borderless)
                    .help(selectedFolder == nil ? "New chat" : "New chat in “\(selectedFolder!.name)”")
            }
            .padding(.horizontal, Theme.Spacing.s)
            .frame(height: 48)

            Divider()

            List(selection: $selection) {
                ForEach(conversations(in: nil)) { conversationRow($0) }
                ForEach(folders) { folder in
                    folderRow(folder)
                    if !collapsedFolders.contains(folder.persistentModelID) {
                        ForEach(conversations(in: folder)) { conversation in
                            conversationRow(conversation).padding(.leading, 14)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .onChange(of: selection) { _, conversation in
                if let conversation { selectedFolder = conversation.folder }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func folderRow(_ folder: ChatFolder) -> some View {
        if renamingFolder == folder {
            HStack(spacing: 4) {
                TextField("Folder name", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .focused($renameFieldFocused)
                    .onAppear { renameFieldFocused = true }
                    .onSubmit { commitRename() }
                    .onExitCommand { renamingFolder = nil }
                renameActions(cancel: { renamingFolder = nil })
            }
        } else {
            Button {
                selectedFolder = folder
                if collapsedFolders.contains(folder.persistentModelID) {
                    collapsedFolders.remove(folder.persistentModelID)
                } else {
                    collapsedFolders.insert(folder.persistentModelID)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: collapsedFolders.contains(folder.persistentModelID) ? "chevron.right" : "chevron.down")
                        .scaledFont(.caption2).foregroundStyle(.secondary).frame(width: 10)
                    Image(systemName: "folder.fill")
                        .foregroundStyle(selectedFolder == folder ? Color.accentColor : .secondary)
                    Text(folder.name).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(selectedFolder == folder ? Color.accentColor.opacity(0.12) : Color.clear)
            .dropDestination(for: String.self) { items, _ in
                for item in items { moveConversation(dragID: item, to: folder) }
                return !items.isEmpty
            }
            .contextMenu {
                Button { newChat(in: folder) } label: { Label("New Chat in Folder", systemImage: "square.and.pencil") }
                Button { startRenameFolder(folder) } label: { Label("Rename", systemImage: "pencil") }
                Divider()
                Button(role: .destructive) { context.delete(folder) } label: { Label("Delete Folder", systemImage: "trash") }
            }
        }
    }

    @ViewBuilder
    private func conversationRow(_ conversation: Conversation) -> some View {
        if renamingConversation == conversation {
            HStack(spacing: 4) {
                TextField("Title", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .focused($renameFieldFocused)
                    .onAppear { renameFieldFocused = true }
                    .onSubmit { commitRename() }
                    .onExitCommand { renamingConversation = nil }
                renameActions(cancel: { renamingConversation = nil })
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.title.isEmpty ? "New Chat" : conversation.title).lineLimit(1)
                if let model = conversation.modelName {
                    Text(model).scaledFont(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .tag(conversation)
            .draggable(dragID(conversation))
            .contextMenu {
                Button { startRenameConversation(conversation) } label: { Label("Rename", systemImage: "pencil") }
                Menu {
                    Button("None") { conversation.folder = nil }
                    ForEach(folders) { folder in
                        Button(folder.name) {
                            conversation.folder = folder
                            collapsedFolders.remove(folder.persistentModelID)
                        }
                    }
                } label: { Label("Move to", systemImage: "folder") }
                Divider()
                Button(role: .destructive) {
                    if selection == conversation { selection = nil }
                    context.delete(conversation)
                } label: { Label("Delete", systemImage: "trash") }
            }
        }
    }

    private func conversations(in folder: ChatFolder?) -> [Conversation] {
        let base = search.isEmpty
            ? conversations
            : conversations.filter { $0.title.localizedCaseInsensitiveContains(search) }
        return base.filter { $0.folder?.persistentModelID == folder?.persistentModelID }
    }

    // MARK: Chat area

    private var chatArea: some View {
        VStack(spacing: 0) {
            modelBar
            Divider().opacity(0.5)
            transcript
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            composer
            if showLog {
                Divider()
                logTerminal
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Files dragged anywhere over the chat attach to the composer.
        .dropDestination(for: URL.self) { urls, _ in
            stageDropped(urls)
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
    }

    private var modelBar: some View {
        HStack(spacing: Theme.Spacing.s) {
            modelSelector

            Spacer()

            // "Running" is redundant next to a picked model — only states that
            // carry information (starting up, failed) get called out.
            if let active = serve.active, active.isRunning == false {
                Text(serve.statusText)
                    .scaledFont(.callout)
                    .foregroundStyle(isFailed ? .red : .secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, Theme.Spacing.m)
        .frame(height: 48)
    }

    /// Chat only *picks* among deployed models — deploying happens on the
    /// Server page (Chat stays a conversation surface).
    private var modelSelector: some View {
        Menu {
            if !serve.deployments.isEmpty {
                Section("Running") {
                    ForEach(serve.runningDeployments) { deployment in
                        Button {
                            serve.activeID = deployment.id
                        } label: {
                            let title = "\(deployment.servedModelName ?? deployment.model)  ·  :\(deployment.port)"
                            if deployment.id == serve.active?.id {
                                Label(title, systemImage: "checkmark")
                            } else {
                                Text(title)
                            }
                        }
                    }
                }
                Divider()
            }
            Button("Deploy a model…") { navigation.section = .server }
        } label: {
            HStack(spacing: 7) {
                if serve.isStarting {
                    ProgressView().controlSize(.mini)
                }
                Text(activeModelLabel)
                    .scaledFont(.callout, weight: .medium).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down").scaledFont(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)      // no button chrome — just our label…
        .menuIndicator(.hidden)   // …and no built-in dropdown arrow either
        .fixedSize()
        // Glass on the menu itself — inside the label it doesn't render.
        .glassCapsule()
    }

    private var activeModelLabel: String {
        if let active = serve.active {
            return active.servedModelName ?? active.model
        }
        return "No model running"
    }

    // MARK: Bottom engine-log terminal (collapsible)

    private var logTerminal: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Spacing.s) {
                Image(systemName: "terminal").scaledFont(.caption).foregroundStyle(.secondary)
                Text("Engine Log").scaledFont(.caption, weight: .medium)
                if serve.isStarting {
                    ProgressView().controlSize(.mini)
                    Text("loading…").scaledFont(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                HardwareStatsView()
                Button {
                    Pasteboard.copy(serve.logs.map(\.text).joined(separator: "\n"))
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain).controlSize(.small).help("Copy log")
                .disabled(serve.logs.isEmpty)
                Button { showLog = false } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.plain).controlSize(.small).help("Hide log")
            }
            .padding(.horizontal, Theme.Spacing.m).padding(.vertical, 5)
            .background(.quaternary.opacity(0.4))

            Divider()

            EngineLogView(lines: serve.logs)
        }
        .frame(height: 180)
        .background(.regularMaterial)
    }

    // An empty conversation stays visually empty (iMessage-style) — the composer
    // placeholder already carries the "run a model / type below" affordance.
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: Theme.Spacing.l) {
                    ForEach(messages, id: \.persistentModelID) { message in
                        MessageBubble(
                            message: message,
                            isStreaming: chat.isStreaming && message.persistentModelID == messages.last?.persistentModelID,
                            onCopy: { Pasteboard.copy(ThinkingParser.split(message.content).answer) },
                            onRegenerate: { regenerate(message) }
                        )
                        .id(message.persistentModelID)
                    }
                }
                .padding(Theme.Spacing.l)
                // Message bodies inherit this default font (Text size setting).
                .scaledFont(.body)
                // On wide windows the sent bubble and the reply shouldn't drift
                // to opposite edges — keep the conversation a readable column.
                .pageWidth(max: 880)
            }
            .onChange(of: messages.last?.content) { _, _ in
                if let last = messages.last?.persistentModelID {
                    withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
            // Land on the latest message when this conversation's scroll view
            // appears (fresh identity per conversation, see below).
            .onAppear {
                if let last = messages.last?.persistentModelID {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
        // One scroll view *per conversation*: switching rebuilds it, so the
        // offset always starts at zero and a short thread can never inherit a
        // longer thread's scroll position (scrollTo-based resets raced the
        // lazy row layout and silently no-opped).
        .id(selection?.persistentModelID)
    }

    /// Whether the running model takes image input (from its cached config).
    private var modelSupportsVision: Bool {
        let model = serve.servedModelName ?? serve.modelInput
        guard let config = LocalModels().configJSON(forModelID: model) else { return false }
        return LocalModels.supportsVision(configJSON: config)
    }

    private var attachableTypes: [UTType] {
        modelSupportsVision ? [.image, .text, .pdf] : [.text, .pdf]
    }

    private var composer: some View {
        @Bindable var chat = chat
        return VStack(alignment: .leading, spacing: 6) {
            if !chat.attachments.isEmpty {
                attachmentChips
            }
            composerRow
        }
        .padding(.leading, Theme.Spacing.m)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .glassCard(cornerRadius: Theme.Radius.xl)
        // Lights up while a drag hovers anywhere over the chat area.
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .shadow(color: Color.accentColor.opacity(0.5), radius: 6)
                .opacity(isDropTargeted ? 1 : 0)
        )
        .animation(.easeOut(duration: 0.15), value: isDropTargeted)
        // Rejected-image notice: without it, dropping a picture on a text-only
        // model silently does nothing and reads as the app being broken.
        .overlay(alignment: .top) {
            if let attachmentNotice {
                Label(attachmentNotice, systemImage: "eye.slash")
                    .scaledFont(.caption, weight: .medium)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .glassCapsule()
                    .offset(y: -38)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: attachmentNotice)
        .padding(Theme.Spacing.m)
        // Matches the transcript column so the composer edges line up.
        .pageWidth(max: 880)
    }

    /// Stages files dragged into the chat (images only when the model can see).
    private func stageDropped(_ urls: [URL]) -> Bool {
        let bundleID = Bundle.main.bundleIdentifier ?? "vllm-metal-desktop"
        var stagedAny = false
        var rejectedImages = 0
        for url in urls {
            guard let kind = ComposerAttachment.kind(of: url) else { continue }
            if kind == .image && !modelSupportsVision {
                rejectedImages += 1
                continue
            }
            if let staged = ComposerAttachment.stage(url, bundleID: bundleID) {
                chat.attachments.append(staged)
                stagedAny = true
            }
        }
        if rejectedImages > 0 {
            let model = serve.servedModelName ?? serve.modelInput
            showAttachmentNotice("\(shortModelName(model)) doesn't support images — try a vision (VL) model")
        }
        return stagedAny
    }

    private func shortModelName(_ model: String) -> String {
        model.split(separator: "/").last.map(String.init) ?? model
    }

    /// Shows the composer notice for a few seconds, then fades it out.
    private func showAttachmentNotice(_ text: String) {
        attachmentNotice = text
        noticeDismissTask?.cancel()
        noticeDismissTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { attachmentNotice = nil }
        }
    }

    private var attachmentChips: some View {
        @Bindable var chat = chat
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.s) {
                ForEach(chat.attachments) { attachment in
                    AttachmentChip(attachment: attachment) {
                        chat.attachments.removeAll { $0.id == attachment.id }
                    }
                }
            }
        }
        .padding(.top, 6)
    }

    private var composerRow: some View {
        @Bindable var chat = chat
        return HStack(alignment: .bottom, spacing: Theme.Spacing.s) {
            Button {
                showAttachPicker = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .disabled(!serve.isRunning)
            .help(modelSupportsVision
                  ? "Attach images or files"
                  : "Attach files (this model doesn't support images)")
            .padding(.bottom, 8)
            .fileImporter(
                isPresented: $showAttachPicker,
                allowedContentTypes: attachableTypes,
                allowsMultipleSelection: true
            ) { result in
                guard case .success(let urls) = result else { return }
                let bundleID = Bundle.main.bundleIdentifier ?? "vllm-metal-desktop"
                for url in urls {
                    if let staged = ComposerAttachment.stage(url, bundleID: bundleID) {
                        chat.attachments.append(staged)
                    }
                }
            }

            TextField(serve.isRunning ? "Message…" : "Run a model to chat", text: $chat.input, axis: .vertical)
                .textFieldStyle(.plain)
                .scaledFont(.body)
                .lineLimit(1...8)
                .disabled(!serve.isRunning)
                .onSubmit {
                    // Shift+Return inserts a line break; plain Return sends.
                    if NSEvent.modifierFlags.contains(.shift) {
                        chat.input += "\n"
                    } else {
                        sendMessage()
                    }
                }
                // The binding doesn't update while an IME is composing (marked
                // text), which would leave the send button dim mid-typing —
                // watch the field editor directly.
                .onReceive(NotificationCenter.default.publisher(for: NSText.didChangeNotification)) { note in
                    guard let editor = note.object as? NSTextView else { return }
                    chat.isComposing = editor.hasMarkedText()
                }
                .padding(.vertical, 8)

            Button {
                if chat.isStreaming { chat.stopStreaming() } else { sendMessage() }
            } label: {
                Image(systemName: chat.isStreaming ? "stop.fill" : "arrow.up")
                    .scaledFont(.headline, weight: .bold)
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(sendEnabled ? Color.accentColor : Color.gray.opacity(0.4)))
            }
            .buttonStyle(.plain)
            .disabled(!chat.isStreaming && !(serve.isRunning && chat.canSend))
        }
    }

    private var sendEnabled: Bool {
        chat.isStreaming || (serve.isRunning && chat.canSend)
    }

    private var parametersForm: some View {
        @Bindable var chat = chat
        return Form {
            Section("Sampling") {
                VStack(alignment: .leading) {
                    HStack {
                        Text("Temperature"); Spacer()
                        Text(String(format: "%.2f", chat.temperature)).foregroundStyle(.secondary)
                    }
                    Slider(value: $chat.temperature, in: 0...2)
                }
                Stepper("Max tokens: \(chat.maxTokens)", value: $chat.maxTokens, in: 64...32768, step: 64)
            }
            Section {
                Picker("Thinking", selection: $chat.thinkingMode) {
                    ForEach(ChatViewModel.ThinkingMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .disabled(chat.thinkingSupport != .toggleable)
            } header: {
                Text("Reasoning")
            } footer: {
                switch chat.thinkingSupport {
                case .toggleable:
                    Text("This model's template honors the switch: \"On\" forces reasoning, \"Off\" suppresses it.")
                case .always:
                    Text("This model always reasons — there is no switch to flip.")
                case .none:
                    Text("This model doesn't support thinking, so the switch is disabled.")
                }
            }
            Section("System Prompt") {
                TextField("Optional", text: $chat.systemPrompt, axis: .vertical).lineLimit(3...10)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: Actions

    @discardableResult
    private func newChat(in folder: ChatFolder? = nil) -> Conversation {
        // Don't pile up empty chats: reuse an existing empty one in the same folder.
        if let existing = conversations.first(where: {
            $0.messages.isEmpty && $0.folder?.persistentModelID == folder?.persistentModelID
        }) {
            selectedFolder = folder
            selection = existing
            return existing
        }
        let conversation = Conversation(title: "New Chat")
        conversation.folder = folder
        context.insert(conversation)
        if let folder { collapsedFolders.remove(folder.persistentModelID) }
        selectedFolder = folder
        selection = conversation
        return conversation
    }

    // MARK: Drag & drop (move conversation into a folder)

    private func dragID(_ conversation: Conversation) -> String {
        (try? JSONEncoder().encode(conversation.persistentModelID))?.base64EncodedString() ?? ""
    }

    private func moveConversation(dragID: String, to folder: ChatFolder?) {
        guard let data = Data(base64Encoded: dragID),
              let identifier = try? JSONDecoder().decode(PersistentIdentifier.self, from: data),
              let conversation = conversations.first(where: { $0.persistentModelID == identifier })
        else { return }
        conversation.folder = folder
        if let folder { collapsedFolders.remove(folder.persistentModelID) }
    }

    private func newFolder() {
        let folder = ChatFolder(name: "New Folder")
        context.insert(folder)
        startRenameFolder(folder)
    }

    private func startRenameFolder(_ folder: ChatFolder) {
        renamingConversation = nil
        renamingFolder = folder
        renameText = folder.name
    }

    private func startRenameConversation(_ conversation: Conversation) {
        renamingFolder = nil
        renamingConversation = conversation
        renameText = conversation.title
    }

    /// Confirm/cancel buttons beside an inline rename field.
    private func renameActions(cancel: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Button(action: commitRename) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .contentShape(Rectangle())
            }
            .help("Rename")
            Button(action: cancel) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .help("Cancel")
        }
        .buttonStyle(.plain)
        .scaledFont(.title3)
        .pointingHandCursor()
    }

    private func commitRename() {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let folder = renamingFolder {
            if !trimmed.isEmpty { folder.name = trimmed }
            renamingFolder = nil
        }
        if let conversation = renamingConversation {
            if !trimmed.isEmpty { conversation.title = trimmed }
            renamingConversation = nil
        }
    }

    private func sendMessage() {
        guard serve.isRunning,
              let client = serve.openAIClient,
              let model = serve.servedModelName else { return }
        let conversation = selection ?? newChat()
        chat.send(into: conversation, client: client, model: model, context: context)
    }

    private func regenerate(_ message: ChatMessage) {
        guard let conversation = selection,
              let client = serve.openAIClient,
              let model = serve.servedModelName else { return }
        chat.regenerate(message, in: conversation, client: client, model: model, context: context)
    }
}

/// A staged attachment in the composer. Images show as bare thumbnails (tap to
/// preview, ✕ floating on the corner); other files as a name chip.
private struct AttachmentChip: View {
    let attachment: ComposerAttachment
    let onRemove: () -> Void

    @Environment(ImageZoomModel.self) private var imageZoom: ImageZoomModel?

    var body: some View {
        if attachment.kind == .image, let image = NSImage(contentsOf: attachment.url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(Rectangle())
                .onTapGesture { imageZoom?.show(attachment.url) }
                .pointingHandCursor()
                .overlay(alignment: .topTrailing) {
                    Button(action: onRemove) {
                        Image(systemName: "xmark.circle.fill")
                            .scaledFont(.footnote)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .padding(3)
                    .help("Remove")
                }
        } else {
            HStack(spacing: 6) {
                Image(systemName: attachment.kind == .pdf ? "doc.richtext" : "doc.text")
                    .foregroundStyle(.secondary)
                Text(attachment.displayName)
                    .scaledFont(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 160)
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help("Remove")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }
}

/// One chat bubble. Assistant bubbles split `<think>` reasoning into a
/// collapsible section above the answer.
private struct MessageBubble: View {
    let message: ChatMessage
    let isStreaming: Bool
    let onCopy: () -> Void
    let onRegenerate: () -> Void
    @Environment(ImageZoomModel.self) private var imageZoom: ImageZoomModel?
    @State private var showReasoning = false
    @State private var showStats = false
    @State private var copied = false

    private var split: ThinkingSplit { ThinkingParser.split(message.content) }

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 60)
                VStack(alignment: .trailing, spacing: 6) {
                    if let paths = message.attachmentPaths, !paths.isEmpty {
                        userAttachments(paths)
                    }
                    if !message.content.isEmpty {
                        Text(message.content)
                            .textSelection(.enabled)
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .foregroundStyle(.white)
                    }
                }
            }
        } else {
            assistantBubble
        }
    }

    /// Sent attachments: image thumbnails (tap to enlarge) and file chips.
    private func userAttachments(_ paths: [String]) -> some View {
        HStack(spacing: 6) {
            ForEach(paths, id: \.self) { path in
                let url = URL(fileURLWithPath: path)
                if ComposerAttachment.fromPath(path)?.kind == .image,
                   let image = NSImage(contentsOf: url) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 96, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .contentShape(Rectangle())
                        .onTapGesture { imageZoom?.show(url) }
                        .pointingHandCursor()
                } else {
                    HStack(spacing: 5) {
                        Image(systemName: "doc.text")
                        Text(url.lastPathComponent)
                            .scaledFont(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 180)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.quaternary, in: Capsule())
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var assistantBubble: some View {
        let split = self.split
        return HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                if let modelName = message.modelName {
                    Text(modelName)
                        .scaledFont(.caption, design: .monospaced)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if split.thinking != nil || split.isThinking {
                    reasoningSection(split)
                }
                if !split.answer.isEmpty {
                    // Flat, no bubble — only user messages get a bubble.
                    MarkdownText(text: split.answer)
                        .padding(.vertical, 2)
                } else if message.content.isEmpty, isStreaming {
                    ProgressView().controlSize(.small)
                } else if !isStreaming {
                    // Stream ended without a visible answer (cancelled, error, or
                    // cut off mid-reasoning) — say so instead of spinning forever.
                    Text("No answer — the reply was interrupted. Try Regenerate.")
                        .scaledFont(.callout)
                        .foregroundStyle(.secondary)
                }
                if !isStreaming {
                    actions(hasAnswer: !split.answer.isEmpty)
                }
            }
            Spacer(minLength: 40)
        }
        .onAppear { showReasoning = split.isThinking && isStreaming }
        .onChange(of: split.isThinking) { _, thinking in
            withAnimation(.easeInOut(duration: 0.2)) { showReasoning = thinking && isStreaming }
        }
    }

    private func reasoningSection(_ split: ThinkingSplit) -> some View {
        DisclosureGroup(isExpanded: $showReasoning) {
            Text(split.thinking ?? "")
                .scaledFont(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(spacing: 6) {
                if split.isThinking, isStreaming {
                    // Only spin while tokens are actually flowing.
                    ProgressView().controlSize(.mini)
                    Text("Thinking…")
                } else if let seconds = message.thinkingSeconds {
                    Text(String(format: "Thought for %.2f seconds", seconds))
                } else if split.isThinking {
                    Text("Reasoning (interrupted)")
                } else {
                    Text("Reasoning")
                }
            }
            .scaledFont(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func actions(hasAnswer: Bool) -> some View {
        HStack(spacing: 14) {
            if let stats = statsSummary {
                Image(systemName: "stopwatch")
                    .onHover { hovering in
                        withAnimation(.easeOut(duration: 0.12)) { showStats = hovering }
                    }
                    .overlay(alignment: .topLeading) {
                        // Instant on hover — the system .help() tooltip takes
                        // over a second to appear. Shown below the icon.
                        if showStats {
                            Text(stats)
                                .scaledFont(.caption, monospacedDigit: true)
                                .fixedSize()
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(.quaternary, lineWidth: 1))
                                .offset(y: 24)
                                .allowsHitTesting(false)
                                .transition(.opacity)
                        }
                    }
            }
            if hasAnswer {
                Button {
                    onCopy()
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .help("Copy")
            }
            Button(action: onRegenerate) { Image(systemName: "arrow.clockwise") }.help("Regenerate")
        }
        .buttonStyle(.plain)
        .scaledFont(.callout)
        .foregroundStyle(.secondary)
        .padding(.leading, 4)
        .padding(.top, 2)
    }

    /// "38.5 tok/s · 379 tokens (total 391)" — hover text for the stopwatch icon,
    /// from server-reported counts and the measured stream duration.
    private var statsSummary: String? {
        guard let tokens = message.completionTokens else { return nil }
        var parts: [String] = []
        if let seconds = message.generationSeconds, seconds > 0 {
            parts.append(String(format: "%.1f tok/s", Double(tokens) / seconds))
        }
        parts.append("\(tokens) tokens")
        if let total = message.totalTokens {
            parts.append("(total \(total))")
        }
        return parts.joined(separator: " · ")
    }
}
