import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Sitemaps: where they are (`robots.txt`), what they list, and which listed
/// pages match the agent's words (the web's `sitemap.ts`). Pure.
enum Sitemap {

    /// A site with many sitemaps is still read in a moment: the first few say
    /// enough about its sections, and each is one request.
    static let maxSitemaps = 4
    static let maxPages = 5000
    static let minWordLength = 3

    /// The sitemaps `robots.txt` names on the site's origin (a `.gz` one is
    /// skipped), or the conventional `/sitemap.xml`.
    static func sitemapURLs(robots: String?, siteURL: URL) -> [URL] {
        let named = (robots ?? "")
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> URL? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.lowercased().hasPrefix("sitemap:") else { return nil }
                let href = trimmed.dropFirst("sitemap:".count).trimmingCharacters(in: .whitespaces)
                    .split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
                return SiteAddress.sameOriginURL(href, base: siteURL)
            }
            .filter { !isCompressed($0) }
        if !named.isEmpty { return named }
        return SiteAddress.sameOriginURL("/sitemap.xml", base: siteURL).map { [$0] } ?? []
    }

    static func isCompressed(_ url: URL) -> Bool {
        url.path.hasSuffix(".gz")
    }

    /// One sitemap file: an index of further sitemaps, or a list of pages.
    enum File: Equatable {
        case index([String])
        case pages([String])
    }

    /// The `<loc>`s of a sitemap or a sitemap index; nil when it is not XML.
    static func parse(_ data: Data) -> File? {
        let reader = LocReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.shouldResolveExternalEntities = false
        guard parser.parse() || !reader.locs.isEmpty, let root = reader.root else { return nil }
        return root == "sitemapindex" ? .index(reader.locs) : .pages(reader.locs)
    }

    private final class LocReader: NSObject, XMLParserDelegate {
        var root: String?
        var locs: [String] = []
        private var inLoc = false
        private var text = ""

        private func local(_ name: String) -> String {
            name.split(separator: ":").last.map(String.init)?.lowercased() ?? name
        }

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName: String?, attributes: [String: String] = [:]
        ) {
            let name = local(elementName)
            if root == nil { root = name }
            if name == "loc" {
                inLoc = true
                text = ""
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inLoc { text += string }
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if inLoc { text += String(decoding: CDATABlock, as: UTF8.self) }
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?
        ) {
            if local(elementName) == "loc" {
                inLoc = false
                let loc = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !loc.isEmpty { locs.append(loc) }
            }
        }
    }

    private static func wordsOf(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .map(String.init)
            .filter { $0.count >= minWordLength }
    }

    // "returns" finds /help/return-policy: a word also matches without a plural s.
    private static func stems(_ word: String) -> [String] {
        word.hasSuffix("s") ? [word, String(word.dropLast())] : [word]
    }

    /// The paths whose address holds the most words of `query`, best first;
    /// ties go to the shorter path, then to the sitemap's order.
    static func pathsMatching(_ paths: [String], query: String, limit: Int) -> [String] {
        let words = wordsOf(query)
        guard !words.isEmpty else { return Array(paths.prefix(limit)) }
        return paths.enumerated()
            .map { offset, path -> (path: String, score: Int, offset: Int) in
                let address = path.lowercased()
                let score = words.filter { word in stems(word).contains { address.contains($0) } }.count
                return (path, score, offset)
            }
            .filter { $0.score > 0 }
            .sorted { a, b in
                if a.score != b.score { return a.score > b.score }
                if a.path.count != b.path.count { return a.path.count < b.path.count }
                return a.offset < b.offset
            }
            .prefix(limit)
            .map(\.path)
    }
}
