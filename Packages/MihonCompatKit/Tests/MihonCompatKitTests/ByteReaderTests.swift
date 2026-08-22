import XCTest
@testable import MihonCompatKit

final class ByteReaderTests: XCTestCase {
    func testULEB128RejectsOverlongValue() {
        var reader = ByteReader([UInt8](repeating: 0x80, count: 11))
        XCTAssertThrowsError(try reader.uleb128()) { error in
            guard case ByteReader.Error.badULEB128 = error else {
                return XCTFail("expected badULEB128, got \(error)")
            }
        }
    }

    func testSLEB128RejectsOverlongValue() {
        var reader = ByteReader([UInt8](repeating: 0x80, count: 11))
        XCTAssertThrowsError(try reader.sleb128()) { error in
            guard case ByteReader.Error.badSLEB128 = error else {
                return XCTFail("expected badSLEB128, got \(error)")
            }
        }
    }
}
