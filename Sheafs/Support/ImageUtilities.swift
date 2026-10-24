import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

enum ImageUtilities {
    /// Decodes and downsamples image data in one pass (ImageIO), returning JPEG bytes.
    nonisolated static func jpegThumbnail(from data: Data, maxPixelSize: CGFloat) -> Data? {
        guard let image = downsampled(data, maxPixelSize: maxPixelSize) else { return nil }
        return image.jpegData(compressionQuality: 0.85)
    }

    /// Decodes and downsamples image data so that its longest side is at most `maxPixelSize` pixels.
    nonisolated static func downsampled(_ data: Data, maxPixelSize: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixelSize),
        ] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: cg)
    }

    nonisolated static func pixelSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let h = props[kCGImagePropertyPixelHeight] as? CGFloat else { return nil }
        return CGSize(width: w, height: h)
    }
}
