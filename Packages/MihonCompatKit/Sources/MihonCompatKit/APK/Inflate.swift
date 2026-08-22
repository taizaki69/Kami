import Foundation

/// RFC 1951 DEFLATE decompressor (pure Swift).
///
/// Extension APK entries are DEFLATE-compressed, so the kit cannot rely on
/// Apple's Compression framework and stay host-testable. The decode structure
/// follows the classic canonical-Huffman approach: per-block code tables are
/// built into (count, symbol) arrays and decoded bit-first MSB-of-code.
///
/// Verified against stored-block and fixed-Huffman fixtures in
/// `InflateTests`; real-APK cross-validation happens in the macOS integration
/// tests (`scripts/fetch_corpus.sh`).
enum Inflate {
    enum Error: Swift.Error, CustomStringConvertible {
        case badBlockType(Int)
        case badHuffmanCode
        case storedLengthMismatch
        case distanceTooFar(Int)
        case invalidCodeLengthRepeat
        case incompleteStream
        case unexpectedEnd
        case outputLimitExceeded(Int)

        var description: String {
            switch self {
            case let .badBlockType(t): return "invalid deflate block type \(t)"
            case .badHuffmanCode: return "oversubscribed/invalid huffman code lengths"
            case .storedLengthMismatch: return "stored block LEN/NLEN mismatch"
            case let .distanceTooFar(d): return "distance \(d) exceeds output produced so far"
            case .invalidCodeLengthRepeat: return "code length repeat without preceding length"
            case .incompleteStream: return "final block ended before stream was complete"
            case .unexpectedEnd: return "unexpected end of compressed stream"
            case let .outputLimitExceeded(limit): return "decompressed data exceeds the \(limit)-byte limit"
            }
        }
    }

    struct BitReader {
        let bytes: [UInt8]
        var pos = 0      // byte position
        var bit = 0      // bit position within current byte (0 = LSB)

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func bitValue() throws -> UInt8 {
            guard pos < bytes.count else { throw Error.unexpectedEnd }
            let b = (bytes[pos] >> bit) & 1
            advance()
            return b
        }

        private mutating func advance() {
            bit += 1
            if bit == 8 { bit = 0; pos += 1 }
        }

        /// LSB-first integer, used for block headers and huffman codes.
        mutating func bits(_ n: Int) throws -> UInt32 {
            var v: UInt32 = 0
            for i in 0..<n {
                let b = try bitValue()
                v |= UInt32(b) << i
            }
            return v
        }

        /// Huffman codes are stored MSB-first once their bits are gathered.
        mutating func code(_ length: Int) throws -> UInt32 {
            try bits(length)
        }

        /// Reverse the next `n` bits so canonical codes compare naturally.
        mutating func reverse(_ n: Int) throws -> UInt32 {
            var v: UInt32 = 0
            for _ in 0..<n {
                v = (v << 1) | UInt32(try bitValue())
            }
            return v
        }

        mutating func alignToByte() {
            if bit != 0 { bit = 0; pos += 1 }
        }
    }

    /// Canonical Huffman decoder: counts[symbol length] and symbols sorted by
    /// (length, symbol). `decode` walks the code bit by bit, which is slow but
    /// simple and correct; ZIP entries in APKs are small enough that this is
    /// fine (dex payloads are a few MB; decoding is ~1s worst case).
    struct Huffman {
        var counts = [Int](repeating: 0, count: 16)
        var symbols = [Int]()

        init(lengths: [Int]) throws {
            for l in lengths where l != 0 {
                guard l < counts.count else { throw Error.badHuffmanCode }
                counts[l] += 1
            }
            var codesRemaining = 1
            for length in 1...15 {
                codesRemaining = (codesRemaining << 1) - counts[length]
                guard codesRemaining >= 0 else { throw Error.badHuffmanCode }
            }
            var offsets = [Int](repeating: 0, count: 16)
            for l in 1..<15 { offsets[l + 1] = offsets[l] + counts[l] }
            symbols = [Int](repeating: 0, count: lengths.filter { $0 != 0 }.count)
            for (symbol, l) in lengths.enumerated() where l != 0 {
                symbols[offsets[l]] = symbol
                offsets[l] += 1
            }
        }

        func decode(_ br: inout BitReader) throws -> Int {
            var code = 0
            var first = 0
            var index = 0
            for length in 1...15 {
                code |= Int(try br.bitValue())
                let count = counts[length]
                let offset = code - first
                if offset >= 0, offset < count {
                    let position = index + offset
                    guard position >= 0, position < symbols.count else { throw Error.badHuffmanCode }
                    return symbols[position]
                }
                index += count
                first = (first + count) << 1
                code <<= 1
            }
            throw Error.badHuffmanCode
        }
    }

    /// Decompresses a raw DEFLATE stream (no zlib/gzip wrapper).
    static let defaultOutputLimit = 128 * 1024 * 1024

    static func decompress(_ input: [UInt8], outputLimit: Int = defaultOutputLimit) throws -> [UInt8] {
        guard outputLimit >= 0 else { throw Error.outputLimitExceeded(outputLimit) }
        var br = BitReader(input)
        var out: [UInt8] = []
        let (scaledCapacity, overflow) = input.count.multipliedReportingOverflow(by: 4)
        out.reserveCapacity(min(outputLimit, overflow ? outputLimit : scaledCapacity))

        while true {
            let final = try br.bits(1)
            let type = try br.bits(2)
            switch type {
            case 0:
                br.alignToByte()
                let len = Int(try br.bits(16))
                let nlen = Int(try br.bits(16))
                guard len & 0xffff == (~nlen & 0xffff) else { throw Error.storedLengthMismatch }
                guard len <= outputLimit - out.count else { throw Error.outputLimitExceeded(outputLimit) }
                for _ in 0..<len {
                    out.append(UInt8(try br.bits(8)))
                }

            case 1:
                var litLengths = [Int](repeating: 8, count: 144)
                litLengths += [Int](repeating: 9, count: 112)
                litLengths += [Int](repeating: 7, count: 24)
                litLengths += [Int](repeating: 8, count: 8)
                let lit = try Huffman(lengths: litLengths)
                let dist = try Huffman(lengths: [Int](repeating: 5, count: 30))
                try inflateBlock(&br, &out, lit, dist, outputLimit: outputLimit)

            case 2:
                let (lit, dist) = try dynamicTables(&br)
                try inflateBlock(&br, &out, lit, dist, outputLimit: outputLimit)

            default:
                throw Error.badBlockType(Int(type))
            }
            if final == 1 { break }
        }
        return out
    }

    private static let lengthBase: [Int] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    private static let lengthExtra: [Int] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let distBase: [Int] = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    private static let distExtra: [Int] = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    private static let codeLengthOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    private static func dynamicTables(_ br: inout BitReader) throws -> (Huffman, Huffman) {
        let hlit = Int(try br.bits(5)) + 257
        let hdist = Int(try br.bits(5)) + 1
        let hclen = Int(try br.bits(4)) + 4

        var codeLengthLengths = [Int](repeating: 0, count: 19)
        for i in 0..<hclen {
            codeLengthLengths[codeLengthOrder[i]] = Int(try br.bits(3))
        }
        let clHuffman = try Huffman(lengths: codeLengthLengths)

        var lengths: [Int] = []
        lengths.reserveCapacity(hlit + hdist)
        while lengths.count < hlit + hdist {
            let symbol = try clHuffman.decode(&br)
            switch symbol {
            case 0...15:
                lengths.append(symbol)
            case 16:
                guard let prev = lengths.last else { throw Error.invalidCodeLengthRepeat }
                let repeatCount = 3 + Int(try br.bits(2))
                guard repeatCount <= hlit + hdist - lengths.count else { throw Error.badHuffmanCode }
                lengths += [Int](repeating: prev, count: repeatCount)
            case 17:
                let repeatCount = 3 + Int(try br.bits(3))
                guard repeatCount <= hlit + hdist - lengths.count else { throw Error.badHuffmanCode }
                lengths += [Int](repeating: 0, count: repeatCount)
            case 18:
                let repeatCount = 11 + Int(try br.bits(7))
                guard repeatCount <= hlit + hdist - lengths.count else { throw Error.badHuffmanCode }
                lengths += [Int](repeating: 0, count: repeatCount)
            default:
                throw Error.badHuffmanCode
            }
        }
        guard lengths.count == hlit + hdist else { throw Error.badHuffmanCode }

        let lit = try Huffman(lengths: Array(lengths[0..<hlit]))
        // A single distance code of zero length means "no distance codes".
        let distLengths = Array(lengths[hlit...])
        let dist = distLengths.allSatisfy({ $0 == 0 })
            ? try Huffman(lengths: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0].map { _ in 0 })
            : try Huffman(lengths: distLengths)
        return (lit, dist)
    }

    private static func inflateBlock(_ br: inout BitReader, _ out: inout [UInt8], _ lit: Huffman, _ dist: Huffman,
                                     outputLimit: Int = defaultOutputLimit) throws {
        while true {
            let symbol = try lit.decode(&br)
            if symbol < 256 {
                guard out.count < outputLimit else { throw Error.outputLimitExceeded(outputLimit) }
                out.append(UInt8(symbol))
            } else if symbol == 256 {
                return
            } else {
                let li = symbol - 257
                guard li < lengthBase.count else { throw Error.badHuffmanCode }
                let length = lengthBase[li] + Int(try br.bits(lengthExtra[li]))
                let dsymbol = try dist.decode(&br)
                guard dsymbol < distBase.count else { throw Error.badHuffmanCode }
                let distance = distBase[dsymbol] + Int(try br.bits(distExtra[dsymbol]))
                guard distance <= out.count else { throw Error.distanceTooFar(distance) }
                guard length <= outputLimit - out.count else { throw Error.outputLimitExceeded(outputLimit) }
                let from = out.count - distance
                for i in 0..<length {
                    out.append(out[from + i])
                }
            }
        }
    }
}

/// zlib (RFC 1950) wrapper used by legacy Tachiyomi backups: 2-byte header
/// (`78 xx`), raw DEFLATE body, adler32 trailer.
enum Zlib {
    enum Error: Swift.Error, CustomStringConvertible {
        case notZlib
        case presetDictionaryUnsupported
        case checksumMismatch

        var description: String {
            switch self {
            case .notZlib: return "stream has an invalid zlib header"
            case .presetDictionaryUnsupported: return "zlib preset dictionaries are not supported"
            case .checksumMismatch: return "zlib stream failed its Adler-32 check"
            }
        }
    }

    static func decompress(_ input: [UInt8], outputLimit: Int = Inflate.defaultOutputLimit) throws -> [UInt8] {
        guard input.count >= 6 else { throw Error.notZlib }
        let cmf = input[0]
        let flg = input[1]
        let header = UInt16(cmf) << 8 | UInt16(flg)
        guard cmf & 0x0f == 8, cmf >> 4 <= 7, header % 31 == 0 else { throw Error.notZlib }
        guard flg & 0x20 == 0 else { throw Error.presetDictionaryUnsupported }
        let body = Array(input[2..<(input.count - 4)])
        let decoded = try Inflate.decompress(body, outputLimit: outputLimit)
        let expected = UInt32(input[input.count - 4]) << 24
            | UInt32(input[input.count - 3]) << 16
            | UInt32(input[input.count - 2]) << 8
            | UInt32(input[input.count - 1])
        guard adler32(decoded) == expected else { throw Error.checksumMismatch }
        return decoded
    }

    private static func adler32(_ bytes: [UInt8]) -> UInt32 {
        let modulus: UInt32 = 65_521
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in bytes {
            a = (a + UInt32(byte)) % modulus
            b = (b + a) % modulus
        }
        return b << 16 | a
    }
}

/// gzip (RFC 1952) wrapper: 10-byte header (flags may include extra field,
/// name, comment), raw DEFLATE body, crc32 + isize trailer.
enum Gzip {
    enum Error: Swift.Error, CustomStringConvertible {
        case notGzip
        case checksumMismatch
        case sizeMismatch

        var description: String {
            switch self {
            case .notGzip: return "stream has an invalid gzip header"
            case .checksumMismatch: return "gzip stream failed its CRC-32 check"
            case .sizeMismatch: return "gzip stream failed its uncompressed-size check"
            }
        }
    }

    static func decompress(_ input: [UInt8], outputLimit: Int = Inflate.defaultOutputLimit) throws -> [UInt8] {
        guard input.count > 18, input[0] == 0x1f, input[1] == 0x8b,
              input[2] == 8 else { throw Error.notGzip }
        let flags = input[3]
        guard flags & 0xe0 == 0 else { throw Error.notGzip }
        let trailerStart = input.count - 8
        var start = 10
        if flags & 0x04 != 0 { // FEXTRA
            guard start <= trailerStart - 2 else { throw Error.notGzip }
            let xlen = Int(input[start]) | Int(input[start + 1]) << 8
            start += 2
            guard xlen <= trailerStart - start else { throw Error.notGzip }
            start += xlen
        }
        if flags & 0x08 != 0 { // FNAME: zero-terminated
            while start < trailerStart, input[start] != 0 { start += 1 }
            guard start < trailerStart else { throw Error.notGzip }
            start += 1
        }
        if flags & 0x10 != 0 { // FCOMMENT
            while start < trailerStart, input[start] != 0 { start += 1 }
            guard start < trailerStart else { throw Error.notGzip }
            start += 1
        }
        if flags & 0x02 != 0 { // FHCRC
            guard start <= trailerStart - 2 else { throw Error.notGzip }
            start += 2
        }
        guard start < trailerStart else { throw Error.notGzip }
        let body = Array(input[start..<trailerStart])
        let decoded = try Inflate.decompress(body, outputLimit: outputLimit)
        let expectedCRC = littleEndianUInt32(input, at: trailerStart)
        let expectedSize = littleEndianUInt32(input, at: trailerStart + 4)
        guard crc32(decoded) == expectedCRC else { throw Error.checksumMismatch }
        guard UInt32(truncatingIfNeeded: decoded.count) == expectedSize else { throw Error.sizeMismatch }
        return decoded
    }

    private static func littleEndianUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xedb8_8320)
            }
        }
        return ~crc
    }
}
