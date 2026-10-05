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
/// and creates bounded bitmaps off the main actor. Long reader pages may keep
/// their full dimensions when they fit the separate reader pixel budget.
public enum NativeImageValidation {
    public static func reducedReaderPage(_ page: NativePageImage) async throws -> NativePageImage {
        guard let plan = ReaderImageDecodePlan(width: page.image.width, height: page.image.height,
                                              ordinaryMaximumDimension: 2_048, memoryConstrained: true) else {
            throw DownloadImageValidationError.dimensionsTooLarge
        }
        return try await reduce(page, maximumPixelDimension: plan.maximumPixelDimension)
    }

    /// Reduce an already decoded page without retaining or reloading its
    /// compressed source. Preserve the existing crop and source metadata;
    /// recomputing the crop at a different resolution could change the artwork.
    public static func reduced(
        _ page: NativePageImage, maximumPixelDimension: Int = 2_048
    ) async throws -> NativePageImage {
        try await reduce(page, maximumPixelDimension: max(512, min(maximumPixelDimension, 2_048)))
    }

    private static func reduce(_ page: NativePageImage, maximumPixelDimension: Int) async throws -> NativePageImage {
        try Task.checkCancellation()
        let reducing = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let largest = max(page.image.width, page.image.height)
            guard largest <= ReaderImageDecodePlan.maximumLongDimension else {
                throw DownloadImageValidationError.dimensionsTooLarge
            }
            guard largest > maximumPixelDimension else { return page }
            let factor = Double(maximumPixelDimension) / Double(largest)
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
        try await decode(data: data, sizing: .thumbnail(maximumPixelDimension), prepareBorderTrim: prepareBorderTrim)
    }

    /// The display path may use a tall bounded bitmap and draw it as tiles.
    /// Download validation retains its small fixed-size thumbnail boundary.
    public static func readerPage(
        data: Data, ordinaryMaximumDimension: Int, memoryConstrained: Bool, prepareBorderTrim: Bool = false
    ) async throws -> NativePageImage {
        try await decode(data: data, sizing: .reader(ordinaryMaximumDimension, memoryConstrained),
                         prepareBorderTrim: prepareBorderTrim)
    }

    private enum Sizing: Sendable {
        case thumbnail(Int)
        case reader(Int, Bool)
    }

    private static func decode(data: Data, sizing: Sizing, prepareBorderTrim: Bool) async throws -> NativePageImage {
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
            let maximumDimension: Int
            let maximumPixels: Int
            switch sizing {
            case let .thumbnail(limit):
                maximumDimension = max(512, min(limit, 8_192))
                maximumPixels = maximumDimension * maximumDimension
            case let .reader(limit, constrained):
                guard let plan = ReaderImageDecodePlan(width: pixelWidth, height: pixelHeight,
                                                      ordinaryMaximumDimension: limit, memoryConstrained: constrained) else {
                    throw DownloadImageValidationError.dimensionsTooLarge
                }
                maximumDimension = plan.maximumPixelDimension
                maximumPixels = plan.maximumDecodedPixels
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceShouldAllowFloat: false,
                kCGImageSourceThumbnailMaxPixelSize: maximumDimension
            ]
            try Task.checkCancellation()
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                  CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
                throw DownloadImageValidationError.invalidImage
            }
            try Task.checkCancellation()
            guard thumbnail.width <= maximumDimension, thumbnail.height <= maximumDimension,
                  Int64(thumbnail.width) * Int64(thumbnail.height) <= Int64(maximumPixels) else {
                throw DownloadImageValidationError.dimensionsTooLarge
            }
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
