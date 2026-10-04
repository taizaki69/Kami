import Foundation
import XCTest
@testable import MihonCompatKit

final class StrictGzipTests: XCTestCase, @unchecked Sendable {
    // Independent compressor: CPython 3.12.3 / zlib 1.3, compressobj(level,
    // DEFLATED, -15, 8, strategy), plus an mtime=0 gzip header and zlib.crc32.
    // Stored uses level 0 and the short string; fixed uses level 6 / Z_FIXED;
    // dynamic uses level 6 / Z_DEFAULT_STRATEGY and the repeated string below.
    private func fixtures() throws -> [(bytes: [UInt8], plain: [UInt8], block: UInt8)] {
        let repeated = Array(String(repeating: "Kami library backup: chapter 12, progress 7, bookmarked.\n", count: 200).utf8)
        return [
            (try hex("1f8b0800000000000003011300ecff6261636b75702073746f72656420626c6f636bcf7877a413000000"),
             Array("backup stored block".utf8), 0),
            (try hex("1f8b0800000000000003f34ecccd54c8c94c2a4a2caa54484a4cce2e2db05248ce482c28492d523034d2512828ca4f2f4a2d2e5630d75148cacfcfce4d2cca4e4dd1e3f21ed538aa7154e3a8c6518da31a47358e6a1cd538aa7154e3a8c6518da31a47358e6a1cd538aa7154e3a8c6518da31a47358e6a1cd538aa7154e3a8c6518da31a47358e6a1cd538aa7154e3a8c6518da31a47358e6a1cd538aa7154e348d508005b86ebe5882c0000"),
             repeated, 1),
            (try hex("1f8b0800000000000003edcbc109c2301400d0bb53fc018aa017c1153a4552832db124a47a707b07f1bdfb9bd3bec56bcb238d6fe4b4d44fbfc7b2a6fe2e232ed729fa68cf518e236e53e4d6ea9e462d8ff3691645511445511445511445511445511445511445511445511445511445511445f15fe30f5b86ebe5882c0000"),
             repeated, 2)
        ]
    }

    func testIndependentStoredFixedAndDynamicMembersDecodeWithExactOutputLimit() throws {
        for fixture in try fixtures() {
            XCTAssertEqual((fixture.bytes[10] >> 1) & 3, fixture.block)
            XCTAssertEqual(try Gzip.decompressSingleMember(fixture.bytes, outputLimit: fixture.plain.count), fixture.plain)
        }
    }

    func testEveryTruncatedPrefixOfEachCompressorFixtureIsRejected() throws {
        for fixture in try fixtures() {
            for length in 0..<fixture.bytes.count {
                XCTAssertThrowsError(try Gzip.decompressSingleMember(Array(fixture.bytes.prefix(length))),
                                     "Block type \(fixture.block), prefix \(length)")
            }
        }
    }

    func testOptionalHeaderFieldsAndCRC16AreCheckedBeforeBodyDecode() throws {
        let fixture = try XCTUnwrap(fixtures().first)
        let (member, headerEnd) = optionalHeaderMember(fixture.bytes)
        XCTAssertEqual(try Gzip.decompressSingleMember(member), fixture.plain)
        var corruptHeader = member
        corruptHeader[headerEnd - 1] ^= 1
        XCTAssertThrowsError(try Gzip.decompressSingleMember(corruptHeader)) {
            guard case Gzip.Error.headerChecksumMismatch = $0 else { return XCTFail("Expected header CRC failure, got \($0)") }
        }
        for length in 0..<headerEnd {
            XCTAssertThrowsError(try Gzip.decompressSingleMember(Array(member.prefix(length)) + [UInt8](repeating: 0, count: 8)))
        }
    }

    func testMalformedFlagsAndOptionalHeaderLengthsDoNotConsumeTheTrailer() throws {
        let base = try XCTUnwrap(fixtures().first).bytes
        var badMethod = base
        badMethod[2] = 0
        XCTAssertThrowsError(try Gzip.decompressSingleMember(badMethod))
        for flag: UInt8 in [0x20, 0x40, 0x80] {
            var bad = base
            bad[3] = flag
            XCTAssertThrowsError(try Gzip.decompressSingleMember(bad))
        }
        var header = Array(base.prefix(10))
        header[3] = 4
        XCTAssertThrowsError(try Gzip.decompressSingleMember(header + [0xff, 0xff] + base.dropFirst(10)))
        for flag: UInt8 in [8, 16] {
            header[3] = flag
            let noTerminator = header + [UInt8](repeating: 0x41, count: 64) + [UInt8](repeating: 0, count: 8)
            XCTAssertThrowsError(try Gzip.decompressSingleMember(noTerminator))
        }
    }

    func testSingleMemberPolicyRejectsTrailingBytesAndConcatenation() throws {
        let fixture = try XCTUnwrap(fixtures().first)
        let duplicate = fixture.bytes + fixture.bytes
        // Keep the pre-existing index entry point's behavior separate. The
        // strict backup entry point must not inherit its early-stop behavior.
        XCTAssertEqual(try Gzip.decompress(duplicate), fixture.plain)
        let trailer = Array(fixture.bytes.suffix(8))
        let invalidMembers: [[UInt8]] = [duplicate, fixture.bytes + trailer,
                                        Array(fixture.bytes.dropLast(8)) + [0] + trailer]
        for invalid in invalidMembers {
            XCTAssertThrowsError(try Gzip.decompressSingleMember(invalid)) {
                guard case Inflate.Error.trailingData = $0 else { return XCTFail("Expected unconsumed input, got \($0)") }
            }
        }
    }

    func testBodyCRCAndISIZEAreIndependentlyChecked() throws {
        let fixture = try XCTUnwrap(fixtures().last)
        var badCRC = fixture.bytes
        badCRC[badCRC.count - 8] ^= 1
        XCTAssertThrowsError(try Gzip.decompressSingleMember(badCRC)) {
            guard case Gzip.Error.checksumMismatch = $0 else { return XCTFail("Expected body CRC failure, got \($0)") }
        }
        var badSize = fixture.bytes
        badSize[badSize.count - 4] ^= 1
        XCTAssertThrowsError(try Gzip.decompressSingleMember(badSize)) {
            guard case Gzip.Error.sizeMismatch = $0 else { return XCTFail("Expected ISIZE failure, got \($0)") }
        }
    }

    func testOutputLimitStopsAllBlockKindsAndEmptyFinalPaddingIsAllowed() throws {
        for fixture in try fixtures() {
            let limit = fixture.plain.count - 1
            XCTAssertThrowsError(try Gzip.decompressSingleMember(fixture.bytes, outputLimit: limit)) {
                guard case Inflate.Error.outputLimitExceeded(limit) = $0 else { return XCTFail("Expected output limit, got \($0)") }
            }
        }
        let header: [UInt8] = [0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3]
        // Empty fixed block takes 10 bits. The unused high six bits need not
        // be zero, but no extra byte may follow the final block.
        let empty = header + [0x03, 0xfc] + [UInt8](repeating: 0, count: 8)
        XCTAssertEqual(try Gzip.decompressSingleMember(empty, outputLimit: 0), [])
        XCTAssertThrowsError(try Gzip.decompressSingleMember(empty, outputLimit: -1))
    }

    func testCancelledBackupContainerDecodeDoesNotReturnData() async throws {
        let fixture = try XCTUnwrap(fixtures().last)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try Gzip.decompressSingleMember(fixture.bytes)
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled gzip decode returned data")
        } catch is CancellationError { }
    }

    private func hex(_ text: String) throws -> [UInt8] {
        let chars = Array(text)
        XCTAssertEqual(chars.count % 2, 0)
        return try stride(from: 0, to: chars.count, by: 2).map { index in
            try XCTUnwrap(UInt8(String(chars[index..<index + 2]), radix: 16))
        }
    }

    private func optionalHeaderMember(_ base: [UInt8]) -> ([UInt8], Int) {
        var header = Array(base.prefix(10))
        header[3] = 0x1f // FTEXT, FHCRC, FEXTRA, FNAME, FCOMMENT
        header += [4, 0, 0x4b, 0x41, 0, 0]
        header += Array("fixture.tachibk\0Kami test\0".utf8)
        // Independent bitwise header checksum, unlike production's table path.
        var crc = UInt32.max
        for byte in header {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xedb8_8320) }
        }
        crc = ~crc
        header += [UInt8(truncatingIfNeeded: crc), UInt8(truncatingIfNeeded: crc >> 8)]
        return (header + base.dropFirst(10), header.count)
    }
}
