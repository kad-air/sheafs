import Foundation

/// Converts one EPUB spine document (XHTML, often sloppy) into a `Chapter`: a flat list of
/// `Block`s with inline runs, plus element paths that map positions to and from KOReader
/// xpointers.
///
/// The converter emits semantics, not styling; the typesetter picks fonts and sizes. It is
/// tolerant by design (undefined entities, unclosed tags, stray close tags) and never fails:
/// garbage in gives a best-effort, possibly empty, chapter.
///
/// Conversion rules in brief:
/// - Only `<body>` content matters (the `<head><title>` becomes `Chapter.title`). `script`,
///   `style`, `head`, `template` and anything with a `hidden` attribute is skipped.
/// - `Block.elementPath` follows CREngine: from `<body>` down, each step `tag[n]` with `n`
///   1-based among same-tag siblings opened so far. A closing tag pops to the nearest matching
///   open element; an unmatched close is ignored. Opening a block-level element implicitly
///   closes an open `p`.
/// - Block text has whitespace collapsed (U+00A0 is kept), `<br>` becomes U+2028, and every
///   block is followed by one "\n" in the chapter's plain text; offsets are UTF-16 units.
public struct XHTMLConverter: Sendable {
    public init() {}

    /// Converts raw document bytes. The text is decoded as UTF-8, then UTF-16 (if there is a
    /// byte order mark), then ISO Latin 1, which accepts anything.
    public func convert(_ data: Data) -> Chapter {
        convert(Self.decodeText(data))
    }

    /// Converts an already decoded document.
    public func convert(_ html: String) -> Chapter {
        var builder = ChapterBuilder()
        for token in HTMLTokenizer(html).tokens() {
            builder.consume(token)
        }
        return builder.finish()
    }

    /// UTF-8 (BOM stripped), else UTF-16 when a BOM says so, else Latin 1.
    static func decodeText(_ data: Data) -> String {
        if let text = String(validating: data, as: UTF8.self) {
            return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        }
        let bytes = [UInt8](data.prefix(2))
        if bytes == [0xFF, 0xFE] || bytes == [0xFE, 0xFF] {
            let encoding: String.Encoding = bytes[0] == 0xFF ? .utf16LittleEndian : .utf16BigEndian
            if let text = String(data: data.dropFirst(2), encoding: encoding) { return text }
        }
        // Latin 1 maps every byte to the scalar with the same value; the 0x80...0x9F control
        // range is read as Windows-1252, which is what files declaring Latin 1 actually contain.
        var scalars = String.UnicodeScalarView()
        for byte in data {
            scalars.append(HTMLEntities.windows1252Scalar(UInt32(byte)) ?? "\u{FFFD}")
        }
        return String(scalars)
    }
}
