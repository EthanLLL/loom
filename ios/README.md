# Loom for iPhone

A native Loom for iPhone, made for the iPhone Duo but fine on any iPhone. SwiftUI owns the layout and every control,
with Liquid Glass throughout: the session list, the bars, the composer, the right-hand column's bars, and the
terminals (SwiftTerm). Loom's own page renders only what goes under the glass, in two web views: one conversation's
transcript (`?surface=main`), and the canvas or Loom's browser (`?surface=pane`). The page's side is
`frontend/src/native.ts` and `frontend/src/ios/`.

The page keeps the socket, the lobby and the API; the app drives it through a bridge of state and actions
(`post` / `loom-native`), never of positions. What the glass covers reaches WebKit as `obscuredContentInsets` (iOS
26) plus the scroll view's bottom inset, so the page needs no padding of its own: SwiftUI's safe area does not reach
a web view, and `env(safe-area-inset-*)` reads 0 there.

Why not the home-screen web app: WebKit misreports the viewport height there, and a web page cannot reach the
Duo's vertical bar.

## Build

Xcode 27 or later, iOS 27.1 or later. Signing uses your own team, given on the command line, so nothing personal is
in the project:

    xcodebuild -project Loom.xcodeproj -scheme Loom -configuration Debug \
      -destination 'id=<device udid>' LOOM_TEAM=<team id> -allowProvisioningUpdates -skipPackagePluginValidation build
    xcrun devicectl device install app --device <udid> <derived data>/Build/Products/Debug-iphoneos/Loom.app

The first build fetches SwiftTerm and the packages its manifest names from GitHub; on a slow link that takes a while,
once. `-skipPackagePluginValidation` lets a command-line build run SwiftTerm's build plugin, which Xcode would
otherwise ask to trust.

`LOOM_BUNDLE_ID` (default `cloud.luozhen.loom`) changes the bundle id, which a free Apple ID needs to be unique.
With a free Apple ID the build runs for 7 days, then it has to be installed again.

On first launch it asks for the Loom's address (`-loomURL https://…` as a launch argument skips that). Debug builds
also take, for the simulator and screenshots: `-loomToken` (a login token), `-loomOrient landscape|portrait`,
`-loomOpen YES` (show the conversation on one column), `-loomSide terminal|canvas|apps|browser`, and `-loomEval <js>`
(run in the main page, result printed).

## Notes

- A long press on an image shares the image, not its address: WebKit's own menu is switched off for images
  (`imagePress`).
- `alert`, `confirm` and `prompt` in any page show as system alerts (`Panel`); without them WebKit skips them.
- The terminal font is Loom's own Nerd Font, fetched from `/fonts/` once and kept in Caches.
- System sheets follow the phone's language among those in `Info.plist`; the app's own words are in `*.lproj`.
