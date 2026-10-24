import SwiftUI

/// Where the reader was before each jump (a link, the contents, a note, the slider, a synced
/// position), so "Back to page N" can return there. A stack: following a link from an endnote and
/// going back twice retraces both hops. Page turns never add to it.
struct ReturnTrail: Equatable {
    /// A place left, with the book-wide page number its folio showed then ("Back to page 136").
    struct Stop: Equatable {
        var location: ReadingLocation
        var page: Int?
    }

    private(set) var stops: [Stop] = []
    static let limit = 20

    var last: ReadingLocation? { stops.last?.location }
    var lastPage: Int? { stops.last?.page }
    var isEmpty: Bool { stops.isEmpty }

    /// Remembers `from` before a jump to `to`. A jump that stays on the same page is not a place
    /// to come back from, and neither is the place already on top of the trail.
    mutating func leave(_ from: ReadingLocation, page: Int? = nil, for to: ReadingLocation,
                        samePage: (ReadingLocation, ReadingLocation) -> Bool) {
        guard !samePage(from, to) else { return }
        if let last, samePage(last, from) { return }
        stops.append(Stop(location: from, page: page))
        if stops.count > Self.limit { stops.removeFirst(stops.count - Self.limit) }
    }

    /// The place to go back to, taken off the trail.
    mutating func back() -> ReadingLocation? { stops.popLast()?.location }

    /// Paging back onto the last stop by hand is going back too: it leaves the trail.
    mutating func arrived(at location: ReadingLocation, samePage: (ReadingLocation, ReadingLocation) -> Bool) {
        while let last, samePage(last, location) { stops.removeLast() }
    }

    mutating func clear() { stops.removeAll() }
}

/// The floating "Back to page N" capsule, with a separate ✕ that forgets the trail.
struct BackToPageButton: View {
    var label: String
    var onBack: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onBack) {
                Label(label, systemImage: "arrow.uturn.backward")
                    .font(.footnote.weight(.semibold))
                    .padding(.leading, 14)
                    .padding(.trailing, 8)
                    .frame(height: 34)
            }
            Divider().frame(height: 18)
            Button("Dismiss", systemImage: "xmark", action: onDismiss)
                .labelStyle(.iconOnly)
                .font(.caption.weight(.semibold))
                .frame(width: 34, height: 34)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(in: .capsule)
        .accessibilityElement(children: .contain)
    }
}
