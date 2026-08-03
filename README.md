# Clarity Support Chat — iOS SDK Integration Guide

Add Clarity's in-app customer support chat to your iOS app. The SDK gives
you a native-feel chat (bottom sheet or full screen) backed by your Clarity
workspace: real agents and AI agents, attachments, notifications, an unread
badge for your own UI, and context APIs so your team sees who the customer
is and what they were doing.

- Opens instantly — the widget pre-warms in the background and is revealed
  only after it is fully painted, never as a blank sheet
- Bottom sheet (any height) or full screen, no web chrome
- In-app message notifications while the chat is closed; APNs forwarding
  for replies while your app is backgrounded
- User identity, user & ticket attributes, product events, session reset
- Never crashes your app — every failure is classified and reported to you
  instead

**Requirements:** iOS 15+, Swift 5.10+ (Xcode 15.3+). UIKit and SwiftUI
hosts. No third-party dependencies.

## 1. Get your credentials

In the Clarity cabinet open **Settings → Channels** and create (or open)
your iOS SDK channel. You need three values:

| Value | Where it goes |
|---|---|
| Organization ID | `ClarityConfig.organizationId` |
| Integration key | `ClarityConfig.integrationKey` |
| Live Chat host | `ClarityConfig.baseUrl` |

The channel's **App ID must match your app's bundle identifier** — the SDK
sends it during the session handshake and mismatches are rejected.
Credentials are identifiers, not secrets: shipping them inside the app is
fine.

## 2. Install (Swift Package Manager)

In Xcode: **File → Add Package Dependencies…** and paste
`https://github.com/Anecdote-AI/clarity-ios-sdk` (rule: *Up to Next Major
Version*, from `1.0.0`). Or in `Package.swift`:

```swift
dependencies: [
    .package(
        url: "https://github.com/Anecdote-AI/clarity-ios-sdk",
        .upToNextMajor(from: "1.0.0")
    )
]
```

The product is **ClaritySDK**; the public entry point is the `Clarity`
enum.

## 3. Initialize at launch

```swift
import ClaritySDK

@main
struct MyApp: App {
    init() {
        Clarity.initialize(config: ClarityConfig(
            organizationId: "YOUR_ORGANIZATION_ID",
            integrationKey: "YOUR_INTEGRATION_KEY",
            baseUrl: "https://YOUR_LIVE_CHAT_HOST"
        ))
    }
    // …
}
```

UIKit apps do the same in `application(_:didFinishLaunchingWithOptions:)`.
With the default `autoPreload` the SDK warms the widget shortly after
launch, so the first open is instant.

Useful `ClarityConfig` knobs: `presentationMode` (default `.bottomSheet`),
`sheetHeightFraction` (default 0.85, clamped 0.3–1.0), `autoFocusInput`,
`autoPreload`, `loadTimeout`, `language`, `appId` (defaults to your bundle
id; must match the channel's App ID).

## 4. Identify the user (after your login)

```swift
Clarity.identify(ClarityUser(
    externalId: user.id,          // stable id in YOUR system
    firstName: user.firstName,
    lastName: user.lastName,
    email: user.email
))
```

Identify before the first open — identity is bound when the widget session
starts. Calling `identify` later with a **different `externalId`** is
treated as logout + login: the previous user's session is wiped so
conversations can never leak between users. Re-identifying the **same
`externalId`** with updated profile fields is a profile update — the
conversation is kept. `Clarity.resetSession()` is the explicit logout.

## 5. Open the chat

```swift
Clarity.show()                        // config's default presentation
Clarity.show(mode: .bottomSheet, sheetHeightFraction: 0.85)
Clarity.show(mode: .fullScreen)
Clarity.dismiss()
```

The widget only appears after the chat page reports itself authenticated
and painted. If it cannot load, the failure surfaces through the listener
(section 6) instead of presenting a dead sheet.

## 6. Listen for events and badge your Help button

Every `ClarityListener` method is optional — implement what you need:

```swift
final class SupportBridge: ClarityListener {
    func onNewMessage(_ textPreview: String) {
        // agent replied while the chat is closed
    }
    func onUnreadCountChanged(_ count: Int) {
        helpBadge.isHidden = count == 0   // 1 = unseen replies, 0 = none
    }
    func onTicketStatusChanged(_ status: String) {
        // "open" / "closed" (also readable via Clarity.currentTicketStatus)
    }
    func onError(_ error: ClarityError) {
        if !error.recoverable { /* hide the Help entry / fall back to e-mail */ }
    }
}

Clarity.setListener(bridge)   // the SDK holds a strong reference
print(Clarity.unreadCount)    // 1 while unseen replies exist, else 0
```

While the chat is closed, an agent reply raises `onNewMessage`, sets the
unread flag, and posts a local notification **only if your app already has
notification permission** — the SDK never prompts. Route notification taps
back to the chat from your `UNUserNotificationCenterDelegate`:

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

For banners while your app is in the foreground, iOS additionally requires
your `willPresent` delegate to allow them
(`completionHandler([.banner, .sound])`).

## 7. Keep it fresh: `refresh()`

Realtime delivery while the chat is closed is best-effort (it rides the
app's live connection). When freshness matters — app returning to the
foreground, pull-to-refresh, a screen with your support entry point — call:

```swift
Clarity.refresh()
```

It fetches the latest ticket state on demand; missed replies and status
changes arrive through the same listener callbacks.

## 8. Attributes and product events

```swift
// Contact-scoped, long-lived. Typed values: String / Int / Double / Bool;
// [String] selects list-attribute option ids; nil removes the attribute.
Clarity.setUserAttributes(["plan": "gold", "seat_count": 7, "vip": true])

// Stamps the NEXT ticket the customer opens (consumed by exactly one ticket):
Clarity.setTicketAttributes(["order_id": "A-1042"])

// Product events for automations and AI-agent context:
Clarity.logEvent("checkout_failed", params: ["code": "card_declined"])
```

All safe to call any time from any thread; values queue until the widget
session is live. Server-side event ingestion activates with the platform's
product-events rollout for your organization — ask your Clarity contact.

## 9. Push notifications (APNs)

Forward your device token so agent replies can reach the device while your
app is backgrounded:

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

Token registration is forwarded fail-soft; background push delivery
activates with the platform's mobile push rollout for your organization —
ask your Clarity contact about availability.

## 10. Attachments and the camera

The chat composer lets customers attach images and PDFs. **Photo Library**
and **Choose File** use out-of-process system pickers — no permissions or
Info.plist keys needed. **Take Photo** opens the camera inside *your*
app's process, and iOS terminates any app that touches the camera without
a usage description. Declare it to enable camera capture:

```xml
<key>NSCameraUsageDescription</key>
<string>The camera lets you take a photo to attach to your support conversation.</string>
```

Without the key the SDK protects your app instead of letting iOS kill it:
the camera option is safely disabled (the tap does nothing, a debug event
is emitted, and an init-time audit warns in the console). Photo Library
and file uploads keep working either way.

## 11. Errors — the SDK never crashes your app

Every failure is classified into `ClarityError.kind` and delivered through
`onError`:

| Kind | Meaning | Recoverable |
|---|---|---|
| `.network` | Offline / host unreachable / 5xx | yes — next `show()` retries |
| `.handshakeRejected` | Wrong organization id / integration key / App ID | **no** — fix configuration |
| `.pageLoadFailed` | Page loaded but never became ready | yes — next `show()` reloads |
| `.rendererCrashed` | WebKit renderer died | yes — auto-recovers |
| `.internalError` | Unexpected SDK failure caught by the safety net | yes |

Recoverable errors need no reaction — the next `show()` retries with a
fresh load. Non-recoverable means retrying won't help: hide your Help
entry or fall back to e-mail, and check the configuration. OS-level crash
vectors (like the camera privacy kill in section 10) are pre-empted before
they can fire.

## Full API reference

| Call | Purpose |
|---|---|
| `Clarity.initialize(config:)` / `updateConfig(_:)` / `config` | Lifecycle & runtime re-configuration |
| `Clarity.identify(_:)` / `resetSession()` | Identity binding / logout |
| `Clarity.preload()` | Manual warm-up (with `autoPreload: false`) |
| `Clarity.refresh()` | On-demand sync of ticket status + missed replies |
| `Clarity.show(mode:sheetHeightFraction:)` / `dismiss()` | Presentation |
| `Clarity.show(mode:sheetHeightFraction:from:)` | Present from a pinned view controller (multi-scene hosts) |
| `Clarity.isWidgetVisible` | True while the widget is on screen |
| `Clarity.currentTicketStatus` | Last known ticket status (`"open"`/`"closed"`) |
| `Clarity.setUserAttributes` / `setTicketAttributes` / `logEvent` | Context |
| `Clarity.setDeviceToken(Data/String)` | APNs forwarding |
| `Clarity.isClarityPush` / `handlePush` / `handleNotificationResponse` | Push & notification routing |
| `Clarity.unreadCount` / `setListener(_:)` | New-message flag (1/0) & callbacks |
| `Clarity.previewWidgetUrl(...)` | The exact widget URL the SDK would load (debugging) |

## Troubleshooting

- **Nothing appears on `show()`** — check `onError`: `.handshakeRejected`
  means wrong `organizationId` / `integrationKey` / App ID (the channel's
  App ID must equal your bundle id); `.network` means the `baseUrl` host is
  unreachable from the device.
- **Replies while closed don't notify** — local notifications require your
  app to have asked for notification permission; the SDK never prompts.
- **"Take Photo" does nothing** — add `NSCameraUsageDescription` to your
  Info.plist (section 10).
- **Which URL is it loading?** — `Clarity.previewWidgetUrl(...)` and the
  `onDebugEvent` trail show every step (handshake, navigation, page-ready).

Questions? Reach your Clarity contact — we're happy to help with the
integration.

## About this repository

This repository is a **read-only source mirror**: every release of the
Clarity iOS SDK is published here and tagged `vX.Y.Z` — see
`CHANGELOG.md` for what changed in each version. The package builds from
source; `swift test` runs the platform-independent core test suite on any
machine with Swift 5.10+.
