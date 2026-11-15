import SwiftUI
import WebKit

/// The right-hand column: a glass bar of the pane's own — its title, a menu
/// where there is a choice, and its buttons in capsules — over what it shows.
/// The terminals are SwiftTerm (Terminal.swift), the apps a native grid with
/// each app in a web view of its own, and the canvas and the browser the pane
/// web view (ios/Pane.tsx), whose bar buttons go to it as actions.
struct PaneColumn: View {
    @Bindable var loom: Loom
    @State private var app: AppTile?

    var body: some View {
        let side = loom.side ?? .terminal
        content(side)
            .safeAreaBar(edge: .top) {
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        title(side)
                        Spacer(minLength: 0)
                        buttons(side)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .background(loom.background.ignoresSafeArea())
    }

    @ViewBuilder private func content(_ side: Side) -> some View {
        switch side {
        case .terminal:
            if let id = loom.terminal {
                TerminalScreen(loom: loom, id: id).id(id)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .canvas, .browser:
            WebPane(view: loom.paneView, underTop: false)
        case .apps:
            if let app {
                AppPage(url: app.url).id(app.id)
            } else {
                AppsGrid(apps: loom.apps) { app = $0 }
            }
        }
    }

    // ── The bar ──────────────────────────────────────────────────────────

    @ViewBuilder private func title(_ side: Side) -> some View {
        switch side {
        case .terminal:
            Menu {
                ForEach(Array(loom.terminals.enumerated()), id: \.element) { index, id in
                    Button { loom.terminal = id } label: {
                        Label("Terminal \(index + 1)", systemImage: id == loom.terminal ? "checkmark" : "apple.terminal")
                    }
                }
            } label: {
                capsuleTitle(terminalTitle, menu: loom.terminals.count > 1)
            }
            .buttonStyle(.plain)
        case .canvas:
            capsuleTitle(LocalizedStringKey(loom.pane.kind == "canvas" && !loom.pane.title.isEmpty ? loom.pane.title : "Canvas"))
        case .apps:
            HStack(spacing: 8) {
                if app != nil {
                    circle("chevron.left", "Back to apps") { app = nil }
                }
                capsuleTitle(LocalizedStringKey(app?.title ?? "Apps"))
            }
        case .browser:
            capsuleTitle(loom.pane.state == "connecting" ? "Connecting…" : loom.pane.state == "closed" ? "Disconnected" : "Browser")
        }
    }

    private var terminalTitle: LocalizedStringKey {
        let index = loom.terminal.flatMap { loom.terminals.firstIndex(of: $0) } ?? 0
        return "Terminal \(index + 1)"
    }

    @ViewBuilder private func buttons(_ side: Side) -> some View {
        switch side {
        case .terminal:
            group([("plus", "New terminal", { loom.send("terminal-new") }),
                   ("xmark", "Close this terminal", { if let id = loom.terminal { loom.send("terminal-close", id) } })])
        case .canvas:
            group([("sidebar.left", "All files in this session", { loom.sendPane("canvas-tree") })])
            if loom.pane.item {
                group([("arrow.clockwise", "Reload", { loom.sendPane("canvas-reload") }),
                       ("square.and.arrow.down", "Download", { loom.sendPane("canvas-download") })])
            }
        case .apps:
            if let app {
                group([("safari", "Open in Safari", { UIApplication.shared.open(app.url) })])
            }
        case .browser:
            group([("keyboard", "Type text into the page", { loom.sendPane("browser-keyboard") }),
                   (loom.pane.fit ? "plus.magnifyingglass" : "arrow.down.right.and.arrow.up.left",
                    "Fit", { loom.sendPane("browser-fit") })])
            if loom.pane.state == "closed" {
                group([("arrow.clockwise", "Connect again", { loom.sendPane("browser-reconnect") })])
            }
        }
    }

    private func capsuleTitle(_ title: LocalizedStringKey, menu: Bool = false) -> some View {
        HStack(spacing: 5) {
            Text(title).font(.headline).lineLimit(1)
            if menu {
                Image(systemName: "chevron.down").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    private func circle(_ symbol: String, _ label: LocalizedStringKey, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol).font(.system(size: 17)).frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .glassEffect(.regular.interactive(), in: .circle)
    }

    /// Buttons that belong together share one capsule of glass.
    private func group(_ items: [(String, LocalizedStringKey, () -> Void)]) -> some View {
        HStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { i in
                Button(action: items[i].2) {
                    Image(systemName: items[i].0).font(.system(size: 17)).frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(items[i].1)
            }
        }
        .padding(.horizontal, 2)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}

/// The apps as a home screen, in the user's order.
private struct AppsGrid: View {
    let apps: [AppTile]
    let open: (AppTile) -> Void

    var body: some View {
        ScrollView {
            if apps.isEmpty {
                Text("No apps yet. Ask an agent to make one.")
                    .foregroundStyle(.secondary)
                    .padding(.top, 40)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 14)], spacing: 22) {
                ForEach(apps) { app in
                    Button { open(app) } label: {
                        VStack(spacing: 8) {
                            icon(app)
                                .frame(width: 64, height: 64)
                                .clipShape(.rect(cornerRadius: 15))
                            Text(app.title).font(.footnote).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
        }
    }

    /// The app's favicon. Most are SVG, which UIImage cannot read, so those
    /// are drawn by a web view of their own, the size of the tile.
    @ViewBuilder private func icon(_ app: AppTile) -> some View {
        if let url = app.icon, url.pathExtension.lowercased() == "svg" {
            SVGIcon(url: url)
        } else if let url = app.icon {
            AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.2) }
        } else {
            Text(app.title.prefix(1).uppercased()).font(.title)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.quaternary)
        }
    }
}

private struct SVGIcon: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.isUserInteractionEnabled = false
        let src = url.absoluteString.replacingOccurrences(of: "\"", with: "&quot;")
        view.loadHTMLString("""
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>html,body{margin:0;height:100%;background:transparent}img{width:100%;height:100%;object-fit:cover;display:block}</style>
        <img src="\(src)">
        """, baseURL: nil)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}
}
