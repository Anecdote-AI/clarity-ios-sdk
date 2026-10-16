import Foundation

/// The few strings the SDK draws itself, in the chat's language: the one
/// `ClarityConfig.language` names, else the device's first preferred language
/// — the same rule the page uses. The SDK ships no localization tables (one
/// Swift target, nothing to bundle for SPM or CocoaPods), so the translations
/// live here; a language without a column here gets English.
///
/// The debug-only diagnostic screen stays English on purpose: its reader is
/// the integrating developer.
enum NativeStrings {

    enum Key: CaseIterable {
        case notificationTitle
        case notificationFallbackBody
        case close
        case imageLoadFailed
        case imageRetry
    }

    static func text(
        _ key: Key,
        language: String?,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> String {
        let table = baseLanguage(language, preferredLanguages: preferredLanguages) == "ar"
            ? arabic : english
        return table[key] ?? english[key] ?? ""
    }

    /// `ar-SA`, `ar_EG` and ` AR ` all name Arabic; a blank configured value
    /// counts as not configured.
    static func baseLanguage(_ configured: String?, preferredLanguages: [String]) -> String {
        let configuredTag = configured?.trimmingCharacters(in: .whitespacesAndNewlines)
        let tag = (configuredTag?.isEmpty == false ? configuredTag : preferredLanguages.first) ?? "en"
        let base = tag.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? tag
        return base.lowercased()
    }

    static let english: [Key: String] = [
        .notificationTitle: "New message from support",
        .notificationFallbackBody: "You have a new reply",
        .close: "Close",
        .imageLoadFailed: "Couldn't load image",
        .imageRetry: "Try again",
    ]

    // Wording follows the chat's own Arabic copy where it has the same string
    // (`live-chat/src/configs/locales/ar.json`: "حاول مرة أخرى").
    static let arabic: [Key: String] = [
        .notificationTitle: "رسالة جديدة من الدعم",
        .notificationFallbackBody: "لديك رد جديد",
        .close: "إغلاق",
        .imageLoadFailed: "تعذّر تحميل الصورة",
        .imageRetry: "حاول مرة أخرى",
    ]
}
