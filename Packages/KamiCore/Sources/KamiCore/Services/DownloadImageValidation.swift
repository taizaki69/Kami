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
    public let sourceWidth: Int
    public let sourceHeight: Int
}

/// Shared by downloaded-page validation and the reader. Compressed-byte
/// budgets belong to their callers; this boundary bounds decoded dimensions
/// and creates only a thumbnail off the main actor, not a full-size bitmap.
public enum NativeImageValidation {
    public static func thumbnail(
        data: Data, maximumPixelDimension: Int
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
            return NativePageImage(image: thumbnail, sourceWidth: pixelWidth, sourceHeight: pixelHeight)
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
