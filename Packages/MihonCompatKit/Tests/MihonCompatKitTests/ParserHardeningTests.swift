import XCTest
@testable import MihonCompatKit

final class ParserHardeningTests: XCTestCase {
    func testByteReaderRejectsNegativeSkip() {
        var reader = ByteReader([1, 2, 3])
        XCTAssertThrowsError(try reader.skip(-1))
        XCTAssertEqual(reader.offset, 0)
    }

    func testBinaryXMLRejectsNonProgressingChunk() {
        var bytes: [UInt8] = []
        appendU16(0x0003, to: &bytes)
        appendU16(8, to: &bytes)
        appendU32(16, to: &bytes)
        appendU16(0x9999, to: &bytes)
        appendU16(8, to: &bytes)
        appendU32(0, to: &bytes)
        XCTAssertThrowsError(try BinaryXMLDocument(bytes))
    }

    func testDexRejectsOutOfRangeTypeDescriptor() {
        var builder = DexBuilder()
        builder.setClass("LTest;")
        builder.addMethod(.init(name: "run", registers: 0, ins: 0, outs: 0,
                                insns: Insn.returnVoid(), isStatic: true))
        var bytes = builder.build()
        let typeIdsOffset = readU32(bytes, at: 68)
        writeU32(UInt32.max, to: &bytes, at: typeIdsOffset)
        updateDexChecksum(&bytes)
        XCTAssertThrowsError(try DexFile(bytes))
    }

    func testDexRejectsTableCountLargerThanFile() {
        var builder = DexBuilder()
        builder.setClass("LTest;")
        builder.addMethod(.init(name: "run", registers: 0, ins: 0, outs: 0,
                                insns: Insn.returnVoid(), isStatic: true))
        var bytes = builder.build()
        writeU32(UInt32.max, to: &bytes, at: 56) // string_ids_size
        updateDexChecksum(&bytes)
        XCTAssertThrowsError(try DexFile(bytes))
    }

    func testDexRejectsUnsupportedVersionAndBadChecksum() {
        var builder = DexBuilder()
        builder.setClass("LTest;")
        builder.addMethod(.init(name: "run", registers: 0, ins: 0, outs: 0,
                                insns: Insn.returnVoid(), isStatic: true))
        let valid = builder.build()

        for version in ["036", "041"] {
            var bytes = valid
            bytes.replaceSubrange(4..<7, with: version.utf8)
            XCTAssertThrowsError(try DexFile(bytes))
        }

        var corrupt = valid
        corrupt[corrupt.count - 1] ^= 1
        XCTAssertThrowsError(try DexFile(corrupt)) { error in
            guard case DexFile.Error.checksumMismatch = error else {
                return XCTFail("expected checksumMismatch, got \(error)")
            }
        }
    }

    func testProtoRejectsLengthPastEndAndGroups() {
        XCTAssertThrowsError(try ProtoMessage([0x0a, 0x0a]))
        XCTAssertThrowsError(try ProtoMessage([0x0b]))
    }

    func testProtoCapsFieldCount() {
        let field = [UInt8](arrayLiteral: 0x08, 0x00)
        let bytes = Array(repeating: field, count: ProtoMessage.maximumFieldCount + 1).flatMap { $0 }
        XCTAssertThrowsError(try ProtoMessage(bytes))
    }

    func testStoredZipRoundTripAndCRCValidation() throws {
        let payload = Array("classes".utf8)
        let archive = try ZipArchive(makeStoredZip(name: "classes.dex", payload: payload))
        XCTAssertEqual(try archive.data(named: "classes.dex"), payload)

        let corrupt = try ZipArchive(makeStoredZip(name: "classes.dex", payload: payload, crcOverride: 0))
        XCTAssertThrowsError(try corrupt.data(named: "classes.dex")) { error in
            guard case ZipArchive.Error.checksumMismatch = error else {
                return XCTFail("expected checksumMismatch, got \(error)")
            }
        }
    }

    func testZipRejectsOversizedDeclaredEntryBeforeAllocation() throws {
        let bytes = makeStoredZip(
            name: "classes.dex", payload: [0], reportedUncompressedSize: 129 * 1024 * 1024
        )
        let archive = try ZipArchive(bytes)
        XCTAssertThrowsError(try archive.data(named: "classes.dex")) { error in
            guard case ZipArchive.Error.entryTooLarge = error else {
                return XCTFail("expected entryTooLarge, got \(error)")
            }
        }
    }

    func testEveryTruncatedDexAndZipPrefixIsCatchable() throws {
        var builder = DexBuilder()
        builder.setClass("LTest;")
        builder.addMethod(.init(name: "run", registers: 0, ins: 0, outs: 0,
                                insns: Insn.returnVoid(), isStatic: true))
        let dex = builder.build()
        XCTAssertNoThrow(try DexFile(dex))
        for length in 0..<dex.count {
            XCTAssertThrowsError(try DexFile(Array(dex.prefix(length))), "DEX prefix length \(length)")
        }

        let zip = makeStoredZip(name: "classes.dex", payload: dex)
        XCTAssertNoThrow(try ZipArchive(zip))
        for length in 0..<zip.count {
            XCTAssertThrowsError(try ZipArchive(Array(zip.prefix(length))), "ZIP prefix length \(length)")
        }
    }

    private func makeStoredZip(name: String, payload: [UInt8], crcOverride: UInt32? = nil,
                               reportedUncompressedSize: UInt32? = nil) -> [UInt8] {
        let nameBytes = Array(name.utf8)
        let crc = crcOverride ?? crc32(payload)
        let reportedSize = reportedUncompressedSize ?? UInt32(payload.count)
        var bytes: [UInt8] = []

        appendU32(0x0403_4b50, to: &bytes)
        appendU16(20, to: &bytes)
        appendU16(0, to: &bytes)
        appendU16(0, to: &bytes)
        appendU16(0, to: &bytes)
        appendU16(0, to: &bytes)
        appendU32(crc, to: &bytes)
        appendU32(UInt32(payload.count), to: &bytes)
        appendU32(UInt32(payload.count), to: &bytes)
        appendU16(UInt16(nameBytes.count), to: &bytes)
        appendU16(0, to: &bytes)
        bytes += nameBytes + payload

        let centralOffset = UInt32(bytes.count)
        appendU32(0x0201_4b50, to: &bytes)
        appendU16(20, to: &bytes)
        appendU16(20, to: &bytes)
        appendU16(0, to: &bytes)
        appendU16(0, to: &bytes)
        appendU16(0, to: &bytes)
        appendU16(0, to: &bytes)
        appendU32(crc, to: &bytes)
        appendU32(UInt32(payload.count), to: &bytes)
        appendU32(reportedSize, to: &bytes)
        appendU16(UInt16(nameBytes.count), to: &bytes)
        appendU16(0, to: &bytes)
        appendU16(0, to: &bytes)
        appendU16(0, to: &bytes)
        appendU16(0, to: &bytes)
        appendU32(0, to: &bytes)
        appendU32(0, to: &bytes)
        bytes += nameBytes
        let centralSize = UInt32(bytes.count) - centralOffset

        appendU32(0x0605_4b50, to: &bytes)
        appendU16(0, to: &bytes)
        appendU16(0, to: &bytes)
        appendU16(1, to: &bytes)
        appendU16(1, to: &bytes)
        appendU32(centralSize, to: &bytes)
        appendU32(centralOffset, to: &bytes)
        appendU16(0, to: &bytes)
        return bytes
    }

    private func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xedb8_8320) }
        }
        return ~crc
    }

    private func readU32(_ bytes: [UInt8], at offset: Int) -> Int {
        Int(UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 |
            UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24)
    }

    private func writeU32(_ value: UInt32, to bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = UInt8(value & 0xff)
        bytes[offset + 1] = UInt8((value >> 8) & 0xff)
        bytes[offset + 2] = UInt8((value >> 16) & 0xff)
        bytes[offset + 3] = UInt8(value >> 24)
    }

    private func updateDexChecksum(_ bytes: inout [UInt8]) {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in bytes.dropFirst(12) {
            a = (a + UInt32(byte)) % 65_521
            b = (b + a) % 65_521
        }
        writeU32(b << 16 | a, to: &bytes, at: 8)
    }

    private func appendU16(_ value: UInt16, to bytes: inout [UInt8]) {
        bytes.append(UInt8(value & 0xff))
        bytes.append(UInt8(value >> 8))
    }

    private func appendU32(_ value: UInt32, to bytes: inout [UInt8]) {
        appendU16(UInt16(value & 0xffff), to: &bytes)
        appendU16(UInt16(value >> 16), to: &bytes)
    }
}
