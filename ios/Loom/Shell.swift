import SwiftUI

/// The app: SwiftUI's split view with Liquid Glass throughout. The session
/// list is native (Sidebar.swift); the conversation is the main web view
/// under the system's bar and the native composer (Composer.swift); the
/// right-hand column is an inspector with a glass bar of its own over a
/// terminal, the apps, or the pane web view (Panes.swift). Until the page is
/// signed in, it has the screen to itself.
struct Shell: View {
    let onAddress: (String) -> Void
    @State private var loom: Loom

    /// `url` nil asks for the address first.
    init(url: URL?, onAddress: @escaping (String) -> Void) {
        self.onAddress = onAddress
        _loom = State(initialValue: Loom(url: url, onAddress: onAddress))
    }

    var body: some View {
        Group {
            if loom.authed {
                Split(loom: loom, onAddress: onAddress)
            } else {
                WebPane(view: loom.main)
                    .background(loom.background.ignoresSafeArea())
            }
        }
        .preferredColorScheme(loom.dark ? .dark : .light)
        .sheet(item: $loom.saved) { shared in
            ShareSheet(items: shared.items)
        }
        #if DEBUG
        .onAppear(perform: debugLaunch)
        #endif
    }

    #if DEBUG
    /// `-loomOrient landscape|portrait` at launch turns the simulator, for
    /// screenshots of both; `-loomEval <js>` runs in the main page a few
    /// seconds in and prints what it returns, for checking from a shell.
    private func debugLaunch() {
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        if let js = arguments["loomEval"] as? String {
            for delay in [6.0, 10.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [loom] in
                    loom.main.evaluateJavaScript(js) { result, error in print("loomEval:", result ?? error ?? "nil") }
                }
            }
        }
        Self.turn()
    }

    private static func turn() {
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        guard let orient = arguments["loomOrient"] as? String,
              let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: orient == "portrait" ? .portrait : .landscapeRight))
        }
    }
    #endif
}

private struct Split: View {
    @Bindable var loom: Loom
    let onAddress: (String) -> Void
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// The list's selection, which is also what shows the conversation when
    /// the split view is one column (the Duo folded): nil is the list.
    @State private var selection: String?

    var body: some View {
        NavigationSplitView {
            Sidebar(loom: loom, selection: $selection, onAddress: onAddress)
        } detail: {
            ChatScreen(loom: loom)
                // A column beside the conversation where there is room. The
                // inspector says it closed when a turn moves it between
                // column and sheet, which would close the pane, so only the
                // buttons close it.
                .inspector(isPresented: Binding(get: { loom.side != nil && sizeClass != .compact }, set: { _ in })) {
                    PaneColumn(loom: loom)
                        .inspectorColumnWidth(min: 320, ideal: 420, max: 640)
                }
                // On one column (the Duo folded) a sheet over it instead,
                // which a swipe closes.
                .sheet(isPresented: Binding(
                    get: { loom.side != nil && sizeClass == .compact },
                    set: { open in if !open { loom.side = nil } }
                )) {
                    PaneColumn(loom: loom)
                        .presentationDetents([.large, .medium])
                        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                }
        }
        .onAppear { selection = loom.activeId }
        #if DEBUG
        // `-loomOpen YES` opens the conversation on one column, and
        // `-loomSide terminal|canvas|apps|browser` a pane, for screenshots.
        .task {
            let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            for _ in 0..<20 where loom.activeId == nil { try? await Task.sleep(for: .seconds(0.5)) }
            if arguments["loomOpen"] != nil { selection = loom.activeId }
            if let side = (arguments["loomSide"] as? String).flatMap(Side.init(rawValue:)) { loom.side = side }
        }
        #endif
        .onChange(of: selection) { _, id in if let id { loom.select(id) } }
        .onChange(of: loom.activeId) { _, id in if selection != nil, id != selection { selection = id } }
    }
}

/// The conversation: the page's transcript under the system's bar, the
/// composer at the foot, and the pane switches in the toolbar — the Duo's
/// vertical bar where it has one, else centred along the bottom.
private struct ChatScreen: View {
    @Bindable var loom: Loom
    @State private var renaming = false
    @State private var draft = ""
    @State private var deleting = false
    @State private var moving = false

    var body: some View {
        WebPane(view: loom.main)
            .background(loom.background.ignoresSafeArea())
            .navigationTitle(loom.chat?.title ?? "Loom")
            .navigationSubtitle(subtitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarTitleMenu {
                if let chat = loom.chat {
                    Button("Rename", systemImage: "pencil") {
                        draft = chat.title
                        renaming = true
                    }
                    Button("Move to…", systemImage: "folder") { moving = true }
                    Button("Delete", systemImage: "trash", role: .destructive) { deleting = true }
                }
            }
            .safeAreaBar(edge: .bottom) {
                if loom.chat != nil { Composer(loom: loom) }
            }
            .toolbar { panes }
            .alert("Rename", isPresented: $renaming) {
                TextField("Name", text: $draft)
                Button("Rename") {
                    if let id = loom.chat?.id { loom.send("rename", ["id": id, "title": draft]) }
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Delete this session?", isPresented: $deleting, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let id = loom.chat?.id { loom.send("delete", id) }
                }
            } message: {
                Text("The session and its whole history, with what it made. This cannot be undone.")
            }
            .sheet(isPresented: $moving) {
                if let id = loom.chat?.id {
                    MovePicker(loom: loom, id: id)
                }
            }
    }

    private var subtitle: String {
        guard let chat = loom.chat else { return "" }
        return "\(chat.engine) · \(String(localized: chat.labelResource))"
    }

    @ToolbarContentBuilder private var panes: some ToolbarContent {
        ToolbarSpacer(.flexible, placement: .bottomBar)
        pane(.terminal, "Terminals", "apple.terminal", badge: loom.terminals.count)
        pane(.canvas, "Canvas", "paintbrush")
        pane(.apps, "Apps", "square.grid.2x2")
        pane(.browser, "Browser", "globe")
        ToolbarSpacer(.flexible, placement: .bottomBar)
    }

    /// A switch for one of the right-hand column's panes, on a grey disc
    /// while it is the one open, as Slack marks the current tab.
    private func pane(_ side: Side, _ title: LocalizedStringKey, _ symbol: String, badge: Int = 0) -> some ToolbarContent {
        ToolbarItem(placement: .bottomBar) {
            Button { loom.side = loom.side == side ? nil : side } label: {
                Label(title, systemImage: symbol)
                    .labelStyle(.iconOnly)
                    .frame(width: 40, height: 40)
                    .background(loom.side == side ? Color.primary.opacity(0.16) : .clear, in: .circle)
                    .overlay(alignment: .topTrailing) {
                        if badge > 0 {
                            Text("\(badge)")
                                .font(.caption2.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .frame(minWidth: 16, minHeight: 16)
                                .background(.red, in: .capsule)
                                .offset(x: 4, y: -2)
                        }
                    }
            }
            // Plain, so the bar hosts this view as it is and redraws it with
            // the page: with the default style it draws the label itself and
            // drops the disc, and `.badge` waits for the bar's next refresh.
            .buttonStyle(.plain)
        }
        .axisBehavior(.verticalPreferred)
    }
}

/// A download or an image, offered to Photos, Files, AirDrop and the rest.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
