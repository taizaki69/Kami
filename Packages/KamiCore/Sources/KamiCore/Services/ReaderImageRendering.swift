import Foundation
#if canImport(ImageIO)
import ImageIO
#endif

/// Choose a bounded whole-image decode without reducing every long page to a
/// narrow 4096-pixel-tall strip. Tiled drawing is separate from region decoding:
/// the resulting bounded CPU bitmap still stays resident while the page does.
public struct ReaderImageDecodePlan: Equatable, Sendable {
    public static let maximumLongDimension = 65_536
    public static let normalLongPagePixels = 16 * 1_024 * 1_024
    public static let constrainedPixels = 4 * 1_024 * 1_024

    public let maximumPixelDimension: Int
    public let maximumDecodedPixels: Int
    public let isLongPage: Bool

    public init?(width: Int, height: Int, ordinaryMaximumDimension: Int, memoryConstrained: Bool) {
        guard width > 0, height > 0, width <= 100_000, height <= 100_000,
              Int64(width) * Int64(height) <= 250_000_000 else { return nil }
        let largest = max(width, height), smallest = min(width, height)
        isLongPage = largest >= smallest * 4
        let ordinaryLimit = memoryConstrained ? 2_048 : max(512, min(ordinaryMaximumDimension, 8_192))
        maximumDecodedPixels = isLongPage
            ? (memoryConstrained ? Self.constrainedPixels : Self.normalLongPagePixels)
            : ordinaryLimit * ordinaryLimit
        let dimensionLimit = isLongPage ? Self.maximumLongDimension : ordinaryLimit
        let fromArea = Int(sqrt(Double(maximumDecodedPixels) * Double(largest) / Double(smallest)))
        var side = min(largest, dimensionLimit, fromArea)
        // Account for a decoder rounding the shorter dimension up. The ImageIO
        // result is also checked against both bounds before it is published.
        while side > 1 && side * Int(ceil(Double(smallest) * Double(side) / Double(largest))) > maximumDecodedPixels {
            side -= 1
        }
        maximumPixelDimension = max(1, side)
    }
}

/// A clipped tile in top-left image coordinates. Integral source rectangles
/// overlap by one pixel for interpolation; the caller clips output to `clip`.
/// Mapping that rectangle back to the surface avoids seams and stretched edges.
public struct ReaderImageTilePlan: Equatable, Sendable {
    public let source: CGRect
    public let destination: CGRect
    public let clip: CGRect

    public init?(imageWidth: Int, imageHeight: Int, surface: CGSize, clip requested: CGRect) {
        guard imageWidth > 0, imageHeight > 0,
              imageWidth <= ReaderImageDecodePlan.maximumLongDimension,
              imageHeight <= ReaderImageDecodePlan.maximumLongDimension,
              [surface.width, surface.height, requested.origin.x, requested.origin.y,
               requested.width, requested.height].allSatisfy({ $0.isFinite }),
              surface.width > 0, surface.height > 0, requested.width > 0, requested.height > 0 else { return nil }
        let clipped = requested.intersection(CGRect(origin: .zero, size: surface))
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
        let sx = CGFloat(imageWidth) / surface.width, sy = CGFloat(imageHeight) / surface.height
        let left = max(0, floor(clipped.minX * sx) - 1)
        let top = max(0, floor(clipped.minY * sy) - 1)
        let right = min(CGFloat(imageWidth), ceil(clipped.maxX * sx) + 1)
        let bottom = min(CGFloat(imageHeight), ceil(clipped.maxY * sy) + 1)
        guard [sx, sy, left, top, right, bottom].allSatisfy({ $0.isFinite }),
              sx > 0, sy > 0, right > left, bottom > top else { return nil }
        source = CGRect(x: left, y: top, width: right - left, height: bottom - top)
        destination = CGRect(x: left / sx, y: top / sy, width: (right - left) / sx, height: (bottom - top) / sy)
        clip = clipped
    }
}

#if canImport(ImageIO)
public enum NativeReaderTileRenderer {
    /// The destination context uses top-left surface coordinates, as does a
    /// UIKit backing layer. No mutable UI object is touched on the tile thread.
    public static func draw(_ image: CGImage, surface: CGSize, in context: CGContext) {
        guard let plan = ReaderImageTilePlan(imageWidth: image.width, imageHeight: image.height,
                                             surface: surface, clip: context.boundingBoxOfClipPath),
              let tile = image.cropping(to: plan.source) else { return }
        context.saveGState()
        context.clip(to: plan.clip)
        context.interpolationQuality = .high
        context.translateBy(x: plan.destination.minX, y: plan.destination.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(tile, in: CGRect(origin: .zero, size: plan.destination.size))
        context.restoreGState()
    }
}
#endif
