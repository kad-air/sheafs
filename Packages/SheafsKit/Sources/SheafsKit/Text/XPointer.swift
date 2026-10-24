import Foundation

/// A KOReader (CREngine) reading position, the `progress` string of the kosync protocol:
///
///     /body/DocFragment[12]/body/div/p[3]/text().0
///     /body/DocFragment[7]/body/section[1]/p[44]/text()[2].186
///
/// `DocFragment[N]` is the 1-based index over the full OPF spine. Element steps are indexed
/// 1-based among same-tag siblings; a missing index means 1. The optional `text()[k].offset`
/// tail names a text node within the element and a character offset inside it.
public struct XPointer: Hashable, Sendable {
    /// 0-based spine index.
    public var spineIndex: Int
    /// Path from the document body, e.g. "/body/section[1]/p[44]".
    public var elementPath: String
    /// 1-based text node index within the element (`text()[k]`), when present.
    public var textNodeIndex: Int?
    /// Character offset inside that text node, when present.
    public var characterOffset: Int?

    public init(spineIndex: Int, elementPath: String, textNodeIndex: Int? = nil, characterOffset: Int? = nil) {
        self.spineIndex = spineIndex
        self.elementPath = elementPath
        self.textNodeIndex = textNodeIndex
        self.characterOffset = characterOffset
    }

    /// Parses a CREngine pointer. Returns nil for anything that is not of the EPUB form.
    public init?(parsing string: String) {
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("/body/DocFragment") else { return nil }
        var rest = s.dropFirst("/body/DocFragment".count)
        var fragment = 1
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]"),
                  let n = Int(rest[rest.index(after: rest.startIndex)..<close]) else { return nil }
            fragment = n
            rest = rest[rest.index(after: close)...]
        }
        guard fragment >= 1 else { return nil }
        var path = String(rest)
        var textNode: Int?
        var offset: Int?
        if let range = path.range(of: "/text()") {
            let tail = path[range.upperBound...]
            path = String(path[..<range.lowerBound])
            var t = Substring(tail)
            if t.hasPrefix("[") {
                guard let close = t.firstIndex(of: "]"),
                      let k = Int(t[t.index(after: t.startIndex)..<close]) else { return nil }
                textNode = k
                t = t[t.index(after: close)...]
            } else {
                textNode = 1
            }
            if t.hasPrefix(".") {
                guard let o = Int(t.dropFirst()) else { return nil }
                offset = o
            }
        }
        if path.isEmpty { path = "/body" }
        guard path.hasPrefix("/") else { return nil }
        self.init(spineIndex: fragment - 1, elementPath: path, textNodeIndex: textNode, characterOffset: offset)
    }

    /// The pointer in CREngine form, with every element step indexed (the dialect CrossPoint
    /// writes and the one validated against real device pointers).
    public var serialized: String {
        var s = "/body/DocFragment[\(spineIndex + 1)]" + elementPath
        if let characterOffset {
            s += "/text()"
            if let textNodeIndex, textNodeIndex > 1 { s += "[\(textNodeIndex)]" }
            s += ".\(characterOffset)"
        }
        return s
    }
}
