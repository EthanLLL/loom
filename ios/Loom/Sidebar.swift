import SwiftUI

/// The session list, as the page's sidebar has it (Sidebar.tsx): the
/// directories in the order dragged into, each folded or not on this device,
/// then Recents, what is in none; newest first within each. The lobby comes
/// from the page, and every change goes back through it.
struct Sidebar: View {
    @Bindable var loom: Loom
    @Binding var selection: String?
    let onAddress: (String) -> Void
    @AppStorage("foldedDirectories") private var foldedJSON = "[]"
    @State private var renaming: SessionRow?
    @State private var draft = ""
    @State private var deleting: SessionRow?
    @State private var moving: SessionRow?

    var body: some View {
        List(selection: $selection) {
            ForEach(loom.directories, id: \.self) { dir in
                Section(isExpanded: expanded(dir)) {
                    ForEach(loom.sessions.filter { $0.directory == dir }) { row($0) }
                } header: {
                    Label(dir, systemImage: "folder")
                }
            }
            Section("Recents") {
                ForEach(loom.sessions.filter { !loom.directories.contains($0.directory) }) { row($0) }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Loom")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button("Settings", systemImage: "gearshape") { showPage("settings") }
                    Button("Reload", systemImage: "arrow.clockwise") { loom.reload() }
                    Button("Change Loom", systemImage: "server.rack") { onAddress("") }
                } label: {
                    Image("Logo").resizable().scaledToFill()
                        .frame(width: 30, height: 30)
                        .clipShape(.circle)
                }
                .accessibilityLabel("Loom")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Search", systemImage: "magnifyingglass") { showPage("search") }
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Menu {
                    ForEach(Backend.all, id: \.self) { backend in
                        Button(Backend.name(backend)) { loom.send("create", backend) }
                    }
                } label: {
                    Label("New session", systemImage: "square.and.pencil")
                }
            }
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $draft)
            Button("Rename") {
                if let s = renaming { loom.send("rename", ["id": s.id, "title": draft]) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            deleting.map { String(localized: "Delete \($0.title)?") } ?? "",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let s = deleting { loom.send("delete", s.id) }
            }
        } message: {
            Text("The session and its whole history, with what it made. This cannot be undone.")
        }
        .sheet(item: $moving) { s in MovePicker(loom: loom, id: s.id) }
    }

    /// Search and settings are pages in the main web view: on one column it
    /// has to be shown first.
    private func showPage(_ action: String) {
        if selection == nil { selection = loom.activeId }
        loom.send(action)
    }

    private func row(_ s: SessionRow) -> some View {
        HStack(spacing: 10) {
            BackendBadge(backend: s.backend)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.title).lineLimit(1)
                    .foregroundStyle(s.working ? .secondary : .primary)
                HStack(spacing: 4) {
                    Text(s.active, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                    if s.queued > 0 { Text("· \(s.queued) queued") }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if s.working {
                ProgressView().controlSize(.small)
            }
        }
        .tag(s.id)
        .contextMenu {
            Button("Rename", systemImage: "pencil") {
                draft = s.title
                renaming = s
            }
            Button("Move to…", systemImage: "folder") { moving = s }
            Button("Delete", systemImage: "trash", role: .destructive) { deleting = s }
        }
        .swipeActions {
            Button("Delete", systemImage: "trash", role: .destructive) { deleting = s }
            Button("Rename", systemImage: "pencil") {
                draft = s.title
                renaming = s
            }
        }
    }

    private func expanded(_ dir: String) -> Binding<Bool> {
        Binding(
            get: { !folded.contains(dir) },
            set: { open in
                var set = folded
                if open { set.remove(dir) } else { set.insert(dir) }
                foldedJSON = (try? String(data: JSONEncoder().encode(Array(set)), encoding: .utf8)) ?? "[]"
            }
        )
    }

    private var folded: Set<String> {
        Set((try? JSONDecoder().decode([String].self, from: Data(foldedJSON.utf8))) ?? [])
    }
}

/// The engine a session runs on, as a small tile.
struct BackendBadge: View {
    let backend: String

    var body: some View {
        let (letter, color): (String, Color) = switch backend {
        case "codex": ("X", .blue)
        case "kiro": ("K", .purple)
        default: ("C", .orange)
        }
        Text(letter).font(.caption.weight(.bold)).foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(color.gradient, in: .rect(cornerRadius: 6))
    }
}

/// Where to file a session: a directory there is, a new one, or none.
struct MovePicker: View {
    let loom: Loom
    let id: String
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("New directory", text: $name)
                        .submitLabel(.done)
                        .onSubmit { move(to: name) }
                }
                Section {
                    ForEach(loom.directories, id: \.self) { dir in
                        Button { move(to: dir) } label: { Label(dir, systemImage: "folder") }
                    }
                    Button { move(to: "") } label: { Label("Recents", systemImage: "clock") }
                }
            }
            .navigationTitle("Move to…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", role: .cancel) { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// One level deep, as the page keeps them (`dirName`).
    private func move(to dir: String) {
        let clean = dir.replacingOccurrences(of: "/", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        loom.send("move", ["id": id, "directory": clean])
        dismiss()
    }
}
