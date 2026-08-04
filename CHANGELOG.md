# Changelog

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
