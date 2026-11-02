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

## 2. Install

### Swift Package Manager

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

### CocoaPods

```ruby
pod 'ClaritySDK', '~> 1.0'
```

Then `pod install`. Same source, same versions as SPM — pick whichever your
project already uses. (CocoaPods is also what a Flutter or React Native plugin
needs, since a plugin's iOS side is a pod and cannot depend on an SPM-only
package.)

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

### Verify who the user is (signed identity)

An `externalId` on its own is a claim the app makes about itself. To have
Clarity trust it, your own backend signs a short-lived token for the logged-in
user and the app hands that token to the SDK:

```swift
// 1. After login, ask YOUR backend for a Clarity token for this user.
let token = try await myBackend.fetchClarityToken()

// 2. Pass it along with the identity.
Clarity.identify(ClarityUser(
    externalId: user.id,
    email: user.email,
    jwt: token
))
```

The SDK only carries the token to the chat; it never creates or inspects it.

**Minting the token (on your backend)**

- Sign a JWT with **HS256** using the channel's **identity secret**. Find the
  secret in the cabinet, in your iOS SDK channel's settings under
  **Identity verification**.
- Claims: `user_id` (required, the same value you pass as `externalId`) and,
  optionally, `email`, `phone`, `first_name`, `last_name`, `avatar` and
  `custom_attributes`.
- **Include `email` or `phone` only if your system has verified the user
  controls them.** The chat is linked to any existing contact that already
  holds that email or phone, including its history from other channels, so an
  unverified or user-editable address could expose another person's support
  history.
- `exp` is required and must be at most 24 hours ahead. Keep it short and
  issue a fresh token per login.
- The payload is signed, not encrypted — the user can read it, so put nothing
  in it you would not show them.
- **Never put the secret in the app.** Anyone who can extract it from the
  binary can impersonate any of your users. Only your backend holds it.
- Rotating the secret in the cabinet keeps the previous secret valid for
  7 days, so tokens already issued keep working while you roll the new one out.

**Lifecycle**

- When the token expires, fetch a new one and call `Clarity.identify` again
  with the same `externalId` and the new `jwt`. The conversation is kept.
- On logout call `Clarity.resetSession()`.
- A token the platform rejects (invalid, expired, missing or malformed) is
  reported through `onError` as `.pageLoadFailed` with `code` 401; the reason
  is in the message.
- In the same **Identity verification** section, turn on **Require a verified
  identity** to refuse a session that states an `externalId` without a token. Turn it on once
  every app version in the field sends a token.

`ClarityUser.userHash` is **deprecated**. It was never verified by the
platform; use `jwt` instead.

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

**If your workspace marks contact attributes as required,** set them
immediately after `Clarity.init` — before the widget first loads, not just
before the first `show()`. Only attributes present at load time reach the
session; a session missing a required one is rejected, and a rejected session
never becomes ready, so `show()` reports `.pageLoadFailed` with the missing keys
named in the message. With the default `autoPreload: true` the first load starts
~1.5s after `init` — beat it, or set `autoPreload: false` and call
`Clarity.preload()` once the attributes are in.

While developing, a **debug-only** screen names the reason whenever the widget
fails to open, so a misconfiguration is visible without wiring a listener. It
never appears in a Release build; `showDiagnosticsOnFailure` forces it either
way if your build configuration does not map to `DEBUG` as expected.

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

### Voice and dictation

If your organization has a voice agent or composer dictation enabled, the
chat can offer a microphone button. It records inside *your* app's process
too, so it is opt-in the same way — declare a microphone usage description:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>The microphone lets you talk to a voice agent or dictate a message in your support conversation.</string>
```

With the key present the SDK tells the chat it may offer the microphone,
and iOS shows its standard permission prompt on first use. Without it the
chat shows no microphone button at all, and any capture request is denied
up front rather than letting iOS terminate your app.

## 11. In-app tools (the agent acts inside your app)

Your app declares what the support agent may do inside it — what each tool
does, its arguments, and its kind — and supplies the code. A **read** changes
nothing the customer sees, and the agent calls it when it needs the data. A
**safe action** changes only what is on screen (opens a screen, scrolls): it
runs at once, and the agent calls it only when the customer asks. An **action**
changes the customer's data, money or settings: the customer taps Allow first,
and the actions the agent asks for in one reply share one card and one Allow. Agents with
**Tools from the customer's app** switched on in the cabinet are offered the
tools while this customer chats.

```swift
Clarity.registerTool(ClarityTool(
    name: "list_devices",
    description: "Lists the devices signed in to the customer's account.",
    kind: .read
) { _, completion in
    api.devices { result in
        switch result {
        case .success(let devices):
            completion(.success(["devices": devices.map { ["id": $0.id, "name": $0.name] }]))
        case .failure(let error):
            completion(.failure(error.localizedDescription))
        }
    }
})

Clarity.registerTool(ClarityTool(
    name: "remove_device",
    description: "Signs a device out of the customer's account.",
    kind: .action,
    parameters: [
        "type": "object",
        "properties": ["device_id": ["type": "string", "description": "From list_devices"]],
        "required": ["device_id"],
    ]
) { arguments, completion in
    api.removeDevice(arguments["device_id"] as? String ?? "") { completion(.success(["removed": $0])) }
})
```

- The handler runs on the main thread; call `completion` once, from any thread.
- Return JSON-shaped values only (dictionaries, arrays, strings, numbers,
  `Bool`, `nil`). Anything else becomes an error for the agent.
- No answer within `timeoutSeconds` (20 s for a read, 30 s for a safe action or an action,
  counted from Allow) is an error too. That time includes any confirmation of
  your own: a handler that asks for Face ID or the passcode first should raise
  `timeoutSeconds` (up to 90), or a customer who takes a moment gets "did not
  finish in time".
- The description and the result reach the agent as data from your app, never
  as instructions or verified facts: authorize every change in your own API.
- `registerTool` works before `initialize`; registering a name again replaces
  the tool; `unregisterTool(_:)` removes it.
- `registerTool` returns `false` and logs the reason for a declaration the
  platform would refuse (property names must be lowercase with `_`, a subset
  of JSON Schema, `timeoutSeconds` 1–90, the description at most 1000
  characters). A refusal by the platform itself also reaches the log.
- The handler runs on the main actor and the completion is `@Sendable`, so
  both work in Swift 6 language mode.
- A tool that opens a screen or highlights something does it behind the
  chat. Give it `reveal: ClarityToolReveal(message: "Opening the screen…")`
  and the chat steps aside while it runs (`.strip` drops the sheet to a strip
  with the loader, `.fade` fades it out), then comes back after `holdAfter`.
  Steps that follow one another keep it aside until the last one,
  as long as each pauses after it answers (the default does). A
  full-screen chat stays as it is.
  To bring it back when your app is ready instead, set `waitForApp` and call `Clarity.bringChatBack()`; a pause, when set, wins. Your app
  can also step the chat aside on its own with `Clarity.stepAside(message:style:)` /
  `updateStepAside` / `bringChatBack`, and `ClarityListener` gets
  `onChatSteppedAside` / `onChatReturned`.
- An action can ask who holds the phone first: register it with
  `requiresSecurityCheck: true` and set your check once with
  `Clarity.setSecurityCheck { request, done in … }` (Face ID, the passcode,
  your own PIN screen; call `done(true)` when it passed). When the customer
  taps Allow on a card with such a tool, the check runs once for the whole
  card, before any step; not passed (or no answer in 60 s) → nothing runs and
  the card asks again. Only for `kind: .action`; a card that needs it while
  none is set does not run.

Full guide: <https://docs.support.onclarity.com/sdks/in-app-tools>.

## 12. Errors — the SDK never crashes your app

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
| `Clarity.identify(_:)` / `resetSession()` | Identity binding (incl. the signed `jwt`) / logout |
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
| `Clarity.registerTool(_:)` / `unregisterTool(_:)` | Declare an in-app tool (`ClarityTool`) the support agent can call in your app / remove it |
| `Clarity.setSecurityCheck(_:)` | Your check (Face ID, a passcode) run once when the customer allows a card with a `requiresSecurityCheck` tool |

## Troubleshooting

- **Nothing appears on `show()`** — check `onError`: `.handshakeRejected`
  means wrong `organizationId` / `integrationKey` / App ID (the channel's
  App ID must equal your bundle id); `.network` means the `baseUrl` host is
  unreachable from the device.
- **The chat refuses to open after adding `jwt`** — `onError` carries the
  reason in its message: the token is invalid (wrong secret or signature),
  expired, missing or malformed. Check that your backend signs with the
  channel's current identity secret and sets a valid `exp`.
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
