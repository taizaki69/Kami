import Foundation
import XCTest
@testable import KamiCore

final class PNGImageIntegrityTests: XCTestCase, @unchecked Sendable {
    // A complete 1x1 RGBA PNG also used by the real ImageIO reader regression.
    private let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4////fwAJ+wP9KobjigAAAABJRU5ErkJggg==")!

    func testCompletePNGAndNonPNGLeavePixelDecodingToImageIO() throws {
        try PNGImageIntegrity.validateIfPNG(png)
        try PNGImageIntegrity.validateIfPNG(Data([0xff, 0xd8, 0xff, 0xd9]))
        // The helper is only a PNG gate; passing non-PNG bytes is not admission.
        try PNGImageIntegrity.validateIfPNG(Data("<html>challenge</html>".utf8))
        let slice = Data([0, 0]) + png
        try PNGImageIntegrity.validateIfPNG(slice.dropFirst(2))
    }

    func testEveryTruncationAfterSignatureIsRejectedIncludingMissingIEND() {
        for length in 8..<png.count {
            assertInvalid(Data(png.prefix(length)), "Truncated at byte \(length)")
        }
    }

    func testCRCAndLengthCorruptionCannotBeHiddenByATrailer() {
        var badCRC = png
        badCRC[badCRC.count - 1] ^= 1
        assertInvalid(badCRC)
        var badPixels = png
        badPixels[45] ^= 1
        assertInvalid(badPixels)
        var hugeLength = png
        hugeLength.replaceSubrange(33..<37, with: [0xff, 0xff, 0xff, 0xff])
        assertInvalid(hugeLength)
        var appendedTrailer = Data(png.prefix(45))
        appendedTrailer.append(png.suffix(12))
        assertInvalid(appendedTrailer)
        assertInvalid(png + Data([0]))
    }

    func testHeaderDataAndTrailerOrderingIsRequiredEvenWithValidChecksums() {
        let signature = Data(png.prefix(8))
        let header = Data(png[8..<33])
        let pixels = Data(png[33..<png.count - 12])
        let end = Data(png.suffix(12))
        assertInvalid(signature + pixels + header + end)
        assertInvalid(signature + header + header + pixels + end)
        assertInvalid(signature + header + end)
        assertInvalid(signature + header + pixels + chunk("teXT", Data()) + pixels + end)
        assertInvalid(signature + header + pixels + chunk("IEND", Data([0])))
        assertInvalid(signature + header + pixels + end + end)
        assertInvalid(signature + header + pixels + chunk("PLTE", Data([0, 0, 0])) + end)
    }

    func testUnknownAncillaryChunksAreAllowedButCriticalChunksAreRejected() throws {
        let prefix = Data(png.prefix(33))
        let suffix = Data(png.dropFirst(33))
        try PNGImageIntegrity.validateIfPNG(prefix + chunk("kaMI", Data([1, 2, 3])) + suffix)
        assertInvalid(prefix + chunk("KAMI", Data()) + suffix)
        assertInvalid(prefix + chunk("ka0I", Data()) + suffix)
    }

    func testCancelledValidationDoesNotScanTheContainer() async throws {
        let data = png
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try PNGImageIntegrity.validateIfPNG(data)
        }
        do {
            try await task.value
            XCTFail("Cancelled validation succeeded")
        } catch is CancellationError { }
    }

    private func assertInvalid(_ data: Data, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try PNGImageIntegrity.validateIfPNG(data), message, file: file, line: line) {
            XCTAssertEqual($0 as? DownloadImageValidationError, .invalidImage, file: file, line: line)
        }
    }

    // Independent bitwise CRC implementation to construct framed fixtures.
    private func chunk(_ type: String, _ payload: Data) -> Data {
        let contents = Data(type.utf8) + payload
        var crc = UInt32.max
        for byte in contents {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xedb8_8320) }
        }
        func word(_ value: UInt32) -> Data {
            Data([UInt8(value >> 24), UInt8(truncatingIfNeeded: value >> 16),
                  UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
        }
        return word(UInt32(payload.count)) + contents + word(crc ^ UInt32.max)
    }
}
