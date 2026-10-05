import Foundation
#if canImport(ImageIO)
import ImageIO
#endif

public enum DownloadImageValidationError: Error, Equatable, Sendable, LocalizedError {
    case invalidImage, dimensionsTooLarge, unavailable

    public var errorDescription: String? {
        switch self {
        case .invalidImage: return "This page is not a complete supported image."
        case .dimensionsTooLarge: return "This page exceeds the supported image dimensions."
        case .unavailable: return "Image validation is unavailable on this platform."
        }
    }
}

/// An explicit injection seam for filesystem/coordination fixtures. Production
/// downloads must use the ImageIO validator, never a no-op format detector.
public protocol DownloadImageValidating: Sendable {
    func validate(_ data: Data) async throws
}

public struct PlatformDownloadImageValidator: DownloadImageValidating {
    public init() {}

    public func validate(_ data: Data) async throws {
        #if canImport(ImageIO)
        _ = try await NativeImageValidation.thumbnail(data: data, maximumPixelDimension: 512)
        #else
        throw DownloadImageValidationError.unavailable
        #endif
    }
}

#if canImport(ImageIO)
public struct NativePageImage: @unchecked Sendable {
    public let image: CGImage
    public let borderTrimmedImage: CGImage?
    public let sourceWidth: Int
    public let sourceHeight: Int
}

/// Shared by downloaded-page validation and the reader. Compressed-byte
/// budgets belong to their callers; this boundary bounds decoded dimensions
/// and creates only a thumbnail off the main actor, not a full-size bitmap.
public enum NativeImageValidation {
    /// Reduce an already decoded page without retaining or reloading its
    /// compressed source. Preserve the existing crop and source metadata;
    /// recomputing the crop at a different resolution could change the artwork.
    public static func reduced(
        _ page: NativePageImage, maximumPixelDimension: Int = 2_048
    ) async throws -> NativePageImage {
        try Task.checkCancellation()
        let reducing = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let maximum = max(512, min(maximumPixelDimension, 2_048))
            let largest = max(page.image.width, page.image.height)
            guard largest <= 8_192 else { throw DownloadImageValidationError.dimensionsTooLarge }
            guard largest > maximum else { return page }
            let factor = Double(maximum) / Double(largest)
            func resize(_ source: CGImage) throws -> CGImage {
                try Task.checkCancellation()
                let width = max(1, Int((Double(source.width) * factor).rounded(.down)))
                let height = max(1, Int((Double(source.height) * factor).rounded(.down)))
                guard let context = CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
                ) else { throw DownloadImageValidationError.invalidImage }
                context.interpolationQuality = .high
                context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
                try Task.checkCancellation()
                guard let image = context.makeImage() else { throw DownloadImageValidationError.invalidImage }
                return image
            }
            let image = try resize(page.image)
            let cropped: CGImage?
            if let oldCrop = page.borderTrimmedImage {
                // Blank pages reuse the same reduced bitmap, not a second copy.
                cropped = oldCrop.width == page.image.width && oldCrop.height == page.image.height
                    ? image : try resize(oldCrop)
            } else {
                cropped = nil
            }
            try Task.checkCancellation()
            return NativePageImage(image: image, borderTrimmedImage: cropped,
                                   sourceWidth: page.sourceWidth, sourceHeight: page.sourceHeight)
        }
        return try await withTaskCancellationHandler {
            let image = try await reducing.value
            try Task.checkCancellation()
            return image
        } onCancel: {
            reducing.cancel()
        }
    }

    public static func thumbnail(
        data: Data, maximumPixelDimension: Int, prepareBorderTrim: Bool = false
    ) async throws -> NativePageImage {
        try Task.checkCancellation()
        let decoding = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            try PNGImageIntegrity.validateIfPNG(data)
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard !data.isEmpty,
                  let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
                  CGImageSourceGetStatus(source) == .statusComplete,
                  (1...2_048).contains(CGImageSourceGetCount(source)),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
                throw DownloadImageValidationError.invalidImage
            }
            let pixelWidth = width.intValue
            let pixelHeight = height.intValue
            guard pixelWidth > 0, pixelHeight > 0,
                  pixelWidth <= 100_000, pixelHeight <= 100_000,
                  Int64(pixelWidth) * Int64(pixelHeight) <= 250_000_000 else {
                throw DownloadImageValidationError.dimensionsTooLarge
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: max(512, min(maximumPixelDimension, 8_192))
            ]
            try Task.checkCancellation()
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                  CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
                throw DownloadImageValidationError.invalidImage
            }
            try Task.checkCancellation()
            let trimmed = prepareBorderTrim ? try ReaderBorderCrop.trimming(thumbnail) : nil
            try Task.checkCancellation()
            return NativePageImage(image: thumbnail, borderTrimmedImage: trimmed,
                                   sourceWidth: pixelWidth, sourceHeight: pixelHeight)
        }
        return try await withTaskCancellationHandler {
            let image = try await decoding.value
            try Task.checkCancellation()
            return image
        } onCancel: {
            decoding.cancel()
        }
    }
}
#endif
