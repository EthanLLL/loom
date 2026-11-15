import SwiftUI

/// The page under the app's Liquid Glass, as Slack does it: the web view fills
/// the screen, and the conversation's top bar, the sidebar's head and its
/// new-chat button float over it, placed where the page says its cards are.
/// The pane switches are the toolbar: in the Duo's vertical bar, at its foot,
/// or on a screen without one, at the bottom, centred.
struct Shell: View {
    let onAddress: (String) -> Void
    @State private var page: LoomPage

    /// `url` nil asks for the address first.
    init(url: URL?, onAddress: @escaping (String) -> Void) {
        self.onAddress = onAddress
        _page = State(initialValue: LoomPage(url: url, onAddress: onAddress))
    }

    var body: some View {
        NavigationStack {
            Chrome(page: page, onAddress: onAddress)
                .toolbar(.hidden, for: .navigationBar)
                .toolbarBackgroundVisibility(.hidden, for: .bottomBar)
        }
        .preferredColorScheme(page.dark ? .dark : .light)
        .sheet(item: $page.saved) { shared in
            ShareSheet(items: shared.items)
        }
    }
}

/// Inside the navigation stack, where the vertical bar's edge is known.
private struct Chrome: View {
    let page: LoomPage
    let onAddress: (String) -> Void
    @Environment(\.toolbarVerticalEdge) private var verticalEdge
    @State private var renaming = false
    @State private var draft = ""
    /// The top of the safe area, and the room the system keeps at the top
    /// trailing corner: on the Duo in portrait, its status bar's own glass.
    @State private var safeTop: CGFloat = 0
    @State private var statusCorner: CGSize = .zero

    /// The edges the page runs under: all of them, but for the vertical bar,
    /// which holds the buttons. With the status bar at the top (a tall
    /// screen) the top bar shares its row, as Slack's does.
    private var edges: Edge.Set {
        verticalEdge == .trailing ? [.top, .bottom, .leading] : verticalEdge == .leading ? [.top, .bottom, .trailing] : .all
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            page.background.ignoresSafeArea()
            LoomWebView(page: page)
                .ignoresSafeArea(.container, edges: edges)
            if page.home != nil {
                GeometryReader { proxy in
                    // No morphing between neighbours: each piece of glass keeps its shape.
                    GlassEffectContainer(spacing: 0) {
                        ZStack(alignment: .topLeading) {
                            if let sidebar = page.sidebar { sidebarGlass(sidebar) }
                            if let card = page.card { topBar(card) }
                        }
                    }
                }
                .ignoresSafeArea(.container, edges: edges)
            }
        }
        // How much of the page the bottom toolbar covers, for its padding;
        // the vertical bar covers none of it.
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onChange(of: proxy.safeAreaInsets.top, initial: true) { _, top in safeTop = top }
                    .onChange(of: proxy.containerCornerInsets.topTrailing, initial: true) { _, corner in
                        statusCorner = corner.width < proxy.size.width / 2 ? corner : .zero
                    }
                    .onChange(of: [rowTop, verticalEdge == nil ? proxy.safeAreaInsets.bottom : 0,
                                   floatingStatus ? statusCorner.height : 0], initial: true) {
                        _, inset in page.setInsets(top: inset[0] + Self.barHeight + Self.margin, bottom: inset[1], status: inset[2])
                    }
            }
            .ignoresSafeArea(.keyboard)
        }
        .toolbar { if page.home != nil { toolbar } }
        .alert("Rename", isPresented: $renaming) {
            TextField("Name", text: $draft)
            Button("Rename") { page.press("rename", draft) }
            Button("Cancel", role: .cancel) {}
        }
    }

    static let barHeight: CGFloat = 48
    static let margin: CGFloat = 8

    // ── Where the glass goes ──────────────────────────────────────────────

    /// With a vertical bar the status bar is in it. Without one it is a strip
    /// across the top, which the row goes under, or on the Duo its own glass
    /// in the top trailing corner, which the row lines up with and stops
    /// short of, as Slack's does.
    private var floatingStatus: Bool { verticalEdge == nil && statusCorner.width > 0 }

    /// The top of the glass row, from the top of the screen.
    private var rowTop: CGFloat {
        verticalEdge != nil ? Self.margin : floatingStatus ? Self.statusMiddle - Self.barHeight / 2 : safeTop
    }

    /// The leading inset of glass that starts at `x`: at the screen's
    /// leading edge, far enough in that a circle clears the corner's curve,
    /// which is also the status bar's gap from the trailing edge.
    private func lead(_ x: CGFloat) -> CGFloat {
        x < 1 ? Self.cornerInset : Self.margin
    }

    /// The middle of the Duo's floating status bar from the top, measured
    /// from a screenshot: the system reports only the corner it keeps.
    static let statusMiddle: CGFloat = 48
    /// For a corner radius of 59 pt, the Duo's: 6 pt clear of the curve.
    static let cornerInset: CGFloat = 24

    // ── Over the chat card: the sidebar's switch and the conversation ─────

    @ViewBuilder private func topBar(_ card: CGRect) -> some View {
        HStack(spacing: 10) {
            Button("Sidebar", systemImage: "sidebar.left") { page.press("sidebar") }
                .labelStyle(.iconOnly)
                .font(.system(size: 19))
                .frame(width: Self.barHeight, height: Self.barHeight)
                .glassEffect(.regular.interactive(), in: .circle)
            if let chat = page.chat {
                VStack(alignment: .leading, spacing: 1) {
                    Text(chat.title).font(.headline).lineLimit(1)
                    HStack(spacing: 5) {
                        Circle().fill(chat.dot).frame(width: 7, height: 7)
                        Text("\(chat.engine) · \(chat.label)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, minHeight: Self.barHeight, maxHeight: Self.barHeight, alignment: .leading)
                .contentShape(.capsule)
                .glassEffect(.regular.interactive(), in: .capsule)
                .onLongPressGesture {
                    draft = chat.title
                    renaming = true
                }
            } else {
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .padding(.top, rowTop)
        .padding(.leading, lead(card.minX))
        .padding(.trailing, floatingStatus ? statusCorner.width : Self.margin)
        .frame(width: card.width)
        .offset(x: card.minX, y: card.minY)
    }

    // ── Over the sidebar: its name and search, and a new chat at the foot ──

    @ViewBuilder private func sidebarGlass(_ sidebar: CGRect) -> some View {
        HStack {
            Menu {
                Button("Reload", systemImage: "arrow.clockwise") { page.reload() }
                Button("Change Loom", systemImage: "server.rack") { onAddress("") }
            } label: {
                Image("Logo").resizable().scaledToFill()
                    .frame(width: 38, height: 38)
                    .clipShape(.circle)
                    .frame(width: Self.barHeight, height: Self.barHeight)
            }
            .accessibilityLabel("Loom")
            .glassEffect(.regular.interactive(), in: .circle)
            Spacer()
            Button("Search", systemImage: "magnifyingglass") { page.press("search") }
                .labelStyle(.iconOnly)
                .font(.system(size: 19))
                .frame(width: Self.barHeight, height: Self.barHeight)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(.plain)
        .padding(.top, rowTop)
        .padding(.leading, lead(sidebar.minX))
        .padding(.trailing, Self.margin)
        .frame(width: sidebar.width)
        .offset(x: sidebar.minX, y: sidebar.minY)

        Menu {
            Button("Claude Code") { page.press("new", "claude_code") }
            Button("Codex") { page.press("new", "codex") }
            Button("Kiro") { page.press("new", "kiro") }
        } label: {
            Image(systemName: "plus").font(.system(size: 22, weight: .medium))
                .frame(width: 56, height: 56)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .offset(x: sidebar.maxX - 56 - 16, y: sidebar.maxY - 56 - 16)
    }

    // ── The pane switches ─────────────────────────────────────────────────

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarSpacer(.flexible, placement: .bottomBar)
        pane("terminal", "Terminals", "apple.terminal", badge: page.terminals)
        pane("canvas", "Canvas", "paintbrush")
        pane("apps", "Apps", "square.grid.2x2")
        pane("browser", "Browser", "globe")
        ToolbarItem(placement: .bottomBar) {
            Button("Settings", systemImage: "gearshape") { page.press("settings") }
        }
        .axisBehavior(.verticalPreferred)
        // Centred at the bottom; at the foot of the vertical bar.
        if verticalEdge == nil { ToolbarSpacer(.flexible, placement: .bottomBar) }
    }

    /// A switch for one of the right-hand column's panes, on a grey disc
    /// while it is the one open, as Slack marks the current tab.
    private func pane(_ action: String, _ title: LocalizedStringKey, _ symbol: String, badge: Int = 0) -> some ToolbarContent {
        ToolbarItem(placement: .bottomBar) {
            Button { page.press(action) } label: {
                Label(title, systemImage: symbol)
                    .labelStyle(.iconOnly)
                    .frame(width: 40, height: 40)
                    .background(page.side == action ? Color.primary.opacity(0.16) : .clear, in: .circle)
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
