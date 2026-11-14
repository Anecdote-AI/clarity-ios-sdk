import Foundation

/// A small, tolerant HTML reader for the website tools (`read_link`,
/// `find_on_site`): there is no DOM in an app, and WebKit's HTML import must
/// not be used off the main thread. The same algorithm runs on Android
/// (`HtmlText.kt`); both are pinned by the shared golden fixtures.
///
/// It builds a light element tree (void elements, raw-text `script`/`style`,
/// end tags closing the nearest open element of their name, HTML's implied
/// end tags for the common cases — a new `p`/`li`/`dt`/`dd`/`option`/`tr`/
/// `td`/`th` closes an open one of its kind, a block closes an open `p` —
/// and no nesting past `maxDepth`) and reads from
/// it what the web templates read from a parsed document: the title, the
/// content root (`<main>`, else `<body>`), its readable text, its links, the
/// schema.org JSON-LD blocks, and whether the page is a script shell.
struct HTMLDocument {

    final class Element {
        let name: String
        let attributes: [String: String]
        var children: [Node] = []
        weak var parent: Element?
        /// 0 for the document; a child is one deeper than its parent.
        let depth: Int

        init(name: String, attributes: [String: String], parent: Element?) {
            self.name = name
            self.attributes = attributes
            self.parent = parent
            depth = parent.map { $0.depth + 1 } ?? 0
        }
    }

    /// No element is nested deeper: one that would be goes beside the open
    /// element at this depth instead of inside it (keeping its own text).
    /// Unclosed markup (`<div><div>…`) cannot build a chain deep enough to
    /// exhaust a background thread's stack when it is released.
    static let maxDepth = 256

    enum Node {
        case element(Element)
        case text(String)
    }

    let root: Element

    // Never part of the text (the web's NOT_TEXT, plus iframe).
    static let notText: Set<String> = ["script", "style", "noscript", "template", "svg", "iframe"]
    // A block ends a run of text: a heading never runs into the paragraph after it.
    static let blocks: Set<String> = [
        "p", "div", "li", "dt", "dd", "h1", "h2", "h3", "h4", "h5", "h6", "br", "tr", "td", "th",
        "section", "article", "header", "footer", "blockquote", "pre",
    ]
    static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param",
        "source", "track", "wbr",
    ]
    private static let rawText: Set<String> = ["script", "style"]
    private static let escapableRawText: Set<String> = ["title", "textarea"]

    /// The schema.org types that help a support answer (the web's STRUCTURED_TYPES).
    static let structuredTypes: Set<String> = [
        "Product", "Offer", "AggregateOffer", "BreadcrumbList", "FAQPage", "LocalBusiness",
        "Store", "Organization", "Event",
    ]
    static let maxStructuredItems = 20
    /// Fewer characters than this in a page's content: a script shell.
    static let shellTextLength = 20

    init(html: String) {
        var tokenizer = HTMLTokenizer(html)
        root = tokenizer.buildTree()
    }

    // MARK: - What the tools read

    /// The first `<title>`, whitespace collapsed.
    var title: String {
        first("title").map { Self.collapse(Self.allText($0)) } ?? ""
    }

    /// `<main>`, else `<body>`, else the whole document.
    var contentRoot: Element {
        first("main") ?? first("body") ?? root
    }

    /// The readable text of the content root, cut to `limit` characters.
    func mainText(limit: Int) -> String {
        String(Self.readableText(contentRoot).prefix(limit))
    }

    /// The `<a href>` links with text under `element` (the content root by
    /// default), in document order.
    func links(in element: Element? = nil) -> [(text: String, href: String)] {
        var out: [(String, String)] = []
        Self.visit(element ?? contentRoot) { node in
            guard node.name == "a", let href = node.attributes["href"] else { return true }
            let text = Self.collapse(Self.allText(node))
            if !text.isEmpty { out.append((text, href)) }
            return false
        }
        return out
    }

    /// Every JSON-LD block, a `@graph` (or a top-level array) spread out.
    var jsonLDItems: [[String: Any]] {
        var items: [[String: Any]] = []
        Self.visit(root) { node in
            guard node.name == "script" else { return true }
            guard Self.isJSONLD(node) else { return false }
            let text = Self.rawContent(node)
            guard let data = text.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            else { return false }
            var blocks: [Any] = [value]
            if let object = value as? [String: Any], let graph = object["@graph"] as? [Any] {
                blocks = graph
            } else if let array = value as? [Any] {
                blocks = array
            }
            items.append(contentsOf: blocks.compactMap { $0 as? [String: Any] })
            return false
        }
        return items
    }

    /// The JSON-LD blocks of the types that help a support answer, at most 20.
    var structuredData: [[String: Any]] {
        Array(jsonLDItems.filter { Self.structuredTypes.contains(Self.schemaType($0)) }.prefix(Self.maxStructuredItems))
    }

    /// A page whose content a script draws: it has a script that is not
    /// JSON-LD, and next to no text where the content goes.
    var isScriptShell: Bool {
        var hasScript = false
        Self.visit(root) { node in
            if node.name == "script" && !Self.isJSONLD(node) { hasScript = true }
            return !hasScript
        }
        return hasScript && Self.readableText(contentRoot).count < Self.shellTextLength
    }

    static func schemaType(_ item: [String: Any]) -> String {
        if let types = item["@type"] as? [Any] { return types.first.map { "\($0)" } ?? "" }
        return item["@type"].map { "\($0)" } ?? ""
    }

    // MARK: - Tree helpers

    func first(_ name: String) -> Element? {
        var found: Element?
        Self.visit(root) { node in
            if found == nil && node.name == name { found = node }
            return found == nil
        }
        return found
    }

    /// Depth-first over elements, in document order; `body` returns false
    /// to skip the children. Iterative: no recursion per level.
    static func visit(_ element: Element, _ body: (Element) -> Bool) {
        var stack: [Element] = elements(of: element).reversed()
        while let node = stack.popLast() {
            if body(node) { stack.append(contentsOf: elements(of: node).reversed()) }
        }
    }

    private static func elements(of element: Element) -> [Element] {
        element.children.compactMap { if case .element(let node) = $0 { return node } else { return nil } }
    }

    static func isJSONLD(_ script: Element) -> Bool {
        (script.attributes["type"] ?? "").trimmingCharacters(in: .whitespaces).lowercased() == "application/ld+json"
    }

    static func rawContent(_ element: Element) -> String {
        element.children.map { if case .text(let text) = $0 { return text } else { return "" } }.joined()
    }

    /// Every text under the element, nothing skipped (a title, a link's text).
    static func allText(_ element: Element) -> String {
        var parts: [String] = []
        var stack: [Node] = element.children.reversed()
        while let node = stack.popLast() {
            switch node {
            case .text(let text): parts.append(text)
            case .element(let inner):
                if !rawText.contains(inner.name) { stack.append(contentsOf: inner.children.reversed()) }
            }
        }
        return parts.joined()
    }

    /// The text as a reader sees it: no scripts or styles, a space after each
    /// block, whitespace collapsed (the web's `readableText`).
    static func readableText(_ element: Element) -> String {
        enum Step { case node(Node), blockEnd }
        var parts: [String] = []
        var stack: [Step] = element.children.reversed().map(Step.node)
        while let step = stack.popLast() {
            switch step {
            case .blockEnd: parts.append(" ")
            case .node(.text(let text)): parts.append(text)
            case .node(.element(let inner)):
                if notText.contains(inner.name) { continue }
                // The space comes after the block's own text.
                if blocks.contains(inner.name) { stack.append(.blockEnd) }
                stack.append(contentsOf: inner.children.reversed().map(Step.node))
            }
        }
        return collapse(parts.joined())
    }

    static func collapse(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

/// The tokenizer behind `HTMLDocument`: bytes in, a tolerant tree out.
private struct HTMLTokenizer {
    private let bytes: [UInt8]
    private var index = 0

    init(_ html: String) {
        bytes = Array(html.utf8)
    }

    mutating func buildTree() -> HTMLDocument.Element {
        let root = HTMLDocument.Element(name: "#document", attributes: [:], parent: nil)
        var current = root
        var text: [UInt8] = []

        func flushText() {
            guard !text.isEmpty else { return }
            current.children.append(.text(HTMLEntities.decode(String(decoding: text, as: UTF8.self))))
            text.removeAll(keepingCapacity: true)
        }

        while index < bytes.count {
            let byte = bytes[index]
            guard byte == UInt8(ascii: "<") else {
                text.append(byte)
                index += 1
                continue
            }
            if starts(with: "<!--") {
                flushText()
                skip(past: "-->", from: index + 4)
            } else if starts(with: "<!") || starts(with: "<?") {
                flushText()
                skip(past: ">", from: index + 2)
            } else if starts(with: "</"), let name = tagName(at: index + 2) {
                flushText()
                skip(past: ">", from: index + 2)
                // Close the nearest open element of this name; a stray end tag is ignored.
                var node: HTMLDocument.Element? = current
                while let open = node, open.name != name { node = open.parent }
                if let open = node, let parent = open.parent { current = parent }
            } else if let name = tagName(at: index + 1) {
                flushText()
                index += 1 + name.utf8.count
                let (attributes, selfClosing) = readAttributes()
                current = HTMLTokenizer.closingImplied(by: name, current: current)
                let parent = current.depth >= HTMLDocument.maxDepth ? (current.parent ?? current) : current
                let element = HTMLDocument.Element(name: name, attributes: attributes, parent: parent)
                parent.children.append(.element(element))
                if HTMLDocument.voidElements.contains(name) || selfClosing && name != "script" {
                    continue
                }
                if name == "script" || name == "style" || name == "title" || name == "textarea" {
                    let content = readRaw(until: name)
                    let decoded = (name == "title" || name == "textarea") ? HTMLEntities.decode(content) : content
                    if !decoded.isEmpty { element.children.append(.text(decoded)) }
                    continue
                }
                current = element
            } else {
                text.append(byte)
                index += 1
            }
        }
        flushText()
        return root
    }

    // MARK: Implied end tags (the common cases of the HTML spec)

    /// A start tag of the key closes the nearest open element of these names…
    private static let closesOpen: [String: Set<String>] = [
        "li": ["li"], "dt": ["dt", "dd"], "dd": ["dt", "dd"], "option": ["option"],
        "tr": ["tr"], "td": ["td", "th"], "th": ["td", "th"],
    ]
    /// …unless one of these is open first: the search stops there.
    private static let closesOpenScope: [String: Set<String>] = [
        "li": ["ul", "ol", "menu", "table", "td", "th", "button", "template"],
        "dt": ["dl", "table", "td", "th", "button", "template"],
        "dd": ["dl", "table", "td", "th", "button", "template"],
        "option": ["select", "datalist", "optgroup", "template"],
        "tr": ["table", "thead", "tbody", "tfoot", "template"],
        "td": ["tr", "table", "template"], "th": ["tr", "table", "template"],
    ]
    /// A start tag of these closes an open `p`.
    private static let closesP: Set<String> = [
        "address", "article", "aside", "blockquote", "details", "dd", "div", "dl", "dt",
        "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6",
        "header", "hr", "li", "main", "nav", "ol", "p", "pre", "section", "table", "ul",
    ]
    /// No search for an open `p` goes past these.
    private static let pScope: Set<String> = [
        "html", "body", "table", "td", "th", "caption", "button", "template", "object",
    ]

    /// Where an element named `name` goes once the elements its start tag
    /// implicitly ends are closed.
    static func closingImplied(by name: String, current: HTMLDocument.Element) -> HTMLDocument.Element {
        var current = current
        if let peers = closesOpen[name] {
            current = close(peers, stoppingAt: closesOpenScope[name] ?? [], from: current)
        }
        if closesP.contains(name) {
            current = close(["p"], stoppingAt: pScope, from: current)
        }
        return current
    }

    private static func close(
        _ names: Set<String>,
        stoppingAt limits: Set<String>,
        from current: HTMLDocument.Element
    ) -> HTMLDocument.Element {
        var node: HTMLDocument.Element? = current
        while let open = node {
            if names.contains(open.name) { return open.parent ?? current }
            if limits.contains(open.name) { return current }
            node = open.parent
        }
        return current
    }

    private func starts(with prefix: String) -> Bool {
        let p = Array(prefix.utf8)
        guard index + p.count <= bytes.count else { return false }
        for (offset, byte) in p.enumerated() where bytes[index + offset] != byte { return false }
        return true
    }

    private mutating func skip(past terminator: String, from start: Int) {
        let t = Array(terminator.utf8)
        var i = start
        while i + t.count <= bytes.count {
            if Array(bytes[i..<(i + t.count)]) == t {
                index = i + t.count
                return
            }
            i += 1
        }
        index = bytes.count
    }

    /// A tag name starting at `at` (a letter, then letters, digits, `-`), lowercased.
    private func tagName(at start: Int) -> String? {
        guard start < bytes.count, isLetter(bytes[start]) else { return nil }
        var end = start
        while end < bytes.count, isLetter(bytes[end]) || isDigit(bytes[end]) || bytes[end] == UInt8(ascii: "-") || bytes[end] == UInt8(ascii: ":") {
            end += 1
        }
        return String(decoding: bytes[start..<end], as: UTF8.self).lowercased()
    }

    private mutating func readAttributes() -> ([String: String], Bool) {
        var attributes: [String: String] = [:]
        var selfClosing = false
        while index < bytes.count {
            skipSpaces()
            guard index < bytes.count else { break }
            let byte = bytes[index]
            if byte == UInt8(ascii: ">") {
                index += 1
                return (attributes, selfClosing)
            }
            if byte == UInt8(ascii: "/") {
                selfClosing = true
                index += 1
                continue
            }
            selfClosing = false
            var end = index
            while end < bytes.count, !isSpace(bytes[end]),
                  bytes[end] != UInt8(ascii: "="), bytes[end] != UInt8(ascii: ">"), bytes[end] != UInt8(ascii: "/") {
                end += 1
            }
            if end == index { index += 1; continue }
            let name = String(decoding: bytes[index..<end], as: UTF8.self).lowercased()
            index = end
            skipSpaces()
            var value = ""
            if index < bytes.count, bytes[index] == UInt8(ascii: "=") {
                index += 1
                skipSpaces()
                if index < bytes.count, bytes[index] == UInt8(ascii: "\"") || bytes[index] == UInt8(ascii: "'") {
                    let quote = bytes[index]
                    var close = index + 1
                    while close < bytes.count, bytes[close] != quote { close += 1 }
                    value = String(decoding: bytes[(index + 1)..<min(close, bytes.count)], as: UTF8.self)
                    index = min(close + 1, bytes.count)
                } else {
                    var close = index
                    while close < bytes.count, !isSpace(bytes[close]), bytes[close] != UInt8(ascii: ">") { close += 1 }
                    value = String(decoding: bytes[index..<close], as: UTF8.self)
                    index = close
                }
            }
            if attributes[name] == nil { attributes[name] = HTMLEntities.decode(value) }
        }
        return (attributes, selfClosing)
    }

    /// The raw content of a `script`/`style`/`title`/`textarea`, up to its end tag.
    private mutating func readRaw(until name: String) -> String {
        let closing = Array("</\(name)".utf8)
        var i = index
        while i + closing.count <= bytes.count {
            var match = true
            for (offset, byte) in closing.enumerated() where lower(bytes[i + offset]) != byte {
                match = false
                break
            }
            if match {
                let content = String(decoding: bytes[index..<i], as: UTF8.self)
                index = i
                skip(past: ">", from: i)
                return content
            }
            i += 1
        }
        let content = String(decoding: bytes[index...], as: UTF8.self)
        index = bytes.count
        return content
    }

    private mutating func skipSpaces() {
        while index < bytes.count, isSpace(bytes[index]) { index += 1 }
    }

    private func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0x0C }
    private func isLetter(_ b: UInt8) -> Bool { (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) }
    private func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }
    private func lower(_ b: UInt8) -> UInt8 { (b >= 0x41 && b <= 0x5A) ? b + 32 : b }
}

/// Numeric character references and the common named ones.
enum HTMLEntities {

    static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "copy": "©", "reg": "®", "trade": "™", "hellip": "…", "mdash": "—", "ndash": "–",
        "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "laquo": "«", "raquo": "»",
        "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "deg": "°", "middot": "·",
        "bull": "•", "times": "×", "divide": "÷", "shy": "\u{00AD}", "sect": "§", "para": "¶",
        "iexcl": "¡", "iquest": "¿", "zwnj": "\u{200C}", "zwj": "\u{200D}", "thinsp": "\u{2009}",
        "ensp": "\u{2002}", "emsp": "\u{2003}",
    ]

    static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = ""
        out.reserveCapacity(text.count)
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[rest.startIndex..<amp]
            let after = rest[rest.index(after: amp)...]
            if let semi = after.prefix(32).firstIndex(of: ";") {
                let entity = after[after.startIndex..<semi]
                if let decoded = decodeEntity(entity) {
                    out += decoded
                    rest = after[after.index(after: semi)...]
                    continue
                }
            }
            out += "&"
            rest = after
        }
        out += rest
        return out
    }

    private static func decodeEntity(_ entity: Substring) -> String? {
        if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
            return UInt32(entity.dropFirst(2), radix: 16).flatMap(scalar)
        }
        if entity.hasPrefix("#") {
            return UInt32(entity.dropFirst(), radix: 10).flatMap(scalar)
        }
        return named[String(entity)]
    }

    private static func scalar(_ value: UInt32) -> String? {
        guard value != 0, let scalar = Unicode.Scalar(value) else { return "\u{FFFD}" }
        return String(Character(scalar))
    }
}
