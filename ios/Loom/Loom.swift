import SwiftUI
import WebKit

/// One Loom, as the app knows it: what its pages last said, and the two web
/// views they live in. The page holds the socket, the lobby and the API
/// (`frontend/src/native.ts`); the app draws everything and asks the page to
/// do things. The main web view is one conversation (`ios/Main.tsx`), the pane
/// web view is the right-hand column's canvas or browser (`ios/Pane.tsx`).
@Observable final class Loom: NSObject {
    // ── What the main page says ──────────────────────────────────────────
    /// Signed in and the lobby loaded; until then the page (sign-in) has the screen.
    var authed = false
    var sessions: [SessionRow] = []
    var directories: [String] = []
    var apps: [AppTile] = []
    /// The conversation the page has open, and what its composer needs.
    var activeId: String?
    var chat: ChatState?
    var terminals: [String] = []
    var background = Color.black
    var dark = true

    // ── What the pane page says ──────────────────────────────────────────
    var pane = PaneState()

    // ── The app's own ────────────────────────────────────────────────────
    /// Which of the right-hand column's panes is open.
    var side: Side? {
        didSet { if side != oldValue { showPane() } }
    }
    /// The terminal the column shows, of `terminals`.
    var terminal: String?
    /// A finished download or a long-pressed image, offered in a share sheet.
    var saved: Shared?

    let home: URL?
    let main: WKWebView
    let paneView: WKWebView
    @ObservationIgnored private let onAddress: (String) -> Void
    @ObservationIgnored private var downloads: [ObjectIdentifier: URL] = [:]
    /// Actions for the pane page, held until it says it is up.
    @ObservationIgnored private var paneReady = false
    @ObservationIgnored private var paneQueue: [(String, Any)] = []
    /// Where each terminal's bytes go; see Terminal.swift.
    @ObservationIgnored var terminalSinks: [String: (Data) -> Void] = [:]

    init(url: URL?, onAddress: @escaping (String) -> Void) {
        home = url
        self.onAddress = onAddress
        main = Self.webView()
        paneView = Self.webView()
        super.init()
        for view in [main, paneView] {
            view.configuration.userContentController.add(self, name: "loom")
            view.uiDelegate = self
            view.navigationDelegate = self
        }

        if let url {
            main.load(URLRequest(url: Self.surface("main", of: url)))
            paneView.load(URLRequest(url: Self.surface("pane", of: url)))
        } else {
            // A web page rather than a SwiftUI field: on the Duo the field took
            // focus but never brought up the keyboard, where the web view's do.
            main.loadHTMLString(Self.addressForm, baseURL: nil)
        }
    }

    /// The page as one of the app's web views (native.ts).
    private static func surface(_ name: String, of url: URL) -> URL {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.queryItems = [URLQueryItem(name: "surface", value: name)]
        return parts?.url ?? url
    }

    private static func webView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.addUserScript(WKUserScript(
            source: imagePress, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        #if DEBUG
        // `-loomToken …` at launch signs the pages in, so the simulator can be
        // tested without typing a password and a code into it.
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        if let token = arguments["loomToken"] as? String,
           let json = try? JSONSerialization.data(withJSONObject: [token]),
           let literal = String(data: json, encoding: .utf8) {
            config.userContentController.addUserScript(WKUserScript(
                source: "localStorage.setItem('loom_token', \(literal)[0])",
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        #endif
        let view = WKWebView(frame: .zero, configuration: config)
        view.isInspectable = true
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        // WebKit is told what the glass covers instead (`obscuredContentInsets`);
        // UIKit insetting the scroll view as well would count it twice.
        view.scrollView.contentInsetAdjustmentBehavior = .never
        return view
    }

    // ── Asking the pages ─────────────────────────────────────────────────

    /// An action for the main page.
    func send(_ action: String, _ value: Any = "") {
        Self.dispatch(main, action, value)
    }

    /// An action for the pane page, once it is up.
    func sendPane(_ action: String, _ value: Any = "") {
        if paneReady { Self.dispatch(paneView, action, value) } else { paneQueue.append((action, value)) }
    }

    private static func dispatch(_ view: WKWebView, _ action: String, _ value: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: ["action": action, "value": value]),
              let detail = String(data: data, encoding: .utf8)
        else { return }
        view.evaluateJavaScript("window.dispatchEvent(new CustomEvent('loom-native', { detail: \(detail) }))")
    }

    func select(_ id: String) {
        guard id != activeId else { return }
        activeId = id
        send("select", id)
        showPane()
    }

    /// Tell the pane page what to show: the canvas or the browser, for this
    /// conversation. The terminals and the apps are the app's own.
    private func showPane() {
        let pane = side == .canvas ? "canvas" : side == .browser ? "browser" : ""
        sendPane("show", ["pane": pane, "session": activeId ?? ""])
        if side == .terminal { send("terminals") }
    }

    func reload() {
        Shells.shared.reset()
        terminalSinks = [:]
        main.reload()
        paneReady = false
        paneView.reload()
    }

    // ── Hearing from them ────────────────────────────────────────────────

    private func main(said body: [String: Any]) {
        if let address = body["address"] as? String {
            if ContentView.loom(address) != nil { onAddress(address) }
        } else if let theme = body["theme"] as? [String: Any] {
            if let css = theme["background"] as? String, let color = Self.color(css) { background = color }
            dark = theme["dark"] as? Bool ?? true
        } else if let auth = body["auth"] as? Bool {
            authed = auth
        } else if let lobby = body["lobby"] as? [String: Any] {
            sessions = (lobby["sessions"] as? [[String: Any]] ?? []).map(SessionRow.init)
            directories = lobby["directories"] as? [String] ?? []
            apps = (lobby["apps"] as? [[String: Any]] ?? []).compactMap { AppTile($0, base: home) }
            let active = lobby["active"] as? String
            if active != activeId {
                activeId = active
                showPane()
            }
        } else if let chat = body["chat"] as? [String: Any] {
            self.chat = ChatState(chat)
        } else if let canvas = body["canvas"] as? [String: Any] {
            // A link tapped in the conversation, or a page a turn just built.
            sendPane("canvas-open", canvas)
            side = .canvas
        } else if let files = body["files"] as? [String: Any] {
            sendPane("canvas-files", files)
        } else if let list = body["terminals"] as? [String] {
            terminals = list
            if terminal == nil || !list.contains(terminal!) { terminal = list.last }
            // Opening the column with nothing running starts a shell.
            if side == .terminal && list.isEmpty { send("terminal-new") }
        } else if let created = body["terminalCreated"] as? String {
            terminal = created
        } else if let output = body["terminal"] as? [String: Any], let id = output["id"] as? String {
            if let b64 = output["data"] as? String, let data = Data(base64Encoded: b64) { terminalSinks[id]?(data) }
        } else if let closed = body["terminalClosed"] as? String {
            terminalSinks[closed] = nil
            if terminal == closed { terminal = nil }
        }
    }

    private func pane(said body: [String: Any]) {
        if body["ready"] as? Bool == true {
            paneReady = true
            let queued = paneQueue
            paneQueue = []
            showPane()
            for (action, value) in queued { Self.dispatch(paneView, action, value) }
        } else if let state = body["pane"] as? [String: Any] {
            pane = PaneState(state)
        }
    }

    // ── Pieces ───────────────────────────────────────────────────────────

    /// A long press on an image shares the image. WebKit's own menu would
    /// share its address, and offers no way to change that, so its menu is
    /// turned off for images and the press is caught here instead: in every
    /// frame, canvas pages and apps included, with the bytes fetched by the
    /// frame itself, which has the cookies and the origin to read them.
    static let imagePress = """
    (() => {
      const style = document.createElement('style')
      style.textContent = 'img { -webkit-touch-callout: none }'
      document.documentElement.append(style)
      let timer = 0, x = 0, y = 0
      const cancel = () => { clearTimeout(timer); timer = 0 }
      addEventListener('touchstart', (e) => {
        cancel()
        const img = e.target instanceof Element && e.target.closest('img')
        if (!img || e.touches.length > 1) return
        x = e.touches[0].clientX; y = e.touches[0].clientY
        timer = setTimeout(async () => {
          timer = 0
          const src = img.currentSrc || img.src
          const name = decodeURIComponent(new URL(src, location.href).pathname.split('/').pop() || '')
          try {
            const blob = await (await fetch(src)).blob()
            const data = await new Promise((done, fail) => {
              const r = new FileReader(); r.onload = () => done(r.result); r.onerror = fail; r.readAsDataURL(blob)
            })
            webkit.messageHandlers.loom.postMessage({ image: { data, name } })
          } catch {
            webkit.messageHandlers.loom.postMessage({ image: { url: new URL(src, location.href).href, name } })
          }
        }, 500)
      }, { capture: true, passive: true })
      addEventListener('touchmove', (e) => {
        if (timer && Math.hypot(e.touches[0].clientX - x, e.touches[0].clientY - y) > 10) cancel()
      }, { capture: true, passive: true })
      addEventListener('touchend', cancel, { capture: true, passive: true })
      addEventListener('touchcancel', cancel, { capture: true, passive: true })
    })()
    """

    /// What a long-pressed image posted: its bytes, or, when the frame could
    /// not read them, its address, fetched here without the frame's cookies.
    private func share(image: [String: Any]) {
        Task {
            var data: Data?
            if let url = (image["data"] as? String).flatMap(URL.init(string:)) {
                data = try? Data(contentsOf: url)
            } else if let url = (image["url"] as? String).flatMap(URL.init(string:)), url.scheme == "https" {
                data = try? await URLSession.shared.data(from: url).0
            }
            guard let data, let picture = UIImage(data: data) else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            saved = Shared(items: [picture])
        }
    }

    /// `#rrggbb`, which is what theme.ts sends.
    private static func color(_ css: String) -> Color? {
        let hex = css.trimmingCharacters(in: .whitespaces).dropFirst(css.hasPrefix("#") ? 1 : 0)
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return Color(red: Double(value >> 16 & 0xff) / 255, green: Double(value >> 8 & 0xff) / 255,
                     blue: Double(value & 0xff) / 255)
    }

    private static let addressForm = """
    <!doctype html><meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
    <style>
      :root { color-scheme: dark; font: 17px -apple-system, sans-serif; }
      body { margin: 0; height: 100vh; display: grid; place-items: center; background: #131314; color: #eee; }
      form { display: grid; gap: 14px; width: min(420px, 86vw); text-align: center; }
      input { font: inherit; padding: 12px 14px; border-radius: 12px; border: 1px solid #444; background: #1e1e20; color: inherit; }
      button { font: inherit; font-weight: 600; padding: 12px; border-radius: 999px; border: 0; background: #eee; color: #111; }
    </style>
    <form onsubmit="event.preventDefault(); webkit.messageHandlers.loom.postMessage({ address: this.address.value.trim() })">
      <h2>Which Loom?</h2>
      <input name="address" type="url" value="https://" autocapitalize="off" autocorrect="off" required autofocus>
      <button>Open</button>
    </form>
    """
}

// ── What the pages send, decoded ─────────────────────────────────────────

enum Side: String { case terminal, canvas, apps, browser }

struct SessionRow: Identifiable, Hashable {
    let id: String
    let title: String
    let backend: String
    let status: String
    let directory: String
    let active: Date
    let queued: Int

    init(_ json: [String: Any]) {
        id = json["id"] as? String ?? ""
        title = json["title"] as? String ?? id
        backend = json["backend"] as? String ?? ""
        status = json["status"] as? String ?? "idle"
        directory = json["directory"] as? String ?? ""
        active = Date(timeIntervalSince1970: (json["active"] as? Double ?? 0) / 1000)
        queued = json["queued"] as? Int ?? 0
    }

    var working: Bool { status == "running" || status == "starting" }
}

struct AppTile: Identifiable, Hashable {
    let name: String
    let title: String
    let url: URL
    let icon: URL?
    var id: String { name }

    /// Addresses as the page has them, which may be relative to the Loom.
    init?(_ json: [String: Any], base: URL?) {
        let resolve = { (s: String?) in s.flatMap { URL(string: $0, relativeTo: base)?.absoluteURL } }
        guard let name = json["name"] as? String, let url = resolve(json["url"] as? String) else { return nil }
        self.name = name
        self.url = url
        title = json["title"] as? String ?? name
        icon = resolve(json["icon"] as? String)
    }
}

struct ModelChoice: Identifiable, Hashable {
    let id: String
    let label: String
    let isDefault: Bool
}

struct Pending: Identifiable, Hashable {
    let id: String
    let name: String
    let uploading: Bool
    let error: String?
}

/// The open conversation, as its bar and composer show it.
struct ChatState {
    let id: String
    let title: String
    let backend: String
    let status: String
    let busy: Bool
    let model: String?
    let models: [ModelChoice]
    let attachments: [Pending]

    init(_ json: [String: Any]) {
        id = json["id"] as? String ?? ""
        title = json["title"] as? String ?? ""
        backend = json["backend"] as? String ?? ""
        status = json["status"] as? String ?? "idle"
        busy = json["busy"] as? Bool ?? false
        model = json["model"] as? String
        models = (json["models"] as? [[String: Any]] ?? []).map {
            ModelChoice(id: $0["id"] as? String ?? "", label: $0["label"] as? String ?? "",
                        isDefault: $0["default"] as? Bool ?? false)
        }
        attachments = (json["attachments"] as? [[String: Any]] ?? []).map {
            Pending(id: $0["key"] as? String ?? "", name: $0["name"] as? String ?? "",
                    uploading: $0["uploading"] as? Bool ?? false, error: $0["error"] as? String)
        }
    }

    var engine: String { Backend.name(backend) }
    var currentModel: ModelChoice? { models.first { $0.id == model } ?? models.first { $0.isDefault } }

    /// As the page says it (chat/Header.tsx).
    var labelResource: LocalizedStringResource {
        switch status {
        case "starting": "starting…"
        case "running": "working"
        case "interrupted": "stopped"
        default: "idle"
        }
    }

    var dot: Color {
        switch status {
        case "starting": .orange
        case "running": .green
        case "interrupted": .red
        default: .secondary
        }
    }
}

struct PaneState {
    var kind = ""
    var title = ""
    var item = false
    var tree = false
    var state = ""
    var typing = false
    var fit = true

    init() {}
    init(_ json: [String: Any]) {
        kind = json["kind"] as? String ?? ""
        title = json["title"] as? String ?? ""
        item = json["item"] as? Bool ?? false
        tree = json["tree"] as? Bool ?? false
        state = json["state"] as? String ?? ""
        typing = json["typing"] as? Bool ?? false
        fit = json["fit"] as? Bool ?? true
    }
}

enum Backend {
    static let all = ["claude_code", "codex", "kiro"]
    static func name(_ backend: String) -> String {
        switch backend {
        case "claude_code": "Claude Code"
        case "codex": "Codex"
        case "kiro": "Kiro"
        default: backend
        }
    }
}

struct Shared: Identifiable {
    let items: [Any]
    let id = UUID()
}

// ── WebKit's side ────────────────────────────────────────────────────────

extension Loom: WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if let image = body["image"] as? [String: Any] {
            share(image: image)
            return
        }
        // The rest is the pages' own say, never a canvas page's or an app's.
        guard message.frameInfo.isMainFrame else { return }
        if message.webView === paneView { pane(said: body) } else { main(said: body) }
    }
}

extension Loom: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        // `<a download>`, which is how the page saves a file (a blob URL).
        if action.shouldPerformDownload { return .download }
        // Links away from this Loom open in Safari; the page itself stays.
        guard action.navigationType == .linkActivated, action.targetFrame?.isMainFrame == true,
              let url = action.request.url, let home, url.host() != home.host()
        else { return .allow }
        await UIApplication.shared.open(url)
        return .cancel
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        response.canShowMIMEType ? .allow : .download
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    /// `target=_blank` and `window.open`: Safari too, rather than a third web view.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { UIApplication.shared.open(url) }
        return nil
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if webView === paneView { paneReady = false }
    }

    /// iOS kills a background web view's content process when it needs the
    /// memory; coming back to a blank page, load it again.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if webView === paneView { paneReady = false } else { Shells.shared.reset() }
        webView.reload()
    }

    // `alert()`, `confirm()` and `prompt()`: without these WebKit skips them,
    // and `confirm()` answers false. Canvas pages and apps use them too.
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        _ = await Panel.show(message, buttons: [("OK", .default, true)])
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await Panel.show(message, buttons: [("Cancel", .cancel, false), ("OK", .default, true)]) ?? false
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        await Panel.ask(prompt, text: defaultText ?? "")
    }
}

extension Loom: WKDownloadDelegate {
    /// Into a fresh temporary directory under the name the page gave it.
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String) async -> URL? {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: suggestedFilename.isEmpty ? "download" : suggestedFilename)
        downloads[ObjectIdentifier(download)] = url
        return url
    }

    func downloadDidFinish(_ download: WKDownload) {
        if let url = downloads.removeValue(forKey: ObjectIdentifier(download)) { saved = Shared(items: [url]) }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloads.removeValue(forKey: ObjectIdentifier(download))
    }
}

/// A page's `alert`, `confirm` or `prompt`, as a system alert over whatever is
/// on screen.
enum Panel {
    static func show(_ message: String, buttons: [(String, UIAlertAction.Style, Bool)]) async -> Bool? {
        await withCheckedContinuation { done in
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            for (title, style, answer) in buttons {
                alert.addAction(UIAlertAction(title: String(localized: String.LocalizationValue(title)), style: style) { _ in
                    done.resume(returning: answer)
                })
            }
            guard let top = topController() else { return done.resume(returning: nil) }
            top.present(alert, animated: true)
        }
    }

    static func ask(_ message: String, text: String) async -> String? {
        await withCheckedContinuation { done in
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addTextField { $0.text = text }
            alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { _ in
                done.resume(returning: nil)
            })
            alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default) { _ in
                done.resume(returning: alert.textFields?.first?.text ?? "")
            })
            guard let top = topController() else { return done.resume(returning: nil) }
            top.present(alert, animated: true)
        }
    }

    private static func topController() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        var top = window?.rootViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }
}
