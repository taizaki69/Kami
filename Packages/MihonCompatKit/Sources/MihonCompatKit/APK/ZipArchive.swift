import Foundation

/// Minimal ZIP central-directory reader (PKZIP APPNOTE) covering what APKs
/// contain: STORE and DEFLATE entries, UTF-8 names, data descriptors skipped
/// by trusting the central directory sizes. Single-disk ZIP64 metadata is
/// supported; multi-disk archives are rejected explicitly.
public struct ZipArchive {

    public struct Entry {
        public let name: String
        public let compressionMethod: UInt16
        public let compressedSize: UInt64
        public let uncompressedSize: UInt64
        public let localHeaderOffset: UInt64
        public let crc32: UInt32
    }

    enum Error: Swift.Error, CustomStringConvertible {
        case notAZip
        case zip64Unsupported(String)
        case unsupportedCompression(UInt16, entry: String)
        case entryMissing(String)
        case encryptedEntry(String)
        case entryTooLarge(String, UInt64)
        case sizeMismatch(String, expected: UInt64, actual: Int)
        case checksumMismatch(String)

        var description: String {
            switch self {
            case .notAZip: return "end-of-central-directory record not found"
            case let .zip64Unsupported(what): return "ZIP64 \(what) is not supported yet"
            case let .unsupportedCompression(m, entry): return "entry '\(entry)' uses unsupported compression method \(m)"
            case let .entryMissing(name): return "no entry named '\(name)'"
            case let .encryptedEntry(name): return "entry '\(name)' is encrypted"
            case let .entryTooLarge(name, size): return "entry '\(name)' is too large (\(size) bytes)"
            case let .sizeMismatch(name, expected, actual): return "entry '\(name)' expected \(expected) bytes, decoded \(actual)"
            case let .checksumMismatch(name): return "entry '\(name)' failed its CRC-32 check"
            }
        }
    }

    private static let maxEntrySize: UInt64 = 128 * 1024 * 1024
    private static let maxEntryCount = 100_000

    let entries: [Entry]
    private let bytes: [UInt8]

    init(_ data: Data) throws {
        try self.init([UInt8](data))
    }

    public init(_ bytes: [UInt8]) throws {
        self.bytes = bytes
        guard let eocd = ZipArchive.locateEOCD(bytes) else { throw Error.notAZip }
        var r = ByteReader(bytes)
        try r.seek(eocd + 4)
        let diskNumber = try r.u16()
        let directoryDisk = try r.u16()
        let entriesOnDisk = try r.u16()
        let totalEntries16 = try r.u16()
        let directorySize32 = try r.u32()
        let directoryOffset32 = try r.u32()
        guard diskNumber == 0, directoryDisk == 0, entriesOnDisk == totalEntries16 else {
            throw Error.zip64Unsupported("multi-disk archives")
        }

        var entryCount: Int
        var directorySize: Int
        var directoryOffset: Int
        if directoryOffset32 == 0xFFFF_FFFF || directorySize32 == 0xFFFF_FFFF || totalEntries16 == 0xFFFF {
            // Look for the ZIP64 EOCD locator 20 bytes before the classic EOCD.
            guard let z64 = ZipArchive.locateZip64EOCD(bytes, before: eocd) else {
                throw Error.zip64Unsupported("end record")
            }
            try r.seek(z64 + 4)
            let recordSize = try r.u64()
            guard z64 <= bytes.count - 12,
                  recordSize >= 44,
                  recordSize <= UInt64(bytes.count - z64 - 12) else { throw Error.notAZip }
            _ = try r.u16()        // version made by
            _ = try r.u16()        // version needed
            let z64Disk = try r.u32()
            let z64DirectoryDisk = try r.u32()
            let z64EntriesOnDisk = try r.u64()
            let total = try r.u64()
            let cdSize = try r.u64()
            let cdOff = try r.u64()
            guard z64Disk == 0, z64DirectoryDisk == 0, z64EntriesOnDisk == total else {
                throw Error.zip64Unsupported("multi-disk archives")
            }
            entryCount = try Self.integer(total)
            directorySize = try Self.integer(cdSize)
            directoryOffset = try Self.integer(cdOff)
        } else {
            entryCount = Int(totalEntries16)
            directorySize = Int(directorySize32)
            directoryOffset = Int(directoryOffset32)
        }
        guard entryCount <= Self.maxEntryCount,
              directoryOffset >= 0, directoryOffset <= bytes.count,
              directorySize >= 0, directorySize <= bytes.count - directoryOffset,
              entryCount == 0 || entryCount <= directorySize / 46 else { throw Error.notAZip }
        let directoryEnd = directoryOffset + directorySize
        try r.seek(directoryOffset)

        var parsed: [Entry] = []
        parsed.reserveCapacity(entryCount)
        for _ in 0..<entryCount {
            guard r.offset <= directoryEnd - 46 else { throw Error.notAZip }
            let sig = try r.u32()
            guard sig == 0x02014b50 else { throw Error.notAZip }
            _ = try r.u16()        // version made by
            _ = try r.u16()        // version needed
            let flags = try r.u16()
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
            let variableLength = nameLen + extraLen + commentLen
            guard variableLength <= directoryEnd - nameStart else { throw Error.notAZip }
            let nameData = Array(bytes[nameStart..<(nameStart + nameLen)])
            let extraStart = nameStart + nameLen
            try r.skip(variableLength)
            let name = String(decoding: nameData, as: UTF8.self)
            guard flags & 0x0001 == 0 else { throw Error.encryptedEntry(name) }

            // ZIP64 extra field (0x0001) can upgrade any of the 32-bit values.
            if compSize == 0xFFFFFFFF || uncompSize == 0xFFFFFFFF || headerOffset == 0xFFFFFFFF {
                var ex = r
                try ex.seek(extraStart)
                let extraEnd = extraStart + extraLen
                while ex.offset <= extraEnd - 4 {
                    let headerID = try ex.u16()
                    let size = Int(try ex.u16())
                    guard size <= extraEnd - ex.offset else { throw Error.notAZip }
                    let fieldEnd = ex.offset + size
                    if headerID == 0x0001 {
                        if uncompSize == 0xFFFFFFFF {
                            guard ex.offset <= fieldEnd - 8 else { throw Error.notAZip }
                            uncompSize = try ex.u64()
                        }
                        if compSize == 0xFFFFFFFF {
                            guard ex.offset <= fieldEnd - 8 else { throw Error.notAZip }
                            compSize = try ex.u64()
                        }
                        if headerOffset == 0xFFFFFFFF {
                            guard ex.offset <= fieldEnd - 8 else { throw Error.notAZip }
                            headerOffset = try ex.u64()
                        }
                    }
                    try ex.seek(fieldEnd)
                }
                guard compSize != 0xFFFFFFFF, uncompSize != 0xFFFFFFFF, headerOffset != 0xFFFFFFFF else {
                    throw Error.notAZip
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
        guard bytes.count >= 22 else { return nil }
        let searchStart = max(0, bytes.count - 65_557 - 22)
        var i = bytes.count - 22
        while i >= searchStart {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4b, bytes[i + 2] == 0x05, bytes[i + 3] == 0x06 {
                let commentLength = Int(bytes[i + 20]) | Int(bytes[i + 21]) << 8
                if i + 22 + commentLength == bytes.count { return i }
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
        guard z64Offset <= UInt64(bytes.count - 4) else { return nil }
        let z = Int(z64Offset)
        guard bytes[z] == 0x50, bytes[z + 1] == 0x4b,
              bytes[z + 2] == 0x06, bytes[z + 3] == 0x06 else { return nil }
        return z
    }

    private static func integer(_ value: UInt64) throws -> Int {
        guard value <= UInt64(Int.max) else { throw Error.notAZip }
        return Int(value)
    }

    func entry(named name: String) -> Entry? {
        entries.first { $0.name == name }
    }

    /// Decompresses an entry to raw bytes.
    public func data(for entry: Entry) throws -> [UInt8] {
        guard entry.compressedSize <= Self.maxEntrySize,
              entry.uncompressedSize <= Self.maxEntrySize else {
            throw Error.entryTooLarge(entry.name, max(entry.compressedSize, entry.uncompressedSize))
        }
        var r = ByteReader(bytes)
        try r.seek(try Self.integer(entry.localHeaderOffset))
        let sig = try r.u32()
        guard sig == 0x04034b50 else { throw Error.notAZip }
        _ = try r.u16() // version needed
        let flags = try r.u16()
        let localMethod = try r.u16()
        try r.skip(16) // time, date, crc, compressed size, uncompressed size
        // Local header: sig(4) version(2) flags(2) method(2) time(2) date(2) crc(4)
        // comp(4) uncomp(4) nameLen(2) extraLen(2) = 30 bytes total.
        let nameLen = Int(try r.u16())
        let extraLen = Int(try r.u16())
        guard flags & 0x0001 == 0 else { throw Error.encryptedEntry(entry.name) }
        guard localMethod == entry.compressionMethod,
              nameLen + extraLen <= r.remaining else { throw Error.notAZip }
        try r.skip(nameLen + extraLen)

        let start = r.offset
        let compressedSize = try Self.integer(entry.compressedSize)
        guard compressedSize <= bytes.count - start else { throw Error.notAZip }
        let end = start + compressedSize
        let payload = Array(bytes[start..<end])

        let decoded: [UInt8]
        switch entry.compressionMethod {
        case 0:
            decoded = payload
        case 8:
            decoded = try Inflate.decompress(payload, outputLimit: try Self.integer(entry.uncompressedSize))
        default:
            throw Error.unsupportedCompression(entry.compressionMethod, entry: entry.name)
        }
        guard UInt64(decoded.count) == entry.uncompressedSize else {
            throw Error.sizeMismatch(entry.name, expected: entry.uncompressedSize, actual: decoded.count)
        }
        guard Self.crc32(decoded) == entry.crc32 else { throw Error.checksumMismatch(entry.name) }
        return decoded
    }

    public func data(named name: String) throws -> [UInt8] {
        guard let e = entry(named: name) else { throw Error.entryMissing(name) }
        return try data(for: e)
    }

    private static func crc32(_ data: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xEDB8_8320)
            }
        }
        return ~crc
    }
}
