import SwiftUI

/// Loom for iPhone, made for the iPhone Duo: SwiftUI and Liquid Glass for the
/// layout, the session list, the composer and the terminals, and Loom's own
/// page for the conversation and the canvas under the glass (Shell.swift).
/// See `frontend/src/native.ts` for the page's side.
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
