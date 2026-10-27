import Foundation
import SheafsKit
import Testing

/// Helpers for the text-conversion tests. These read fixture chapters with `/usr/bin/unzip`
/// on purpose: the tests must not depend on the EPUB module they are cross-checking.
enum TextFixture {
    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    static func epubURL(_ name: String) throws -> URL {
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        guard let url = Bundle.module.url(forResource: stem, withExtension: ext, subdirectory: "Fixtures") else {
            throw Failure(description: "fixture \(name) is missing from the test bundle")
        }
        return url
    }

    /// The bytes of one zip entry.
    static func entry(_ path: String, in epub: String) throws -> Data {
        try unzip(["-p", epubURL(epub).path, path])
    }

    /// Every XHTML/HTML entry in the archive, in archive order.
    static func documentPaths(in epub: String) throws -> [String] {
        let listing = try unzip(["-Z1", epubURL(epub).path])
        return String(decoding: listing, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
            .filter { name in [".xhtml", ".html", ".htm"].contains { name.hasSuffix($0) } }
    }

    private static func unzip(_ arguments: [String]) throws -> Data {
        #if os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Drain before waiting: a 1 MB chapter would otherwise fill the pipe and deadlock.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure(description: "unzip \(arguments.joined(separator: " ")) exited with \(process.terminationStatus)")
        }
        return data
        #else
        throw Failure(description: "reading fixture chapters needs /usr/bin/unzip, which only the macOS test run has")
        #endif
    }
}

enum TextTesting {
    /// Converts one fixture chapter, with the stylesheets it links (read through `unzip` too)
    /// when `stylesheets` is set, as the app does, or without them.
    static func convert(_ path: String, in epub: String, stylesheets: Bool) throws -> Chapter {
        let data = try TextFixture.entry(path, in: epub)
        guard stylesheets else { return XHTMLConverter().convert(data) }
        let library = StylesheetLibrary { cssPath in try? TextFixture.entry(cssPath, in: epub) }
        return XHTMLConverter().convert(data, documentPath: path, stylesheets: library)
    }

    /// Converts a fragment wrapped in a minimal XHTML document.
    static func convert(_ bodyContent: String, head: String = "") -> Chapter {
        XHTMLConverter().convert(
            "<?xml version=\"1.0\"?><html xmlns=\"http://www.w3.org/1999/xhtml\"><head>\(head)</head><body>\(bodyContent)</body></html>"
        )
    }

    /// Maps every Unicode whitespace scalar (U+00A0, U+2003, U+2028 included) to a space, collapses
    /// runs and trims. This is the comparison the Python reference's `\s+` collapsing implies.
    static func normalizedWhitespace(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        var lastWasSpace = true
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace {
                if !lastWasSpace { result.append(" ") }
                lastWasSpace = true
            } else {
                result.append(scalar)
                lastWasSpace = false
            }
        }
        var collapsed = String(result)
        if collapsed.hasSuffix(" ") { collapsed.removeLast() }
        return collapsed
    }

    /// The text with every whitespace scalar removed.
    static func withoutWhitespace(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { !$0.properties.isWhitespace }))
    }

    static func run(_ text: String, _ style: InlineStyle = [], link: String? = nil) -> InlineRun {
        InlineRun(text: text, style: style, link: link)
    }

    /// The last path step of a block: "p[3]" for "/body/div[1]/p[3]".
    static func lastStep(of path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? ""
    }
}

extension Chapter {
    var blockTexts: [String] { blocks.map(\.text) }
    var blockPaths: [String] { blocks.map(\.elementPath) }
}
