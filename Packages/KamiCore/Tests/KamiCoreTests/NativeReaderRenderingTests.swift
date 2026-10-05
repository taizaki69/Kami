#if canImport(ImageIO)
import Foundation
import ImageIO
import XCTest
@testable import KamiCore

final class NativeReaderRenderingTests: XCTestCase, @unchecked Sendable {
    private func image(width: Int, height: Int) throws -> (CGImage, Data) {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let i = (y * width + x) * 4
            pixels[i] = UInt8(x % 200)
            pixels[i + 1] = UInt8(y % 200)
            pixels[i + 2] = UInt8((x + y) % 200)
        } }
        let data = Data(pixels)
        return (try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                     bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                                     provider: try XCTUnwrap(CGDataProvider(data: data as CFData)), decode: nil,
                                     shouldInterpolate: false, intent: .defaultIntent)), data)
    }

    private func png(width: Int, height: Int) throws -> Data {
        let (image, _) = try image(width: width, height: height)
        let encoded = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(encoded, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return encoded as Data
    }

    func testLongReaderDecodeRetainsWidthWhileNormalAndPressureOutputsStayBounded() async throws {
        let data = try png(width: 512, height: 12_000)
        let previous = try await NativeImageValidation.thumbnail(data: data, maximumPixelDimension: 4_096)
        let page = try await NativeImageValidation.readerPage(data: data, ordinaryMaximumDimension: 4_096,
                                                              memoryConstrained: false, prepareBorderTrim: true)
        XCTAssertEqual(page.image.width, 512); XCTAssertEqual(page.image.height, 12_000)
        XCTAssertGreaterThan(page.image.width, previous.image.width * 2)
        XCTAssertLessThanOrEqual(page.image.width * page.image.height, ReaderImageDecodePlan.normalLongPagePixels)
        let reduced = try await NativeImageValidation.reducedReaderPage(page)
        let pressuredDecode = try await NativeImageValidation.readerPage(data: data, ordinaryMaximumDimension: 4_096,
                                                                         memoryConstrained: true)
        for image in [reduced.image, pressuredDecode.image] {
            XCTAssertGreaterThan(image.width, 400)
            XCTAssertGreaterThan(image.height, 9_000)
            XCTAssertLessThanOrEqual(image.width * image.height, ReaderImageDecodePlan.constrainedPixels)
        }
        XCTAssertEqual(reduced.sourceWidth, 512); XCTAssertEqual(reduced.sourceHeight, 12_000)
        try await PlatformDownloadImageValidator().validate(data)
        let validation = try await NativeImageValidation.thumbnail(data: data, maximumPixelDimension: 512)
        XCTAssertLessThanOrEqual(validation.image.height, 512)
    }

    func testAdjacentTileRenderingMatchesOriginalPixelsIncludingOrientationAndSeams() throws {
        let width = 93, height = 287
        let (image, expected) = try image(width: width, height: height)
        var rendered = Data(count: width * height * 4)
        try rendered.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height,
                                                 bitsPerComponent: 8, bytesPerRow: width * 4,
                                                 space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            // Match UIKit's upper-left coordinate system. The renderer must
            // invert each CGImage locally, without inverting the page/tile grid.
            context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
            for y in stride(from: 0, to: height, by: 71) {
                for x in stride(from: 0, to: width, by: 31) {
                    context.saveGState()
                    context.clip(to: CGRect(x: x, y: y, width: 31, height: 71))
                    NativeReaderTileRenderer.draw(image, surface: CGSize(width: width, height: height), in: context)
                    context.restoreGState()
                }
            }
        }
        XCTAssertEqual(rendered, expected)
    }

    func testTileDrawingLeavesPixelsOutsideItsClipUntouched() throws {
        let (image, _) = try image(width: 100, height: 100)
        var rendered = Data(count: 100 * 100 * 4)
        try rendered.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 100, height: 100,
                                                 bitsPerComponent: 8, bytesPerRow: 400,
                                                 space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.translateBy(x: 0, y: 100); context.scaleBy(x: 1, y: -1)
            context.clip(to: CGRect(x: 20, y: 25, width: 40, height: 30))
            NativeReaderTileRenderer.draw(image, surface: CGSize(width: 100, height: 100), in: context)
        }
        for y in 0..<100 { for x in 0..<100 {
            XCTAssertEqual(rendered[(y * 100 + x) * 4 + 3], (20..<60).contains(x) && (25..<55).contains(y) ? 255 : 0)
        } }
    }

    func testReaderPathStillRejectsTruncatedImagesAndCanceledLoads() async throws {
        let complete = try png(width: 32, height: 256)
        for invalid in [Data("<html>challenge</html>".utf8), Data(complete.dropLast(12))] {
            do {
                _ = try await NativeImageValidation.readerPage(data: invalid, ordinaryMaximumDimension: 4_096,
                                                                memoryConstrained: false)
                XCTFail("Invalid reader image accepted")
            } catch let error as DownloadImageValidationError { XCTAssertEqual(error, .invalidImage) }
        }
        let canceled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await NativeImageValidation.readerPage(data: complete, ordinaryMaximumDimension: 4_096,
                                                               memoryConstrained: false)
        }
        do { _ = try await canceled.value; XCTFail("Canceled reader decode returned pixels") }
        catch is CancellationError {}
    }
}
#endif
