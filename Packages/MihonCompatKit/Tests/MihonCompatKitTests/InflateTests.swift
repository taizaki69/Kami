import XCTest
@testable import MihonCompatKit

final class InflateTests: XCTestCase {
    /// Writes a DEFLATE stream of stored (BTYPE=00) blocks, chunked small to
    /// exercise multiple blocks. The 3 header bits share one byte; LEN/NLEN
    /// begin at the next byte boundary.
    private func storedBlocks(_ payload: [UInt8], chunkSize: Int = 8) -> [UInt8] {
        var out: [UInt8] = []
        let chunks = stride(from: 0, to: max(payload.count, 1), by: chunkSize).map {
            Array(payload[$0..<min($0 + chunkSize, payload.count)])
        }
        for (i, chunk) in chunks.enumerated() {
            let final: UInt8 = i == chunks.count - 1 ? 1 : 0
            out.append(final)              // BFINAL bit + BTYPE(00) + 5 pad bits
            out.append(UInt8(chunk.count & 0xFF))
            out.append(UInt8((chunk.count >> 8) & 0xFF))
            let nlen = ~chunk.count
            out.append(UInt8(nlen & 0xFF))
            out.append(UInt8((nlen >> 8) & 0xFF))
            out.append(contentsOf: chunk)
        }
        return out
    }

    /// Fixed-Huffman block containing only literals (codes 0–143 are 8 bits,
    /// values 0x30–0xBF). Bits are packed LSB-first per RFC 1951: each stream
    /// bit takes the next-lowest free bit position of the current byte.
    private func fixedHuffmanLiterals(_ text: String) -> [UInt8] {
        var out: [UInt8] = []
        var bitBuffer: UInt32 = 0
        var bitCount = 0

        func putBits(_ value: UInt32, _ count: Int, msbFirst: Bool) {
            for i in 0..<count {
                let bit = msbFirst ? (value >> UInt32(count - 1 - i)) & 1 : (value >> UInt32(i)) & 1
                bitBuffer |= bit << UInt32(bitCount)
                bitCount += 1
                if bitCount == 8 {
                    out.append(UInt8(bitBuffer & 0xFF))
                    bitBuffer = 0
                    bitCount = 0
                }
            }
        }

        putBits(1, 1, msbFirst: false) // BFINAL
        putBits(1, 2, msbFirst: false) // BTYPE=01 fixed

        for byte in text.utf8 {
            let code = 0x30 + UInt32(byte) // literals 0-143 → 8-bit codes
            putBits(code, 8, msbFirst: true)
        }
        putBits(0, 7, msbFirst: true) // EOB: symbol 256 → 0000000
        if bitCount > 0 {
            out.append(UInt8(bitBuffer & 0xFF))
        }
        return out
    }

    func testStoredBlocks() throws {
        let payload = Array("Hello, extension world! 0123456789".utf8)
        let stream = storedBlocks(payload, chunkSize: 5)
        let result = try Inflate.decompress(stream)
        XCTAssertEqual(result, payload)
    }

    func testStoredEmpty() throws {
        // A single final empty block: header byte 0x01, LEN=0x0000, NLEN=0xFFFF.
        let stream: [UInt8] = [0x01, 0x00, 0x00, 0xFF, 0xFF]
        XCTAssertEqual(try Inflate.decompress(stream), [])
    }

    func testFixedHuffmanLiterals() throws {
        let text = "tachiyomix"
        let stream = fixedHuffmanLiterals(text)
        let result = try Inflate.decompress(stream)
        XCTAssertEqual(String(decoding: result, as: UTF8.self), text)
    }

    func testCorruptStoredThrows() {
        let bad: [UInt8] = [0x01, 0x00, 0x05, 0x00, 0x00, 0x00] // LEN=5, NLEN=0 (mismatch)
        XCTAssertThrowsError(try Inflate.decompress(bad))
    }

    func testOutputLimitStopsExpansion() {
        let stream = storedBlocks(Array("too large".utf8))
        XCTAssertThrowsError(try Inflate.decompress(stream, outputLimit: 3)) { error in
            guard case Inflate.Error.outputLimitExceeded(3) = error else {
                return XCTFail("expected outputLimitExceeded, got \(error)")
            }
        }
    }

    func testOversubscribedHuffmanTableIsRejected() {
        XCTAssertThrowsError(try Inflate.Huffman(lengths: [1, 1, 1])) { error in
            guard case Inflate.Error.badHuffmanCode = error else {
                return XCTFail("expected badHuffmanCode, got \(error)")
            }
        }
    }

    func testZlibWrapper() throws {
        // zlib stream of a single stored block containing "dex".
        let inner: [UInt8] = [0x01, 0x03, 0x00, 0xFC, 0xFF] + Array("dex".utf8)
        let stream: [UInt8] = [0x78, 0x01] + inner + [0x02, 0x71, 0x01, 0x42]
        let result = try Zlib.decompress(stream)
        XCTAssertEqual(String(decoding: result, as: UTF8.self), "dex")
    }

    func testZlibRejectsBadHeaderAndChecksum() {
        let inner: [UInt8] = [0x01, 0x03, 0x00, 0xFC, 0xFF] + Array("dex".utf8)
        XCTAssertThrowsError(try Zlib.decompress([0x78, 0x00] + inner + [0x02, 0x71, 0x01, 0x42]))
        XCTAssertThrowsError(try Zlib.decompress([0x78, 0x01] + inner + [0, 0, 0, 0]))
    }

    func testGzipWrapperAndIntegrityChecks() throws {
        let inner: [UInt8] = [0x01, 0x03, 0x00, 0xFC, 0xFF] + Array("dex".utf8)
        let header: [UInt8] = [0x1f, 0x8b, 0x08, 0, 0, 0, 0, 0, 0, 0]
        let trailer: [UInt8] = [0x02, 0xdc, 0xcb, 0xf6, 3, 0, 0, 0]
        XCTAssertEqual(try Gzip.decompress(header + inner + trailer), Array("dex".utf8))
        XCTAssertThrowsError(try Gzip.decompress(header + inner + [UInt8](repeating: 0, count: 8)))
    }
}
