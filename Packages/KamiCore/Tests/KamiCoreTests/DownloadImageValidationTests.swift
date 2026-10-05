import Foundation
import XCTest
@testable import KamiCore
#if canImport(ImageIO)
import ImageIO

final class DownloadImageValidationTests: XCTestCase, @unchecked Sendable {
    // ImageIO produces these fixtures on the Apple host; the filesystem tests'
    // injected validator deliberately does not stand in for real decoding.
    private func png(width: Int = 1_024, height: Int = 16) throws -> Data {
        let pixels = Data(repeating: 0xff, count: width * height * 4)
        let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
        let image = try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let encoded = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(encoded, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return encoded as Data
    }

    func testProductionValidatorDecodesCompleteImageAndReaderThumbnailIsBounded() async throws {
        let data = try png()
        try await PlatformDownloadImageValidator().validate(data)
        let result = try await NativeImageValidation.thumbnail(data: data, maximumPixelDimension: 512)
        XCTAssertEqual(result.sourceWidth, 1_024)
        XCTAssertEqual(result.sourceHeight, 16)
        XCTAssertEqual(result.image.width, 512)
        XCTAssertLessThanOrEqual(result.image.height, 512)
    }

    func testHTMLAndTruncatedPayloadCannotBecomeDownloadedImages() async throws {
        let complete = try png()
        var corruptCRC = complete
        corruptCRC[corruptCRC.count - 1] ^= 1
        let invalidPayloads = [Data(), Data("<html>challenge</html>".utf8),
                               Data(complete.prefix(32)), Data(complete.prefix(complete.count / 2)),
                               Data(complete.dropLast(12)), corruptCRC]
        for (index, invalid) in invalidPayloads.enumerated() {
            do {
                try await PlatformDownloadImageValidator().validate(invalid)
                XCTFail("Incomplete or non-image payload \(index) was accepted (\(invalid.count) bytes)")
            } catch let error as DownloadImageValidationError {
                XCTAssertEqual(error, .invalidImage)
            }
        }
    }

    func testDimensionLimitRejectsACompleteOverwideImageBeforeThumbnailDecode() async throws {
        // A one-row image stays small while exercising the real dimension
        // guard, without allocating a decompression-bomb fixture in the test.
        let data = try png(width: 100_001, height: 1)
        do {
            try await PlatformDownloadImageValidator().validate(data)
            XCTFail("Overwide image accepted")
        } catch let error as DownloadImageValidationError {
            XCTAssertEqual(error, .dimensionsTooLarge)
        }
    }

    func testAlreadyCancelledValidationDoesNotReturnAnImage() async throws {
        let data = try png()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await NativeImageValidation.thumbnail(data: data, maximumPixelDimension: 512, prepareBorderTrim: true)
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled decoding returned an image")
        } catch is CancellationError { }
    }

    func testReaderPreparesReversibleCropWithoutChangingOriginalOrSourceBytes() async throws {
        var pixels = [UInt8](repeating: 255, count: 40 * 32 * 4)
        for y in 6..<25 { for x in 8..<30 {
            let i = (y * 40 + x) * 4
            pixels[i] = 80; pixels[i + 1] = 100; pixels[i + 2] = 120
        } }
        let image = try XCTUnwrap(CGImage(
            width: 40, height: 32, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 160,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData)), decode: nil,
            shouldInterpolate: false, intent: .defaultIntent))
        let encoded = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(encoded, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let source = encoded as Data, saved = source
        let normal = try await NativeImageValidation.thumbnail(data: source, maximumPixelDimension: 512)
        XCTAssertNil(normal.borderTrimmedImage)
        let result = try await NativeImageValidation.thumbnail(data: source, maximumPixelDimension: 512, prepareBorderTrim: true)
        let cropped = try XCTUnwrap(result.borderTrimmedImage)
        XCTAssertEqual(result.image.width, 40); XCTAssertEqual(result.image.height, 32)
        XCTAssertEqual(result.sourceWidth, 40); XCTAssertEqual(result.sourceHeight, 32)
        XCTAssertEqual(cropped.width, 26); XCTAssertEqual(cropped.height, 23)
        XCTAssertEqual(source, saved)
        var rendered = Data(count: cropped.width * cropped.height * 4)
        try rendered.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: cropped.width, height: cropped.height,
                                                 bitsPerComponent: 8, bytesPerRow: cropped.width * 4,
                                                 space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        }
        // Asymmetric margins prove that the analysis and CGImage crop use the
        // same pixel origin; a vertical flip would cut one of these margins.
        XCTAssertGreaterThan(rendered[(1 * 26 + 2) * 4], 240)
        XCTAssertLessThan(rendered[(2 * 26 + 2) * 4], 200)
    }

    func testBlankReaderThumbnailKeepsItsFullBoundedDimensions() async throws {
        let data = try png()
        let result = try await NativeImageValidation.thumbnail(data: data, maximumPixelDimension: 512, prepareBorderTrim: true)
        let cropped = try XCTUnwrap(result.borderTrimmedImage)
        XCTAssertEqual(cropped.width, result.image.width)
        XCTAssertEqual(cropped.height, result.image.height)
        XCTAssertLessThanOrEqual(cropped.width, 512)
        XCTAssertLessThanOrEqual(cropped.height, 512)
    }
}
#else
final class DownloadImageValidationTests: XCTestCase, @unchecked Sendable {
    func testProductionValidationFailsClosedWhenImageIOIsUnavailable() async throws {
        do {
            try await PlatformDownloadImageValidator().validate(Data([0x89, 0x50, 0x4e, 0x47]))
            XCTFail("A non-Apple host must not claim production image validation")
        } catch let error as DownloadImageValidationError {
            XCTAssertEqual(error, .unavailable)
        }
    }
}
#endif
