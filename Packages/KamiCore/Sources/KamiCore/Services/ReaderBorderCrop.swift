import Foundation
#if canImport(ImageIO)
import ImageIO
#endif

public enum ReaderBorderCropError: Error, Equatable { case invalidRaster }

public struct ReaderPixelCrop: Equatable, Sendable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
}

/// Conservative display-only border detection, bounded to a 512×512 RGBA
/// sample. Mixed corners or a blank page keep the full image. Two sample pixels
/// of padding remain and each edge trims at most a quarter of the dimension.
public enum ReaderBorderCrop {
    public static let maximumSampleDimension = 512

    public static func detectRGBA(_ data: Data, width: Int, height: Int) throws -> ReaderPixelCrop {
        try Task.checkCancellation()
        guard (1...maximumSampleDimension).contains(width), (1...maximumSampleDimension).contains(height),
              data.count == width * height * 4 else { throw ReaderBorderCropError.invalidRaster }
        let full = ReaderPixelCrop(x: 0, y: 0, width: width, height: height)
        return try data.withUnsafeBytes { bytes in
            let pixels = bytes.bindMemory(to: UInt8.self)
            func kind(_ x: Int, _ y: Int) -> Int {
                let i = (y * width + x) * 4
                if pixels[i + 3] <= 5 { return 0 } // transparent, not premultiplied black
                guard pixels[i + 3] >= 250 else { return -1 }
                if pixels[i] >= 250 && pixels[i + 1] >= 250 && pixels[i + 2] >= 250 { return 1 }
                if pixels[i] <= 5 && pixels[i + 1] <= 5 && pixels[i + 2] <= 5 { return 2 }
                return -1
            }
            let border = kind(0, 0)
            guard border >= 0, kind(width - 1, 0) == border,
                  kind(0, height - 1) == border, kind(width - 1, height - 1) == border else { return full }
            func blankRow(_ y: Int) -> Bool { (0..<width).allSatisfy { kind($0, y) == border } }
            func blankColumn(_ x: Int) -> Bool { (0..<height).allSatisfy { kind(x, $0) == border } }
            var top = 0, bottom = height, left = 0, right = width
            while top < bottom && blankRow(top) {
                if top % 32 == 0 { try Task.checkCancellation() }; top += 1
            }
            guard top < bottom else { return full }
            while bottom > top && blankRow(bottom - 1) {
                if bottom % 32 == 0 { try Task.checkCancellation() }; bottom -= 1
            }
            while left < right && blankColumn(left) {
                if left % 32 == 0 { try Task.checkCancellation() }; left += 1
            }
            while right > left && blankColumn(right - 1) {
                if right % 32 == 0 { try Task.checkCancellation() }; right -= 1
            }
            left = min(width / 4, max(0, left - 2))
            top = min(height / 4, max(0, top - 2))
            right = max(width - width / 4, min(width, right + 2))
            bottom = max(height - height / 4, min(height, bottom + 2))
            try Task.checkCancellation()
            return .init(x: left, y: top, width: right - left, height: bottom - top)
        }
    }

    #if canImport(ImageIO)
    /// Called inside NativeImageValidation's detached, cancellable decoding
    /// task. Never renders the full source bitmap or changes downloaded bytes.
    static func trimming(_ image: CGImage) throws -> CGImage {
        let factor = min(1, Double(maximumSampleDimension) / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * factor))
        let height = max(1, Int(Double(image.height) * factor))
        var data = Data(count: width * height * 4)
        let drawn = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                            | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return image }
        let crop = try detectRGBA(data, width: width, height: height)
        if crop.x == 0 && crop.y == 0 && crop.width == width && crop.height == height { return image }
        let x = floor(Double(crop.x) * Double(image.width) / Double(width))
        let y = floor(Double(crop.y) * Double(image.height) / Double(height))
        let right = ceil(Double(crop.x + crop.width) * Double(image.width) / Double(width))
        let bottom = ceil(Double(crop.y + crop.height) * Double(image.height) / Double(height))
        return image.cropping(to: CGRect(x: x, y: y, width: right - x, height: bottom - y)) ?? image
    }
    #endif
}
