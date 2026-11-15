import CoreText
import SwiftTerm
import SwiftUI

/// One of the server's shells in a native terminal (SwiftTerm), with the
/// system's text input, selection and scrolling, and SwiftTerm's own key bar
/// (esc, ctrl, arrows) over the keyboard. Its bytes travel over the main
/// page's socket (ios/Terminals.tsx): the channel is joined once the view
/// knows its size in cells, and the view is kept per shell, scrollback and
/// all, for as long as the app runs.
struct TerminalScreen: UIViewRepresentable {
    let loom: Loom
    let id: String

    func makeUIView(context: Context) -> TerminalView {
        Shells.shared.box(for: id, loom: loom).view
    }

    func updateUIView(_ view: TerminalView, context: Context) {}
}

/// The terminals made so far, by shell.
@MainActor final class Shells {
    static let shared = Shells()
    private var boxes: [String: Box] = [:]

    /// After the main page reloads: its channels are gone, so each view
    /// starts again and joins anew.
    func reset() {
        boxes = [:]
    }

    func box(for id: String, loom: Loom) -> Box {
        if let box = boxes[id] { return box }
        let box = Box(id: id, loom: loom)
        boxes[id] = box
        if let fonts { box.view.setFonts(normal: fonts.0, bold: fonts.1, italic: fonts.0, boldItalic: fonts.1) }
        else { loadFonts(from: loom.home) }
        loom.terminalSinks[id] = { [weak box] data in box?.view.feed(byteArray: ArraySlice(data)) }
        return box
    }

    // ── The font ─────────────────────────────────────────────────────────
    //
    // Terminal.tsx's, from the Loom itself (`/fonts/`): a Nerd Font, so the
    // prompt's powerline and icon glyphs draw rather than show as boxes.
    // Kept in Caches after the first time; until it is there, the system's.

    private static let size: CGFloat = 13
    private var fonts: (UIFont, UIFont)?
    private var loading = false

    private func loadFonts(from home: URL?) {
        guard !loading, let home else { return }
        loading = true
        Task {
            var loaded: [UIFont] = []
            for name in ["MesloLGLNerdFontMono-Regular", "MesloLGLNerdFontMono-Bold"] {
                if let font = await Self.font(name, from: home) { loaded.append(font) }
            }
            loading = false
            guard loaded.count == 2 else { return }
            fonts = (loaded[0], loaded[1])
            for box in boxes.values {
                box.view.setFonts(normal: loaded[0], bold: loaded[1], italic: loaded[0], boldItalic: loaded[1])
            }
        }
    }

    private static func font(_ name: String, from home: URL) async -> UIFont? {
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "\(name).ttf")
        if !FileManager.default.fileExists(atPath: cache.path) {
            guard let (data, response) = try? await URLSession.shared.data(from: home.appending(path: "fonts/\(name).ttf")),
                  (response as? HTTPURLResponse)?.statusCode == 200
            else { return nil }
            try? data.write(to: cache)
        }
        guard let provider = CGDataProvider(url: cache as CFURL), let font = CGFont(provider),
              let postScript = font.postScriptName as String?
        else { return nil }
        CTFontManagerRegisterGraphicsFont(font, nil)
        return UIFont(name: postScript, size: size)
    }

    /// One shell's view, and what it says to the channel.
    final class Box: NSObject, TerminalViewDelegate {
        let id: String
        let view: TerminalView
        private weak var loom: Loom?
        private var joined = false

        init(id: String, loom: Loom) {
            self.id = id
            self.loom = loom
            view = TerminalView(frame: .zero, font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular))
            super.init()
            view.terminalDelegate = self
            Self.paint(view)
        }

        /// Terminal.tsx's colours, so a shell looks the same in the browser.
        private static func paint(_ view: TerminalView) {
            func color(_ hex: UInt32) -> SwiftTerm.Color {
                SwiftTerm.Color(red: UInt16(hex >> 16 & 0xff) * 257, green: UInt16(hex >> 8 & 0xff) * 257,
                                blue: UInt16(hex & 0xff) * 257)
            }
            view.installColors([
                0x0b3b61, 0xff3a3a, 0x52ffd0, 0xfff383, 0x1376f9, 0xc792ea, 0xff5ed4, 0x16fda2,
                0x63686d, 0xff54b0, 0x74ffd8, 0xfcf5ae, 0x388eff, 0xae81ff, 0xff6ad7, 0x60fbbf,
            ].map(color))
            view.nativeBackgroundColor = UIColor(red: 0x01 / 255, green: 0x0c / 255, blue: 0x18 / 255, alpha: 1)
            view.nativeForegroundColor = UIColor(red: 0xec / 255, green: 0xde / 255, blue: 0xf4 / 255, alpha: 1)
            view.caretColor = UIColor(red: 0x38 / 255, green: 1, blue: 0x9d / 255, alpha: 1)
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            // Laid out at zero first; a shell that size would wrap every line.
            guard newCols > 4, newRows > 1, let loom else { return }
            let size: [String: Any] = ["id": id, "cols": newCols, "rows": newRows]
            loom.send(joined ? "terminal-resize" : "terminal-open", size)
            joined = true
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            loom?.send("terminal-input", ["id": id, "data": Data(data).base64EncodedString()])
        }

        func clipboardCopy(source: TerminalView, content: Data) {
            if let text = String(data: content, encoding: .utf8) { UIPasteboard.general.string = text }
        }

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            if let url = URL(string: link), url.scheme == "https" || url.scheme == "http" {
                UIApplication.shared.open(url)
            }
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
