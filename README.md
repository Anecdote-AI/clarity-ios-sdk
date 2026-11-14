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
Version*, from `1.6.0`). Or in `Package.swift`:

```swift
dependencies: [
    .package(
        url: "https://github.com/Anecdote-AI/clarity-ios-sdk",
        .upToNextMajor(from: "1.6.0")
    )
]
```

### CocoaPods

```ruby
pod 'ClaritySDK', '~> 1.6'
```

Then `pod install`. Same source, same versions as SPM — pick whichever your
project already uses. (CocoaPods is also what a Flutter or React Native plugin
needs, since a plugin's iOS side is a pod and cannot depend on an SPM-only
package.)

The location provider for the ready-made `get_location` tool (since 1.6.0) is
separate and opt-in: the `ClarityLocation` product with SPM, `pod 'ClaritySDK/Location'`
with CocoaPods (see "Ready-made in-app tools").

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
id; must match the channel's App ID), `voiceBubblePosition` (default
`.bottomEnd`; see "Voice and dictation").

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

During a voice call the chat's header has a collapse arrow: the chat gives
the screen back to your app, and a bubble with the assistant's status waits
in a corner (above your keyboard when it is up) while the call goes on.
Your app keeps its keyboard and every touch outside the bubble; a tap on the
bubble opens the call again, and so do the call ending and a question the
assistant needs you to answer on screen. `ClarityConfig.voiceBubblePosition` picks the corner (`.topStart`,
`.topEnd`, `.bottomStart`, `.bottomEnd` — the default; start and end follow
the layout direction). The customer can drag the bubble anywhere (the grip
on it says so); let go, it sticks to the nearer side. An in-app tool that
shows something in your app during a call collapses the chat the same way
instead of bringing it back. Your app's own `Clarity.stepAside` steps the chat
aside as usual during a call, and you still hear `onChatSteppedAside` /
`onChatReturned`. `Clarity.dismiss()` while the call is in the bubble ends the
call: nothing would be left on screen to show it.

To open the voice assistant straight away instead of the chat — from a "Talk
to us" button, say — call:

```swift
Clarity.startVoiceCall()            // in the sheet
Clarity.startVoiceCall(.bubble)     // collapsed from the start
```

The call starts in a conversation of the customer's; `.bubble` shows only the
bubble over your app (iOS asks for the microphone the first time). On a
channel without voice the chat opens instead.

## 11. In-app tools (the agent acts inside your app)

Your app declares what the support agent may do inside it — what each tool
does, its arguments, and its kind — and supplies the code. A **read** changes
nothing the customer sees, and the agent calls it when it needs the data. A
**safe action** changes only what is on screen (opens a screen, scrolls): it
runs at once, and the agent calls it only when the customer asks. An **action**
changes the customer's data, money or settings: the customer taps Allow first,
and the actions the agent asks for in one reply share one card and one Allow. The
agent is offered the tools while this customer chats when the app's channel has
**Use for chat** switched on under **In-app tools** in the cabinet. It is off
by default: an admin turns it on.

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
  the tool in its place; `unregisterTool(_:)` removes it.
- The agent is offered the tools in the order you register them, so register
  the ones it should reach for first, first: the agent neglects the tools
  listed last. At most 32 are offered; past that, the ones registered last are
  left out and named in a `[ClaritySDK]` console warning, because the platform
  refuses a longer list whole.
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
- Since 1.6.0 the SDK holds every call to these rules itself rather than
  taking the chat's word for it: a step that needs the security check runs only on a check that
  passed in your app for that card (each pass covers one step, once, within
  10 minutes); a call the chat did not handle as the tool's kind — an action
  without the customer's Allow — is refused; and only the chat page itself
  can call a tool, never content shown inside a conversation.
- Since 1.6.0 an action without arguments can keep its answer: with `rememberResult: true`,
  once the customer allowed it and it answered, the agent gets the same answer
  at once for the rest of the session, with no second card. Kept in memory
  only, and forgotten on `resetSession()` or when `identify` switches the user.
  Ignored for a tool with `requiresSecurityCheck`, which asks for the card and
  the check every time.
- During a voice call, an action can put your app in view while it runs:
  register it with `collapseCallOnAllow: true`, and once the customer taps
  Allow the call folds back to its bubble while the steps run. Every step of
  the card must have it set; a card with one step without it keeps the call
  open. Only for `kind: .action`.

### Ready-made in-app tools

> Since 1.6.0. Before it, an app offers only the tools it registers itself.

The SDK can offer the agent a set of tools it implements itself — the same
ones a website gets from `inAppToolTemplates`, with the same names — so it
can read the screen the customer is on, show them where something is, help
with a form, search your help website and check why something does not work.

Every group is on by default. You control them in code, in
`ClarityConfig.inAppToolTemplates`, the same way as on the web:

- **Nothing passed** (`nil`, the default): every group is on.
- **Some groups set to `false`**, such as `ClarityToolTemplates(location: false)`:
  only those groups are off.
- **An empty `ClarityToolTemplates()`, or `ClarityToolTemplates.disabled`**:
  every ready-made tool is off.

`page`, `forms`, `diagnostics` and `click` need nothing from you. Three groups need what
only your app knows, and offer nothing until you give it with `.with(…)`, which
keeps the other groups on:

```swift
var config = ClarityConfig(organizationId: "…", integrationKey: "…", baseUrl: "…")
config.inAppToolTemplates = ClarityToolTemplates(
    page: .with(.init(pageText: .off)),              // read_page, show_on_page (no get_page_text)
    siteSearch: .with(.init(siteURL: URL(string: "https://help.example.com")!,
                            searchURL: "/search?q={query}")), // find_on_site, read_link
    navigation: .with(.init(screens: [               // open_link
        ClarityScreen(path: "/orders", title: "My orders"),
        ClarityScreen(path: "/orders/{order_id}", title: "One order", description: "Items and delivery"),
    ])),
    location: .with(.init(provider: ClarityCoreLocation())), // get_location
    click: false                                     // no click_element
    // forms and diagnostics: on, as they were not mentioned
)
Clarity.initialize(config: config)
```

A group set to `true` is on with its default options. If it needs something you
did not give, it offers nothing and logs why.

**The channel decides whether the agent gets them.** The agent is offered these
tools, and your own, only while the app's channel has **Use for chat** (in
chat) or **Use for voice** (in a call) switched on under **In-app tools** in
the cabinet. Voice needs chat. The server checks it, so nothing changes in
your code when an admin turns a switch. An action still asks the customer
first: they tap Allow on the card, or say "yes" in a call.

| Group | Tools | What the agent does with them |
| --- | --- | --- |
| `page` | `read_page` (read), `show_on_page` (safe action), `get_page_text` (action) | Reads the current screen: its title, heading, messages, buttons, links and form field labels. Points at something: the chat steps aside, the screen scrolls to it and dims around it with a short note; it never taps. `get_page_text` reads the screen's whole text and asks the customer each time (`.with(.init(pageText: .off))` leaves it out). |
| `siteSearch` | `find_on_site`, `read_link` (reads) | Searches and reads your public help website (HTTPS, its own origin only, no cookies). |
| `navigation` | `open_link` (safe action) | Opens one of the screens you list, through your navigator. |
| `forms` | `get_form` (read), `focus_form_field`, `fill_form_fields` (safe actions) | Lists the form's standard fields, highlights one, and fills in what the customer told it: `fill_form_fields` takes one field flat (`field`, `value`) or several in `fields`, and refuses neither or both. It never submits, never focuses a field, and never fills a password, one-time code or card field. |
| `diagnostics` | `get_diagnostics` (read), `reload_page` (action) | Device, OS and app version, network, what the app may use (microphone, camera, location, notifications) and the errors your app reported. |
| `location` | `get_location` (action) | The customer's location, rounded to about a kilometre, after they allow it on the card and in the system prompt. Remembered for 30 minutes in memory. |
| `click` | `click_element` (action) | Presses a button, link, switch or tab the agent names, after the customer allows it on the card ("Press "Save profile""): it scrolls to it, checks it can be seen and is enabled, and presses it as a tap does (`sendActions(for: .touchUpInside)`, a switch toggles, a segment is chosen; a SwiftUI button through its `clarityLabel` action, or `accessibilityActivate()` while VoiceOver is on). Answers `{pressed, label}`, with the new screen's `title` and `path` when the press opened one. It never types and never presses a text field, a disabled or hidden control, anything private, or a control marked `clarityNoClick`. A link in text (`UITextView`) opens only when it goes to your `siteSearch` website (https) or one of your app's own URL schemes, and only when the text view's delegate agrees; a `tel:`, `sms:` or `mailto:` link, another app or another site is left for the customer to press. |

Your own tools come first, then these, at most 32 in all. A tool you register
with a template's name replaces the template.

What your app provides:

- **Navigation:** a navigator, once your UI is up. Without one, a screen opens
  only through a `deepLink` in one of your own URL schemes.

  ```swift
  Clarity.setNavigator(ClarityNavigator(
      open: { request, done in            // request.path, request.screen, request.params
          router.open(request.path)
          done(.done)                     // or .failed("why")
      },
      currentPath: { router.currentPath }  // "/orders/123"
  ))
  ```

- **Reload:** `reload_page` is offered only when you say what refreshing a
  screen means in your app: `Clarity.setScreenReloader { done in reloadData(); done(.done) }`.
- **App errors:** `Clarity.recordAppError("Checkout failed: 502", screen: "/checkout")`
  — a short message, never the customer's data. The last 20 are kept in memory.
- **Forms:** set `textContentType` on your text fields (`.emailAddress`,
  `.telephoneNumber`, `.postalCode`, `.name`, …) so the agent knows which field
  is which; the keyboard type is used when there is none. A secure text field
  is always one the customer types themselves.
- **Location:** add the `ClarityLocation` product (SPM) or
  `pod 'ClaritySDK/Location'` (CocoaPods), `import ClarityLocation` (SPM), and
  `NSLocationWhenInUseUsageDescription` to your Info.plist. The core SDK links
  no location framework, so an app that does not use this never carries one.
  Without the usage string the tool is not offered.
- **Camera and microphone in `get_diagnostics`:** read only when your
  Info.plist has `NSCameraUsageDescription` / `NSMicrophoneUsageDescription`;
  without it the answer is `not_declared` and the SDK does not touch the
  camera API. The core SDK names `AVCaptureDevice` only at run time, so an app
  without the usage strings carries no reference to it for App Store review.

What the tools never see:

- What is typed in a field: only whether it is filled.
- A view you mark private: `view.clarityPrivate = true` (UIKit) or
  `.clarityPrivate()` (SwiftUI) keeps it and everything inside it out, for
  example a balance or a card number.
- The chat itself and anything the SDK draws.

What `click_element` never presses: a control you mark
`view.clarityNoClick = true` (UIKit) or `.clarityNoClick()` (SwiftUI), or one
inside such a view — "Delete my account", "Pay now". The agent can still read
it and point at it, and asks the customer to press it themselves.

**SwiftUI screens.** SwiftUI draws its text and buttons itself, and iOS lets
an app read them only while an assistive technology such as VoiceOver or
Voice Control is on. Without one, `read_page` sees a SwiftUI screen's text
fields, toggles, navigation and tab bars (these are UIKit underneath) but not
its `Text` and `Button`s; the result then tells the agent that only part of
the screen could be read, so it asks the customer rather than guessing. Name
the controls the agent should know about with `.clarityLabel(_:role:)` — it
works with no assistive technology on, and `show_on_page` can point at them:

```swift
Button("Save address") { save() }
    .clarityLabel("Save address", action: save) // click_element presses it through `action`
Text("Delivery address").font(.title)
    .clarityLabel("Delivery address", role: .heading)
Text("Saved at 12:27")
    .clarityLabel("Saved at 12:27", role: .status) // read_page lists it with the messages
```

SwiftUI has no way to tap a button from code while no assistive technology
is on, so `click_element` presses a SwiftUI control through the `action` you
give its `clarityLabel`; without one it answers that the control could not be
pressed, and the agent asks the customer to press it.

SwiftUI's own `.accessibilityLabel` and `.accessibilityIdentifier` do not help
here: they too are read only with an assistive technology on. UIKit screens
are read in full either way. A screen that is a web page inside your app
(`WKWebView`) cannot be read.

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
| `ClarityConfig.inAppToolTemplates` (`ClarityToolTemplates`) | The ready-made in-app tools: reading and pointing at the screen, forms, your help website, navigation, diagnostics, location (since 1.6.0) |
| `Clarity.setNavigator(_:)` / `setScreenReloader(_:)` / `recordAppError(_:screen:)` | What the ready-made tools need from your app at run time (since 1.6.0) |
| `UIView.clarityPrivate` / `.clarityPrivate()` / `.clarityLabel(_:role:)` | Keep a region out of the ready-made tools / name a SwiftUI control for them (since 1.6.0) |
| `ClarityTool(rememberResult:)` | Keep an action's answer for the session after the customer allowed it once (since 1.6.0) |

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
