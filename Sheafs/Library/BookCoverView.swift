import SwiftUI
import UIKit

/// A book cover at a 2:3 aspect: the thumbnail when there is one, else a typeset placeholder.
struct BookCoverView: View {
    let book: Book
    let url: URL?
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholder
            }
        }
        .aspectRatio(2 / 3, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
        .task(id: url) {
            guard let url else { image = nil; return }
            image = await CoverCache.shared.image(at: url)
        }
    }

    private var placeholder: some View {
        let hue = Double(abs(book.title.hashValue % 360)) / 360
        return ZStack {
            LinearGradient(colors: [Color(hue: hue, saturation: 0.35, brightness: 0.55),
                                    Color(hue: hue, saturation: 0.45, brightness: 0.35)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(alignment: .leading, spacing: 6) {
                Text(book.title)
                    .font(.system(.headline, design: .serif))
                    .lineLimit(4)
                if let author = book.author {
                    Text(author)
                        .font(.system(.caption, design: .serif))
                        .opacity(0.85)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// Decoded cover thumbnails, shared across cells.
final class CoverCache: Sendable {
    static let shared = CoverCache()
    private let cache = NSCache<NSURL, UIImage>()

    func image(at url: URL) async -> UIImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        let loaded = await Task.detached(priority: .utility) { () -> UIImage? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return ImageUtilities.downsampled(data, maxPixelSize: 600)?.preparingForDisplay()
        }.value
        if let loaded { cache.setObject(loaded, forKey: url as NSURL) }
        return loaded
    }
}
