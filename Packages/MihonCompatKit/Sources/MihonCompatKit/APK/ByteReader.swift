import Foundation

/// Little-endian cursor over a byte array. Foundation-only; no platform
/// dependencies so the whole kit stays testable on any Swift host.
struct ByteReader {
    let bytes: [UInt8]
    private(set) var offset: Int

    init(_ bytes: [UInt8]) { self.bytes = bytes; self.offset = 0 }
    init(_ data: Data) { self.bytes = [UInt8](data); self.offset = 0 }

    var remaining: Int { bytes.count - offset }
    var isAtEnd: Bool { offset >= bytes.count }

    enum Error: Swift.Error, CustomStringConvertible {
        case outOfBounds(needed: Int, at: Int)
        case badULEB128(at: Int)
        case badSLEB128(at: Int)

        var description: String {
            switch self {
            case let .outOfBounds(needed, at): return "read of \(needed) bytes at offset \(at) exceeds buffer"
            case let .badULEB128(at): return "malformed ULEB128 at offset \(at)"
            case let .badSLEB128(at): return "malformed SLEB128 at offset \(at)"
            }
        }
    }

    mutating func seek(_ to: Int) throws {
        guard to >= 0, to <= bytes.count else { throw Error.outOfBounds(needed: 0, at: to) }
        offset = to
    }

    mutating func skip(_ n: Int) throws {
        guard n >= 0, n <= remaining else { throw Error.outOfBounds(needed: max(0, n), at: offset) }
        offset += n
    }

    mutating func u8() throws -> UInt8 {
        guard offset < bytes.count else { throw Error.outOfBounds(needed: 1, at: offset) }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func u16() throws -> UInt16 {
        guard remaining >= 2 else { throw Error.outOfBounds(needed: 2, at: offset) }
        defer { offset += 2 }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    mutating func u32() throws -> UInt32 {
        guard remaining >= 4 else { throw Error.outOfBounds(needed: 4, at: offset) }
        defer { offset += 4 }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    mutating func u64() throws -> UInt64 {
        let lo = try u32()
        let hi = try u32()
        return UInt64(hi) << 32 | UInt64(lo)
    }

    /// Unsigned LEB128, used throughout the DEX format.
    mutating func uleb128() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        let start = offset
        for byteIndex in 0..<10 {
            guard offset < bytes.count else { throw Error.outOfBounds(needed: 1, at: offset) }
            let b = bytes[offset]
            offset += 1
            if byteIndex == 9, b & 0x7e != 0 { throw Error.badULEB128(at: start) }
            result |= UInt64(b & 0x7f) << shift
            if b & 0x80 == 0 { return result }
            shift += 7
        }
        throw Error.badULEB128(at: start)
    }

    /// Signed LEB128 (DEX uses it for access flags diffs etc.).
    mutating func sleb128() throws -> Int64 {
        var result: UInt64 = 0
        var shift = 0
        let start = offset
        for byteIndex in 0..<10 {
            guard offset < bytes.count else { throw Error.outOfBounds(needed: 1, at: offset) }
            let b = bytes[offset]
            offset += 1
            if byteIndex == 9, b & 0x7e != 0, b & 0x7e != 0x7e {
                throw Error.badSLEB128(at: start)
            }
            result |= UInt64(b & 0x7f) << UInt64(shift)
            shift += 7
            if b & 0x80 == 0 {
                if shift < 64, b & 0x40 != 0 { result |= UInt64.max << UInt64(shift) }
                return Int64(bitPattern: result)
            }
        }
        throw Error.badSLEB128(at: start)
    }

    func bytes(at range: Range<Int>) throws -> ArraySlice<UInt8> {
        guard range.lowerBound >= 0, range.upperBound <= bytes.count else {
            throw Error.outOfBounds(needed: range.count, at: range.lowerBound)
        }
        return bytes[range]
    }

    /// Reads a fixed-size unsigned little-endian integer at an absolute offset
    /// without moving the cursor (used for DEX table lookups).
    func u32(at absolute: Int) throws -> UInt32 {
        var r = self
        try r.seek(absolute)
        return try r.u32()
    }
}
