# Clarity Support SDK for iOS

> Lives in `apps/ios-sdk/` in `anecdote-monorepo`. CI workflows sit at the
> monorepo root, prefixed **"iOS SDK: "**; releases tag as
> `ios-sdk-v<version>` (see `docs/RELEASING.md`). The public repository
> `Anecdote-AI/clarity-ios-sdk` is a read-only source mirror published on
> release.

Native-feel in-app **customer support chat** (Clarity Live Chat) for iOS.

- Opens instantly (background pre-warm, revealed only after the page reports
  it is painted — never a blank sheet)
- Bottom sheet (any height fraction) or full screen, no web chrome
- In-app message notifications while the chat is closed, unread badge for
  your own UI, APNs token forwarding for backgrounded delivery
- User identity, user/ticket attributes, product events, session reset

**Requirements:** iOS 15+, Swift 5.10+. **Dependencies:** none.

## 1. Install (Swift Package Manager)

```swift
// Package.swift
dependencies: [
    .package(
        url: "https://github.com/Anecdote-AI/clarity-ios-sdk",
        .upToNextMajor(from: "1.0.0")
    )
]
```

Or in Xcode: File → Add Package Dependencies… →
`https://github.com/Anecdote-AI/clarity-ios-sdk`. The product is
**ClaritySDK**; the public entry point is the `Clarity` enum.

## 2. Initialize

```swift
import ClaritySDK

@main
struct MyApp: App {
    init() {
        Clarity.initialize(config: ClarityConfig(
            organizationId: "…",           // Clarity cabinet → Settings → Channels
            integrationKey: "…",
            baseUrl: "https://chat.yourcompany.com",  // your Live Chat host
            channelHost: "yourdomain.com"  // only when reusing web-widget credentials
        ))
    }
    // …
}
```

UIKit apps do the same in
`application(_:didFinishLaunchingWithOptions:)`. Credentials are
identifiers, not secrets — shipping them in the app is fine. With the
default `autoPreload` the SDK warms the widget shortly after launch, so the
first open is instant.

## 3. Identify the user (after your login)

```swift
Clarity.identify(ClarityUser(
    externalId: user.id,          // stable id in YOUR system
    firstName: user.firstName,
    lastName: user.lastName,
    email: user.email
))
```

Identity is bound when the widget session starts, so identify before the
first open. Calling `identify` with a **different `externalId`** later is
treated as logout + login: the previous user's widget web session is wiped so
conversations can never leak between users. Re-identifying the **same
`externalId`** with updated profile fields (a later-known email, a changed
name) is a profile update — the session and conversation are kept.
`Clarity.resetSession()` is the explicit logout.

## 4. Show the widget

```swift
Clarity.show()                        // config's default presentation
Clarity.show(mode: .bottomSheet, sheetHeightFraction: 0.85)
Clarity.show(mode: .fullScreen)
Clarity.dismiss()
```

The widget only appears after the chat page reports itself authenticated
and painted. If the page cannot load, the failure surfaces through the
listener instead of presenting a dead sheet.

## 5. Listen for events

```swift
final class SupportBridge: ClarityListener {
    func onWidgetShown() {}                      // on screen; unread already 0
    func onWidgetDismissed() {}
    func onNewMessage(_ textPreview: String) {}  // reply while chat is closed
    func onUnreadCountChanged(_ count: Int) {}   // 1 = new messages, 0 = none
    func onError(_ error: ClarityError) {}       // classified, with .recoverable
    func onWidgetFailed(code: Int, message: String) {}  // legacy; onError supersedes
    func onDebugEvent(_ event: String) {}        // diagnostic trail
}

Clarity.setListener(bridge)   // the SDK holds a strong reference
print(Clarity.unreadCount)    // 1 while unseen replies exist, else 0
```

`onWidgetShown` is a contract: when it fires, the widget is on screen and
`Clarity.unreadCount` is already reset (the `onUnreadCountChanged(0)` for
that presentation always precedes it).

While the chat is closed, an agent reply raises `onNewMessage`, increments
the unread count, and posts a local notification **only if your app already
has notification permission** — the SDK never prompts. For the banner to
appear while your app is in the **foreground**, iOS additionally requires
your `UNUserNotificationCenterDelegate` to allow it:

```swift
func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler:
        @escaping (UNNotificationPresentationOptions) -> Void
) {
    completionHandler([.banner, .sound])
}
```

Realtime delivery while the chat is closed is **best-effort** (it rides the
app's live connection). When freshness matters — app returning to
foreground, pull-to-refresh, a screen with your support entry point — call
`Clarity.refresh()`: it fetches the latest ticket state on demand, and
anything new arrives through the same callbacks. Route notification taps
back to the chat:

```swift
func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
) {
    if Clarity.handleNotificationResponse(response) { // reopens the chat
        completionHandler()
        return
    }
    // …your own notifications…
}
```

## 6. Push notifications (APNs)

Forward your device token so the backend can target agent replies at the
device while the app is backgrounded. Token registration is forwarded
fail-soft; background push delivery activates with the platform's mobile
push rollout for your organization — ask your Clarity contact about
availability:

```swift
func application(_ application: UIApplication,
                 didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    Clarity.setDeviceToken(deviceToken)     // or the hex-string variant
}

func application(_ application: UIApplication,
                 didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                 fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
    if Clarity.isClarityPush(userInfo: userInfo) {
        _ = Clarity.handlePush(userInfo: userInfo)
        completionHandler(.newData)
        return
    }
    // …your own pushes…
}
```

## 7. Attributes & events

```swift
Clarity.setUserAttributes(["plan": "gold"])          // long-lived, contact-scoped
Clarity.setTicketAttributes(["order_id": "A-1042"])  // stamps the NEXT ticket
Clarity.logEvent("checkout_failed", params: ["code": "card_declined"])
```

Events are forwarded fail-soft; server-side ingestion (automations / AI
context) activates with the platform's product-events rollout for your
organization.

All safe to call any time from any thread; values queue until the widget
session is live.

## 8. Full API

| Call | Purpose |
|---|---|
| `Clarity.initialize(config:)` / `updateConfig(_:)` / `config` | Lifecycle & runtime re-configuration |
| `Clarity.identify(_:)` / `resetSession()` | Identity binding / logout |
| `Clarity.preload()` | Manual warm-up (with `autoPreload: false`) |
| `Clarity.refresh()` | On-demand sync: fetch the latest ticket state (status + any missed replies); results arrive via the listener callbacks |
| `Clarity.show(mode:sheetHeightFraction:)` / `dismiss()` | Presentation |
| `Clarity.show(mode:sheetHeightFraction:from:)` | Present from a pinned view controller (multi-scene hosts) |
| `Clarity.isWidgetVisible` | True while the widget is on screen |
| `Clarity.currentTicketStatus` | Last known ticket status (`"open"`/`"closed"`); changes via `onTicketStatusChanged` |
| `Clarity.setUserAttributes` / `setTicketAttributes` / `logEvent` | Context |
| `Clarity.setDeviceToken(Data/String)` | APNs forwarding |
| `Clarity.isClarityPush` / `handlePush` / `handleNotificationResponse` | Push & notification routing |
| `Clarity.unreadCount` / `setListener(_:)` | New-message flag (1/0) & callbacks |
| `Clarity.previewWidgetUrl(...)` | The exact widget URL the SDK would load (debug/support tooling) |

`ClarityConfig` knobs: `presentationMode` (default `.bottomSheet`),
`sheetHeightFraction` (default 0.85, clamped 0.3–1.0), `autoFocusInput`,
`autoPreload` (default on), `showNativeCloseButton` (default off — the
page renders its own close affordance), `loadTimeout`,
`language`, `appId` (defaults to your bundle id; must match the channel's
App ID).

## Attachments and the camera

The chat composer lets customers attach images and PDFs. Two of the three
sources iOS offers — **Photo Library** and **Choose File** — use
out-of-process system pickers and need no permissions or Info.plist keys.
The third, **Take Photo**, opens the camera inside *your* app's process,
and iOS terminates any app that touches the camera without a usage
description. Declare it to enable camera capture:

```xml
<key>NSCameraUsageDescription</key>
<string>The camera lets you take a photo to attach to your support conversation.</string>
```

Without the key the SDK protects your app instead of letting iOS kill it:
the camera picker is blocked (the tap does nothing), a
`camera capture blocked: NSCameraUsageDescription missing…` debug event is
emitted, and an init-time audit warns in the console. Photo Library and
file uploads keep working either way. Page media-capture requests
(`getUserMedia`) are likewise denied unless the matching usage keys
(`NSCameraUsageDescription` / `NSMicrophoneUsageDescription`) are
declared.

## Errors

`ClarityError.kind` classifies every failure: `.network`,
`.pageLoadFailed` and `.rendererCrashed` are `recoverable` (a later
`show()` retries); `.handshakeRejected` (wrong credentials — HTTP 4xx) is
not. The SDK never crashes the host app: internal failures surface as
`.internalError` callbacks, and OS-level crash vectors (like the camera
privacy kill) are pre-empted before they can fire — see "Attachments and
the camera".

## Troubleshooting

- **Nothing appears on `show()`** — check `onError`: `.handshakeRejected`
  means wrong `organizationId`/`integrationKey`/`appId` (the channel's App
  ID must equal your bundle id); `.network` means the `baseUrl` host is
  unreachable from the device.
- **Replies while closed don't notify** — local notifications require your
  app to have asked for notification permission; the SDK never prompts.
- **Which URL is it loading?** — `Clarity.previewWidgetUrl(...)` and the
  `onDebugEvent` trail show every step (handshake, navigation, page-ready).

## Development (monorepo)

| Path | Purpose |
|---|---|
| `Package.swift`, `Sources/`, `Tests/` | The SDK package (mirrored verbatim to the public repo on release) |
| `project.yml` | XcodeGen spec for the dev harness (demo app, e2e host, hosted e2e bundle) — the `.xcodeproj` is generated, never committed |
| `demo/` | SwiftUI demo app |
| `e2e/` | Hosted XCTest e2e suite driving the real SDK against a live environment |
| `scripts/` | Build / test / simulator / release helpers (see headers) |
| `docs/` | Internal runbooks (releasing, e2e test plan) — not mirrored |

```bash
# Pure-Swift core tests — run anywhere, including Linux:
swift test

# Full harness (macOS + Xcode): generate the project and compile everything:
bash scripts/build-all.sh

# E2E suite against a live environment (see docs/E2E-TEST-PLAN.md):
bash scripts/run-e2e.sh --baseUrl https://… --org 1 --token … --agent 2
```

CI: the `iOS SDK: *` workflows in `.github/workflows/` — build & unit
tests, hosted e2e, demo artifact, release. All manual-only, mirroring the
Android SDK's CI conventions.
