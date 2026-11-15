# Loom for iPhone

A native shell around Loom's web page, made for the iPhone Duo but fine on any iPhone: a `WKWebView` fills the
screen, and Liquid Glass (the conversation's top bar, the sidebar's head and new-chat button, the pane switches)
floats over it where the page reports its cards are. The page side is `frontend/src/native.ts`; it only
switches on inside this app (`window.webkit.messageHandlers.loom`).

Why not the home-screen web app: WebKit misreports the viewport height there, and a web page cannot reach the
Duo's vertical bar.

## Build

Xcode 27 or later, iOS 27.1 or later. Signing uses your own team, given on the command line, so nothing personal is
in the project:

    xcodebuild -project Loom.xcodeproj -scheme Loom -configuration Debug \
      -destination 'id=<device udid>' LOOM_TEAM=<team id> -allowProvisioningUpdates build
    xcrun devicectl device install app --device <udid> <derived data>/Build/Products/Debug-iphoneos/Loom.app

`LOOM_BUNDLE_ID` (default `cloud.luozhen.loom`) changes the bundle id, which a free Apple ID needs to be unique.
With a free Apple ID the build runs for 7 days, then it has to be installed again.

On first launch it asks for the Loom's address (`-loomURL https://…` as a launch argument skips that). Debug builds
also take `-loomToken` (a login token, for the simulator), `-loomPress <action>` and `-loomEval <js>`, for
screenshots.

## Notes

- Hiding the ‹ › ✓ bar above the keyboard swaps a private WebKit view's class at run time (`hideKeyboardBar`); a
  WebKit update may undo it, and App Store review would not take it.
- A long press on an image shares the image, not its address: WebKit's own menu is switched off for images
  (`imagePress`).
- System sheets follow the phone's language among those in `Info.plist`; the app's own words are in `*.lproj`.
