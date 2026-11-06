import Foundation

/// The single answer to one in-app tool call.
public enum ClarityToolResult {
    /// The tool ran. The value must be JSON-shaped: `[String: Any]`, `[Any]`,
    /// `String`, a number, `Bool` or `nil` (`NSNull`).
    case success(Any?)
    /// The tool could not run; the message is shown to the agent.
    case failure(String)
}

// The value is JSON-shaped data the SDK serialises right away; the completion
// may be called from any thread.
extension ClarityToolResult: @unchecked Sendable {}

/// Call once, from any thread, synchronously or later. Later calls are ignored.
public typealias ClarityToolCompletion = @Sendable (ClarityToolResult) -> Void

/// What an in-app tool does when the agent calls it: the agent's arguments
/// (already checked against the tool's `parameters` schema) and the completion
/// to answer with. Invoked on the main actor.
public typealias ClarityToolHandler = @MainActor (
    _ arguments: [String: Any],
    _ completion: @escaping ClarityToolCompletion
) -> Void

/// Whether the customer is asked before an in-app tool runs.
public enum ClarityToolKind: String {
    /// Changes nothing the customer sees; the agent calls it when it needs the data.
    case read
    /// Changes only what is on screen (opens a screen, scrolls); runs at once,
    /// and the agent calls it only when the customer asks.
    case safeAction = "safe_action"
    /// Changes the customer's data, money or settings; the customer taps Allow
    /// in the chat first.
    case action
}

/// How the chat gets out of the way while a tool shows something in your app,
/// such as opening a screen: the chat steps aside, a loader shows `message`,
/// the SDK waits `delayBefore`, runs the handler, and once it answers brings
/// the chat back — after `holdAfter` (1 s unless you set it), or, with
/// `waitForApp: true` and no `holdAfter`, when your app calls
/// `Clarity.bringChatBack()` (at most `Clarity.maxStepAsideSeconds` later).
/// Set `holdAfter` as well, and the pause wins. Steps that follow one
/// another keep the chat aside until the last one, in the style of the
/// first, as long as each pauses after it answers (the default does); with
/// no pause the chat can come back between steps.
///
/// Applies to a chat shown as a bottom sheet; a full-screen chat has no app
/// behind it to show and stays as it is. `delayBefore` counts against the
/// tool's `timeoutSeconds`; `holdAfter` and a wait for the app start once the
/// tool has answered, so they never make it time out.
public struct ClarityToolReveal {
    public enum Style {
        /// The sheet drops to a strip with the loader; the app behind is undimmed.
        case strip
        /// The sheet fades out in place; the loader floats over the app.
        case fade
    }

    public let style: Style
    /// The loader's text, e.g. "Opening your plan…"; 1…80 characters.
    public let message: String
    /// Seconds between the chat stepping aside and the handler running, 0…3.
    public let delayBefore: TimeInterval
    /// Seconds the customer gets to see the result before the chat returns,
    /// 0…3. Unless you set it: 1 s, or none with `waitForApp`.
    public let holdAfter: TimeInterval?
    /// Keeps the chat aside after the tool answered until your app calls
    /// `Clarity.bringChatBack()` — when the screen it opened has loaded, say.
    /// A `holdAfter` you set as well wins.
    public let waitForApp: Bool

    /// The pause after the tool answered when the app does not set one.
    public static let defaultHoldAfter: TimeInterval = 1.0

    public init(
        message: String,
        style: Style = .strip,
        delayBefore: TimeInterval = 0.3,
        holdAfter: TimeInterval? = nil,
        waitForApp: Bool = false
    ) {
        self.message = message
        self.style = style
        self.delayBefore = delayBefore
        // Waiting for the app means no pause of its own; a pause the app
        // sets explicitly still wins over the wait.
        self.holdAfter = holdAfter ?? (waitForApp ? nil : Self.defaultHoldAfter)
        self.waitForApp = waitForApp
    }
}

/// An in-app tool: a capability of your app the support agent can use.
///
/// Your app declares it — what it does, its arguments, read or action — and
/// supplies the code. Agents with "Tools from the customer's app" switched on
/// in the cabinet are offered it while this customer chats.
///
/// ```swift
/// Clarity.registerTool(ClarityTool(
///     name: "list_devices",
///     description: "Lists the devices signed in to the customer's account.",
///     kind: .read
/// ) { _, completion in
///     api.devices { devices in completion(.success(["devices": devices.map(\.json)])) }
/// })
/// ```
///
/// The description and what you return reach the agent as data from the
/// customer's app, never as a verified fact or an instruction: authorize every
/// change in your own API, as you would for the customer themselves.
public struct ClarityTool {
    /// Lowercase letters, digits and `_`, starting with a letter; ≤ 64 characters.
    public let name: String
    /// What the tool does and when to use it, for the agent; ≤ 1000 characters.
    public let description: String
    public let kind: ClarityToolKind
    /// JSON Schema (type `object`) of the arguments — a subset: `type`,
    /// `properties`, `required`, `items`, `enum`, `description`.
    public let parameters: [String: Any]
    /// Optional JSON Schema the result must match, or the agent gets an error.
    public let resultSchema: [String: Any]?
    /// Seconds the app gets to answer, 1…90; nil = 20 for a read, 30 for an
    /// action (counted from the customer's Allow).
    public let timeoutSeconds: Int?
    /// Set for a tool that shows something in the app (opens a screen,
    /// highlights a control): the chat steps aside while it runs.
    public let reveal: ClarityToolReveal?
    /// The app's security check (`Clarity.setSecurityCheck`) runs once when
    /// the customer taps Allow on a card with this tool, before any step
    /// runs. Only for `kind: .action` — a read or a safe action has no card.
    public let requiresSecurityCheck: Bool
    /// During a voice call, the call folds back to its bubble once the
    /// customer allows a card whose every step has this set (a card of this
    /// one step included), so the app is in view while they run. A card with
    /// one step without it keeps the call open. Only for `kind: .action`.
    public let collapseCallOnAllow: Bool
    public let handler: ClarityToolHandler

    public init(
        name: String,
        description: String,
        kind: ClarityToolKind = .action,
        parameters: [String: Any] = ["type": "object", "properties": [String: Any]()],
        resultSchema: [String: Any]? = nil,
        timeoutSeconds: Int? = nil,
        reveal: ClarityToolReveal? = nil,
        requiresSecurityCheck: Bool = false,
        collapseCallOnAllow: Bool = false,
        handler: @escaping ClarityToolHandler
    ) {
        self.name = name
        self.description = description
        self.kind = kind
        self.parameters = parameters
        self.resultSchema = resultSchema
        self.timeoutSeconds = timeoutSeconds
        self.reveal = reveal
        self.requiresSecurityCheck = requiresSecurityCheck
        self.collapseCallOnAllow = collapseCallOnAllow
        self.handler = handler
    }
}

/// What the app's security check is asked to confirm: the card the customer
/// allowed. Lets the app word its prompt ("Confirm signing out 2 devices").
public struct ClaritySecurityCheckRequest: Sendable {
    /// The tool of every step on the card, in order.
    public let toolNames: [String]

    public init(toolNames: [String]) {
        self.toolNames = toolNames
    }
}

/// The app's own check that the person holding the phone is the customer —
/// Face ID, Touch ID, a passcode, a PIN screen. Call `done(true)` when it
/// passed and `done(false)` when it did not; once, from any thread. Invoked
/// on the main actor, over the chat, so the app's own UI shows on top.
public typealias ClaritySecurityCheck = @MainActor (
    _ request: ClaritySecurityCheckRequest,
    _ done: @escaping @Sendable (Bool) -> Void
) -> Void
