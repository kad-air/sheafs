import Foundation

/// Book-wide page numbers that hold still under the reader. Chapters not laid out yet can only be
/// estimated (from their text length at the characters per page of the chapters that are), and
/// that estimate moves every time another chapter is laid out, so numbering every page from the
/// start of the book afresh made the folio jump: turning forward from page 531 landed on 518 once
/// the neighbours had been laid out behind it (an iPhone Duo recording, The Lord of the Rings).
///
/// So a chapter's first page number is decided once, the first time any of its pages is numbered,
/// and kept until the layout changes (`reset`). It comes from a neighbour that has its number
/// already and an exact page count between them (the chapter before plus that chapter's pages, or
/// the chapter after less this one's), so turning across a chapter boundary always counts on by
/// one; only a chapter reached by a jump, with no numbered neighbour, starts from the estimate,
/// and then that number stays too. `PageNumberingTests`.
struct PageNumbering {
    /// The first page of each chapter numbered so far, 0-based.
    private(set) var starts: [Int: Int] = [:]

    mutating func reset() { starts.removeAll() }

    /// The 0-based first page of chapter `index`: `exact` is a chapter's page count if it is laid
    /// out, `estimate` the count to assume if it is not.
    mutating func start(of index: Int, exact: (Int) -> Int?, estimate: (Int) -> Int) -> Int {
        if let known = starts[index] { return known }
        let start: Int
        if let previous = starts[index - 1], let pages = exact(index - 1) {
            start = previous + pages
        } else if let next = starts[index + 1], let pages = exact(index) {
            start = max(0, next - pages)
        } else {
            start = (0 ..< max(0, index)).reduce(0) { $0 + (exact($1) ?? estimate($1)) }
        }
        starts[index] = start
        return start
    }
}
