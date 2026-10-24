import Foundation

// Small text helpers shared by the OPDS parser: whitespace, HTML to plain text, RFC 3339 dates.

extension String {
    /// Trims the ends and collapses every run of whitespace (including newlines) to one space.
    var collapsingWhitespace: String {
        split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// Turns the HTML (or already plain) text found in Atom `summary` / `content` into plain text.
enum HTMLText {
    /// Strips tags, turns block boundaries into line breaks, decodes entities and tidies whitespace.
    static func plain(fromHTML html: String) -> String {
        var stripped = ""
        stripped.reserveCapacity(html.count)
        var index = html.startIndex
        while index < html.endIndex {
            let character = html[index]
            if character == "<", let close = tagEnd(in: html, openingAt: index) {
                let name = tagName(in: html[html.index(after: index)..<close])
                if breaksLine.contains(name) { stripped.append("\n") }
                index = html.index(after: close)
                continue
            }
            stripped.append(character)
            index = html.index(after: index)
        }
        return tidy(decodeEntities(in: stripped))
    }

    /// Trims lines, collapses runs of spaces and keeps at most one blank line in a row.
    static func tidy(_ text: String) -> String {
        var lines: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if line.isEmpty && (lines.last?.isEmpty ?? true) { continue }
            lines.append(line)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// Elements whose start or end separates lines of text.
    static let breaksLine: Set<String> = [
        "br", "p", "div", "li", "ul", "ol", "tr", "blockquote", "hr", "pre", "table",
        "h1", "h2", "h3", "h4", "h5", "h6",
    ]

    /// The index of the `>` that closes a tag opened at `start`, or nil when `<` is just text.
    private static func tagEnd(in text: String, openingAt start: String.Index) -> String.Index? {
        var cursor = text.index(after: start)
        guard cursor < text.endIndex else { return nil }
        let first = text[cursor]
        guard first.isLetter || first == "/" || first == "!" || first == "?" else { return nil }
        if first == "/" {
            cursor = text.index(after: cursor)
            guard cursor < text.endIndex, text[cursor].isLetter else { return nil }
        }
        return text[cursor...].firstIndex(of: ">")
    }

    private static func tagName(in tag: Substring) -> String {
        let body = tag.drop(while: { $0 == "/" })
        let name = body.prefix { $0.isLetter || $0.isNumber }
        return name.lowercased()
    }

    static func decodeEntities(in text: String) -> String {
        guard text.contains("&") else { return text }
        var output = ""
        output.reserveCapacity(text.count)
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "&", let semicolon = text[index...].prefix(12).firstIndex(of: ";") {
                let name = text[text.index(after: index)..<semicolon]
                if let decoded = decode(entity: name) {
                    output.unicodeScalars.append(decoded)
                    index = text.index(after: semicolon)
                    continue
                }
            }
            output.append(character)
            index = text.index(after: index)
        }
        return output
    }

    private static func decode(entity name: Substring) -> Unicode.Scalar? {
        if name.hasPrefix("#") {
            let digits = name.dropFirst()
            let value: UInt32?
            if digits.hasPrefix("x") || digits.hasPrefix("X") {
                value = UInt32(digits.dropFirst(), radix: 16)
            } else {
                value = UInt32(digits, radix: 10)
            }
            return value.flatMap(Unicode.Scalar.init)
        }
        return named[String(name)].flatMap(Unicode.Scalar.init)
    }

    /// HTML 4 named entities: the Latin-1 block (U+00A0...U+00FF, in order) plus common punctuation.
    private static let named: [String: UInt32] = {
        let latin1 = [
            "nbsp", "iexcl", "cent", "pound", "curren", "yen", "brvbar", "sect", "uml", "copy", "ordf", "laquo",
            "not", "shy", "reg", "macr", "deg", "plusmn", "sup2", "sup3", "acute", "micro", "para", "middot",
            "cedil", "sup1", "ordm", "raquo", "frac14", "frac12", "frac34", "iquest", "Agrave", "Aacute",
            "Acirc", "Atilde", "Auml", "Aring", "AElig", "Ccedil", "Egrave", "Eacute", "Ecirc", "Euml",
            "Igrave", "Iacute", "Icirc", "Iuml", "ETH", "Ntilde", "Ograve", "Oacute", "Ocirc", "Otilde",
            "Ouml", "times", "Oslash", "Ugrave", "Uacute", "Ucirc", "Uuml", "Yacute", "THORN", "szlig",
            "agrave", "aacute", "acirc", "atilde", "auml", "aring", "aelig", "ccedil", "egrave", "eacute",
            "ecirc", "euml", "igrave", "iacute", "icirc", "iuml", "eth", "ntilde", "ograve", "oacute",
            "ocirc", "otilde", "ouml", "divide", "oslash", "ugrave", "uacute", "ucirc", "uuml", "yacute",
            "thorn", "yuml",
        ]
        var table: [String: UInt32] = [
            "amp": 0x26, "lt": 0x3C, "gt": 0x3E, "quot": 0x22, "apos": 0x27,
            "OElig": 0x152, "oelig": 0x153, "Scaron": 0x160, "scaron": 0x161, "Yuml": 0x178,
            "circ": 0x2C6, "tilde": 0x2DC,
            "ensp": 0x2002, "emsp": 0x2003, "thinsp": 0x2009,
            "ndash": 0x2013, "mdash": 0x2014,
            "lsquo": 0x2018, "rsquo": 0x2019, "sbquo": 0x201A,
            "ldquo": 0x201C, "rdquo": 0x201D, "bdquo": 0x201E,
            "dagger": 0x2020, "Dagger": 0x2021, "bull": 0x2022, "hellip": 0x2026, "permil": 0x2030,
            "prime": 0x2032, "Prime": 0x2033, "lsaquo": 0x2039, "rsaquo": 0x203A,
            "euro": 0x20AC, "trade": 0x2122,
        ]
        for (offset, name) in latin1.enumerated() { table[name] = 0xA0 + UInt32(offset) }
        return table
    }()
}

/// RFC 3339 / ISO 8601 timestamps as found in Atom feeds, with or without fractional seconds.
/// Also accepts a date only (`2008-05-01`), a bare year, a space instead of `T`, and a
/// lowercase `t` / `z`.
enum OPDSDate {
    static func parse(_ raw: String) -> Date? {
        var scanner = ByteScanner(bytes: Array(raw.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
        guard let year = scanner.digits(4) else { return nil }
        var month = 1
        var day = 1
        var hour = 0
        var minute = 0
        var second = 0
        var fraction = 0.0
        var offsetSeconds = 0

        if scanner.eat("-") {
            guard let parsedMonth = scanner.digits(2) else { return nil }
            month = parsedMonth
            if scanner.eat("-") {
                guard let parsedDay = scanner.digits(2) else { return nil }
                day = parsedDay
            }
        }
        if scanner.eat("T") || scanner.eat("t") || scanner.eat(" ") {
            guard let parsedHour = scanner.digits(2), scanner.eat(":"), let parsedMinute = scanner.digits(2) else {
                return nil
            }
            hour = parsedHour
            minute = parsedMinute
            if scanner.eat(":") {
                guard let parsedSecond = scanner.digits(2) else { return nil }
                second = parsedSecond
                if scanner.eat(".") || scanner.eat(",") {
                    guard let parsedFraction = scanner.fraction() else { return nil }
                    fraction = parsedFraction
                }
            }
            scanner.skipSpaces()
            if scanner.eat("Z") || scanner.eat("z") {
                offsetSeconds = 0
            } else if let sign = scanner.sign() {
                guard let offsetHour = scanner.digits(2) else { return nil }
                _ = scanner.eat(":")
                let offsetMinute = scanner.digits(2) ?? 0
                offsetSeconds = sign * (offsetHour * 3600 + offsetMinute * 60)
            }
        }
        guard scanner.isAtEnd,
              (1...12).contains(month), (1...31).contains(day),
              (0...23).contains(hour), (0...59).contains(minute), (0...60).contains(second)
        else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: offsetSeconds) ?? .gmt
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        return calendar.date(from: components).map { $0.addingTimeInterval(fraction) }
    }

    private struct ByteScanner {
        let bytes: [UInt8]
        var position = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        var isAtEnd: Bool { position >= bytes.count }

        /// Exactly `count` ASCII digits.
        mutating func digits(_ count: Int) -> Int? {
            guard position + count <= bytes.count else { return nil }
            var value = 0
            for byte in bytes[position..<position + count] {
                guard (48...57).contains(byte) else { return nil }
                value = value * 10 + Int(byte - 48)
            }
            position += count
            return value
        }

        /// One or more digits after a decimal point, as a fraction of a second.
        mutating func fraction() -> Double? {
            var scale = 0.1
            var value = 0.0
            var count = 0
            while position < bytes.count, (48...57).contains(bytes[position]) {
                value += Double(bytes[position] - 48) * scale
                scale /= 10
                position += 1
                count += 1
            }
            return count > 0 ? value : nil
        }

        mutating func eat(_ character: Character) -> Bool {
            guard position < bytes.count, bytes[position] == character.asciiValue else { return false }
            position += 1
            return true
        }

        mutating func sign() -> Int? {
            if eat("+") { return 1 }
            if eat("-") { return -1 }
            return nil
        }

        mutating func skipSpaces() {
            while position < bytes.count, bytes[position] == 32 { position += 1 }
        }
    }
}
