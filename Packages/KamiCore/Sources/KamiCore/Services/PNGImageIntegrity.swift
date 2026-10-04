import Foundation

/// ImageIO may salvage pixels from a truncated PNG and still report a complete
/// source. Check the PNG envelope before asking it to decode. This is not a
/// replacement decoder: other formats and PNG pixel semantics still use ImageIO.
/// Chunk layout, ordering and CRC follow https://www.w3.org/TR/png-3/.
enum PNGImageIntegrity {
    static func validateIfPNG(_ data: Data) throws {
        try Task.checkCancellation()
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            let signature: [UInt8] = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
            guard bytes.count >= signature.count,
                  signature.indices.allSatisfy({ bytes[$0] == signature[$0] }) else { return }

            var offset = 8
            var sawPalette = false
            var sawData = false
            var endedData = false
            var requiresPalette = false
            while offset < bytes.count {
                try Task.checkCancellation()
                guard bytes.count - offset >= 12 else { throw DownloadImageValidationError.invalidImage }
                let length = bigEndianUInt32(bytes, offset)
                guard length <= 0x7fff_ffff,
                      Int(length) <= bytes.count - offset - 12 else {
                    throw DownloadImageValidationError.invalidImage
                }
                let end = offset + 12 + Int(length)
                let type = bigEndianUInt32(bytes, offset + 4)
                guard (offset + 4..<offset + 8).allSatisfy({
                    (65...90).contains(bytes[$0]) || (97...122).contains(bytes[$0])
                }), bytes[offset + 6] & 0x20 == 0,
                      try crc32(bytes, offset + 4..<end - 4) == bigEndianUInt32(bytes, end - 4) else {
                    throw DownloadImageValidationError.invalidImage
                }
                if offset == 8 {
                    guard type == 0x4948_4452, length == 13 else {
                        throw DownloadImageValidationError.invalidImage
                    }
                    requiresPalette = bytes[offset + 17] == 3
                } else if type == 0x4948_4452 {
                    throw DownloadImageValidationError.invalidImage
                }

                switch type {
                case 0x4948_4452: break // IHDR, already checked above
                case 0x504c_5445: // PLTE
                    guard !sawPalette, !sawData, (3...768).contains(length), length % 3 == 0 else {
                        throw DownloadImageValidationError.invalidImage
                    }
                    sawPalette = true
                case 0x4944_4154: // IDAT
                    guard !endedData, !requiresPalette || sawPalette else {
                        throw DownloadImageValidationError.invalidImage
                    }
                    sawData = true
                case 0x4945_4e44: // IEND must terminate the actual bytes, not appear inside a chunk
                    guard length == 0, sawData, end == bytes.count else {
                        throw DownloadImageValidationError.invalidImage
                    }
                    return
                default:
                    // An unknown critical chunk cannot be interpreted safely.
                    guard type & 0x2000_0000 != 0 else { throw DownloadImageValidationError.invalidImage }
                    if sawData { endedData = true }
                }
                offset = end
            }
            throw DownloadImageValidationError.invalidImage // Missing IEND
        }
    }

    private static func bigEndianUInt32(_ bytes: UnsafeRawBufferPointer, _ offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
    }

    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xedb8_8320) }
        return crc
    }

    private static func crc32(_ bytes: UnsafeRawBufferPointer, _ range: Range<Int>) throws -> UInt32 {
        var crc = UInt32.max
        for index in range {
            if index & 0xffff == 0 { try Task.checkCancellation() }
            crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(bytes[index])) & 0xff)]
        }
        return crc ^ UInt32.max
    }
}
