import Foundation

/// The app's declared screens (`ClarityToolTemplates.Navigation`): checking
/// them, matching the path `open_link` gets, filling a deep link, and how
/// they are listed for the agent. Pure.
enum ScreenPaths {

    static let maxPathLength = 100
    static let maxTitleLength = 60
    static let maxDescriptionLength = 120
    static let maxMenuLinks = 40
    static let maxListedInError = 20

    private static let pathPattern = #"^/[A-Za-z0-9_\-/{}.]*$"#
    private static let valuePattern = #"^[A-Za-z0-9_\-.]{1,64}$"#
    private static let placeholderPattern = #"^\{([A-Za-z0-9_]+)\}$"#

    /// The screens that can be offered; each one that cannot is named in a
    /// warning and left out, as is a second screen with the same path.
    static func validScreens(_ screens: [ClarityScreen], warn: (String) -> Void) -> [ClarityScreen] {
        var seen = Set<String>()
        return screens.filter { screen in
            if let problem = problem(with: screen) {
                warn("screen \"\(screen.path)\" left out: \(problem)")
                return false
            }
            guard seen.insert(screen.path).inserted else {
                warn("screen \"\(screen.path)\" is declared twice; the first one counts")
                return false
            }
            return true
        }
    }

    static func problem(with screen: ClarityScreen) -> String? {
        if screen.path.count > maxPathLength || !matches(screen.path, pathPattern) {
            return "path must start with / and hold letters, digits, _ - . / and {name} segments (at most \(maxPathLength))"
        }
        let segments = segmentsOf(screen.path)
        for segment in segments where segment.contains("{") || segment.contains("}") {
            if placeholderName(segment) == nil {
                return "a {name} must be a whole segment of the path"
            }
        }
        let title = collapse(screen.title)
        if title.isEmpty || title.count > maxTitleLength {
            return "title must be 1…\(maxTitleLength) characters"
        }
        if let description = screen.description, description.count > maxDescriptionLength {
            return "description must be at most \(maxDescriptionLength) characters"
        }
        if let link = screen.deepLink {
            let declared = Set(placeholders(screen.path))
            let used = placeholdersIn(link)
            if !used.isSubset(of: declared) || URL(string: fillDeepLink(link, params: sampleParams(used))) == nil {
                return "deepLink must be a URL that uses only the path's {name} placeholders"
            }
        }
        return nil
    }

    static func placeholders(_ path: String) -> [String] {
        segmentsOf(path).compactMap(placeholderName)
    }

    static func hasPlaceholders(_ path: String) -> Bool {
        !placeholders(path).isEmpty
    }

    /// The declared screen a requested path opens, with the values of its
    /// `{name}` segments; nil when none matches. A `?query` is dropped.
    static func match(_ requested: String, screens: [ClarityScreen]) -> ClarityNavigationRequest? {
        let path = withoutQuery(requested.trimmingCharacters(in: .whitespaces))
        let wanted = segmentsOf(path)
        guard path.hasPrefix("/") else { return nil }
        for screen in screens {
            let pattern = segmentsOf(screen.path)
            guard pattern.count == wanted.count else { continue }
            var params: [String: String] = [:]
            var ok = true
            for (have, want) in zip(pattern, wanted) {
                if let name = placeholderName(have) {
                    guard matches(want, valuePattern) else { ok = false; break }
                    params[name] = want
                } else if have != want {
                    ok = false
                    break
                }
            }
            if ok { return ClarityNavigationRequest(path: path, screen: screen, params: params) }
        }
        return nil
    }

    static func withoutQuery(_ path: String) -> String {
        String(path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
    }

    /// The error for a path that is not a declared screen.
    static func notOpenableMessage(_ screens: [ClarityScreen]) -> String {
        "only these screens of the app can be opened: "
            + screens.prefix(maxListedInError).map(\.path).joined(separator: ", ")
    }

    /// The deep link with its placeholders filled, each value URL-encoded.
    static func fillDeepLink(_ link: String, params: [String: String]) -> String {
        var filled = link
        for (name, value) in params {
            let encoded = value.addingPercentEncoding(withAllowedCharacters: unreservedCharacters) ?? value
            filled = filled.replacingOccurrences(of: "{\(name)}", with: encoded)
        }
        return filled
    }

    /// Whether the link opens inside the app: its scheme is one of the app's
    /// own URL schemes. A universal link is not routed back to the app that
    /// opens it, so it needs a navigator.
    static func isAppLink(_ link: String, schemes: Set<String>) -> Bool {
        guard let scheme = link.split(separator: ":", maxSplits: 1).first.map({ $0.lowercased() }),
              link.contains(":")
        else { return false }
        return schemes.contains(scheme) && scheme != "http" && scheme != "https"
    }

    /// `read_page.menu_links`: the screens the agent can open as they are,
    /// without an id to fill in.
    static func menuLinks(_ screens: [ClarityScreen]) -> [[String: Any]] {
        screens.filter { !hasPlaceholders($0.path) }
            .prefix(maxMenuLinks)
            .map { ["text": collapse($0.title), "path": $0.path] }
    }

    /// The intro, then " Screens: " and the screens, as many whole entries as
    /// fit in the backend's 1000 code points.
    static func openLinkDescription(intro: String, screens: [ClarityScreen]) -> String {
        let limit = InAppToolValidation.maxDescriptionLength
        var text = intro + " Screens:"
        var first = true
        for screen in screens {
            let title = collapse(screen.title)
            let about = screen.description.map { collapse($0) }.flatMap { $0.isEmpty ? nil : $0 }
            let entry = "\(screen.path) (\(title)\(about.map { ": \($0)" } ?? ""))"
            let next = text + (first ? " " : ", ") + entry
            if next.unicodeScalars.count > limit { break }
            text = next
            first = false
        }
        return first ? intro : text
    }

    // MARK: - Helpers

    private static let unreservedCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~"
    )

    private static func segmentsOf(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    private static func placeholderName(_ segment: String) -> String? {
        guard let range = segment.range(of: placeholderPattern, options: .regularExpression),
              range == segment.startIndex..<segment.endIndex
        else { return nil }
        return String(segment.dropFirst().dropLast())
    }

    private static func placeholdersIn(_ text: String) -> Set<String> {
        var names = Set<String>()
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            names.insert(String(rest[rest.index(after: open)..<close]))
            rest = rest[rest.index(after: close)...]
        }
        return names
    }

    private static func sampleParams(_ names: Set<String>) -> [String: String] {
        Dictionary(uniqueKeysWithValues: names.map { ($0, "x") })
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    static func collapse(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
