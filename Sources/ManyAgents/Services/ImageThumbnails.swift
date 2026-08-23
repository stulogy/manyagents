import Foundation
import AppKit
import ImageIO

/// Decoded images for the transcript, downsampled once and kept in a
/// bounded cache.
///
/// Image blocks used to be decoded with `NSImage(data:)` inline in the view
/// body: full resolution, no cache, re-run every time SwiftUI re-evaluated
/// the row. A tab full of agent screenshots therefore re-decoded
/// multi-megapixel PNGs on every render pass, and each decode is
/// width × height × 4 bytes of bitmap regardless of how well the PNG
/// compressed — a 5K screenshot is ~60 MB decoded. The inline view draws
/// them 480 points wide.
///
/// So: decode once, through ImageIO, which reads only the pixels the
/// thumbnail needs rather than the whole image; then hold the results under
/// a byte ceiling so a long screenshot-heavy session can't grow without
/// end. Nothing here caps what's in `messages` — the original bytes still
/// live there — but that's compressed data measured in megabytes, not
/// decoded bitmaps measured in tens.
enum ImageThumbnails {
    /// Long-side pixel cap. The inline view is 480×360 points, so 1024px
    /// covers a Retina display with room to spare.
    private static let maxPixel = 1024

    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 200
        c.totalCostLimit = 96 * 1024 * 1024
        return c
    }()

    /// Keyed by the block's id, which is stable for the life of the message.
    static func thumbnail(id: UUID, data: Data) -> NSImage? {
        let key = id.uuidString as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let img = downsample(data) else { return nil }
        cache.setObject(img, forKey: key, cost: cost(of: img))
        return img
    }

    private static func downsample(_ data: Data) -> NSImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            // Not something ImageIO recognizes. Let NSImage have a go rather
            // than dropping the block silently.
            return NSImage(data: data)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            return NSImage(data: data)
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private static func cost(of image: NSImage) -> Int {
        max(1, Int(image.size.width * image.size.height) * 4)
    }
}
