import SwiftUI
import UIKit
import WidgetKit

/// "Continue Reading": the most recently read book's cover; a tap opens it in the reader.
/// The app writes the snapshot (`RecentBookShelf`) and reloads this widget when it changes.
/// `ContinueReadingControl` is the same thing as a Lock Screen / Control Center button.
@main
struct SheafsWidgetBundle: WidgetBundle {
    var body: some Widget {
        ContinueReadingWidget()
        ContinueReadingControl()
    }
}

struct ContinueReadingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: RecentBookShelf.widgetKind, provider: RecentBookProvider()) { entry in
            ContinueReadingView(entry: entry)
        }
        .configurationDisplayName("Continue Reading")
        .description("The book you read last. Tap to pick up where you left off.")
        .supportedFamilies([.systemSmall])
        .contentMarginsDisabled()
    }
}

struct RecentBookEntry: TimelineEntry {
    var date: Date
    var book: RecentBook?
    var cover: UIImage?

    static let sample = RecentBookEntry(
        date: .now,
        book: RecentBook(id: UUID(), title: "Alice's Adventures in Wonderland", author: "Lewis Carroll",
                         progress: 0.42, hasCover: false),
        cover: nil)
}

struct RecentBookProvider: TimelineProvider {
    func placeholder(in context: Context) -> RecentBookEntry { .sample }

    func getSnapshot(in context: Context, completion: @escaping (RecentBookEntry) -> Void) {
        let entry = Self.current()
        completion(entry.book == nil && context.isPreview ? .sample : entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RecentBookEntry>) -> Void) {
        // Nothing changes on a clock: the app reloads the timeline when the book or progress does.
        completion(Timeline(entries: [Self.current()], policy: .never))
    }

    static func current() -> RecentBookEntry {
        let shelf = RecentBookShelf.shared
        let book = shelf?.read()
        let cover = book?.hasCover == true ? shelf?.coverData().flatMap(UIImage.init(data:)) : nil
        return RecentBookEntry(date: .now, book: book, cover: cover)
    }
}

struct ContinueReadingView: View {
    let entry: RecentBookEntry

    var body: some View {
        Group {
            if let book = entry.book {
                content(book)
                    .widgetURL(SheafsLink.open(book.id))
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "books.vertical")
                        .font(.title)
                    Text("No books yet")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                .containerBackground(.fill.tertiary, for: .widget)
            }
        }
    }

    private func content(_ book: RecentBook) -> some View {
        VStack(spacing: 8) {
            cover(book)
                .aspectRatio(2 / 3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
            HStack(spacing: 6) {
                ProgressView(value: min(max(book.progress, 0), 1))
                    .tint(.white)
                Text(book.progress.formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .containerBackground(for: .widget) { backdrop(book) }
    }

    @ViewBuilder
    private func cover(_ book: RecentBook) -> some View {
        if let image = entry.cover {
            Image(uiImage: image)
                .resizable()
                .widgetAccentedRenderingMode(.fullColor)
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack(alignment: .topLeading) {
                Self.gradient(for: book.title)
                Text(book.title)
                    .font(.system(size: 11, weight: .semibold, design: .serif))
                    .foregroundStyle(.white)
                    .lineLimit(5)
                    .padding(6)
            }
        }
    }

    /// The cover itself, blown up, blurred and darkened, so the tile takes on the book's colours.
    @ViewBuilder
    private func backdrop(_ book: RecentBook) -> some View {
        if let image = entry.cover {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .blur(radius: 18)
                .overlay(Color.black.opacity(0.35))
        } else {
            Self.gradient(for: book.title).overlay(Color.black.opacity(0.25))
        }
    }

    /// A stable colour per title (`String.hashValue` changes every launch).
    static func gradient(for title: String) -> LinearGradient {
        let hue = Double(title.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }) / 360
        return LinearGradient(colors: [Color(hue: hue, saturation: 0.35, brightness: 0.55),
                                       Color(hue: hue, saturation: 0.45, brightness: 0.35)],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

#Preview(as: .systemSmall) {
    ContinueReadingWidget()
} timeline: {
    RecentBookEntry.sample
    RecentBookEntry(date: .now, book: nil, cover: nil)
}
