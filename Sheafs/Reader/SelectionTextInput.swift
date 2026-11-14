import UIKit

/// The reader's selection offered to the system as read-only text, so that what iOS reads "the
/// selected text" from gets it.
///
/// 🔴 iOS 27 puts an Ask Siri item into every edit menu itself (it is not among the delegate's
/// `suggestedActions`, and a delegate's own menu gets it anyway), and the item reads the selection
/// from the window's FIRST RESPONDER, only if that responder is a `UITextInput`:
/// `selectedTextRange`, then `text(in:)` (UIKit 27.1, `-[UIResponder _textInputForWritingTools]` /
/// `_intelligentAssistantTextSelectionContext`, the same path Writing Tools uses). The pages draw
/// the selection themselves (TextKit 1, no text view) and the first responder used to be the
/// `PagerController`, which is no text input, so Siri opened with an empty prompt.
///
/// This view stands in for the selection while its menu is up: it is the first responder, its
/// whole text is the selected text as Copy quotes it, and all of it is selected. It draws nothing,
/// takes no touches, edits nothing, brings up no keyboard (an empty `inputView`) and is hidden from
/// VoiceOver. It lies over the selection, so geometry the system asks for (`firstRect(for:)`,
/// `selectionRects(for:)`) is where the selection is drawn. `SelectionTextInputTests` asks UIKit's
/// own lookup what it reads.
final class SelectionTextInput: UIView, UITextInput {
    /// An offset in `text`, in UTF-16 units.
    final class Offset: UITextPosition {
        let value: Int
        init(_ value: Int) { self.value = value }
    }

    final class Span: UITextRange {
        let lower: Offset
        let upper: Offset
        init(_ a: Int, _ b: Int) {
            lower = Offset(min(a, b))
            upper = Offset(max(a, b))
        }
        override var start: UITextPosition { lower }
        override var end: UITextPosition { upper }
        override var isEmpty: Bool { lower.value == upper.value }
    }

    final class LineRect: UITextSelectionRect {
        let frame: CGRect
        let isFirst: Bool
        let isLast: Bool
        init(_ frame: CGRect, isFirst: Bool, isLast: Bool) {
            self.frame = frame
            self.isFirst = isFirst
            self.isLast = isLast
        }
        override var rect: CGRect { frame }
        override var writingDirection: NSWritingDirection { .natural }
        override var containsStart: Bool { isFirst }
        override var containsEnd: Bool { isLast }
        override var isVertical: Bool { false }
    }

    /// The selected text, as the reader quotes it (Copy's text); empty when nothing is offered.
    private(set) var text = ""
    /// The selection's line rects in this view's coordinates.
    private var lineRects: [CGRect] = []
    private let noKeyboard = UIView(frame: .zero)
    private var length: Int { (text as NSString).length }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Takes the selection (its text, and its line rects in the superview's coordinates) and becomes
    /// the first responder. Returns whether it did.
    @discardableResult
    func offer(_ text: String, lineRects rects: [CGRect]) -> Bool {
        let union = rects.dropFirst().reduce(rects.first) { $0?.union($1) } ?? .zero
        inputDelegate?.selectionWillChange(self)
        inputDelegate?.textWillChange(self)
        self.text = text
        frame = union
        lineRects = rects.map { $0.offsetBy(dx: -union.minX, dy: -union.minY) }
        inputDelegate?.textDidChange(self)
        inputDelegate?.selectionDidChange(self)
        guard !text.isEmpty else { return false }
        return isFirstResponder || becomeFirstResponder()
    }

    /// Lets the selection go: no text, and no longer the first responder.
    func withdraw() {
        if isFirstResponder { resignFirstResponder() }
        text = ""
        lineRects = []
    }

    override var canBecomeFirstResponder: Bool { !text.isEmpty }
    /// An empty input view: the first responder conforms to `UIKeyInput`, which would otherwise
    /// bring up the keyboard.
    override var inputView: UIView? { noKeyboard }
    /// Read-only. Not part of `UITextInput`; UIKit asks a text input for it if it has one
    /// (`UITextView.isEditable`), and Siri offers rewriting only for editable text.
    @objc var isEditable: Bool { false }

    // MARK: UIKeyInput (nothing is typed here)

    var hasText: Bool { !text.isEmpty }
    func insertText(_ text: String) {}
    func deleteBackward() {}

    // MARK: UITextInput

    func text(in range: UITextRange) -> String? {
        guard let span = clamped(range) else { return nil }
        return (text as NSString).substring(with: span)
    }

    func replace(_ range: UITextRange, withText text: String) {}

    /// All of it: the text IS the selection. Setting it changes nothing (the handles own the selection).
    var selectedTextRange: UITextRange? {
        get { Span(0, length) }
        set {}
    }

    var markedTextRange: UITextRange? { nil }
    var markedTextStyle: [NSAttributedString.Key: Any]?
    func setMarkedText(_ markedText: String?, selectedRange: NSRange) {}
    func unmarkText() {}

    var beginningOfDocument: UITextPosition { Offset(0) }
    var endOfDocument: UITextPosition { Offset(length) }

    func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        guard let from = fromPosition as? Offset, let to = toPosition as? Offset else { return nil }
        return Span(from.value, to.value)
    }

    func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        guard let position = position as? Offset else { return nil }
        let moved = position.value + offset
        return (0 ... length).contains(moved) ? Offset(moved) : nil
    }

    func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        switch direction {
        case .right, .down: self.position(from: position, offset: offset)
        case .left, .up: self.position(from: position, offset: -offset)
        @unknown default: nil
        }
    }

    func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        let a = (position as? Offset)?.value ?? 0, b = (other as? Offset)?.value ?? 0
        return a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
    }

    func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        ((toPosition as? Offset)?.value ?? 0) - ((from as? Offset)?.value ?? 0)
    }

    weak var inputDelegate: UITextInputDelegate?
    lazy var tokenizer: UITextInputTokenizer = UITextInputStringTokenizer(textInput: self)

    func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        switch direction {
        case .left, .up: range.start
        default: range.end
        }
    }

    func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        guard let position = position as? Offset else { return nil }
        switch direction {
        case .left, .up: return Span(0, position.value)
        default: return Span(position.value, length)
        }
    }

    func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection { .natural }
    func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {}

    func firstRect(for range: UITextRange) -> CGRect { lineRects.first ?? bounds }

    func caretRect(for position: UITextPosition) -> CGRect {
        let atEnd = length > 0 && ((position as? Offset)?.value ?? 0) >= length
        guard let line = atEnd ? lineRects.last : lineRects.first else { return .zero }
        return CGRect(x: atEnd ? line.maxX : line.minX, y: line.minY, width: 2, height: line.height)
    }

    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        guard let span = clamped(range), span.length > 0 else { return [] }
        return lineRects.enumerated().map { index, rect in
            LineRect(rect, isFirst: index == 0, isLast: index == lineRects.count - 1)
        }
    }

    func closestPosition(to point: CGPoint) -> UITextPosition? { beginningOfDocument }
    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? { range.start }
    func characterRange(at point: CGPoint) -> UITextRange? { nil }

    /// A range of ours as an `NSRange` inside the text, or nil if it isn't ours.
    private func clamped(_ range: UITextRange) -> NSRange? {
        guard let span = range as? Span else { return nil }
        let lower = min(max(0, span.lower.value), length), upper = min(max(lower, span.upper.value), length)
        return NSRange(location: lower, length: upper - lower)
    }
}
