/// How the support widget is presented over the host app.
///
/// Raw values intentionally match the Android SDK's enum names — debug events
/// (`"present: BOTTOM_SHEET"`) and cross-platform docs rely on the shared
/// vocabulary.
public enum PresentationMode: String, Sendable {
    /// A sheet sliding up from the bottom, covering `sheetHeightFraction` of
    /// the screen (default 0.85). On iPad the system presents it as a
    /// centered, width-capped page sheet.
    case bottomSheet = "BOTTOM_SHEET"

    /// An edge-to-edge full-screen container.
    case fullScreen = "FULL_SCREEN"
}
