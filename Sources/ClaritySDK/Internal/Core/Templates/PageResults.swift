import Foundation

/// The results of the screen tools, built from one `ScreenSnapshot` (spec
/// 5.1, 5.3, 5.7). Pure: the field set and limits are the web's.
enum PageResults {

    static let maxHeading = 200
    static let maxMessages = 10
    static let maxMessageText = 300
    static let maxPageLinks = 30
    static let maxLinkText = 80
    static let maxFormFields = 15
    static let maxButtons = 15
    static let maxButtonName = 60
    static let maxLabel = 80
    static let maxFormButtons = 10
    static let maxErrors = 30
    static let maxPageText = 5000
    /// The backend takes 16 KB; a result stays under this.
    static let maxResultBytes = 15 * 1024

    static let truncatedNote = "Only part of this screen could be read."
    /// For a screen the SDK can read only part of (SwiftUI text and buttons
    /// with no assistive technology on): the agent asks rather than guesses.
    static let partialNote =
        "Only part of this screen could be read: the app draws some of its text and buttons in a way that cannot be read here. If what you need is not in this result, ask the customer what they see on the screen; do not guess."

    // MARK: - read_page

    static func readPage(
        _ snapshot: ScreenSnapshot,
        menuLinks: [[String: Any]],
        siteURL: URL?
    ) -> [String: Any] {
        let nodes = snapshot.nodes
        // A heading the app marked (the .header trait), else the navigation
        // title, and only then a label that is a heading by its font alone.
        let heading = nodes.first { $0.role == .heading && !$0.inferredHeading }?.name
            ?? snapshot.title.flatMap { $0.isEmpty ? nil : $0 }
            ?? nodes.first { $0.role == .heading }?.name
        let formGroup = form(nodes)
        let formButtons = Set(formGroup?.buttons ?? [])
        var result: [String: Any] = [
            "path": snapshot.path ?? NSNull(),
            "title": snapshot.title.map { ScreenSnapshot.clean($0, limit: maxHeading) } ?? NSNull(),
            "heading": heading.map { ScreenSnapshot.clean($0, limit: maxHeading) } ?? NSNull(),
            "lang": snapshot.lang ?? NSNull(),
            "selection": NSNull(),
            "messages": messages(nodes),
            "menu_links": menuLinks,
            "page_links": pageLinks(nodes, siteURL: siteURL),
            "forms": formGroup.map { group -> [[String: Any]] in
                [["heading": group.heading ?? NSNull(), "fields": group.fields, "buttons": group.buttons]]
            } ?? [],
            "buttons": unique(
                nodes.filter { [.button, .tab, .toggle].contains($0.role) }
                    .map { ScreenSnapshot.clean($0.name, limit: maxButtonName) }
                    .filter { !$0.isEmpty && !formButtons.contains($0) },
                limit: maxButtons
            ),
        ]
        if let note = note(snapshot) { result["note"] = note }
        return trim(result)
    }

    static func note(_ snapshot: ScreenSnapshot) -> String? {
        if let unreadable = snapshot.unreadable { return unreadable }
        if snapshot.partial { return partialNote }
        if snapshot.truncated { return truncatedNote }
        return nil
    }

    private static func messages(_ nodes: [ScreenNode]) -> [[String: Any]] {
        var listed: [[String: Any]] = []
        var texts: [String] = []
        for node in nodes where node.role == .message || node.role == .dialog {
            let text = ScreenSnapshot.clean(node.name, limit: maxMessageText)
            // A message inside one already listed is dropped.
            guard !text.isEmpty, !texts.contains(where: { $0.contains(text) }) else { continue }
            texts.append(text)
            let kind = node.messageKind ?? (node.role == .dialog ? .dialog : .status)
            listed.append(["kind": kind.rawValue, "text": text])
            if listed.count == maxMessages { break }
        }
        return listed
    }

    private static func pageLinks(_ nodes: [ScreenNode], siteURL: URL?) -> [[String: Any]] {
        var seen = Set<String>()
        var links: [[String: Any]] = []
        for node in nodes where node.role == .link {
            guard let url = node.url, links.count < maxPageLinks else { continue }
            let text = ScreenSnapshot.clean(node.name, limit: maxLinkText)
            let path = SiteAddress.linkPath(url, siteURL: siteURL)
            guard !text.isEmpty, seen.insert(path).inserted else { continue }
            links.append(["text": text, "path": path])
        }
        return links
    }

    private struct FormGroup {
        var heading: String?
        var fields: [String]
        var buttons: [String]
    }

    /// Whether a label reads like a title, so its large font may make it the
    /// screen's heading: it has letters, and more of them than digits and
    /// currency or other symbols. On many screens the largest label is data
    /// — a balance, an amount due — which read_page (no card) must not hand
    /// the agent as the heading.
    static func readsLikeTitle(_ text: String) -> Bool {
        var letters = 0
        var other = 0
        for scalar in text.unicodeScalars {
            if scalar.properties.isAlphabetic {
                letters += 1
            } else if scalar.properties.numericType != nil
                        || scalar.properties.generalCategory == .currencySymbol {
                other += 1
            }
        }
        return letters >= 2 && letters > other
    }

    /// The screen's one form: its fields, the heading nearest above the first
    /// field (else the screen's heading) and the buttons after the first field.
    private static func form(_ nodes: [ScreenNode]) -> FormGroup? {
        guard let first = nodes.firstIndex(where: { $0.role == .field }) else { return nil }
        let heading = nodes[..<first].last { $0.role == .heading } ?? nodes.first { $0.role == .heading }
        let fields = nodes.filter { $0.role == .field }
            .map { ScreenSnapshot.clean($0.name, limit: maxButtonName) }
            .filter { !$0.isEmpty }
        let buttons = nodes[first...].filter { $0.role == .button }
            .map { ScreenSnapshot.clean($0.name, limit: maxButtonName) }
            .filter { !$0.isEmpty }
        return FormGroup(
            heading: heading.map { ScreenSnapshot.clean($0.name, limit: maxHeading) },
            fields: Array(fields.prefix(maxFormFields)),
            buttons: unique(buttons, limit: maxButtons)
        )
    }

    private static func unique(_ names: [String], limit: Int) -> [String] {
        var seen = Set<String>()
        return Array(names.filter { seen.insert($0).inserted }.prefix(limit))
    }

    // MARK: - get_page_text

    static let textRoles: Set<ScreenRole> = [.text, .heading, .button, .link, .message, .dialog]

    static func pageText(_ snapshot: ScreenSnapshot) -> [String: Any] {
        var lines: [String] = []
        var length = 0
        for node in snapshot.nodes where textRoles.contains(node.role) {
            let line = ScreenSnapshot.clean(node.name, limit: maxPageText)
            guard !line.isEmpty else { continue }
            lines.append(line)
            length += line.count + 1
            if length > maxPageText { break }
        }
        return trim([
            "path": snapshot.path ?? NSNull(),
            "title": snapshot.title ?? NSNull(),
            "text": String(lines.joined(separator: "\n").prefix(maxPageText)),
        ])
    }

    // MARK: - forms

    struct FormField {
        let type: String
        let customerOnly: Bool
        let node: ScreenNode
    }

    /// The standard fields of the screen, in reading order: enabled, editable,
    /// with a type the agent may see. Every secure field is customer-only.
    static func formFields(_ snapshot: ScreenSnapshot) -> [FormField] {
        snapshot.nodes.compactMap { node in
            guard let field = node.field, field.enabled, field.editable, let type = field.type else { return nil }
            if field.customerOnly || FieldTypes.isCustomerOnly(type) {
                return FormField(type: FieldTypes.isCustomerOnly(type) ? type : "current-password", customerOnly: true, node: node)
            }
            return FieldTypes.isFillable(type) ? FormField(type: type, customerOnly: false, node: node) : nil
        }
    }

    static func describe(_ field: FormField) -> [String: Any] {
        let label = ScreenSnapshot.clean(field.node.name, limit: maxLabel)
        return [
            "field": field.type,
            "label": label.isEmpty ? NSNull() : label,
            "filled": field.node.field?.filled ?? false,
        ]
    }

    static func getForm(_ snapshot: ScreenSnapshot) -> [String: Any] {
        let fields = formFields(snapshot)
        let errors: [[String: Any]] = snapshot.nodes.compactMap { node -> [String: Any]? in
            guard let field = node.field, let error = field.error, !error.isEmpty else { return nil }
            let label = ScreenSnapshot.clean(node.name, limit: maxLabel)
            return [
                "label": label.isEmpty ? NSNull() : label,
                "type": field.type ?? field.inputKind,
                "error": ScreenSnapshot.clean(error, limit: maxMessageText),
            ]
        }
        return [
            "path": snapshot.path ?? NSNull(),
            "fields": fields.filter { !$0.customerOnly }.map(describe),
            "customer_types_it": fields.filter(\.customerOnly).map(describe),
            "errors": Array(errors.prefix(maxErrors)),
            "buttons": Array((form(snapshot.nodes)?.buttons ?? []).prefix(maxFormButtons)),
        ]
    }

    // MARK: - fill_form_fields

    struct FieldValue: Equatable {
        let field: String
        let value: String
    }

    /// Why a `fill_form_fields` call was refused: the agent reads the message.
    struct FillArgumentsError: Error, Equatable {
        let message: String
    }

    static let fillBothForms = "pass either field and value, or fields, not both"
    static let fillNeitherForm = "pass field and value to fill one field, or fields to fill several"
    static let fillFlatIncomplete = "pass field and value together, both as text"

    /// The values a `fill_form_fields` call asks for: one field passed flat
    /// (`field` and `value`), or several in `fields`. A weak model in a voice
    /// call could not build the list and the fill never happened; one field
    /// flat is what it manages. Neither or both is refused. In `fields`, an
    /// entry that is not a field and a text value is skipped, as before.
    static func requestedFields(_ arguments: [String: Any]) throws -> [FieldValue] {
        func given(_ key: String) -> Bool {
            guard let value = arguments[key] else { return false }
            return !(value is NSNull)
        }
        let flat = given("field") || given("value")
        let listed = given("fields")
        if flat && listed { throw FillArgumentsError(message: fillBothForms) }
        if flat {
            guard let field = arguments["field"] as? String, let value = arguments["value"] as? String else {
                throw FillArgumentsError(message: fillFlatIncomplete)
            }
            return [FieldValue(field: field, value: value)]
        }
        guard listed else { throw FillArgumentsError(message: fillNeitherForm) }
        return (arguments["fields"] as? [Any] ?? []).compactMap { item in
            guard let object = item as? [String: Any], let field = object["field"] as? String,
                  let value = object["value"] as? String
            else { return nil }
            return FieldValue(field: field, value: value)
        }
    }

    // MARK: - Trimming

    /// Under the backend's limit: drops from the end of `page_links`, then
    /// `buttons`, then the forms' fields, then `messages`, then cuts `text`.
    /// The result's size as JSON, the way the limit is measured.
    static func byteSize(_ result: [String: Any]) -> Int {
        (try? JSONSerialization.data(withJSONObject: result, options: [])).map(\.count) ?? 0
    }

    static func trim(_ result: [String: Any]) -> [String: Any] {
        var result = result
        func size() -> Int { byteSize(result) }
        func dropLast(_ key: String) -> Bool {
            guard var list = result[key] as? [Any], !list.isEmpty else { return false }
            list.removeLast()
            result[key] = list
            return true
        }
        func dropFormField() -> Bool {
            guard var forms = result["forms"] as? [[String: Any]], var first = forms.first,
                  var fields = first["fields"] as? [String], !fields.isEmpty
            else { return false }
            fields.removeLast()
            first["fields"] = fields
            forms[0] = first
            result["forms"] = forms
            return true
        }
        while size() > maxResultBytes {
            if dropLast("page_links") || dropLast("buttons") || dropFormField() || dropLast("messages") { continue }
            if let text = result["text"] as? String, !text.isEmpty {
                result["text"] = String(text.prefix(max(0, text.count - max(64, text.count / 8))))
                continue
            }
            break
        }
        return result
    }
}

/// `show_on_page`'s matching (a port of the web's `pointAt.ts`).
enum PointMatch {

    static let maxSuggestions = 8
    static let maxNote = 160
    static let maxElementName = 80
    static let secondaryRoles: Set<ScreenRole> = [.heading, .image, .text]
    static let pointableRoles: Set<ScreenRole> = [.button, .link, .tab, .toggle, .field, .heading, .image, .text]
    /// What an answer may name back: controls, fields, headings and
    /// pictures, as the web's POINTABLE selector. Never a text label: it can
    /// be the customer's own data (a name, a balance), which reaches the
    /// agent only through get_page_text, after the customer's Allow —
    /// show_on_page runs with no card.
    static let nameableRoles: Set<ScreenRole> = [.button, .link, .tab, .toggle, .field, .heading, .image]

    /// Lowercase letters, digits and spaces only, whitespace collapsed.
    static func normalize(_ value: String) -> String {
        let collapsed = ScreenSnapshot.clean(value, limit: Int.max).lowercased()
        // The web's /[^\p{L}\p{N}\s]/: letters, numbers and white space stay.
        let kept = collapsed.unicodeScalars.filter { scalar in
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .decimalNumber, .letterNumber, .otherNumber:
                return true
            default:
                return scalar.properties.isWhitespace
            }
        }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: kept)
        return String(out).trimmingCharacters(in: .whitespaces)
    }

    /// exact 4, prefix 3, contains 2, every word (2 or more) contained 1.
    static func score(name: String, wanted: String) -> Int {
        let have = normalize(name)
        if have == wanted { return 4 }
        if have.hasPrefix(wanted) { return 3 }
        if have.contains(wanted) { return 2 }
        let words = wanted.split(separator: " ").map(String.init)
        return words.count > 1 && words.allSatisfy { have.contains($0) } ? 1 : 0
    }

    /// The index of the candidate whose name matches best: a control before a
    /// heading, picture or text of the same name; ties go to the shorter name.
    static func best(_ candidates: [(name: String, role: ScreenRole)], target: String) -> Int? {
        let wanted = normalize(target)
        guard !wanted.isEmpty else { return nil }
        var best: (index: Int, score: Int, length: Int)?
        for (index, candidate) in candidates.enumerated() {
            let score = score(name: candidate.name, wanted: wanted) * 2 - (secondaryRoles.contains(candidate.role) ? 1 : 0)
            let length = candidate.name.count
            if score > 0, best == nil || score > best!.score || (score == best!.score && length < best!.length) {
                best = (index, score, length)
            }
        }
        return best?.index
    }

    /// The error when nothing matches, naming what there is to point at:
    /// only the candidates whose role may be named (`nameableRoles`).
    static func notFound(target: String, candidates: [(name: String, role: ScreenRole)]) -> String {
        notFound(target: target, names: candidates.filter { nameableRoles.contains($0.role) }.map(\.name))
    }

    /// The name an answer gives the matched element: its own, cut, or for a
    /// text label (which may be the customer's data) the agent's own target.
    static func elementName(_ name: String, role: ScreenRole, target: String) -> String {
        nameableRoles.contains(role)
            ? String(name.prefix(maxElementName))
            : ScreenSnapshot.clean(target, limit: maxElementName)
    }

    /// The error when nothing matches, naming the given names.
    static func notFound(target: String, names: [String]) -> String {
        var seen = Set<String>()
        let listed = names.filter { $0.count <= 60 && seen.insert($0).inserted }.prefix(maxSuggestions)
        return "nothing on this screen is called \"\(ScreenSnapshot.clean(target, limit: 60))\"; you can point at: "
            + listed.joined(separator: " · ")
    }

    /// The note shown next to the element: "Here" when none is given.
    static func note(_ value: Any?) -> String {
        let text = ScreenSnapshot.clean(value as? String, limit: maxNote)
        return text.isEmpty ? "Here" : text
    }
}
