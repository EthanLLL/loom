import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The message box, native: the system's keyboard, dictation and text
/// handling, and a photo picker, under glass. The page's composer
/// (chat/Composer.tsx) is the model: attachments above the text, attach on
/// the left, the model, stop and send on the right. What it sends goes
/// through the page (ios/Composer.tsx), which uploads attachments into its own
/// tray and submits over its channel; the draft is kept here, per session.
struct Composer: View {
    @Bindable var loom: Loom
    @State private var text = ""
    @State private var picking = false
    @State private var importing = false
    @State private var photos: [PhotosPickerItem] = []
    @FocusState private var focused: Bool

    /// What a message can be instead of a prompt; see chat/Composer.tsx.
    private static let commands: [(String, LocalizedStringKey)] = [
        ("/compact", "summarize the conversation to free up context"),
        ("/reload", "reload Claude Code, Codex and Kiro config: settings, MCP, skills"),
        ("/cron", "list every scheduled job"),
    ]

    var body: some View {
        if let chat = loom.chat {
            VStack(alignment: .leading, spacing: 8) {
                if !matches.isEmpty { commandList }
                if !chat.attachments.isEmpty { tray(chat.attachments) }
                HStack(alignment: .bottom, spacing: 8) {
                    attachMenu
                    TextField(hint(chat), text: $text, axis: .vertical)
                        .lineLimit(1...6)
                        .focused($focused)
                        .padding(.vertical, 9)
                    modelMenu(chat)
                    sendButton(chat)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            .onAppear { text = draft(chat.id) }
            .onChange(of: chat.id) { old, new in
                keep(old, text)
                text = draft(new)
            }
            .onChange(of: text) { _, now in keep(chat.id, now) }
            .photosPicker(isPresented: $picking, selection: $photos, maxSelectionCount: 10, matching: .any(of: [.images, .videos]))
            .onChange(of: photos) { _, items in
                photos = []
                for item in items { Task { await attach(item) } }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                for url in (try? result.get()) ?? [] { attach(file: url) }
            }
        }
    }

    // ── Pieces ───────────────────────────────────────────────────────────

    private func hint(_ chat: ChatState) -> LocalizedStringKey {
        chat.busy ? "Steer the agent mid-turn…" : chat.status == "interrupted" ? "Stopped — type to continue" : "Message the agent…"
    }

    private var matches: [(String, LocalizedStringKey)] {
        guard text.hasPrefix("/"), !text.contains(where: \.isWhitespace) else { return [] }
        return Self.commands.filter { $0.0.hasPrefix(text) && $0.0 != text }
    }

    private var commandList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(matches, id: \.0) { name, hint in
                Button { text = name } label: {
                    HStack {
                        Text(name).font(.body.monospaced())
                        Text(hint).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
    }

    private func tray(_ items: [Pending]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(items) { item in
                    HStack(spacing: 6) {
                        if item.uploading {
                            ProgressView().controlSize(.mini)
                        } else if item.error != nil {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        } else {
                            Image(systemName: "paperclip")
                        }
                        Text(item.name).lineLimit(1).frame(maxWidth: 160)
                        Button("Remove", systemImage: "xmark") { loom.send("unattach", item.id) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                    .font(.footnote)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.quaternary, in: .capsule)
                }
            }
            .padding(.horizontal, 4)
        }
        .scrollIndicators(.hidden)
    }

    private var attachMenu: some View {
        Menu {
            Button("Photos", systemImage: "photo.on.rectangle") { picking = true }
            Button("Files", systemImage: "folder") { importing = true }
            if UIPasteboard.general.hasImages {
                Button("Paste image", systemImage: "doc.on.clipboard") { pasteImages() }
            }
        } label: {
            Image(systemName: "plus").font(.system(size: 18, weight: .medium))
                .frame(width: 36, height: 36)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Attach")
    }

    @ViewBuilder private func modelMenu(_ chat: ChatState) -> some View {
        if let current = chat.currentModel {
            Menu {
                Picker("Model", selection: Binding(get: { current.id }, set: { loom.send("model", $0) })) {
                    ForEach(chat.models) { Text($0.label).tag($0.id) }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(current.label).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(height: 36)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder private func sendButton(_ chat: ChatState) -> some View {
        let ready = chat.attachments.contains { !$0.uploading && $0.error == nil }
        let uploading = chat.attachments.contains(where: \.uploading)
        let sendable = (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ready) && !uploading
        if chat.busy && !sendable {
            Button("Stop", systemImage: "stop.fill") { loom.send("interrupt") }
                .labelStyle(.iconOnly)
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .tint(.red)
        } else {
            Button("Send", systemImage: "arrow.up") { send(chat) }
                .labelStyle(.iconOnly)
                .fontWeight(.semibold)
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .disabled(!sendable)
                .keyboardShortcut(.return, modifiers: .command)
        }
    }

    // ── Doing ────────────────────────────────────────────────────────────

    private func send(_ chat: ChatState) {
        loom.send("submit", ["session": chat.id, "text": text])
        text = ""
    }

    private func attach(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        let type = item.supportedContentTypes.first ?? .data
        let name = "photo-\(Int(Date().timeIntervalSince1970)).\(type.preferredFilenameExtension ?? "bin")"
        send(data, name: name, type: type.preferredMIMEType ?? "application/octet-stream")
    }

    private func attach(file url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        send(data, name: url.lastPathComponent, type: type)
    }

    private func pasteImages() {
        for (i, image) in (UIPasteboard.general.images ?? []).enumerated() {
            guard let data = image.pngData() else { continue }
            send(data, name: "pasted-\(Int(Date().timeIntervalSince1970))-\(i).png", type: "image/png")
        }
    }

    /// Into the page's tray, which uploads it at once (useAttachments.ts).
    private func send(_ data: Data, name: String, type: String) {
        loom.send("attach", ["name": name, "type": type, "data": data.base64EncodedString()])
    }

    private func draft(_ id: String) -> String {
        UserDefaults.standard.string(forKey: "draft:\(id)") ?? ""
    }

    private func keep(_ id: String, _ text: String) {
        if text.isEmpty { UserDefaults.standard.removeObject(forKey: "draft:\(id)") }
        else { UserDefaults.standard.set(text, forKey: "draft:\(id)") }
    }
}
