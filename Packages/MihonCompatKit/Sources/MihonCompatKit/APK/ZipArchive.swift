import Foundation

/// Minimal ZIP central-directory reader (PKZIP APPNOTE) covering what APKs
/// contain: STORE and DEFLATE entries, UTF-8 names, data descriptors skipped
/// by trusting the central directory sizes. ZIP64 is detected and reported
/// explicitly rather than misparsed.
public struct ZipArchive {
    struct Entry {
        let name: String
        let compressionMethod: UInt16
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let localHeaderOffset: UInt64
        let crc32: UInt32
    }

    enum Error: Swift.Error, CustomStringConvertible {
        case notAZip
        case zip64Unsupported(String)
        case unsupportedCompression(UInt16, entry: String)
        case entryMissing(String)

        var description: String {
            switch self {
            case .notAZip: return "end-of-central-directory record not found"
            case let .zip64Unsupported(what): return "ZIP64 \(what) is not supported yet"
            case let .unsupportedCompression(m, entry): return "entry '\(entry)' uses unsupported compression method \(m)"
            case let .entryMissing(name): return "no entry named '\(name)'"
            }
        }
    }

    let entries: [Entry]
    private let bytes: [UInt8]

    init(_ data: Data) throws {
        try self.init([UInt8](data))
    }

    init(_ bytes: [UInt8]) throws {
        self.bytes = bytes
        guard let eocd = ZipArchive.locateEOCD(bytes) else { throw Error.notAZip }
        var r = ByteReader(bytes)
        try r.seek(eocd + 4)
        _ = try r.u16()            // disk number
        _ = try r.u16()            // disk with CD
        var entryCount = Int(try r.u16())
        _ = try r.u16()            // total entries (duplicate)
        _ = try r.u32()            // CD size
        let cdOffset = Int(try r.u32())

        if cdOffset == 0xFFFFFFF || entryCount == 0xFFFF {
            // Look for the ZIP64 EOCD locator 20 bytes before the classic EOCD.
            guard let z64 = ZipArchive.locateZip64EOCD(bytes, before: eocd) else {
                throw Error.zip64Unsupported("end record")
            }
            try r.seek(z64 + 4)
            _ = try r.u64()        // size of zip64 EOCD
            _ = try r.u32()        // version made by
            _ = try r.u32()        // version needed
            _ = try r.u32()        // disk number
            _ = try r.u32()        // CD disk
            _ = try r.u64()        // entries on disk
            let total = try r.u64()
            let cdOff = try r.u64()
            entryCount = Int(total)
            try r.seek(Int(cdOff))
        } else {
            try r.seek(cdOffset)
        }

        var parsed: [Entry] = []
        parsed.reserveCapacity(entryCount)
        for _ in 0..<entryCount {
            let sig = try r.u32()
            guard sig == 0x02014b50 else { break }
            _ = try r.u16()        // version made by
            _ = try r.u16()        // version needed
            _ = try r.u16()        // flags
            let method = try r.u16()
            _ = try r.u16()        // mod time
            _ = try r.u16()        // mod date
            let crc = try r.u32()
            var compSize = UInt64(try r.u32())
            var uncompSize = UInt64(try r.u32())
            let nameLen = Int(try r.u16())
            let extraLen = Int(try r.u16())
            let commentLen = Int(try r.u16())
            _ = try r.u16()        // disk start
            _ = try r.u16()        // internal attrs
            _ = try r.u32()        // external attrs
            var headerOffset = UInt64(try r.u32())

            let nameStart = r.offset
            guard nameStart + nameLen <= bytes.count else { throw Error.notAZip }
            let nameData = Array(bytes[nameStart..<(nameStart + nameLen)])
            try r.skip(nameLen + extraLen + commentLen)
            let name = String(decoding: nameData, as: UTF8.self)

            // ZIP64 extra field (0x0001) can upgrade any of the 32-bit values.
            if compSize == 0xFFFFFFFF || uncompSize == 0xFFFFFFFF || headerOffset == 0xFFFFFFFF {
                var ex = r
                try ex.seek(nameStart + nameLen)
                var remaining = extraLen
                while remaining >= 4 {
                    let headerID = try ex.u16()
                    let size = Int(try ex.u16())
                    remaining -= 4 + size
                    guard headerID == 0x0001 else { try ex.skip(size); continue }
                    if uncompSize == 0xFFFFFFFF { uncompSize = try ex.u64() }
                    if compSize == 0xFFFFFFFF { compSize = try ex.u64() }
                    if headerOffset == 0xFFFFFFFF { headerOffset = try ex.u64() }
                }
            }

            parsed.append(Entry(
                name: name,
                compressionMethod: method,
                compressedSize: compSize,
                uncompressedSize: uncompSize,
                localHeaderOffset: headerOffset,
                crc32: crc
            ))
        }
        self.entries = parsed
    }

    private static func locateEOCD(_ bytes: [UInt8]) -> Int? {
        // EOCD is at most 22 bytes + 65535 bytes of comment.
        let searchStart = max(0, bytes.count - 65_557 - 22)
        var i = bytes.count - 22
        while i >= searchStart {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4b, bytes[i + 2] == 0x05, bytes[i + 3] == 0x06 {
                return i
            }
            i -= 1
        }
        return nil
    }

    private static func locateZip64EOCD(_ bytes: [UInt8], before eocd: Int) -> Int? {
        guard eocd >= 20 else { return nil }
        let i = eocd - 20
        guard bytes[i] == 0x50, bytes[i + 1] == 0x4b, bytes[i + 2] == 0x06, bytes[i + 3] == 0x07 else { return nil }
        var r = ByteReader(bytes)
        try? r.seek(i + 8)
        guard let z64Offset = try? r.u64() else { return nil }
        let z = Int(z64Offset)
        guard z + 4 <= bytes.count, bytes[z] == 0x50, bytes[z + 1] == 0x4b, bytes[z + 2] == 0x06, bytes[z + 3] == 0x07 else { return nil }
        return z
    }

    func entry(named name: String) -> Entry? {
        entries.first { $0.name == name }
    }

    /// Decompresses an entry to raw bytes.
    func data(for entry: Entry) throws -> [UInt8] {
        var r = ByteReader(bytes)
        try r.seek(Int(entry.localHeaderOffset))
        let sig = try r.u32()
        guard sig == 0x04034b50 else { throw Error.notAZip }
        try r.skip(22) // version..extra-len region minus name/extra lengths
        // Local header: sig(4) version(2) flags(2) method(2) time(2) date(2) crc(4)
        // comp(4) uncomp(4) nameLen(2) extraLen(2) = 30 bytes total.
        let nameLen = Int(try r.u16())
        let extraLen = Int(try r.u16())
        try r.skip(nameLen + extraLen)

        let start = r.offset
        let end = start + Int(entry.compressedSize)
        guard end <= bytes.count else { throw Error.notAZip }
        let payload = Array(bytes[start..<end])

        switch entry.compressionMethod {
        case 0:
            return payload
        case 8:
            return try Inflate.decompress(payload)
        default:
            throw Error.unsupportedCompression(entry.compressionMethod, entry: entry.name)
        }
    }

    func data(named name: String) throws -> [UInt8] {
        guard let e = entry(named: name) else { throw Error.entryMissing(name) }
        return try data(for: e)
    }
}
