import Foundation
import GameController
import Testing
import UIKit
@testable import Sheafs

/// The Input Debug screen's pure parts: row formatting, the "Now pressing" tag, the 2,000-row cap,
/// pausing, the copied text and the names given to what the sources report. Key names are checked
/// against Apple's own constants (`UIKeyboardHIDUsage`, `GCKeyCode`) and the HID Usage Tables'
/// Keyboard/Keypad page, not against the table they come from.
struct InputDebugTests {
    private let utc = TimeZone(secondsFromGMT: 0)!
    /// 2026-11-08 14:03:22.123 UTC.
    private let t0 = Date(timeIntervalSince1970: 1_794_146_602.123)

    // MARK: Rows

    @Test func aRowReadsAsFixedColumns() {
        let log = InputDebugLog(echo: false)
        log.add(.press, "began type=upArrow(0)", at: t0)
        log.setTag(.centre, at: t0)
        log.add(.volume, "outputVolume 0.2500 → 0.3000 UP", at: t0.addingTimeInterval(1.2344))
        let lines = log.rows.map { $0.formatted(timeZone: utc) }
        #expect(lines[0] == "14:03:22.123        — " + "        " + " press    began type=upArrow(0)")
        #expect(lines[2] == "14:03:23.357  +1234ms [Centre] volume   outputVolume 0.2500 → 0.3000 UP")
    }

    /// The clock rounds to the millisecond (x.123 is stored as x.12299…; a formatter truncates to
    /// .122), wraps at midnight, and follows the time zone.
    @Test func theClockRoundsAndFollowsTheTimeZone() {
        #expect(InputNames.clock(t0, timeZone: utc) == "14:03:22.123")
        #expect(InputNames.clock(Date(timeIntervalSince1970: 86_399.9996), timeZone: utc) == "00:00:00.000")
        #expect(InputNames.clock(Date(timeIntervalSince1970: 0.5), timeZone: utc) == "00:00:00.500")
        #expect(InputNames.clock(t0, timeZone: TimeZone(secondsFromGMT: -5 * 3600)!) == "09:03:22.123")
    }

    @Test func theGapIsSinceThePreviousRowAndRestartsAfterClear() {
        let log = InputDebugLog(echo: false)
        log.add(.touch, "a", at: t0)
        log.add(.touch, "b", at: t0.addingTimeInterval(0.0504))
        log.add(.touch, "c", at: t0.addingTimeInterval(2.0504))
        #expect(log.rows[0].delta == nil)
        #expect(abs((log.rows[1].delta ?? 0) - 0.0504) < 1e-6)
        #expect(log.rows.map { $0.formatted(timeZone: utc).dropFirst(13).prefix(8) } == ["       —", "   +50ms", " +2000ms"])
        log.clear()
        log.add(.touch, "d", at: t0.addingTimeInterval(10))
        #expect(log.rows.count == 1)
        #expect(log.rows[0].delta == nil)
    }

    // MARK: The tag

    /// Picking a button tags the rows after it, notes the change once, and "none" untags.
    @Test func theTagMarksTheRowsThatFollow() {
        let log = InputDebugLog(echo: false)
        log.add(.media, "togglePlayPause")
        log.setTag(.up)
        log.add(.press, "began")
        log.add(.press, "ended")
        log.setTag(.up)                     // the same button again: no second note
        log.setTag(nil)
        log.add(.touch, "#1 began")
        #expect(log.rows.map(\.tag) == [nil, .up, .up, .up, nil, nil])
        #expect(log.rows.map(\.message) == ["togglePlayPause", "now pressing: Up", "began", "ended",
                                            "now pressing: none", "#1 began"])
        #expect(log.rows[1].source == .note)
        #expect(InputTag.allCases.map(\.rawValue) == ["Up", "Left", "Right", "Down", "Centre", "Photo"])
    }

    // MARK: The cap

    @Test func theLogKeepsTheLast2000Rows() {
        #expect(InputDebugLog.limit == 2000)
        let log = InputDebugLog(echo: false)
        for n in 0..<2005 { log.add(.touch, "\(n)", at: t0.addingTimeInterval(Double(n))) }
        #expect(log.rows.count == 2000)
        #expect(log.rows.first?.message == "5")
        #expect(log.rows.last?.message == "2004")
        #expect(log.trimmed == 5)
        // Ids keep counting, so the list's identities never repeat.
        #expect(log.rows.first?.id == 5)
        #expect(log.text(header: ["H"]).split(separator: "\n").prefix(2)
                == ["H", "(5 older rows dropped; the log keeps the last 2000)"])
        log.clear()
        #expect(log.rows.isEmpty && log.trimmed == 0)
    }

    @Test func pausingDropsRowsAndSaysSo() {
        let log = InputDebugLog(echo: false)
        log.add(.press, "before")
        log.setPaused(true)
        log.add(.press, "while paused")
        #expect(log.isPaused)
        log.setPaused(false)
        log.add(.press, "after")
        #expect(log.rows.map(\.message) == ["before", "paused", "resumed", "after"])
    }

    @Test func theCopiedTextIsTheHeaderThenOneLinePerRow() {
        let log = InputDebugLog(echo: false)
        log.add(.gcKeyboard, "key 0x52 UpArrow down", at: t0)
        log.add(.gcKeyboard, "key 0x52 UpArrow up", at: t0.addingTimeInterval(0.08))
        #expect(log.text(header: ["Sheafs Input Debug", "keyboards: none"], timeZone: utc) == """
            Sheafs Input Debug
            keyboards: none
            14:03:22.123        —          gc-kbd   key 0x52 UpArrow down
            14:03:22.203    +80ms          gc-kbd   key 0x52 UpArrow up
            """)
    }

    // MARK: Names

    /// UIKit's own HID usages name the same keys (a second source for the table).
    @Test func keyNamesAgreeWithUIKitsHIDUsages() {
        let expected: [(UIKeyboardHIDUsage, String)] = [
            (.keyboardUpArrow, "UpArrow"), (.keyboardDownArrow, "DownArrow"),
            (.keyboardLeftArrow, "LeftArrow"), (.keyboardRightArrow, "RightArrow"),
            (.keyboardPageUp, "PageUp"), (.keyboardPageDown, "PageDown"),
            (.keyboardReturnOrEnter, "Return"), (.keyboardSpacebar, "Space"), (.keyboardEscape, "Escape"),
            (.keyboardDeleteOrBackspace, "Backspace"), (.keyboardTab, "Tab"),
            (.keyboardHome, "Home"), (.keyboardEnd, "End"), (.keyboardDeleteForward, "DeleteForward"),
            (.keyboardVolumeUp, "VolumeUp"), (.keyboardVolumeDown, "VolumeDown"), (.keyboardMute, "Mute"),
            (.keyboardA, "A"), (.keyboardZ, "Z"), (.keyboard1, "1"), (.keyboard9, "9"), (.keyboard0, "0"),
            (.keyboardF1, "F1"), (.keyboardF12, "F12"), (.keyboardF13, "F13"), (.keyboardF24, "F24"),
            (.keypad1, "Keypad1"), (.keypad9, "Keypad9"), (.keypad0, "Keypad0"), (.keypadEnter, "KeypadEnter"),
            (.keyboardLeftGUI, "LeftCommand"), (.keyboardRightAlt, "RightOption"),
            (.keyboardLeftShift, "LeftShift"), (.keyboardCapsLock, "CapsLock"),
        ]
        for (usage, name) in expected {
            #expect(InputNames.key(usage.rawValue) == name, "usage 0x\(String(usage.rawValue, radix: 16))")
        }
    }

    /// GameController's key codes are the same HID usages and get the same names.
    @Test func keyNamesAgreeWithGameControllersKeyCodes() {
        let expected: [(GCKeyCode, String)] = [
            (.upArrow, "UpArrow"), (.downArrow, "DownArrow"), (.leftArrow, "LeftArrow"),
            (.rightArrow, "RightArrow"), (.spacebar, "Space"), (.returnOrEnter, "Return"),
            (.pageUp, "PageUp"), (.pageDown, "PageDown"), (.keyA, "A"), (.escape, "Escape"),
        ]
        for (code, name) in expected {
            #expect(InputNames.key(code.rawValue) == name)
        }
    }

    /// The HID Usage Tables (Keyboard/Keypad page 0x07) by number, as the log prints them.
    @Test func keyLabelsCarryTheUsageInHex() {
        #expect(InputNames.keyLabel(0x52) == "0x52 UpArrow")
        #expect(InputNames.keyLabel(0x28) == "0x28 Return")
        #expect(InputNames.keyLabel(0x2C) == "0x2C Space")
        #expect(InputNames.keyLabel(0x80) == "0x80 VolumeUp")
        #expect(InputNames.keyLabel(0x04) == "0x04 A")
        #expect(InputNames.keyLabel(0xA5) == "0xA5 (unnamed)")   // reserved
        #expect(InputNames.keyLabel(0x1234) == "0x1234 (unnamed)")
    }

    @Test func pressTypesModifiersAndTouchTypes() {
        #expect(InputNames.pressType(UIPress.PressType.upArrow.rawValue) == "upArrow(0)")
        #expect(InputNames.pressType(UIPress.PressType.playPause.rawValue) == "playPause(6)")
        #expect(InputNames.pressType(31) == "pageDown(31)")   // tvOS only, by raw value
        #expect(InputNames.pressType(2041) == "type(2041)")
        #expect(InputNames.modifiers([]) == "none")
        #expect(InputNames.modifiers([.command, .shift]) == "shift+cmd")
        #expect(InputNames.modifiers([.alphaShift, .control, .alternate, .numericPad]) == "caps+ctrl+alt+numpad")
        #expect(InputNames.touchType(UITouch.TouchType.direct.rawValue) == "direct")
        #expect(InputNames.touchType(UITouch.TouchType.indirect.rawValue) == "indirect")
        #expect(InputNames.touchType(UITouch.TouchType.pencil.rawValue) == "pencil")
        #expect(InputNames.touchType(UITouch.TouchType.indirectPointer.rawValue) == "indirectPointer")
    }

    /// Invisible characters are escaped, so a key that carries "\r" or a private-use arrow
    /// character still shows what it carries.
    @Test func charactersAreQuotedAndEscaped() {
        #expect(InputNames.visible("") == #""""#)
        #expect(InputNames.visible("a B") == #""a B""#)
        #expect(InputNames.visible("\r") == #""\r""#)
        #expect(InputNames.visible("\u{1B}") == #""\u{001B}""#)
        #expect(InputNames.visible("\u{F700}") == #""\u{F700}""#)
        #expect(InputNames.visible("\"\\") == #""\"\\""#)
        #expect(InputNames.visible(UIKeyCommand.inputUpArrow).hasPrefix("\""))
    }

    // MARK: Coalesced moves

    /// A swipe's 30 moves become one summary: where it ended, the total movement, the count and
    /// the time; minus zero prints as +0.
    @Test func aSwipeIsOneSummary() {
        var tally = MoveTally(start: CGPoint(x: 100, y: 500), at: 10)
        for step in 1...30 { tally.move(to: CGPoint(x: 100 - 0.0001, y: 500 - 10.4 * Double(step))) }
        #expect(tally.moves == 30)
        #expect(tally.summary(at: 10.25) == "at (100,188) Δ(+0,-312) moves=30 250ms")
        #expect(InputNames.delta(dx: 12.6, dy: -0.4) == "(+13,+0)")
        #expect(InputNames.point(CGPoint(x: 0.4, y: 677.6)) == "(0,678)")
    }
}
