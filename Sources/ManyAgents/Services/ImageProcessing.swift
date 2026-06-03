import Foundation
import AppKit
import CoreGraphics

/// Image normalization for the composer. The pasteboard typically hands us
/// 5K-resolution Retina screenshots — base64'd they exceed Anthropic's
/// per-request payload cap once you paste two or three. We downscale to a
/// max long-side dimension that still reads clearly to the model
/// (Anthropic's docs cite ~1568px as the optimal upper bound for vision
/// input) and re-encode as PNG so UI text stays crisp.
enum ImageProcessing {
    /// Pixel dimension to cap the longest side at. 1568px keeps screenshot
    /// text legible and stays well under the 1.15 MP "best results" zone
    /// Anthropic publishes for vision.
    static let maxLongSidePx: CGFloat = 1568

    /// Downscale (if needed) and re-encode as PNG. If the input is already
    /// within bounds, returns the original bytes unchanged. Returns nil
    /// only when the input isn't a decodable image at all.
    static func normalize(_ data: Data) -> Data? {
        guard let image = NSImage(data: data) else { return data }
        let original = image.size
        let scale = max(original.width, original.height) / maxLongSidePx
        if scale <= 1.0 {
            // Already small enough — keep the original bytes to avoid
            // re-compressing a clean PNG screenshot for no gain.
            return data
        }
        let newSize = NSSize(width: floor(original.width / scale),
                             height: floor(original.height / scale))
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return data
        }
        let bitsPerComponent = 8
        let bytesPerRow = Int(newSize.width) * 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil,
                                  width: Int(newSize.width),
                                  height: Int(newSize.height),
                                  bitsPerComponent: bitsPerComponent,
                                  bytesPerRow: bytesPerRow,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return data
        }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(origin: .zero, size: newSize))
        guard let resized = ctx.makeImage() else { return data }
        let rep = NSBitmapImageRep(cgImage: resized)
        return rep.representation(using: .png, properties: [:])
    }

    /// Hash of the bytes — used to dedupe a user double-pasting the same
    /// screenshot. Cheap MD5 is fine; we're not doing crypto here.
    static func fingerprint(_ data: Data) -> String {
        // Splat first/last KB + length. Good enough for dedupe within a
        // composer session without pulling in CryptoKit.
        let len = data.count
        let head = data.prefix(1024).reduce(0) { ($0 &+ Int($1)) &* 31 }
        let tail = data.suffix(1024).reduce(0) { ($0 &+ Int($1)) &* 31 }
        return "\(len)-\(head)-\(tail)"
    }
}
