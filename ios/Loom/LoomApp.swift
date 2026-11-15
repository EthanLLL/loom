import SwiftUI

/// Loom's web UI in a WKWebView, made for the iPhone Duo: the page gets the
/// whole safe area, measured by UIKit rather than by Safari's viewport, and the
/// switches for the right-hand column and the settings are native buttons in
/// the Duo's vertical bar. See `frontend/src/native.ts` for the page's side.
@main struct LoomApp: App {
    /// `-loomURL https://…` at launch (`devicectl … process launch … -- -loomURL …`)
    /// sets the address without typing it, and keeps it.
    init() {
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        if let address = arguments["loomURL"] as? String, ContentView.loom(address) != nil {
            UserDefaults.standard.set(address, forKey: "loomURL")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    /// Which Loom, asked once: a family has more than one.
    @AppStorage("loomURL") private var address = ""

    var body: some View {
        Shell(url: Self.loom(address), onAddress: { address = $0 })
            .id(address)
    }

    static func loom(_ address: String) -> URL? {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespaces)),
              url.scheme == "https" || url.scheme == "http", url.host() != nil
        else { return nil }
        return url
    }
}
