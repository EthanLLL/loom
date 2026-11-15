import SwiftUI
import WebKit

/// One Loom page and what it last said. The page posts to the `loom` handler
/// (`frontend/src/native.ts`): what is open, and its theme; a button press
/// goes back as a `loom-native` event.
@Observable final class LoomPage: NSObject {
    var side: String?
    var terminals = 0
    /// The open conversation, for the top bar.
    var chat: ChatInfo?
    /// Where the page's sidebar and chat card are, in points; nil while hidden.
    var sidebar: CGRect?
    var card: CGRect?
    /// The page's theme background, for the bars around it.
    var background = Color.black
    var dark = true
    /// A finished download or a long-pressed image, offered in a share sheet.
    var saved: Shared?

    let home: URL?
    let webView: WKWebView
    @ObservationIgnored private let onAddress: (String) -> Void
    @ObservationIgnored private var downloads: [ObjectIdentifier: URL] = [:]
    @ObservationIgnored private var insets = (top: CGFloat(0), bottom: CGFloat(0))

    init(url: URL?, onAddress: @escaping (String) -> Void) {
        home = url
        self.onAddress = onAddress
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        webView = LoomWebKitView(frame: .zero, configuration: config)
        super.init()

        config.userContentController.add(self, name: "loom")
        config.userContentController.addUserScript(WKUserScript(
            source: Self.imagePress, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        #if DEBUG
        // `-loomToken …` at launch signs the page in, so the simulator can be
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
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.isInspectable = true
        // The page pads for the bars itself (viewport-fit=cover); UIKit
        // insetting the scroll view too would pad twice.
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.backgroundColor = .clear
        hideKeyboardBar(webView)

        if let url {
            webView.load(URLRequest(url: url))
        } else {
            // A web page rather than a SwiftUI field: on the Duo the field took
            // focus but never brought up the keyboard, where the web view's do.
            webView.loadHTMLString(Self.addressForm, baseURL: nil)
        }
    }

    func press(_ action: String, _ value: String = "") {
        guard let data = try? JSONSerialization.data(withJSONObject: ["action": action, "value": value]),
              let detail = String(data: data, encoding: .utf8)
        else { return }
        webView.evaluateJavaScript("window.dispatchEvent(new CustomEvent('loom-native', { detail: \(detail) }))")
    }

    /// How much of the page the glass covers at the top and the bottom.
    func setInsets(top: CGFloat, bottom: CGFloat) {
        insets = (top, bottom)
        applyInsets()
    }

    private func applyInsets() {
        webView.evaluateJavaScript("""
        document.documentElement.style.setProperty('--native-top', '\(Int(insets.top))px');
        document.documentElement.style.setProperty('--native-bottom', '\(Int(insets.bottom))px')
        """)
    }

    func reload() {
        webView.reload()
    }

    /// A long press on an image shares the image. WebKit's own menu would
    /// share its address, and offers no way to change that, so its menu is
    /// turned off for images and the press is caught here instead: in every
    /// frame, canvas pages and apps included, with the bytes fetched by the
    /// frame itself, which has the cookies and the origin to read them.
    private static let imagePress = """
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

/// The conversation as the top bar shows it.
struct ChatInfo {
    let title: String
    let engine: String
    let status: String

    init(_ json: [String: Any]) {
        title = json["title"] as? String ?? ""
        status = json["status"] as? String ?? "idle"
        engine = switch json["backend"] as? String {
        case "claude_code": "Claude Code"
        case "codex": "Codex"
        case "kiro": "Kiro"
        case let other: other ?? ""
        }
    }

    /// As the page says it (chat/Header.tsx).
    var label: String {
        switch status {
        case "starting": "starting…"
        case "running": "working"
        case "interrupted": "stopped"
        default: status
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

struct Shared: Identifiable {
    let items: [Any]
    let id = UUID()
}

extension LoomPage: WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if let image = body["image"] as? [String: Any] {
            share(image: image)
            return
        }
        // The rest is the page's own say, never a canvas page's or an app's.
        guard message.frameInfo.isMainFrame else { return }
        if let address = body["address"] as? String {
            if ContentView.loom(address) != nil { onAddress(address) }
        } else if let theme = body["theme"] as? [String: Any] {
            if let css = theme["background"] as? String, let color = Self.color(css) { background = color }
            dark = theme["dark"] as? Bool ?? true
        } else if let state = body["state"] as? [String: Any] {
            side = state["side"] as? String
            terminals = state["terminals"] as? Int ?? 0
            chat = (state["chat"] as? [String: Any]).map { ChatInfo($0) }
            sidebar = Self.rect(state["sidebar"])
            card = Self.rect(state["card"])
        }
    }

    private static func rect(_ value: Any?) -> CGRect? {
        guard let r = value as? [String: Double], let x = r["x"], let y = r["y"], let w = r["w"], let h = r["h"]
        else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// `#rrggbb`, which is what the page's `--bg` is.
    private static func color(_ css: String) -> Color? {
        let hex = css.trimmingCharacters(in: .whitespaces).dropFirst(css.hasPrefix("#") ? 1 : 0)
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return Color(red: Double(value >> 16 & 0xff) / 255, green: Double(value >> 8 & 0xff) / 255,
                     blue: Double(value & 0xff) / 255)
    }
}

extension LoomPage: WKNavigationDelegate, WKUIDelegate {
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

    /// `target=_blank` and `window.open`: Safari too, rather than a second web view.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { UIApplication.shared.open(url) }
        return nil
    }

    /// A reload forgets the page's variables; give them again.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        applyInsets()
        #if DEBUG
        // `-loomPress apps` at launch presses a button once the page is up,
        // so a pane can be screenshotted open in the simulator.
        if let action = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["loomPress"] as? String {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.press(action) }
        }
        // `-loomEval <js>`, run a little later still, to click through the page.
        if let js = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["loomEval"] as? String {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.webView.evaluateJavaScript(js) }
        }
        #endif
    }

    /// iOS kills a background web view's content process when it needs the
    /// memory; coming back to a blank page, load it again.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}

extension LoomPage: WKDownloadDelegate {
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

/// No ‹ › ✓ bar above the keyboard: the page's composer has its own send
/// button, and the bar takes a row from a short screen. WebKit offers no
/// setting, so the view that takes the typing gets a subclass of its own,
/// made at run time, whose accessory view is nothing.
private func hideKeyboardBar(_ webView: WKWebView) {
    guard let content = webView.scrollView.subviews.first(where: { String(describing: type(of: $0)).hasPrefix("WKContent") }),
          let base = object_getClass(content)
    else { return }
    let name = "LoomNoBar_" + NSStringFromClass(base)
    var subclass: AnyClass? = NSClassFromString(name)
    if subclass == nil, let made = objc_allocateClassPair(base, name, 0) {
        let nothing: @convention(block) (AnyObject) -> AnyObject? = { _ in nil }
        if let method = class_getInstanceMethod(UIView.self, #selector(getter: UIResponder.inputAccessoryView)) {
            class_addMethod(made, #selector(getter: UIResponder.inputAccessoryView),
                            imp_implementationWithBlock(nothing), method_getTypeEncoding(method))
        }
        objc_registerClassPair(made)
        subclass = made
    }
    if let subclass { object_setClass(content, subclass) }
}

/// Folding or unfolding the Duo resizes the web view mid-animation, and
/// WebKit can keep the scroll offset (or zoom) it had for the other screen,
/// which leaves the page shifted under the glass. The page never scrolls
/// itself, so once the size settles, put it back at the origin.
final class LoomWebKitView: WKWebView {
    private var size = CGSize.zero

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != size else { return }
        size = bounds.size
        for delay in [0.3, 0.8] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let scroll = self?.scrollView else { return }
                scroll.setZoomScale(scroll.minimumZoomScale, animated: false)
                scroll.setContentOffset(.zero, animated: false)
            }
        }
    }
}

struct LoomWebView: UIViewRepresentable {
    let page: LoomPage

    func makeUIView(context: Context) -> WKWebView { page.webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
