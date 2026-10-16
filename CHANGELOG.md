# Changelog

## 1.3.0

- **The SDK's own strings speak the chat's language.** The notification title
  and fallback text, the image preview's error and retry, and the native ✕'s
  VoiceOver label were always English. They now follow `language` (else the
  device's language) like the chat, with Arabic alongside English; any other
  language still gets English.
- **The native ✕ follows the chat's direction.** With `showNativeCloseButton`
  it was pinned to the app's trailing edge, so an English app with
  `language: "ar"` showed it on the right while the chat's own close button
  sat on the left — two crosses. It now takes the side of the page's own close
  button (left for a right-to-left chat), covering it as it does when the two
  agree.
- **`autoFocusInput` focuses the composer again.** The widget lands on Home,
  which has no composer, so the focus the SDK applied once on opening found
  nothing and the setting did nothing. When there is no composer yet, the SDK
  now waits for one and focuses it the moment the customer enters a
  conversation — once per opening, and never after the widget closes.
- **An html screen can take the whole sheet.** A screen registered to open
  over everything around the chat window now asks the container for the
  room (`requestPresentation` over the page bridge): a bottom sheet rises
  to its largest detent for as long as the screen is open — in place, the
  WebView attached throughout, so nothing the customer typed is lost and
  nothing leaves the screen — and drops back to your `sheetHeightFraction`
  when the screen collapses. A `.fullScreen` presentation already gives the
  whole screen and does nothing. Without this release such a screen fills
  the sheet as sized, which is what it did before. A screen registered for
  the chat window is unaffected: it fills the widget as presented.
- **The edge swipe leaves an html screen opened over the chat.** A screen a
  template registers to open over the whole chat now stands in the
  WebView's history while it is open, and `allowsBackForwardNavigationGestures`
  lets the back swipe pop it — the screen collapses into its message the way
  its own ✕ collapses it. With no screen open the swipe does nothing; the
  widget's own close paths are unchanged. Without this release the page still
  opens and closes such screens; only the gesture is missing.

## 1.2.0

- **HTML widgets render again.** The navigation policy treated every
  cross-origin navigation as a link the customer followed, including ones
  targeting a SUB-frame. An html widget is a sandboxed iframe whose `src`
  redirects to presigned object storage — a foreign origin by design — so the
  widget's own document was handed to the external browser and the frame was
  cancelled, leaving an empty box that timed out into the page's "content
  unavailable" fallback. Only main-frame navigations (and new windows, i.e.
  `target=_blank`) are links now. Ordinary links in messages and articles are
  unaffected: they are main-frame navigations.

- **Voice calls and composer dictation.** When the host app declares
  `NSMicrophoneUsageDescription`, the widget URL now carries
  `nativeCapabilities=microphone`, and the chat offers its microphone
  controls inside the SDK (the page kept them hidden in every SDK WebView
  until now). Without the key nothing changes. See README "Voice and
  dictation".

## 1.1.0

- **`ClarityConfig.showDiagnosticsOnFailure`.** When the widget fails to load,
  the SDK can now present a screen naming the reason instead of nothing at all.
  Previously a failed load left an integrator with a dead Help button and no
  signal unless they had registered a listener.

  This surface is **developer-only** and must never reach an end user. It is
  presented only when all of: a `show()` was actually waiting on the load (a
  background `preload()` failing stays silent rather than stealing focus), and
  the HOST app is debuggable — the app being developed, not this SDK, since an
  SDK consumed as a release binary into a debug app is still a development
  build from the integrator's point of view. Set the flag explicitly to
  override that default in either direction; leave it `nil` to decide from the
  build. The decision is a pure function, unit-tested directly rather than
  inferred from a simulator run, because "never in a release build" is the
  whole contract.

- Removed a dead `WKProcessPool` from the WebView factory (no behaviour
  change — `WKProcessPool` has been a no-op since iOS 15, the deployment floor).

Note: the rejected-session diagnosis shipped in the same period is a **page**
change, not an SDK one. `pageLoadedError` has been decoded since before 1.0.2,
so that fix reaches users on a frontend deploy with no SDK upgrade required.

## 1.0.2

Packaging-only release — no code changes.

- **CocoaPods support.** `ClaritySDK.podspec` now ships alongside
  `Package.swift`, so CocoaPods-based hosts can consume the SDK. Swift
  Package Manager remains the recommended channel; the pod resolves the same
  tag and the same source. The pod version is read from
  `ClarityVersion.swift`, so it can never diverge from the release tag.

## 1.0.1

Documentation-only release — no code changes.

- The README is now the full step-by-step integration guide
  (credentials, install, initialize, identify, events & badge,
  `refresh()`, typed attributes, product events, APNs, camera
  provisioning, error model, troubleshooting) and serves as this
  repository's landing page.

## 1.0.0

First public release — full feature parity with the Android SDK
(`com.onclarity:clarity-android-sdk` 1.2.x), proven by a 43-test hosted
e2e suite against a live Clarity environment.

- Warm pre-loaded `WKWebView` engine with reveal gating: the widget is
  presented only after the chat page reports itself authenticated and
  painted — never a blank sheet. Loads keep the WebView attached to an
  invisible off-screen host so WebKit never suspends the page's
  `requestAnimationFrame` mid-boot.
- Bottom-sheet (custom detent, any height fraction 0.3–1.0) and
  full-screen presentation; unanimated mode switching that keeps the
  conversation alive; sheet drag-to-dismiss, full-screen swipe-down on
  the chat header, page ✕ and native ✕ all routed through one close
  latch.
- Identity: `identify` with visitor-merge semantics, keyed on the stable
  `externalId` — switching it = logout + login with a scoped web-session
  wipe (cookies + origin storage for the widget's domain only, awaited
  before the next load), while a same-id profile update keeps the session
  and conversation; `resetSession` for explicit logout.
- User/ticket attributes and product events, queued until the page is
  live and replayed on load.
- Binary new-message flag (`unreadCount` 1/0) + per-message `onNewMessage`
  while the chat is closed; local
  notification with a single replaced identifier (never prompts for
  permission); APNs token forwarding (`setDeviceToken`), push routing
  helpers (`isClarityPush` / `handlePush` / `handleNotificationResponse`).
- `Clarity.refresh()` — on-demand sync of the latest ticket state (status
  changes + any replies the best-effort realtime channel missed); results
  surface through the normal listener callbacks.
- `Clarity.currentTicketStatus` + `onTicketStatusChanged` — native mirror
  of the conversation's status ("open"/"closed"), derived from the same
  event stream the chat renders.
- `Clarity.isWidgetVisible`; `Clarity.show(mode:sheetHeightFraction:from:)`
  to pin the presenting view controller (multi-scene hosts).
- `onWidgetShown` contract: fires only when the widget is actually on
  screen, always after that presentation's unread reset.
- Native full-screen image preview for attachments (session cookies
  shared, pinch-to-zoom, retry state); message links open in the external
  browser via the `openLink` bridge action.
- Crash safety at the camera seam: the attachment picker's "Take Photo"
  option can no longer terminate a host app that does not declare
  `NSCameraUsageDescription`. The camera picker is blocked (with a debug
  warning) instead of triggering the iOS privacy kill; Photo Library and
  file uploads keep working. Page `getUserMedia` requests are likewise
  denied unless the host declares the matching usage keys, and an
  init-time audit warns about missing provisioning. Declare
  `NSCameraUsageDescription` to enable camera capture — see README
  "Attachments and the camera".
- Classified errors (`network` / `handshakeRejected` / `pageLoadFailed` /
  `rendererCrashed` / `internalError`) with `recoverable` — only a 4xx
  credential rejection is non-recoverable; a retried-out 5xx stays
  transient. Automatic recovery from WebKit content-process termination
  preserves a pending `show()` and re-presents a widget that was on
  screen when the renderer died.
