import Foundation
import Synchronization

// The publisher's CSS, reduced to what the text model can carry.
//
// A deliberately small subset: selectors made of tag, `.class`, `#id` and `*` compounds joined
// by descendant (space) and child (`>`) combinators, in comma lists. A selector with anything
// else in it (pseudo-classes and pseudo-elements, attribute selectors, `+`/`~`, namespaces,
// escapes) is dropped whole, so `p::first-letter` never styles the whole paragraph. The rules
// inside `@supports` always apply, inside `@media` only for no query, `all` or `screen` (never
// `print`, never a feature query we cannot evaluate); other at-rule blocks (`@font-face`, `@page`)
// are skipped. `@import` is recorded and followed by `StylesheetLibrary`. Only the properties in `CSSProperties` are read: the
// stylesheet contributes semantics (italic, bold, small caps, alignment, hiding); the reader's
// font, size, colours and justification stay in charge.

/// The properties the text model understands, as declared by one rule (nil: not declared).
struct CSSProperties: Hashable, Sendable {
    /// Only `super` and `sub` are read: `vertical-align: baseline` (normalize.css puts it on every
    /// `sup`/`sub` and raises them with `position`) never takes the tag's raising away.
    enum VerticalAlign: Hashable, Sendable { case superscript, `subscript` }

    var italic: Bool?
    var bold: Bool?
    var underline: Bool?
    var strikethrough: Bool?
    var smallCaps: Bool?
    var verticalAlign: VerticalAlign?
    /// `justify`, `left` and `start` read as `.natural`: justification is the reader's setting.
    var alignment: BlockAlignment?
    /// `display: none` is true; any other `display` is false.
    var hidden: Bool?

    var isEmpty: Bool { self == CSSProperties() }

    /// Lays `other` on top: every property it declares wins.
    mutating func overlay(_ other: CSSProperties) {
        if let value = other.italic { italic = value }
        if let value = other.bold { bold = value }
        if let value = other.underline { underline = value }
        if let value = other.strikethrough { strikethrough = value }
        if let value = other.smallCaps { smallCaps = value }
        if let value = other.verticalAlign { verticalAlign = value }
        if let value = other.alignment { alignment = value }
        if let value = other.hidden { hidden = value }
    }

    /// The inherited style with these declarations applied: `font-style: normal` takes italic
    /// away, `font-style: italic` adds it, an undeclared property leaves it as it was.
    func applied(to style: InlineStyle) -> InlineStyle {
        var result = style
        func set(_ member: InlineStyle, _ value: Bool?) {
            guard let value else { return }
            if value { result.insert(member) } else { result.remove(member) }
        }
        set(.italic, italic)
        set(.bold, bold)
        set(.underline, underline)
        set(.strikethrough, strikethrough)
        set(.smallCaps, smallCaps)
        switch verticalAlign {
        case .superscript:
            result.insert(.superscript)
            result.remove(.subscript)
        case .subscript:
            result.insert(.subscript)
            result.remove(.superscript)
        case nil:
            break
        }
        return result
    }
}

/// One declaration block (`font-style: italic; text-align: center !important`), split by
/// importance. Also used for inline `style` attributes.
struct CSSDeclarations: Hashable, Sendable {
    var normal = CSSProperties()
    var important = CSSProperties()

    var isEmpty: Bool { normal.isEmpty && important.isEmpty }

    init() {}

    init(_ text: String?) {
        guard let text else { return }
        for declaration in CSSScanner.split(Array(text.unicodeScalars), at: ";") {
            parse(String(String.UnicodeScalarView(declaration)))
        }
    }

    private mutating func parse(_ declaration: String) {
        guard let colon = declaration.firstIndex(of: ":") else { return }
        let property = declaration[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var value = declaration[declaration.index(after: colon)...].lowercased()
        var isImportant = false
        // "!important", also written "! important".
        if let bang = value.lastIndex(of: "!"),
           value[value.index(after: bang)...].trimmingCharacters(in: .whitespacesAndNewlines) == "important" {
            value = String(value[..<bang])
            isImportant = true
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = value.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = words.first else { return }

        var target = CSSProperties()
        switch property {
        case "font-style":
            switch first {
            case "italic", "oblique": target.italic = true
            case "normal": target.italic = false
            default: break
            }
        case "font-weight":
            switch first {
            case "bold", "bolder": target.bold = true
            case "normal", "lighter": target.bold = false
            default:
                if let weight = Int(first) { target.bold = weight >= 600 }
            }
        case "text-decoration", "text-decoration-line":
            // Additive like the browsers' decoration propagation, except that `none` takes away
            // what the element's own tag gave it (`<u style="text-decoration: none">`).
            if first == "none" {
                target.underline = false
                target.strikethrough = false
            }
            if words.contains("underline") { target.underline = true }
            if words.contains("line-through") { target.strikethrough = true }
        case "font-variant", "font-variant-caps":
            if words.contains("small-caps") || words.contains("all-small-caps") {
                target.smallCaps = true
            } else if first == "normal" || first == "none" {
                target.smallCaps = false
            }
        case "vertical-align":
            switch first {
            case "super": target.verticalAlign = .superscript
            case "sub": target.verticalAlign = .subscript
            default: break
            }
        case "text-align":
            switch first {
            case "center", "-webkit-center": target.alignment = .center
            case "right", "end": target.alignment = .trailing
            case "justify", "left", "start": target.alignment = .natural
            default: break
            }
        case "display":
            if first != "inherit", first != "initial", first != "unset" { target.hidden = first == "none" }
        default:
            return
        }
        if isImportant { important.overlay(target) } else { normal.overlay(target) }
    }
}

/// An element as selectors see it.
struct CSSElement: Sendable {
    var tag: String
    var id: String?
    var classes: [String]

    init(tag: String, attributes: [String: String]) {
        self.tag = tag
        id = attributes["id"].flatMap { $0.isEmpty ? nil : $0 }
        var seen: [String] = []
        for token in (attributes["class"] ?? "").split(whereSeparator: \.isWhitespace) {
            let name = String(token)
            if !seen.contains(name) { seen.append(name) }
        }
        classes = seen
    }
}

/// A tag/`*`, `#id` and `.class` compound: `p.note`, `#title`, `*`.
struct CSSCompound: Hashable, Sendable {
    /// Lowercased; nil matches any tag.
    var tag: String?
    var id: String?
    var classes: [String] = []

    func matches(_ element: CSSElement) -> Bool {
        if let tag, tag != element.tag { return false }
        if let id, id != element.id { return false }
        return classes.allSatisfy(element.classes.contains)
    }
}

struct CSSSelector: Hashable, Sendable {
    enum Combinator: Hashable, Sendable { case descendant, child }

    /// Left to right; `combinators[i]` joins `compounds[i]` and `compounds[i + 1]`.
    var compounds: [CSSCompound]
    var combinators: [Combinator]

    /// ids, classes, tags, packed so that a larger number is more specific.
    var specificity: Int {
        var ids = 0, classes = 0, tags = 0
        for compound in compounds {
            if compound.id != nil { ids += 1 }
            classes += compound.classes.count
            if compound.tag != nil { tags += 1 }
        }
        return ids * 1_000_000 + classes * 1_000 + tags
    }

    /// `ancestors` runs from the root to the element's parent.
    func matches(_ element: CSSElement, ancestors: ArraySlice<CSSElement>) -> Bool {
        guard let last = compounds.last, last.matches(element) else { return false }
        return matchesLeft(of: compounds.count - 1, ancestors: ancestors)
    }

    private func matchesLeft(of index: Int, ancestors: ArraySlice<CSSElement>) -> Bool {
        guard index > 0 else { return true }
        let compound = compounds[index - 1]
        switch combinators[index - 1] {
        case .child:
            guard let parent = ancestors.last, compound.matches(parent) else { return false }
            return matchesLeft(of: index - 1, ancestors: ancestors.dropLast())
        case .descendant:
            var rest = ancestors
            while let candidate = rest.last {
                rest = rest.dropLast()
                if compound.matches(candidate), matchesLeft(of: index - 1, ancestors: rest) { return true }
            }
            return false
        }
    }

    /// Parses one selector of a comma list; nil for anything outside the supported subset.
    init?(_ text: some Collection<Unicode.Scalar>) {
        var compounds: [CSSCompound] = []
        var combinators: [Combinator] = []
        var current: CSSCompound?
        var pending: Combinator?
        let scalars = Array(text)
        var i = 0

        func finishCompound() {
            if let compound = current {
                compounds.append(compound)
                current = nil
            }
        }
        func startCompound() -> Bool {
            guard current == nil else { return true }
            if !compounds.isEmpty {
                combinators.append(pending ?? .descendant)
            } else if pending != nil {
                return false   // "> p": a combinator with nothing on its left
            }
            pending = nil
            current = CSSCompound()
            return true
        }
        func identifier() -> String? {
            let start = i
            while i < scalars.count, CSSScanner.isIdentifier(scalars[i]) { i += 1 }
            return i > start ? String(String.UnicodeScalarView(scalars[start..<i])) : nil
        }

        while i < scalars.count {
            let scalar = scalars[i]
            if CSSScanner.isWhitespace(scalar) {
                finishCompound()
                i += 1
            } else if scalar == ">" {
                finishCompound()
                guard pending == nil, !compounds.isEmpty else { return nil }
                pending = .child
                i += 1
            } else if scalar == "*" {
                guard current == nil, startCompound() else { return nil }
                i += 1
            } else if scalar == "." || scalar == "#" {
                guard startCompound() else { return nil }
                i += 1
                guard let name = identifier() else { return nil }
                if scalar == "." {
                    current?.classes.append(name)
                } else {
                    guard current?.id == nil else { return nil }
                    current?.id = name
                }
            } else if CSSScanner.isIdentifier(scalar) {
                guard current == nil, startCompound(), let name = identifier() else { return nil }
                current?.tag = name.lowercased()
            } else {
                return nil   // :pseudo, [attr], +, ~, ns|tag, \escape...
            }
        }
        finishCompound()
        guard !compounds.isEmpty, pending == nil else { return nil }
        self.compounds = compounds
        self.combinators = combinators
    }
}

/// A parsed stylesheet: its rules in source order, indexed by the rightmost compound.
public struct Stylesheet: Sendable {
    struct Rule: Sendable {
        var selector: CSSSelector
        var specificity: Int
        var declarations: CSSDeclarations
    }

    private(set) var rules: [Rule] = []
    /// `@import` targets, as written (relative to the stylesheet's own path).
    public private(set) var imports: [String] = []

    private var byID: [String: [Int]] = [:]
    private var byClass: [String: [Int]] = [:]
    private var byTag: [String: [Int]] = [:]
    private var universal: [Int] = []

    public var ruleCount: Int { rules.count }

    public init(css: String) {
        parse(CSSScanner.stripComments(Array(css.unicodeScalars)), topLevel: true)
        buildIndex()
    }

    /// Appends the rules of `scalars` (a whole sheet, or the inside of an `@media`/`@supports`
    /// block) in source order.
    private mutating func parse(_ scalars: [Unicode.Scalar], topLevel: Bool) {
        var i = 0
        while i < scalars.count {
            let scalar = scalars[i]
            if CSSScanner.isWhitespace(scalar) || scalar == "}" || scalar == ";" {
                i += 1
                continue
            }
            if scalar == "@" {
                let (end, terminator) = CSSScanner.scan(scalars, from: i, until: [";", "{"])
                if terminator == ";" || terminator == nil {
                    if topLevel, let target = CSSScanner.importTarget(scalars[i..<end]) { imports.append(target) }
                    i = end + 1
                } else {
                    let close = CSSScanner.endOfBlock(scalars, openingAt: end)
                    if CSSScanner.conditionalApplies(scalars[i..<end]) {
                        parse(Array(scalars[(end + 1) ..< min(close, scalars.count)]), topLevel: false)
                    }
                    i = close + 1
                }
                continue
            }
            let (open, terminator) = CSSScanner.scan(scalars, from: i, until: ["{"])
            guard terminator != nil else { break }
            let close = CSSScanner.endOfBlock(scalars, openingAt: open)
            let body = scalars[(open + 1) ..< min(close, scalars.count)]
            let declarations = CSSDeclarations(String(String.UnicodeScalarView(body)))
            if !declarations.isEmpty {
                for part in CSSScanner.split(Array(scalars[i..<open]), at: ",") {
                    guard let selector = CSSSelector(part) else { continue }
                    rules.append(Rule(selector: selector, specificity: selector.specificity, declarations: declarations))
                }
            }
            i = close + 1
        }
    }

    /// Decodes like the documents (UTF-8 with or without a BOM, UTF-16 with a BOM, else Latin 1).
    public init(data: Data) {
        self.init(css: XHTMLConverter.decodeText(data))
    }

    /// The rules of several stylesheets, in order, as one (`@import`s already resolved).
    init(merging sheets: [Stylesheet]) {
        rules = sheets.flatMap(\.rules)
        buildIndex()
    }

    private mutating func buildIndex() {
        for (index, rule) in rules.enumerated() {
            guard let key = rule.selector.compounds.last else { continue }
            if let id = key.id {
                byID[id, default: []].append(index)
            } else if let className = key.classes.first {
                byClass[className, default: []].append(index)
            } else if let tag = key.tag {
                byTag[tag, default: []].append(index)
            } else {
                universal.append(index)
            }
        }
    }

    /// Indices of the rules whose rightmost compound could match `element`.
    func candidates(for element: CSSElement) -> [Int] {
        var result = universal
        if let id = element.id, let list = byID[id] { result += list }
        for className in element.classes {
            if let list = byClass[className] { result += list }
        }
        if let list = byTag[element.tag] { result += list }
        return result
    }
}

/// The stylesheets that apply to one document, in document order, and the cascade over them.
struct StyleCascade {
    var sheets: [Stylesheet] = []

    var isEmpty: Bool { sheets.allSatisfy { $0.ruleCount == 0 } }

    /// The declarations that win for `element`: stylesheet rules by specificity then source
    /// order, then the inline `style`, then the `!important` ones the same way round.
    func properties(for element: CSSElement, ancestors: ArraySlice<CSSElement>, inline: CSSDeclarations) -> CSSProperties {
        var matched: [(specificity: Int, sheet: Int, rule: Int)] = []
        for (sheetIndex, sheet) in sheets.enumerated() {
            for ruleIndex in sheet.candidates(for: element)
            where sheet.rules[ruleIndex].selector.matches(element, ancestors: ancestors) {
                matched.append((sheet.rules[ruleIndex].specificity, sheetIndex, ruleIndex))
            }
        }
        matched.sort { ($0.specificity, $0.sheet, $0.rule) < ($1.specificity, $1.sheet, $1.rule) }
        var result = CSSProperties()
        for match in matched { result.overlay(sheets[match.sheet].rules[match.rule].declarations.normal) }
        result.overlay(inline.normal)
        for match in matched { result.overlay(sheets[match.sheet].rules[match.rule].declarations.important) }
        result.overlay(inline.important)
        return result
    }
}

/// A book's stylesheets, parsed once each and shared by every chapter that links them (most
/// books have one or two for the whole spine). Thread-safe: chapters convert in parallel.
public final class StylesheetLibrary: Sendable {
    /// One file's load-and-parse, done once: the first chapter to ask holds the slot's lock while
    /// it reads, and the others wait for its result instead of parsing the file again.
    private final class Slot: Sendable {
        let sheet = Mutex<Stylesheet??>(nil)
    }

    private let load: @Sendable (String) -> Data?
    /// Zip path → its slot (the sheet as written, `@import`s not yet followed).
    private let slots = Mutex<[String: Slot]>([:])
    /// Zip path → the sheet with its imports folded in (nil: missing or unreadable).
    private let resolved = Mutex<[String: Stylesheet?]>([:])

    /// `load` reads a zip path.
    public init(load: @escaping @Sendable (String) -> Data?) {
        self.load = load
    }

    public convenience init(book: EPUBBook) {
        self.init { path in try? book.data(at: path) }
    }

    /// The stylesheet an `href` in the document at `documentPath` names.
    public func stylesheet(href: String, relativeTo documentPath: String) -> Stylesheet? {
        guard !EPUBPath.isExternal(href) else { return nil }
        return stylesheet(at: EPUBPath.resolve(href, relativeTo: documentPath))
    }

    /// The stylesheet at a zip path, its `@import`s first.
    public func stylesheet(at path: String) -> Stylesheet? {
        resolve(path, visiting: [])
    }

    /// Reads and parses a file at most once per library, however many threads ask at once. No
    /// other slot is touched while this one is held, so an `@import` cycle cannot deadlock.
    private func parsed(_ path: String) -> Stylesheet? {
        let slot = slots.withLock { slots in
            if let slot = slots[path] { return slot }
            let slot = Slot()
            slots[path] = slot
            return slot
        }
        return slot.sheet.withLock { sheet in
            if let done = sheet { return done }
            let parsed = load(path).map { Stylesheet(data: $0) }
            sheet = .some(parsed)
            return parsed
        }
    }

    /// Folds the imports in (cheap: the parsing is shared); cached once done.
    private func resolve(_ path: String, visiting: Set<String>) -> Stylesheet? {
        if let cached = resolved.withLock({ $0[path] }) { return cached }
        guard !visiting.contains(path), visiting.count < 8 else { return nil }
        var sheet = parsed(path)
        if let own = sheet, !own.imports.isEmpty {
            let imported = own.imports.compactMap { href -> Stylesheet? in
                guard !EPUBPath.isExternal(href) else { return nil }
                return resolve(EPUBPath.resolve(href, relativeTo: path), visiting: visiting.union([path]))
            }
            sheet = Stylesheet(merging: imported + [own])
        }
        if visiting.isEmpty { resolved.withLock { $0[path] = .some(sheet) } }
        return sheet
    }
}

/// Character-level helpers: strings, comments, balanced blocks.
enum CSSScanner {
    static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x20, 0x09, 0x0A, 0x0D, 0x0C: return true
        default: return false
        }
    }

    static func isIdentifier(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D, 0x5F: return true
        default: return scalar.value >= 0x80
        }
    }

    /// Removes `/* ... */` comments (not inside strings) and the `<!--`/`-->` an old `<style>`
    /// block wraps itself in.
    static func stripComments(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var result: [Unicode.Scalar] = []
        result.reserveCapacity(scalars.count)
        var i = 0
        var quote: Unicode.Scalar?
        while i < scalars.count {
            let scalar = scalars[i]
            if let open = quote {
                result.append(scalar)
                if scalar == "\\", i + 1 < scalars.count {
                    result.append(scalars[i + 1])
                    i += 2
                    continue
                }
                if scalar == open { quote = nil }
                i += 1
            } else if scalar == "/", i + 1 < scalars.count, scalars[i + 1] == "*" {
                i += 2
                while i < scalars.count, !(scalars[i] == "*" && i + 1 < scalars.count && scalars[i + 1] == "/") { i += 1 }
                i += 2
                result.append(" ")
            } else if scalar == "<", scalars[i...].starts(with: ["<", "!", "-", "-"]) {
                i += 4
            } else if scalar == "<", scalars[i...].starts(with: Array("<![CDATA[".unicodeScalars)) {
                i += 9
            } else if scalar == "]", scalars[i...].starts(with: ["]", "]", ">"]) {
                i += 3
            } else if scalar == "-", scalars[i...].starts(with: ["-", "-", ">"]) {
                i += 3
            } else {
                if scalar == "\"" || scalar == "'" { quote = scalar }
                result.append(scalar)
                i += 1
            }
        }
        return result
    }

    /// The index of the first of `stops` at nesting depth 0 outside strings (and which one it
    /// was), or the end of the input and nil.
    static func scan(_ scalars: [Unicode.Scalar], from start: Int, until stops: Set<Unicode.Scalar>) -> (Int, Unicode.Scalar?) {
        var i = start
        var depth = 0
        var quote: Unicode.Scalar?
        while i < scalars.count {
            let scalar = scalars[i]
            if let open = quote {
                if scalar == "\\" { i += 1 } else if scalar == open { quote = nil }
            } else if scalar == "\"" || scalar == "'" {
                quote = scalar
            } else if depth == 0, stops.contains(scalar) {
                return (i, scalar)
            } else if scalar == "(" || scalar == "[" {
                depth += 1
            } else if scalar == ")" || scalar == "]" {
                depth = max(0, depth - 1)
            }
            i += 1
        }
        return (scalars.count, nil)
    }

    /// The index of the `}` closing the block whose `{` is at `open` (nested blocks skipped),
    /// or the end of the input.
    static func endOfBlock(_ scalars: [Unicode.Scalar], openingAt open: Int) -> Int {
        var i = open + 1
        var depth = 1
        var quote: Unicode.Scalar?
        while i < scalars.count {
            let scalar = scalars[i]
            if let opened = quote {
                if scalar == "\\" { i += 1 } else if scalar == opened { quote = nil }
            } else if scalar == "\"" || scalar == "'" {
                quote = scalar
            } else if scalar == "{" {
                depth += 1
            } else if scalar == "}" {
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        return scalars.count
    }

    /// Splits at `separator` where it is not inside a string, parentheses or brackets.
    static func split(_ scalars: [Unicode.Scalar], at separator: Unicode.Scalar) -> [ArraySlice<Unicode.Scalar>] {
        var parts: [ArraySlice<Unicode.Scalar>] = []
        var start = 0
        while start <= scalars.count {
            let (end, _) = scan(scalars, from: start, until: [separator])
            parts.append(scalars[start..<end])
            start = end + 1
        }
        return parts
    }

    /// Whether the rules inside an at-rule block apply: always for `@supports` (the reader is
    /// taken to support what is asked; SE un-hides its title page that way), for `@media` when
    /// `mediaApplies`, never for anything else (`@font-face`, `@page`, `@keyframes`).
    static func conditionalApplies(_ prelude: ArraySlice<Unicode.Scalar>) -> Bool {
        let text = String(String.UnicodeScalarView(prelude)).lowercased()
        if text.hasPrefix("@supports") { return true }
        if text.hasPrefix("@media") { return mediaApplies(String(text.dropFirst("@media".count))) }
        return false
    }

    /// A media query list (an `@media` prelude or a `media` attribute) applies when it is empty
    /// or one of its queries is a bare `all` or `screen` (`only` allowed). Print, other media
    /// types and feature queries (`all and (prefers-color-scheme: dark)`), which this reader
    /// cannot evaluate, do not.
    static func mediaApplies(_ query: String?) -> Bool {
        guard let query = query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !query.isEmpty else {
            return true
        }
        return query.split(separator: ",").contains { part in
            var words = part.split(whereSeparator: { $0.isWhitespace })
            if words.first == "only" { words.removeFirst() }
            return words.count == 1 && (words[0] == "all" || words[0] == "screen")
        }
    }

    /// The target of `@import url("a.css") screen;` / `@import 'a.css';`.
    static func importTarget(_ rule: ArraySlice<Unicode.Scalar>) -> String? {
        let text = String(String.UnicodeScalarView(rule)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.lowercased().hasPrefix("@import") else { return nil }
        var rest = text.dropFirst("@import".count).trimmingCharacters(in: .whitespacesAndNewlines)[...]
        if rest.lowercased().hasPrefix("url(") {
            rest = rest.dropFirst(4)
            guard let close = rest.firstIndex(of: ")") else { return nil }
            rest = rest[..<close]
            let trimmed = rest.trimmingCharacters(in: .whitespacesAndNewlines)
            let unquoted = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return unquoted.isEmpty ? nil : unquoted
        }
        guard let quote = rest.first, quote == "\"" || quote == "'" else { return nil }
        rest = rest.dropFirst()
        guard let close = rest.firstIndex(of: quote) else { return nil }
        let target = String(rest[..<close])
        return target.isEmpty ? nil : target
    }
}
