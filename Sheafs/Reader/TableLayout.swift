import UIKit
import SheafsKit

/// Lays out a table block for the page and draws it, one row at a time.
///
/// Columns are sized to their content: each gets at least its longest unbreakable word, and the
/// room left on the page is shared out by how much wider each would like to be (all of it, when
/// the whole table fits on one line per cell). A table whose narrowest layout is still wider than
/// the page is scaled down to fit (type, padding and all), re-measured at each scale until it
/// fits (type does not shrink in proportion), no smaller than `minimumScale`; past that the
/// columns are squeezed and cells break inside words. Horizontal scrolling is not offered.
///
/// Cells are set in the reader's font at 90 % of the body size, in the theme's colours; header
/// cells (`th`, `thead`) bold. A firm rule opens and closes the table and closes its header, light
/// rules separate the rows, the caption sits beneath. Each row is one text attachment
/// (`TableRowAttachment`, one U+FFFC of the block's text), so pagination breaks between rows like
/// between lines. A row never exceeds a page (with the paragraph spacing around the table): a
/// taller one is set smaller, down to half size, and only past that cut. (The converter already
/// turns tables with page-sized cells into plain blocks, `TableShape`.)
///
/// Measuring is CoreText, one line per cell line (widths of all its words at once), each
/// distinct cell string measured once per scale; only cells that wrap are measured with
/// `boundingRect` for their height.
nonisolated final class TableLayout: @unchecked Sendable {
    enum Part: Hashable, Sendable {
        case row(Int)
        case caption
    }

    struct PlacedCell {
        var string: NSAttributedString
        /// The whole cell, padding included, in the row's content coordinates.
        var frame: CGRect
    }

    /// The smallest a wide table is scaled to before its columns are squeezed instead.
    static let minimumScale: CGFloat = 0.6

    let style: TypesetStyle
    let table: TableContent
    /// The table's width (the columns' sum), at most the page width.
    let width: CGFloat
    /// How much a too-wide table was scaled down (1 when it fits).
    let scale: CGFloat
    let columnWidths: [CGFloat]
    /// Each column's narrowest width (its longest word plus padding), at `scale`.
    let minimumColumnWidths: [CGFloat]
    private(set) var rows: [[PlacedCell]] = []
    /// Each row's image height: its cells plus its rules.
    private(set) var rowHeights: [CGFloat] = []
    private var isHeaderRow: [Bool] = []
    /// Cell padding (horizontal, vertical) at `scale`.
    let padding: CGSize
    private var caption: NSAttributedString?
    private var captionSize: CGSize = .zero
    private let captionGap: CGFloat

    private static let firmRule: CGFloat = 1
    private static let headerRule: CGFloat = 0.75
    private static let lightRule: CGFloat = 0.5

    init(table: TableContent, style: TypesetStyle, pageSize: CGSize) {
        self.style = style
        self.table = table
        let available = max(40, floor(pageSize.width))
        let base = CGFloat(style.fontSize) * 0.9
        let columns = max(1, table.columnCount)
        var measurer = Measurer()

        // Where each cell sits: rows fill columns left to right from their first column, spans included.
        var placements: [[(column: Int, span: Int)]] = []
        for row in table.rows {
            var column = row.firstColumn
            placements.append(row.cells.map { cell in
                defer { column += cell.columnSpan }
                return (column, cell.columnSpan)
            })
        }

        // Cell strings by size: built from attributes made once per run style and size.
        var styler = CellStyler(style: style)
        func string(_ r: Int, _ c: Int, at scale: CGFloat) -> NSAttributedString {
            styler.string(for: table.rows[r].cells[c], size: base * scale)
        }
        let allCells = table.rows.indices.flatMap { r in table.rows[r].cells.indices.map { (r, $0) } }

        /// The columns' narrowest and widest widths from the given cells at a scale, and each
        /// cell's own narrowest width (its longest word).
        func columnLimits(_ cells: [(Int, Int)], at scale: CGFloat)
            -> (min: [CGFloat], max: [CGFloat], lows: [[Int]: CGFloat], strings: [[Int]: NSAttributedString]) {
            let pad = base * 0.45 * scale
            var minimum = [CGFloat](repeating: 2 * pad, count: columns)
            var maximum = minimum
            var lows: [[Int]: CGFloat] = [:]
            var made: [[Int]: NSAttributedString] = [:]
            var spanning: [(range: Range<Int>, min: CGFloat, max: CGFloat)] = []
            for (r, c) in cells {
                let place = placements[r][c]
                let range = min(columns, place.column) ..< min(columns, place.column + place.span)
                let cellString = string(r, c, at: scale)
                made[[r, c]] = cellString
                let widths = measurer.widths(of: cellString)
                // 1 pt of slack: measuring and drawing may round a word differently.
                let low = ceil(widths.longestWord) + 1 + 2 * pad
                let high = ceil(widths.natural) + 1 + 2 * pad
                lows[[r, c]] = low
                if range.count == 1 {
                    minimum[range.lowerBound] = max(minimum[range.lowerBound], low)
                    maximum[range.lowerBound] = max(maximum[range.lowerBound], high)
                } else if !range.isEmpty {
                    spanning.append((range, low, high))
                }
            }
            // A spanning cell widens the columns under it evenly when they are too narrow for it.
            for cell in spanning {
                let haveMin = cell.range.reduce(0) { $0 + minimum[$1] }
                if cell.min > haveMin { for c in cell.range { minimum[c] += (cell.min - haveMin) / CGFloat(cell.range.count) } }
                let haveMax = cell.range.reduce(0) { $0 + maximum[$1] }
                if cell.max > haveMax { for c in cell.range { maximum[c] += (cell.max - haveMax) / CGFloat(cell.range.count) } }
            }
            for c in 0 ..< columns { maximum[c] = max(maximum[c], minimum[c]) }
            return (minimum, maximum, lows, made)
        }

        // Scale down until the narrowest layout fits, measured again at each size, because type
        // does not narrow in proportion (and the slack does not scale at all). The search only
        // re-measures the cells that set each column's minimum (and spanning cells); the whole
        // table is measured once more at the scale it settles on.
        var scale: CGFloat = 1
        var limits = columnLimits(allCells, at: 1)
        var cellStrings = limits.strings
        if limits.min.reduce(0, +) > available {
            var candidates: [(Int, Int)] = []
            for (r, c) in allCells {
                let place = placements[r][c]
                let column = min(columns - 1, place.column)
                if place.span > 1 || (limits.lows[[r, c]] ?? 0) >= limits.min[column] * 0.85 { candidates.append((r, c)) }
            }
            var settled = false
            var attempts = 0
            while !settled, attempts < 12 {
                var sum = limits.min.reduce(0, +)
                while sum > available, scale > Self.minimumScale, attempts < 12 {
                    scale = max(Self.minimumScale, scale * available / sum * 0.995)
                    sum = columnLimits(candidates, at: scale).min.reduce(0, +)
                    attempts += 1
                }
                limits = columnLimits(allCells, at: scale)
                settled = limits.min.reduce(0, +) <= available || scale <= Self.minimumScale
            }
            cellStrings = limits.strings
        }
        self.scale = scale
        padding = CGSize(width: base * 0.45 * scale, height: base * 0.3 * scale)
        captionGap = CGFloat(style.fontSize) * 0.4

        let sumMin = limits.min.reduce(0, +), sumMax = limits.max.reduce(0, +)
        var widths: [CGFloat]
        if sumMax <= available {
            widths = limits.max
        } else if sumMin <= available {
            let share = (available - sumMin) / max(1, sumMax - sumMin)
            // Round the extra only: flooring the sum took a column below its longest word ("No." wrapped).
            widths = zip(limits.min, limits.max).map { low, high in low + floor((high - low) * share) }
        } else {
            // Still too wide at the smallest scale: cut the widest columns down to one level, so
            // the narrow ones ("Year", "1881") keep their words whole and only long words break.
            widths = Self.levelled(limits.min, toFit: available)
        }
        columnWidths = widths
        minimumColumnWidths = limits.min
        width = min(available, widths.reduce(0, +))

        // Rows: every cell wraps to its columns; the row is as tall as its tallest cell. The page
        // also holds the spacing before the table and the descent of the line after the last row.
        let maxHeight = max(40, floor(pageSize.height - CGFloat(style.fontSize) * 1.2 - 2))
        var offsets = [CGFloat](repeating: 0, count: columns + 1)
        for c in 0 ..< columns { offsets[c + 1] = offsets[c] + widths[c] }
        isHeaderRow = table.rows.map(\.isHeader)
        let padding = self.padding
        func place(_ r: Int, _ strings: [NSAttributedString]) -> (cells: [PlacedCell], height: CGFloat) {
            var placed: [PlacedCell] = []
            var contentHeight = measurer.lineHeight(style.font.font(size: base * scale)) + 2 * padding.height
            for (c, string) in strings.enumerated() {
                let place = placements[r][c]
                let start = min(columns, place.column), end = min(columns, place.column + place.span)
                let x = offsets[start], cellWidth = max(0, offsets[end] - x)
                let textHeight = measurer.height(of: string, width: max(1, cellWidth - 2 * padding.width))
                contentHeight = max(contentHeight, textHeight + 2 * padding.height)
                placed.append(PlacedCell(string: string, frame: CGRect(x: x, y: 0, width: cellWidth, height: 0)))
            }
            return (placed, contentHeight)
        }
        for r in table.rows.indices {
            let top = r == 0 ? Self.firmRule : 0
            let bottom = bottomRule(row: r)
            let room = maxHeight - top - bottom
            var (placed, contentHeight) = place(r, table.rows[r].cells.indices.map { c in cellStrings[[r, c]] ?? string(r, c, at: scale) })
            // Too tall for a page: the row in smaller type (its columns stay), then cut.
            var rowScale: CGFloat = 1
            while contentHeight > room, rowScale > 0.5 {
                rowScale = max(0.5, rowScale * max(0.7, min(0.95, (room / contentHeight).squareRoot())))
                (placed, contentHeight) = place(r, table.rows[r].cells.indices.map { c in string(r, c, at: scale * rowScale) })
            }
            contentHeight = min(contentHeight, room)
            for i in placed.indices { placed[i].frame.size.height = contentHeight }
            rows.append(placed)
            rowHeights.append(top + contentHeight + bottom)
        }

        if let runs = table.caption {
            let string = Self.captionString(runs, style: style)
            let natural = ceil(measurer.widths(of: string).natural) + 1
            let captionWidth = max(width, min(available, natural))
            let height = measurer.height(of: string, width: captionWidth)
            caption = string
            captionSize = CGSize(width: captionWidth, height: min(maxHeight, height + captionGap))
        }
    }

    /// The parts in block-text order: the rows, then the caption.
    var parts: [Part] { rows.indices.map(Part.row) + (caption == nil ? [] : [.caption]) }

    func size(of part: Part) -> CGSize {
        switch part {
        case .row(let index): CGSize(width: width, height: index < rowHeights.count ? rowHeights[index] : 0)
        case .caption: captionSize
        }
    }

    /// The block's text, typeset: one attachment per part, separated by U+2028 (so each is a line
    /// of its own). Exactly `TableContent.objectText`'s length.
    func attributedString() -> NSAttributedString {
        let result = NSMutableAttributedString()
        // A hairline font, so the lines are as tall as the rows and the rows abut.
        let filler: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 1)]
        for (index, part) in parts.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: TableContent.lineSeparator, attributes: filler)) }
            let piece = NSMutableAttributedString(attachment: TableRowAttachment(layout: self, part: part))
            piece.addAttributes(filler, range: NSRange(location: 0, length: piece.length))
            result.append(piece)
        }
        return result
    }

    // MARK: Drawing

    func image(of part: Part, scale: CGFloat) -> UIImage {
        let size = size(of: part)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: max(1, size.width), height: max(1, size.height)), format: format)
            .image { context in draw(part, in: context.cgContext) }
    }

    /// Draws a part with its top-left corner at the origin of a UIKit (top-left origin) context.
    func draw(_ part: Part, in context: CGContext) {
        switch part {
        case .caption:
            caption?.draw(with: CGRect(x: 0, y: captionGap, width: captionSize.width, height: captionSize.height - captionGap),
                          options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine], context: nil)
        case .row(let index):
            guard index < rows.count else { return }
            let top = index == 0 ? Self.firmRule : 0
            for cell in rows[index] {
                let text = cell.frame.offsetBy(dx: 0, dy: top).insetBy(dx: padding.width, dy: padding.height)
                guard text.width > 0, text.height > 0 else { continue }
                cell.string.draw(with: text, options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine],
                                 context: nil)
            }
            let rule = style.palette.secondary
            if index == 0 {
                context.setFillColor(rule.withAlphaComponent(0.8).cgColor)
                context.fill(CGRect(x: 0, y: 0, width: width, height: Self.firmRule))
            }
            let thickness = bottomRule(row: index)
            let alpha: CGFloat = thickness == Self.lightRule ? 0.35 : 0.8
            context.setFillColor(rule.withAlphaComponent(alpha).cgColor)
            context.fill(CGRect(x: 0, y: rowHeights[index] - thickness, width: width, height: thickness))
        }
    }

    /// The rule under a row: firm under the last, a little firmer under the header, else light.
    private func bottomRule(row: Int) -> CGFloat {
        if row == isHeaderRow.count - 1 { return Self.firmRule }
        if isHeaderRow[row] && !isHeaderRow[row + 1] { return Self.headerRule }
        return Self.lightRule
    }

    // MARK: Hit-testing

    /// The link under a point in a part's coordinates (origin at its top-left), if any. A cell
    /// with one link (a contents table) answers anywhere in it; otherwise the run under the point.
    func link(at point: CGPoint, in part: Part) -> String? {
        guard case .row(let index) = part, index < rows.count else { return nil }
        let top = index == 0 ? Self.firmRule : 0
        guard let cell = rows[index].first(where: { $0.frame.offsetBy(dx: 0, dy: top).contains(point) }) else { return nil }
        let whole = NSRange(location: 0, length: cell.string.length)
        var links = Set<String>()
        cell.string.enumerateAttribute(.sheafsLink, in: whole) { value, _, _ in
            if let value = value as? String { links.insert(value) }
        }
        guard links.count > 1 else { return links.first }

        let storage = NSTextStorage(attributedString: cell.string)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: max(1, cell.frame.width - 2 * padding.width), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        let local = CGPoint(x: point.x - cell.frame.minX - padding.width, y: point.y - top - padding.height)
        let glyph = manager.glyphIndex(for: local, in: container)
        let rect = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard rect.insetBy(dx: -4, dy: -4).contains(local) else { return nil }
        return storage.attribute(.sheafsLink, at: manager.characterIndexForGlyph(at: glyph), effectiveRange: nil) as? String
    }

    // MARK: Strings

    /// Column widths that fit `available` by cutting the widest columns down to one level: every
    /// column narrower than the level keeps its width.
    static func levelled(_ widths: [CGFloat], toFit available: CGFloat) -> [CGFloat] {
        var level = available / CGFloat(max(1, widths.count))
        for _ in 0 ..< widths.count {
            let keep = widths.filter { $0 <= level }
            let cut = widths.count - keep.count
            guard cut > 0 else { break }
            let next = (available - keep.reduce(0, +)) / CGFloat(cut)
            if abs(next - level) < 0.01 { break }
            level = next
        }
        // Only the cut columns are rounded: flooring a kept one took it below its longest word.
        return widths.map { $0 <= level ? $0 : floor(level) }
    }

    /// Makes cell strings with attributes built once per run style and size (fonts are not cheap).
    struct CellStyler {
        let style: TypesetStyle
        private struct RunKey: Hashable {
            var style: InlineStyle
            var header: Bool
            var link: Bool
            var size: CGFloat
        }
        private struct ParagraphKey: Hashable {
            var alignment: BlockAlignment?
            var size: CGFloat
        }
        private var runAttributes: [RunKey: [NSAttributedString.Key: Any]] = [:]
        private var paragraphs: [ParagraphKey: NSParagraphStyle] = [:]

        init(style: TypesetStyle) { self.style = style }

        mutating func string(for cell: TableContent.Cell, size: CGFloat) -> NSAttributedString {
            let string = NSMutableAttributedString()
            for run in cell.runs {
                let key = RunKey(style: run.style, header: cell.isHeader, link: run.link != nil, size: size)
                var attributes = runAttributes[key] ?? {
                    let made = Typesetter.runAttributes(
                        for: InlineRun(text: "", style: run.style, link: run.link), size: size,
                        bold: run.style.contains(.bold) || cell.isHeader, italic: run.style.contains(.italic),
                        color: style.palette.text, style: style)
                    runAttributes[key] = made
                    return made
                }()
                if let link = run.link { attributes[.sheafsLink] = link }
                attributes[.paragraphStyle] = paragraph(cell.alignment, size: size)
                if let language = style.language { attributes[NSAttributedString.Key(kCTLanguageAttributeName as String)] = language }
                string.append(NSAttributedString(string: run.text, attributes: attributes))
            }
            return string
        }

        private mutating func paragraph(_ alignment: BlockAlignment?, size: CGFloat) -> NSParagraphStyle {
            let key = ParagraphKey(alignment: alignment, size: size)
            if let cached = paragraphs[key] { return cached }
            let paragraph = NSMutableParagraphStyle()
            switch alignment {
            case .center: paragraph.alignment = .center
            case .trailing: paragraph.alignment = .right
            default: paragraph.alignment = .natural
            }
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.hyphenationFactor = style.hyphenate ? 0.6 : 0
            paragraph.lineSpacing = style.font.font(size: size).lineHeight * 0.1
            paragraphs[key] = paragraph
            return paragraph
        }
    }

    private static func captionString(_ runs: [InlineRun], style: TypesetStyle) -> NSAttributedString {
        let size = CGFloat(style.fontSize) * 0.85
        let string = NSMutableAttributedString()
        for run in runs {
            string.append(NSAttributedString(string: run.text, attributes: Typesetter.runAttributes(
                for: run, size: size, bold: run.style.contains(.bold), italic: run.style.contains(.italic),
                color: style.palette.secondary, style: style)))
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        string.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: string.length))
        return string
    }

    /// Measures cell strings, each distinct one once: CoreText lines for the widths (the widest
    /// line, the widest run of text without a break opportunity), `boundingRect` only for the
    /// height of cells that wrap; a cell on one line is as tall as its tallest font's line.
    struct Measurer {
        struct Widths {
            var natural: CGFloat
            var longestWord: CGFloat
        }

        private struct HeightKey: Hashable {
            var string: NSAttributedString
            var width: CGFloat
        }

        private var widthCache: [NSAttributedString: Widths] = [:]
        private var heightCache: [HeightKey: CGFloat] = [:]
        private var lineHeights: [UIFont: CGFloat] = [:]
        private var styledLineHeights: [NSAttributedString: CGFloat] = [:]

        mutating func widths(of string: NSAttributedString) -> Widths {
            if let cached = widthCache[string] { return cached }
            let text = string.string as NSString
            var natural: CGFloat = 0, longest: CGFloat = 0
            var lineStart = 0
            // One CTLine per line of the cell (U+2028 breaks them); words are spans between breaks.
            for index in 0 ... text.length {
                let atEnd = index == text.length
                guard atEnd || text.character(at: index) == 0x2028 || text.character(at: index) == 0x0A else { continue }
                if index > lineStart {
                    let range = NSRange(location: lineStart, length: index - lineStart)
                    let line = CTLineCreateWithAttributedString(string.attributedSubstring(from: range) as CFAttributedString)
                    natural = max(natural, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
                    var wordStart = 0
                    for local in 0 ... range.length {
                        let unit: unichar = local < range.length ? text.character(at: lineStart + local) : 0x20
                        // Spaces, tabs and em spaces break; U+00A0 does not.
                        guard unit == 0x20 || unit == 0x09 || unit == 0x2003 else { continue }
                        if local > wordStart {
                            let start = CTLineGetOffsetForStringIndex(line, wordStart, nil)
                            let end = CTLineGetOffsetForStringIndex(line, local, nil)
                            longest = max(longest, abs(end - start))
                        }
                        wordStart = local + 1
                    }
                }
                lineStart = index + 1
            }
            let result = Widths(natural: natural, longestWord: longest)
            widthCache[string] = result
            return result
        }

        mutating func lineHeight(_ font: UIFont) -> CGFloat {
            if let cached = lineHeights[font] { return cached }
            let height = ceil(font.lineHeight)
            lineHeights[font] = height
            return height
        }

        /// The height of `string` set in `width`.
        mutating func height(of string: NSAttributedString, width: CGFloat) -> CGFloat {
            let key = HeightKey(string: string, width: width)
            if let cached = heightCache[key] { return cached }
            let text = string.string as NSString
            let height: CGFloat
            if text.range(of: "\u{2028}").location == NSNotFound, text.range(of: "\n").location == NSNotFound,
               widths(of: string).natural + 1 <= width {
                // One line: as tall as one line in each of its styles (measured once per style).
                var tallest: CGFloat = 0
                string.enumerateAttributes(in: NSRange(location: 0, length: string.length)) { attributes, _, _ in
                    tallest = max(tallest, oneLineHeight(attributes))
                }
                height = tallest
            } else {
                height = ceil(string.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                                  options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height)
            }
            heightCache[key] = height
            return height
        }

        private mutating func oneLineHeight(_ attributes: [NSAttributedString.Key: Any]) -> CGFloat {
            let sample = NSAttributedString(string: "Hg", attributes: attributes)
            if let cached = styledLineHeights[sample] { return cached }
            let height = ceil(sample.boundingRect(with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                                                  options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height)
            styledLineHeights[sample] = height
            return height
        }
    }
}

/// One row (or the caption) of a table as a text attachment: sized by its `TableLayout`, drawn
/// when TextKit draws the page (nothing is rendered up front, so a long table costs no memory
/// until its rows are on screen).
nonisolated final class TableRowAttachment: NSTextAttachment {
    let layout: TableLayout
    let part: TableLayout.Part

    init(layout: TableLayout, part: TableLayout.Part) {
        self.layout = layout
        self.part = part
        super.init(data: nil, ofType: nil)
        bounds = CGRect(origin: .zero, size: layout.size(of: part))
    }

    required init?(coder: NSCoder) { nil }

    override func image(forBounds imageBounds: CGRect, textContainer: NSTextContainer?, characterIndex charIndex: Int) -> UIImage? {
        // Render at the pixel density of whatever is drawing the page (screen, flip texture, test).
        let scale = UIGraphicsGetCurrentContext().map { abs($0.ctm.a) } ?? 2
        return layout.image(of: part, scale: min(4, max(1, scale)))
    }

    /// The link under a point in the attachment's coordinates (origin at its top-left).
    func link(at point: CGPoint) -> String? { layout.link(at: point, in: part) }

    /// The row (or caption) as text, for VoiceOver.
    var plainText: String {
        switch part {
        case .row(let index): layout.table.plainText(ofRow: index)
        case .caption: layout.table.plainCaption
        }
    }
}
