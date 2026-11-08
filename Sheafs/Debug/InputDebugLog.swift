import CoreGraphics
import Foundation
import Observation
import UIKit
import os

/// Where an Input Debug row came from (the screen's sources, `InputDebugSession`).
enum InputSource: String, CaseIterable {
    /// `pressesBegan/Changed/Ended/Cancelled` on the first responder: hardware keyboard keys.
    case press
    /// A `UIKeyCommand` (arrows, space, return… with priority over system behaviour).
    case keyCommand = "keycmd"
    /// `GCKeyboard.coalesced`'s key handler: every key, below the responder chain.
    case gcKeyboard = "gc-kbd"
    case gcMouse = "gc-mouse"
    case gcController = "gc-pad"
    /// GameController connects and disconnects: what the device presents itself as.
    case device
    /// `AVAudioSession.outputVolume`: volume keys.
    case volume
    /// `MPRemoteCommandCenter`: play/pause, next/previous track… while Sheafs is Now Playing.
    case media
    case touch
    case gesture
    /// The screen's own notes: start, stop, the "Now pressing" tag, first responder.
    case note

    /// The source column, padded so the messages line up.
    nonisolated var column: String { rawValue.padding(toLength: 8, withPad: " ", startingAt: 0) }
}

/// The remote button being pressed, picked on the screen before pressing it, so a shared log says
/// which rows each button made.
enum InputTag: String, CaseIterable, Identifiable {
    case up = "Up", left = "Left", right = "Right", down = "Down", centre = "Centre", photo = "Photo"

    nonisolated var id: String { rawValue }
}

/// One log row: when, how long after the row before, the tag in force, the source and what it saw.
struct InputDebugRow: Identifiable, Equatable {
    let id: Int
    let date: Date
    /// Since the previous row; nil for the first one.
    let delta: TimeInterval?
    let tag: InputTag?
    let source: InputSource
    let message: String

    /// `14:03:22.123  +1234ms [Up]     press    began …`: the clock, the gap, the tag and the
    /// source in fixed columns, so a copied log reads as a table.
    nonisolated func formatted(timeZone: TimeZone = .current) -> String {
        prefix(timeZone: timeZone) + " " + message
    }

    /// Everything before the message (the screen shows it on a line of its own).
    nonisolated func prefix(timeZone: TimeZone = .current) -> String {
        let gap = delta.map { "+\(Int(($0 * 1000).rounded()))ms" } ?? "—"
        let tagColumn = tag.map { "[\($0.rawValue)]" } ?? ""
        return InputNames.clock(date, timeZone: timeZone) + " "
            + String(repeating: " ", count: max(0, 8 - gap.count)) + gap + " "
            + tagColumn.padding(toLength: 8, withPad: " ", startingAt: 0) + " "
            + source.column
    }
}

/// The Input Debug screen's log: in memory only, the newest `limit` rows (oldest dropped), each
/// tagged with the "Now pressing" button in force. Every row also goes to stdout (`[input] …`, for
/// `simctl launch --console-pty` and `devicectl … --console`) and the unified log (category
/// `input`, public), unless `echo` is off (tests).
@Observable
final class InputDebugLog {
    nonisolated static let limit = 2000
    /// UserDefaults: the About screen's version row was tapped 5 times, so the Input Debug row shows.
    nonisolated static let revealedKey = "SheafsInputDebugRevealed"

    private(set) var rows: [InputDebugRow] = []
    private(set) var tag: InputTag?
    /// While paused, rows are dropped (and the list can be scrolled).
    private(set) var isPaused = false
    /// Rows dropped off the front by the cap since the last Clear.
    private(set) var trimmed = 0

    @ObservationIgnored let limit: Int
    @ObservationIgnored private let echo: Bool
    @ObservationIgnored private var nextID = 0
    @ObservationIgnored private var lastDate: Date?
    @ObservationIgnored private let logger = Logger(subsystem: "io.sheafs.reader", category: "input")

    init(limit: Int = InputDebugLog.limit, echo: Bool = true) {
        self.limit = limit
        self.echo = echo
    }

    func add(_ source: InputSource, _ message: String, at date: Date = Date()) {
        guard !isPaused else { return }
        let row = InputDebugRow(id: nextID, date: date, delta: lastDate.map { date.timeIntervalSince($0) },
                                tag: tag, source: source, message: message)
        nextID += 1
        lastDate = date
        rows.append(row)
        if rows.count > limit {
            trimmed += rows.count - limit
            rows.removeFirst(rows.count - limit)
        }
        if echo {
            let line = row.formatted()
            print("[input] \(line)")
            logger.notice("[input] \(line, privacy: .public)")
        }
    }

    /// Tags the rows that follow (nil = none) and notes the change, so the log shows where each
    /// button's rows start.
    func setTag(_ newTag: InputTag?, at date: Date = Date()) {
        guard newTag != tag else { return }
        tag = newTag
        add(.note, "now pressing: \(newTag?.rawValue ?? "none")", at: date)
    }

    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        if paused { add(.note, "paused") }
        isPaused = paused
        if !paused { add(.note, "resumed") }
    }

    func clear() {
        rows.removeAll()
        trimmed = 0
        lastDate = nil
    }

    /// The whole log as text for the pasteboard: the header lines, then one line per row.
    func text(header: [String], timeZone: TimeZone = .current) -> String {
        var lines = header
        if trimmed > 0 { lines.append("(\(trimmed) older rows dropped; the log keeps the last \(limit))") }
        lines += rows.map { $0.formatted(timeZone: timeZone) }
        return lines.joined(separator: "\n")
    }
}

/// Names for what the sources report, for the log.
enum InputNames {
    /// `HH:mm:ss.SSS` in `timeZone`, rounded to the millisecond (a formatter truncates, and
    /// `x.123` is often stored as `x.12299…`).
    nonisolated static func clock(_ date: Date, timeZone: TimeZone) -> String {
        let day = 86_400_000
        let local = Int((date.timeIntervalSince1970 * 1000).rounded()) + timeZone.secondsFromGMT(for: date) * 1000
        let ms = (local % day + day) % day
        return String(format: "%02ld:%02ld:%02ld.%03ld", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }

    /// A HID Keyboard/Keypad page (0x07) usage, the code both `UIKey.keyCode` and `GCKeyCode`
    /// carry, as `0x52 UpArrow`.
    nonisolated static func keyLabel(_ usage: Int) -> String {
        String(format: "0x%02lX ", usage) + (key(usage) ?? "(unnamed)")
    }

    /// The usage's name (HID Usage Tables, Keyboard/Keypad page), nil for codes not named here.
    nonisolated static func key(_ usage: Int) -> String? {
        switch usage {
        case 0x04...0x1D: String(UnicodeScalar(UInt8(0x41 + usage - 0x04)))   // A…Z
        case 0x1E...0x26: String(usage - 0x1D)                                // 1…9
        case 0x27: "0"
        case 0x3A...0x45: "F\(usage - 0x39)"                                  // F1…F12
        case 0x59...0x61: "Keypad\(usage - 0x58)"                             // Keypad 1…9
        case 0x68...0x73: "F\(usage - 0x5B)"                                  // F13…F24
        default: namedKeys[usage]
        }
    }

    nonisolated private static let namedKeys: [Int: String] = [
        0x01: "ErrorRollOver", 0x02: "POSTFail", 0x03: "ErrorUndefined",
        0x28: "Return", 0x29: "Escape", 0x2A: "Backspace", 0x2B: "Tab", 0x2C: "Space",
        0x2D: "Hyphen", 0x2E: "Equal", 0x2F: "OpenBracket", 0x30: "CloseBracket", 0x31: "Backslash",
        0x32: "NonUSPound", 0x33: "Semicolon", 0x34: "Quote", 0x35: "GraveAccent", 0x36: "Comma",
        0x37: "Period", 0x38: "Slash", 0x39: "CapsLock",
        0x46: "PrintScreen", 0x47: "ScrollLock", 0x48: "Pause", 0x49: "Insert", 0x4A: "Home",
        0x4B: "PageUp", 0x4C: "DeleteForward", 0x4D: "End", 0x4E: "PageDown",
        0x4F: "RightArrow", 0x50: "LeftArrow", 0x51: "DownArrow", 0x52: "UpArrow",
        0x53: "NumLock", 0x54: "KeypadSlash", 0x55: "KeypadAsterisk", 0x56: "KeypadHyphen",
        0x57: "KeypadPlus", 0x58: "KeypadEnter", 0x62: "Keypad0", 0x63: "KeypadPeriod",
        0x64: "NonUSBackslash", 0x65: "Application", 0x66: "Power", 0x67: "KeypadEqual",
        0x74: "Execute", 0x75: "Help", 0x76: "Menu", 0x77: "Select", 0x78: "Stop", 0x79: "Again",
        0x7A: "Undo", 0x7B: "Cut", 0x7C: "Copy", 0x7D: "Paste", 0x7E: "Find",
        0x7F: "Mute", 0x80: "VolumeUp", 0x81: "VolumeDown",
        0x90: "LANG1", 0x91: "LANG2",
        0xE0: "LeftControl", 0xE1: "LeftShift", 0xE2: "LeftOption", 0xE3: "LeftCommand",
        0xE4: "RightControl", 0xE5: "RightShift", 0xE6: "RightOption", 0xE7: "RightCommand",
    ]

    /// `UIPress.PressType` by raw value (the arrow/select/menu/play-pause buttons of a TV-style
    /// remote; a keyboard key's press carries its own).
    nonisolated static func pressType(_ raw: Int) -> String {
        let name: String? = switch raw {
        case 0: "upArrow"
        case 1: "downArrow"
        case 2: "leftArrow"
        case 3: "rightArrow"
        case 4: "select"
        case 5: "menu"
        case 6: "playPause"
        case 30: "pageUp"
        case 31: "pageDown"
        case 32: "tvRemoteOneTwoThree"
        case 33: "tvRemoteFourColors"
        default: nil
        }
        return "\(name ?? "type")(\(raw))"
    }

    /// `UIKeyModifierFlags` as `shift+cmd`, `none` when empty.
    nonisolated static func modifiers(_ flags: UIKeyModifierFlags) -> String {
        let names: [(UIKeyModifierFlags, String)] = [
            (.alphaShift, "caps"), (.shift, "shift"), (.control, "ctrl"), (.alternate, "alt"),
            (.command, "cmd"), (.numericPad, "numpad"),
        ]
        let present = names.filter { flags.contains($0.0) }.map(\.1)
        let known = names.reduce(UIKeyModifierFlags()) { $0.union($1.0) }
        let unknown = flags.subtracting(known).rawValue
        let all = present + (unknown == 0 ? [] : [String(format: "0x%lX", unknown)])
        return all.isEmpty ? "none" : all.joined(separator: "+")
    }

    /// `UITouch.TouchType` by raw value.
    nonisolated static func touchType(_ raw: Int) -> String {
        switch raw {
        case 0: "direct"
        case 1: "indirect"
        case 2: "pencil"
        case 3: "indirectPointer"
        default: "type\(raw)"
        }
    }

    /// A key's characters, quoted, with everything but printable ASCII escaped (`"\r"`,
    /// `"\u{F700}"`), so invisible keys still show what they carry.
    nonisolated static func visible(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case " "..."~": out.unicodeScalars.append(scalar)
            default: out += String(format: "\\u{%04X}", scalar.value)
            }
        }
        return out + "\""
    }

    /// A point as `(120,340)`, whole points.
    nonisolated static func point(_ p: CGPoint) -> String {
        "(\(whole(p.x)),\(whole(p.y)))"
    }

    /// A movement as `(+0,-312)`, whole points, signed.
    nonisolated static func delta(dx: CGFloat, dy: CGFloat) -> String {
        "(\(signed(dx)),\(signed(dy)))"
    }

    nonisolated private static func whole(_ value: CGFloat) -> String {
        String(Int(value.rounded()))
    }

    nonisolated private static func signed(_ value: CGFloat) -> String {
        let n = Int(value.rounded())
        return n < 0 ? "\(n)" : "+\(n)"
    }
}

/// One finger's (or pointer's) moves, coalesced: a swipe is a begin row and one end row with
/// the total movement, not a row per `touchesMoved`.
struct MoveTally {
    let start: CGPoint
    let startTime: TimeInterval
    private(set) var last: CGPoint
    private(set) var moves = 0

    nonisolated init(start: CGPoint, at time: TimeInterval) {
        self.start = start
        self.startTime = time
        last = start
    }

    nonisolated mutating func move(to point: CGPoint) {
        last = point
        moves += 1
    }

    /// `at (100,188) Δ(+0,-312) moves=30 250ms`
    nonisolated func summary(at time: TimeInterval) -> String {
        "at \(InputNames.point(last)) Δ\(InputNames.delta(dx: last.x - start.x, dy: last.y - start.y)) moves=\(moves) \(Int(((time - startTime) * 1000).rounded()))ms"
    }
}
