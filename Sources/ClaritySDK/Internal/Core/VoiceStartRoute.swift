import Foundation

/// What `Clarity.startVoiceCall` does to a call already on in the sheet.
///
/// The bubble collapses it, the way the page's collapse arrow does, so the app
/// gets its screen back with the call still on (Android parity). The sheet
/// has nothing to do: the call is on screen. Neither starts a second call.
enum VoiceStartRoute {

    static func collapsesLiveCall(_ presentation: ClarityVoicePresentation) -> Bool {
        presentation == .bubble
    }

    /// When a call asked for in the sheet is started.
    enum SheetStart: Equatable {
        /// The sheet is on screen with the page loaded: start it now.
        case now
        /// The page is loaded but the sheet is not on screen yet: start it
        /// once the sheet appears (`startVoiceCallIfAsked`).
        case onceOnScreen
        /// The page is still loading: start it when it has loaded.
        case afterLoad
    }

    /// Never into a page no window shows: WebKit holds a hidden page's
    /// microphone request without asking or answering, so a call started in
    /// the windowless WebView sat on its spinner for good (the stc tv sheet
    /// spinner).
    static func sheetStart(pageLoaded: Bool, sheetOnScreen: Bool) -> SheetStart {
        guard pageLoaded else { return .afterLoad }
        return sheetOnScreen ? .now : .onceOnScreen
    }
}
