import Foundation

/// HTML 4 named character references, and the helpers EPUB parsing needs them for.
///
/// EPUB navigation documents and cover pages are XHTML, but real files still contain HTML
/// entities such as `&nbsp;` that Foundation's strict XML parser rejects.
enum XHTMLEntities {
    /// The five entities XML itself defines. These are left alone when preparing XHTML.
    static let xmlPredefined: Set<String> = ["amp", "lt", "gt", "quot", "apos"]

    /// Latin-1 supplement, U+00A0 ... U+00FF, in code point order.
    private static let latin1Names = """
        nbsp iexcl cent pound curren yen brvbar sect uml copy ordf laquo not shy reg macr \
        deg plusmn sup2 sup3 acute micro para middot cedil sup1 ordm raquo frac14 frac12 frac34 iquest \
        Agrave Aacute Acirc Atilde Auml Aring AElig Ccedil Egrave Eacute Ecirc Euml Igrave Iacute Icirc Iuml \
        ETH Ntilde Ograve Oacute Ocirc Otilde Ouml times Oslash Ugrave Uacute Ucirc Uuml Yacute THORN szlig \
        agrave aacute acirc atilde auml aring aelig ccedil egrave eacute ecirc euml igrave iacute icirc iuml \
        eth ntilde ograve oacute ocirc otilde ouml divide oslash ugrave uacute ucirc uuml yacute thorn yuml
        """

    /// Everything else in HTML 4, as `name=decimal code point`.
    private static let otherEntities = """
        quot=34 amp=38 lt=60 gt=62 \
        OElig=338 oelig=339 Scaron=352 scaron=353 Yuml=376 fnof=402 circ=710 tilde=732 \
        Alpha=913 Beta=914 Gamma=915 Delta=916 Epsilon=917 Zeta=918 Eta=919 Theta=920 Iota=921 Kappa=922 \
        Lambda=923 Mu=924 Nu=925 Xi=926 Omicron=927 Pi=928 Rho=929 Sigma=931 Tau=932 Upsilon=933 Phi=934 \
        Chi=935 Psi=936 Omega=937 \
        alpha=945 beta=946 gamma=947 delta=948 epsilon=949 zeta=950 eta=951 theta=952 iota=953 kappa=954 \
        lambda=955 mu=956 nu=957 xi=958 omicron=959 pi=960 rho=961 sigmaf=962 sigma=963 tau=964 upsilon=965 \
        phi=966 chi=967 psi=968 omega=969 thetasym=977 upsih=978 piv=982 \
        ensp=8194 emsp=8195 thinsp=8201 zwnj=8204 zwj=8205 lrm=8206 rlm=8207 ndash=8211 mdash=8212 \
        lsquo=8216 rsquo=8217 sbquo=8218 ldquo=8220 rdquo=8221 bdquo=8222 dagger=8224 Dagger=8225 \
        bull=8226 hellip=8230 permil=8240 prime=8242 Prime=8243 lsaquo=8249 rsaquo=8250 oline=8254 frasl=8260 \
        euro=8364 image=8465 weierp=8472 real=8476 trade=8482 alefsym=8501 \
        larr=8592 uarr=8593 rarr=8594 darr=8595 harr=8596 crarr=8629 lArr=8656 uArr=8657 rArr=8658 dArr=8659 hArr=8660 \
        forall=8704 part=8706 exist=8707 empty=8709 nabla=8711 isin=8712 notin=8713 ni=8715 prod=8719 sum=8721 \
        minus=8722 lowast=8727 radic=8730 prop=8733 infin=8734 ang=8736 and=8743 or=8744 cap=8745 cup=8746 \
        int=8747 there4=8756 sim=8764 cong=8773 asymp=8776 ne=8800 equiv=8801 le=8804 ge=8805 sub=8834 sup=8835 \
        nsub=8836 sube=8838 supe=8839 oplus=8853 otimes=8855 perp=8869 sdot=8901 \
        lceil=8968 rceil=8969 lfloor=8970 rfloor=8971 lang=9001 rang=9002 loz=9674 \
        spades=9824 clubs=9827 hearts=9829 diams=9830
        """

    /// Entity name -> character, all 252 entities of HTML 4 (including the four XML ones that
    /// HTML shares: quot, amp, lt, gt).
    static let html4: [String: Character] = {
        var table: [String: Character] = [:]
        for (offset, name) in latin1Names.split(whereSeparator: \.isWhitespace).enumerated() {
            if let scalar = Unicode.Scalar(UInt32(0xA0 + offset)) { table[String(name)] = Character(scalar) }
        }
        for pair in otherEntities.split(whereSeparator: \.isWhitespace) {
            let parts = pair.split(separator: "=")
            if parts.count == 2, let code = UInt32(parts[1]), let scalar = Unicode.Scalar(code) {
                table[String(parts[0])] = Character(scalar)
            }
        }
        return table
    }()

    // MARK: Preparing XHTML for XMLParser

    /// Turns real-world (X)HTML into something a strict XML parser accepts:
    /// strips the XML declaration and DOCTYPE, replaces HTML named entities with their
    /// characters, and escapes any `&` that does not start a valid reference. Always UTF-8 out.
    static func sanitizeXHTML(_ data: Data) -> Data {
        var text = String(decoding: data, as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        var bytes = Array(text.utf8)
        bytes = removingXMLDeclaration(bytes)
        bytes = removingDoctype(bytes)
        return Data(replacingEntities(bytes))
    }

    private static func removingXMLDeclaration(_ bytes: [UInt8]) -> [UInt8] {
        var start = 0
        while start < bytes.count, isXMLSpace(bytes[start]) { start += 1 }
        guard bytes[start...].starts(with: Array("<?xml".utf8)),
              let end = firstIndex(of: Array("?>".utf8), in: bytes, from: start) else { return bytes }
        return Array(bytes[(end + 2)...])
    }

    /// Removes `<!DOCTYPE ...>`, including an internal subset in square brackets.
    private static func removingDoctype(_ bytes: [UInt8]) -> [UInt8] {
        let marker = Array("<!doctype".utf8)
        var i = 0
        while i + marker.count <= bytes.count {
            if bytes[i] == UInt8(ascii: "<"),
               zip(bytes[i ..< i + marker.count], marker).allSatisfy({ lowercased($0) == $1 }) {
                var depth = 0
                var quote: UInt8?
                var j = i + marker.count
                while j < bytes.count {
                    let b = bytes[j]
                    if let q = quote {
                        if b == q { quote = nil }
                    } else if b == UInt8(ascii: "\"") || b == UInt8(ascii: "'") {
                        quote = b
                    } else if b == UInt8(ascii: "[") {
                        depth += 1
                    } else if b == UInt8(ascii: "]") {
                        depth -= 1
                    } else if b == UInt8(ascii: ">"), depth <= 0 {
                        return Array(bytes[..<i]) + Array(bytes[(j + 1)...])
                    }
                    j += 1
                }
                return Array(bytes[..<i])   // unterminated: drop the rest of the prologue
            }
            // The DOCTYPE can only appear before the root element; stop at the first real tag.
            if bytes[i] == UInt8(ascii: "<"), i + 1 < bytes.count,
               bytes[i + 1] != UInt8(ascii: "!"), bytes[i + 1] != UInt8(ascii: "?") { break }
            i += 1
        }
        return bytes
    }

    private static func replacingEntities(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            guard b == UInt8(ascii: "&") else { out.append(b); i += 1; continue }

            // Find the terminating ';' within a plausible distance.
            var end = i + 1
            while end < bytes.count, end - i <= 32, bytes[end] != UInt8(ascii: ";"), isEntityByte(bytes[end]) { end += 1 }
            guard end < bytes.count, bytes[end] == UInt8(ascii: ";"), end > i + 1 else {
                out.append(contentsOf: Array("&amp;".utf8))
                i += 1
                continue
            }
            let name = String(decoding: bytes[(i + 1) ..< end], as: UTF8.self)
            if name.hasPrefix("#") || xmlPredefined.contains(name) {
                out.append(contentsOf: bytes[i ... end])   // numeric references and XML's own five
            } else if let character = html4[name] {
                out.append(contentsOf: Array(String(character).utf8))
            } else {
                out.append(contentsOf: Array("&amp;\(name);".utf8))   // unknown: show it literally
            }
            i = end + 1
        }
        return out
    }

    private static func isEntityByte(_ b: UInt8) -> Bool {
        (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == UInt8(ascii: "#")
    }

    private static func isXMLSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D }

    private static func lowercased(_ b: UInt8) -> UInt8 { b >= 0x41 && b <= 0x5A ? b + 0x20 : b }

    private static func firstIndex(of needle: [UInt8], in haystack: [UInt8], from start: Int) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        var i = start
        while i + needle.count <= haystack.count {
            if haystack[i] == needle[0], haystack[i ..< i + needle.count].elementsEqual(needle) { return i }
            i += 1
        }
        return nil
    }

    // MARK: Text helpers

    /// Collapses runs of whitespace (including newlines and no-break spaces) to single spaces
    /// and trims the ends.
    static func collapseWhitespace(_ string: String) -> String {
        string.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Plain text from a snippet of HTML (a calibre-style `dc:description`): drops tags,
    /// decodes entities, collapses whitespace. Text without markup passes through unchanged
    /// apart from whitespace collapsing.
    static func plainText(fromHTML string: String) -> String {
        var stripped = ""
        var inTag = false
        let characters = Array(string)
        for (i, c) in characters.enumerated() {
            if inTag {
                if c == ">" { inTag = false; stripped.append(" ") }
            } else if c == "<", i + 1 < characters.count,
                      characters[i + 1].isLetter || characters[i + 1] == "/" || characters[i + 1] == "!" {
                inTag = true
            } else {
                stripped.append(c)
            }
        }
        return collapseWhitespace(decodeReferences(stripped))
    }

    /// Decodes `&name;`, `&#123;` and `&#x1F;` references; unknown ones are left as written.
    static func decodeReferences(_ string: String) -> String {
        guard string.contains("&") else { return string }
        var out = ""
        var rest = Substring(string)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let afterAmp = rest.index(after: amp)
            guard let semicolon = rest[afterAmp...].prefix(32).firstIndex(of: ";") else {
                out.append("&")
                rest = rest[afterAmp...]
                continue
            }
            let name = String(rest[afterAmp ..< semicolon])
            if let decoded = decode(name) {
                out.append(decoded)
                rest = rest[rest.index(after: semicolon)...]
            } else {
                out.append("&")
                rest = rest[afterAmp...]
            }
        }
        out += rest
        return out
    }

    private static func decode(_ name: String) -> Character? {
        if name.hasPrefix("#") {
            let digits = name.dropFirst()
            let code: UInt32?
            if digits.first == "x" || digits.first == "X" {
                code = UInt32(digits.dropFirst(), radix: 16)
            } else {
                code = UInt32(digits)
            }
            guard let code, let scalar = Unicode.Scalar(code) else { return nil }
            return Character(scalar)
        }
        if name == "apos" { return "'" }
        return html4[name]
    }
}
