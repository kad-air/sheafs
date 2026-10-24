import Foundation

/// One lexical unit of an HTML or XHTML document.
package enum HTMLToken: Hashable, Sendable {
    /// An opening tag. `name` is lowercased with any namespace prefix dropped (`epub:switch`
    /// becomes `switch`); attribute names are lowercased but keep their prefix (`xlink:href`);
    /// attribute values have character references decoded. `selfClosing` is true when the tag
    /// was written `<x/>`.
    case start(name: String, attributes: [String: String], selfClosing: Bool)
    /// A closing tag, with the same name normalization as `start`.
    case end(name: String)
    /// Character data with character references decoded (CDATA sections and the contents of
    /// `script`/`style` are delivered verbatim).
    case text(String)
}

/// A tolerant tokenizer for real-world EPUB XHTML.
///
/// It never fails and never throws: undefined entities pass through, unclosed or stray tags are
/// reported as written, a `<` that cannot begin markup stays text, and an unterminated construct
/// at the end of the input is dropped. Comments, the DOCTYPE and processing instructions
/// (`<?xml ?>`) are skipped; `<![CDATA[ ]]>` contents are emitted as text.
///
/// The tokenizer does not build a tree and knows nothing about nesting; that is the converter's
/// job.
package struct HTMLTokenizer: Sendable {
    /// Elements that never have content, whether or not they are written `<br/>`.
    package static let voidElements: Set<String> = [
        "br", "img", "hr", "meta", "link", "input", "area", "base", "col", "embed", "source",
        "track", "wbr", "param",
    ]

    /// Elements whose content is raw text (not markup) up to the matching end tag.
    private static let rawTextElements: Set<String> = ["script", "style"]

    private let bytes: [UInt8]

    package init(_ string: String) {
        bytes = Array(string.utf8)
    }

    /// True when a start tag with this name and self-closing flag cannot have content.
    package static func isVoid(name: String, selfClosing: Bool) -> Bool {
        selfClosing || voidElements.contains(name)
    }

    /// Tokenizes the whole input.
    package func tokens() -> [HTMLToken] {
        var tokens: [HTMLToken] = []
        let n = bytes.count
        var i = 0
        var textStart = 0

        func flushText(upTo end: Int) {
            if end > textStart { tokens.append(.text(decodedText(textStart, end))) }
        }

        while i < n {
            guard bytes[i] == Byte.lt else {
                i += 1
                continue
            }
            let next = i + 1 < n ? bytes[i + 1] : 0
            if next == Byte.bang {
                flushText(upTo: i)
                if hasPrefix(Self.commentOpen, at: i) {
                    i = find(Self.commentClose, from: i + 4).map { $0 + 3 } ?? n
                } else if hasPrefix(Self.cdataOpen, at: i) {
                    let contentStart = i + 9
                    let end = find(Self.cdataClose, from: contentStart) ?? n
                    if end > contentStart {
                        tokens.append(.text(String(decoding: bytes[contentStart..<end], as: UTF8.self)))
                    }
                    i = min(end + 3, n)
                } else {
                    i = (firstIndex(of: Byte.gt, from: i + 2) ?? n - 1) + 1
                }
                textStart = i
            } else if next == Byte.question {
                flushText(upTo: i)
                if let close = find(Self.piClose, from: i + 2) {
                    i = close + 2
                } else {
                    i = (firstIndex(of: Byte.gt, from: i + 2) ?? n - 1) + 1
                }
                textStart = i
            } else if next == Byte.slash {
                if i + 2 < n, Byte.isLetter(bytes[i + 2]) {
                    flushText(upTo: i)
                    let (name, after) = parseEndTag(at: i)
                    tokens.append(.end(name: name))
                    i = after
                    textStart = i
                } else if i + 2 < n, bytes[i + 2] == Byte.gt {
                    flushText(upTo: i)
                    i += 3
                    textStart = i
                } else {
                    i += 1  // "</" followed by something odd: literal text
                }
            } else if Byte.isLetter(next) {
                flushText(upTo: i)
                guard let (tag, after) = parseStartTag(at: i) else {
                    // Unterminated tag at the end of the input: drop it.
                    i = n
                    textStart = n
                    break
                }
                tokens.append(tag)
                i = after
                textStart = i
                if case let .start(name, _, selfClosing) = tag, !selfClosing, Self.rawTextElements.contains(name) {
                    let end = findClosingTag(named: name, from: i) ?? n
                    if end > i { tokens.append(.text(String(decoding: bytes[i..<end], as: UTF8.self))) }
                    i = end
                    textStart = i
                }
            } else {
                i += 1  // a lone "<" is just text
            }
        }
        flushText(upTo: n)
        return tokens
    }

    // MARK: Tags

    private func parseEndTag(at start: Int) -> (name: String, next: Int) {
        let n = bytes.count
        var j = start + 2
        let nameStart = j
        while j < n, !Byte.isSpace(bytes[j]), bytes[j] != Byte.gt, bytes[j] != Byte.slash { j += 1 }
        let name = Self.localName(bytes[nameStart..<j])
        let close = firstIndex(of: Byte.gt, from: j) ?? n - 1
        return (name, close + 1)
    }

    private func parseStartTag(at start: Int) -> (HTMLToken, next: Int)? {
        let n = bytes.count
        var j = start + 1
        let nameStart = j
        while j < n, !Byte.isSpace(bytes[j]), bytes[j] != Byte.slash, bytes[j] != Byte.gt { j += 1 }
        let name = Self.localName(bytes[nameStart..<j])
        var attributes: [String: String] = [:]
        var selfClosing = false

        while true {
            while j < n, Byte.isSpace(bytes[j]) { j += 1 }
            guard j < n else { return nil }
            let c = bytes[j]
            if c == Byte.gt {
                j += 1
                break
            }
            if c == Byte.slash {
                if j + 1 < n, bytes[j + 1] == Byte.gt {
                    selfClosing = true
                    j += 2
                    break
                }
                j += 1
                continue
            }

            // Attribute name. A leading "=" is part of the name, which keeps the loop moving.
            let attrStart = j
            if bytes[j] == Byte.equals { j += 1 }
            while j < n, !Byte.isSpace(bytes[j]), bytes[j] != Byte.equals, bytes[j] != Byte.gt,
                  !(bytes[j] == Byte.slash && j + 1 < n && bytes[j + 1] == Byte.gt) {
                j += 1
            }
            let attrName = String(decoding: bytes[attrStart..<j], as: UTF8.self).lowercased()

            while j < n, Byte.isSpace(bytes[j]) { j += 1 }
            var value = ""
            if j < n, bytes[j] == Byte.equals {
                j += 1
                while j < n, Byte.isSpace(bytes[j]) { j += 1 }
                if j < n, bytes[j] == Byte.doubleQuote || bytes[j] == Byte.singleQuote {
                    let quote = bytes[j]
                    let valueStart = j + 1
                    if let end = firstIndex(of: quote, from: valueStart) {
                        value = decodedText(valueStart, end)
                        j = end + 1
                    } else {
                        // Unterminated quote: take everything up to the next ">" and carry on.
                        let end = firstIndex(of: Byte.gt, from: valueStart) ?? n
                        value = decodedText(valueStart, end)
                        j = end
                    }
                } else {
                    let valueStart = j
                    while j < n, !Byte.isSpace(bytes[j]), bytes[j] != Byte.gt { j += 1 }
                    value = decodedText(valueStart, j)
                }
            }
            if !attrName.isEmpty, attributes[attrName] == nil { attributes[attrName] = value }
        }
        return (.start(name: name, attributes: attributes, selfClosing: selfClosing), j)
    }

    /// Lowercased local name: everything after the last colon.
    private static func localName(_ slice: ArraySlice<UInt8>) -> String {
        let lowered = String(decoding: slice, as: UTF8.self).lowercased()
        if let colon = lowered.lastIndex(of: ":") {
            let local = lowered[lowered.index(after: colon)...]
            if !local.isEmpty { return String(local) }
        }
        return lowered
    }

    // MARK: Scanning helpers

    private static let commentOpen = Array("<!--".utf8)
    private static let commentClose = Array("-->".utf8)
    private static let cdataOpen = Array("<![CDATA[".utf8)
    private static let cdataClose = Array("]]>".utf8)
    private static let piClose = Array("?>".utf8)

    private func decodedText(_ start: Int, _ end: Int) -> String {
        HTMLEntities.decode(String(decoding: bytes[start..<end], as: UTF8.self))
    }

    private func firstIndex(of byte: UInt8, from start: Int) -> Int? {
        guard start < bytes.count else { return nil }
        return bytes[start...].firstIndex(of: byte)
    }

    private func hasPrefix(_ pattern: [UInt8], at index: Int) -> Bool {
        guard index + pattern.count <= bytes.count else { return false }
        for (offset, byte) in pattern.enumerated() where bytes[index + offset] != byte { return false }
        return true
    }

    private func find(_ pattern: [UInt8], from start: Int) -> Int? {
        guard let first = pattern.first, start <= bytes.count - pattern.count else { return nil }
        var i = start
        while let hit = firstIndex(of: first, from: i), hit + pattern.count <= bytes.count {
            if hasPrefix(pattern, at: hit) { return hit }
            i = hit + 1
        }
        return nil
    }

    /// Index of the `</name` that ends a raw-text element, matched case-insensitively.
    private func findClosingTag(named name: String, from start: Int) -> Int? {
        let nameBytes = Array(name.utf8)
        var i = start
        while let hit = find([Byte.lt, Byte.slash], from: i) {
            let nameStart = hit + 2
            if nameStart + nameBytes.count <= bytes.count {
                var matches = true
                for (offset, expected) in nameBytes.enumerated() where Byte.lowercased(bytes[nameStart + offset]) != expected {
                    matches = false
                    break
                }
                if matches { return hit }
            }
            i = hit + 2
        }
        return nil
    }

    private enum Byte {
        static let lt = UInt8(ascii: "<")
        static let gt = UInt8(ascii: ">")
        static let slash = UInt8(ascii: "/")
        static let bang = UInt8(ascii: "!")
        static let question = UInt8(ascii: "?")
        static let equals = UInt8(ascii: "=")
        static let doubleQuote = UInt8(ascii: "\"")
        static let singleQuote = UInt8(ascii: "'")

        static func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0x0C }
        static func isLetter(_ b: UInt8) -> Bool { (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) }
        static func lowercased(_ b: UInt8) -> UInt8 { b >= 0x41 && b <= 0x5A ? b + 0x20 : b }
    }
}
