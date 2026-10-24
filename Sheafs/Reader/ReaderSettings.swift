import Foundation
import SwiftUI
import UIKit

enum ReaderTheme: String, CaseIterable, Codable, Identifiable {
    case paper, sepia, night, system
    var id: Self { self }
    var title: String {
        switch self {
        case .paper: "Paper"
        case .sepia: "Sepia"
        case .night: "Night"
        case .system: "Automatic"
        }
    }
}

enum ReaderFont: String, CaseIterable, Codable, Identifiable {
    case newYork, georgia, palatino, charter, iowan, baskerville, times, sanFrancisco, avenir
    var id: Self { self }

    var title: String {
        switch self {
        case .newYork: "New York"
        case .georgia: "Georgia"
        case .palatino: "Palatino"
        case .charter: "Charter"
        case .iowan: "Iowan Old Style"
        case .baskerville: "Baskerville"
        case .times: "Times New Roman"
        case .sanFrancisco: "San Francisco"
        case .avenir: "Avenir Next"
        }
    }

    /// A font of this family at `size`, with optional traits. Falls back to the system serif.
    nonisolated func font(size: CGFloat, bold: Bool = false, italic: Bool = false) -> UIFont {
        var traits: UIFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        let base: UIFontDescriptor
        switch self {
        case .newYork, .sanFrancisco:
            let system = UIFont.systemFont(ofSize: size).fontDescriptor
            base = (self == .newYork ? system.withDesign(.serif) : nil) ?? system
        default:
            base = UIFontDescriptor(fontAttributes: [.family: familyName])
        }
        let descriptor = traits.isEmpty ? base : (base.withSymbolicTraits(traits) ?? base)
        return UIFont(descriptor: descriptor, size: size)
    }

    nonisolated var familyName: String {
        switch self {
        case .newYork: "New York"
        case .georgia: "Georgia"
        case .palatino: "Palatino"
        case .charter: "Charter"
        case .iowan: "Iowan Old Style"
        case .baskerville: "Baskerville"
        case .times: "Times New Roman"
        case .sanFrancisco: "San Francisco"
        case .avenir: "Avenir Next"
        }
    }
}

enum ParagraphStyleChoice: String, CaseIterable, Codable, Identifiable {
    /// Classic book setting: no space between paragraphs, first lines indented.
    case indented
    /// Space between paragraphs, no indent.
    case spaced
    var id: Self { self }
    var title: String { self == .indented ? "Indented" : "Spaced" }
}

/// User preferences for the reading surface, persisted in UserDefaults.
@Observable
final class ReaderSettings {
    var theme: ReaderTheme { didSet { save() } }
    var font: ReaderFont { didSet { save() } }
    var fontSize: Double { didSet { save() } }
    var lineHeight: Double { didSet { save() } }
    var margin: Double { didSet { save() } }
    var justified: Bool { didSet { save() } }
    var hyphenate: Bool { didSet { save() } }
    var paragraphStyle: ParagraphStyleChoice { didSet { save() } }
    var keepScreenAwake: Bool { didSet { save() } }
    var tapToTurn: Bool { didSet { save() } }

    private static let key = "reader.settings.v1"

    struct Stored: Codable {
        var theme = ReaderTheme.system
        var font = ReaderFont.newYork
        var fontSize = 19.0
        var lineHeight = 1.4
        var margin = 24.0
        var justified = false
        var hyphenate = true
        var paragraphStyle = ParagraphStyleChoice.indented
        var keepScreenAwake = true
        var tapToTurn = true
    }

    init() {
        let stored = UserDefaults.standard.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(Stored.self, from: $0) } ?? Stored()
        theme = stored.theme
        font = stored.font
        fontSize = stored.fontSize
        lineHeight = stored.lineHeight
        margin = stored.margin
        justified = stored.justified
        hyphenate = stored.hyphenate
        paragraphStyle = stored.paragraphStyle
        keepScreenAwake = stored.keepScreenAwake
        tapToTurn = stored.tapToTurn
    }

    private func save() {
        let stored = Stored(theme: theme, font: font, fontSize: fontSize, lineHeight: lineHeight, margin: margin,
                            justified: justified, hyphenate: hyphenate, paragraphStyle: paragraphStyle,
                            keepScreenAwake: keepScreenAwake, tapToTurn: tapToTurn)
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    /// Everything the typesetter needs, as a value (so caches can key on it).
    func typesetStyle(colorScheme: ColorScheme, language: String?) -> TypesetStyle {
        TypesetStyle(font: font, fontSize: fontSize, lineHeight: lineHeight, justified: justified,
                     hyphenate: hyphenate, paragraphStyle: paragraphStyle,
                     palette: ReaderPalette.resolve(theme, colorScheme: colorScheme), language: language)
    }
}
