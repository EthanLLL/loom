import SwiftUI
import WebKit

/// One of the Loom's web views, under the app's glass. It runs under the bars
/// at the top and bottom, and WebKit is told how much of it they cover
/// (`obscuredContentInsets`, iOS 26): the page's viewport, its fixed elements
/// and the end of its scrolling all keep clear of them, while what scrolls
/// still shows through. SwiftUI's safe area does not reach a web view, so
/// `env(safe-area-inset-*)` is no help here; this is what takes its place.
struct WebPane: View {
    let view: WKWebView
    /// Under the bar at the top too. Only a page that scrolls as a document
    /// (the conversation) is laid out clear of it by WebKit; one sized to the
    /// window (the canvas, the browser) would start under it.
    var underTop = true

    var body: some View {
        Representable(view: view)
            .ignoresSafeArea(edges: underTop ? .vertical : .bottom)
            .background {
                // The safe area as the bars and the keyboard leave it, read
                // in the frame that runs under all of them. (A reader that
                // ignores the safe area itself is told it has none.)
                GeometryReader { proxy in
                    Color.clear.onChange(of: proxy.safeAreaInsets, initial: true) { _, insets in
                        let covered = UIEdgeInsets(top: insets.top, left: 0, bottom: insets.bottom, right: 0)
                        if view.obscuredContentInsets != covered { view.obscuredContentInsets = covered }
                        // The covered foot still has to be scrolled past: WebKit
                        // takes the top off the scrolling range but not the foot.
                        let foot = UIEdgeInsets(top: 0, left: 0, bottom: insets.bottom, right: 0)
                        if view.scrollView.contentInset != foot {
                            view.scrollView.contentInset = foot
                            view.scrollView.verticalScrollIndicatorInsets = covered
                        }
                    }
                }
            }
    }

    private struct Representable: UIViewRepresentable {
        let view: WKWebView
        func makeUIView(context: Context) -> WKWebView { view }
        func updateUIView(_ view: WKWebView, context: Context) {}
    }
}

/// A web view of its own, for one app: on the apps' origin, with its cookies.
struct AppPage: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        let view = WKWebView(frame: .zero, configuration: config)
        view.isInspectable = true
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        if view.url == nil { view.load(URLRequest(url: url)) }
    }
}
