import Foundation

/// Android binary XML (AXML) parser, sufficient for `AndroidManifest.xml`:
/// string pool + start/end element chunks + attribute values. Only what
/// extension manifests use — package name, uses-feature, meta-data — is
/// surfaced; unsupported chunk types are skipped per their declared size.
public struct BinaryXMLDocument {
    struct Attribute {
        let namespace: String?
        let name: String
        let rawValue: String?
        let typedValue: TypedValue
    }

    struct Element {
        let name: String
        let attributes: [Attribute]

        func attribute(_ name: String, namespace: String? = nil) -> Attribute? {
            // A nil namespace acts as a wildcard; extension manifests only ever
            // carry attributes in the android namespace (or none).
            attributes.first { $0.name == name && (namespace == nil || $0.namespace == namespace) }
        }
    }

    enum TypedValue {
        case string(String)
        case int(Int32)
        case float(Float)
        case boolean(Bool)

        var stringValue: String? {
            switch self {
            case let .string(s): return s
            case let .int(i): return String(i)
            case let .float(f): return String(f)
            case let .boolean(b): return b ? "true" : "false"
            }
        }

        var intValue: Int32? {
            switch self {
            case let .int(i): return i
            case let .float(f):
                let value = Double(f)
                guard value.isFinite,
                      value >= Double(Int32.min), value <= Double(Int32.max) else { return nil }
                return Int32(value)
            case let .boolean(b): return b ? 1 : 0
            default: return nil
            }
        }
    }

    enum Error: Swift.Error, CustomStringConvertible {
        case badMagic(UInt32)
        case truncated
        var description: String {
            switch self {
            case let .badMagic(m): return "not an Android binary XML file (magic 0x\(String(m, radix: 16)))"
            case .truncated: return "truncated binary XML chunk"
            }
        }
    }

    // Chunk types (android-base Res_internal.h).
    private static let chunkStringPool: UInt16 = 0x0001
    private static let chunkStartElement: UInt16 = 0x0102
    private static let chunkEndElement: UInt16 = 0x0103

    private static let typeString: UInt8 = 0x03
    private static let typeFloat: UInt8 = 0x04
    private static let typeIntDec: UInt8 = 0x10
    private static let typeIntBoolean: UInt8 = 0x12

    let root: Element?
    /// Every element encountered, in document order (flat walk).
    let allElements: [Element]
    let strings: [String]

    init(_ bytes: [UInt8]) throws {
        var r = ByteReader(bytes)
        // File header: type(u16)=0x0003 XML, headerSize(u16)=8, size(u32).
        let fileType = try r.u16()
        let fileHeaderSize = Int(try r.u16())
        let totalSize = Int(try r.u32())
        guard fileType == 0x0003 else { throw Error.badMagic(UInt32(fileType)) }
        guard fileHeaderSize >= 8, totalSize >= fileHeaderSize, totalSize <= bytes.count else {
            throw Error.truncated
        }
        try r.seek(fileHeaderSize)

        var stringTable: [String] = []
        var elements: [Element] = []
        var openStack: [String] = []

        while r.offset < totalSize {
            guard r.offset <= totalSize - 8 else { throw Error.truncated }
            let chunkType = try r.u16()
            let chunkHeaderSize = Int(try r.u16())
            let chunkSize = Int(try r.u32())
            let chunkStart = r.offset - 8
            guard chunkHeaderSize >= 8, chunkSize >= chunkHeaderSize,
                  chunkSize <= totalSize - chunkStart else { throw Error.truncated }
            let chunkEnd = chunkStart + chunkSize

            switch chunkType {
            case Self.chunkStringPool:
                stringTable = try Self.parseStringPool(&r, headerSize: chunkHeaderSize, chunkSize: chunkSize)

            case Self.chunkStartElement:
                // ResXMLTree_node has a fixed 16-byte header. The attribute
                // extension starts immediately after it, so accepting a larger
                // header here would make us interpret header padding as fields.
                guard chunkHeaderSize == 16, chunkSize >= 36 else { throw Error.truncated }
                try r.skip(8) // line number, comment
                let attributeExtensionStart = r.offset
                _ = try r.u32() // namespace ref (-1 when absent)
                let nameIdx = Int(try r.u32())
                let attributeStart = Int(try r.u16())
                let attributeSize = Int(try r.u16())
                let attrCount = Int(try r.u16())
                _ = try r.u16() // id index
                _ = try r.u16() // class index
                _ = try r.u16() // style index
                guard attributeSize >= 20,
                      attributeStart >= 20,
                      attributeExtensionStart + attributeStart <= chunkEnd,
                      attrCount <= (chunkEnd - attributeExtensionStart - attributeStart) / attributeSize else {
                    throw Error.truncated
                }
                try r.seek(attributeExtensionStart + attributeStart)

                var attrs: [Attribute] = []
                attrs.reserveCapacity(attrCount)
                for _ in 0..<attrCount {
                    let nsIdxRaw = try r.u32()
                    let attrNameIdx = Int(try r.u32())
                    let rawIdx = Int(try r.u32())
                    _ = try r.u16() // typed value size
                    _ = try r.u8()  // res0
                    let dataType = try r.u8()
                    let data = try r.u32()

                    let name = Self.string(at: attrNameIdx, in: stringTable) ?? "#\(attrNameIdx)"
                    let raw = Self.string(at: rawIdx, in: stringTable)
                    let ns = nsIdxRaw == 0xFFFF_FFFF ? nil : Self.string(at: Int(nsIdxRaw), in: stringTable)
                    attrs.append(Attribute(
                        namespace: ns,
                        name: name,
                        rawValue: raw,
                        typedValue: Self.typedValue(type: dataType, data: data, strings: stringTable)
                    ))
                    try r.skip(attributeSize - 20)
                }
                let elementName = Self.string(at: nameIdx, in: stringTable) ?? "unknown"
                guard elements.count < 100_000 else { throw Error.truncated }
                elements.append(Element(name: elementName, attributes: attrs))
                openStack.append(elementName)

            case Self.chunkEndElement:
                if !openStack.isEmpty { openStack.removeLast() }

            default:
                break // namespace chunks, CDATA, resource map — not needed
            }

            try r.seek(chunkEnd)
        }

        self.allElements = elements
        self.root = elements.first
        self.strings = stringTable
    }

    private static func string(at index: Int, in table: [String]) -> String? {
        guard index >= 0, index < table.count else { return nil }
        return table[index]
    }

    private static func typedValue(type: UInt8, data: UInt32, strings: [String]) -> TypedValue {
        switch type {
        case typeString:
            return .string(string(at: Int(data), in: strings) ?? "")
        case typeFloat:
            return .float(Float(bitPattern: data))
        case typeIntBoolean:
            return .boolean(data != 0)
        default:
            return .int(Int32(bitPattern: data))
        }
    }

    private static func parseStringPool(_ r: inout ByteReader, headerSize: Int, chunkSize: Int) throws -> [String] {
        let chunkStart = r.offset - 8
        let chunkEnd = chunkStart + chunkSize
        guard headerSize >= 28, headerSize <= chunkSize else { throw Error.truncated }
        let stringCount = Int(try r.u32())
        let styleCount = Int(try r.u32())
        let flags = try r.u32()
        let stringsStart = Int(try r.u32()) // relative to chunk start
        _ = try r.u32() // styles start
        let isUTF8 = flags & (1 << 8) != 0

        let offsetsBase = chunkStart + headerSize
        let dataBase = chunkStart + stringsStart
        guard stringCount <= 100_000,
              stringCount + styleCount <= (chunkSize - headerSize) / 4,
              dataBase >= offsetsBase, dataBase <= chunkEnd else { throw Error.truncated }

        var result: [String] = []
        result.reserveCapacity(stringCount)

        for i in 0..<stringCount {
            var or = r
            try or.seek(offsetsBase + i * 4)
            let offset = Int(try or.u32())
            guard offset <= chunkEnd - dataBase else { throw Error.truncated }
            var sr = r
            try sr.seek(dataBase + offset)

            if isUTF8 {
                _ = try Self.u8Length(&sr) // character count (may differ from byte count)
                let byteLen = try Self.u8Length(&sr)
                guard byteLen <= chunkEnd - sr.offset else { throw Error.truncated }
                var data: [UInt8] = []
                data.reserveCapacity(byteLen)
                for _ in 0..<byteLen { data.append(try sr.u8()) }
                result.append(String(decoding: data, as: UTF8.self))
            } else {
                let charCount = try Self.u16Length(&sr)
                guard charCount <= (chunkEnd - sr.offset) / 2 else { throw Error.truncated }
                var units: [UInt16] = []
                units.reserveCapacity(charCount)
                for _ in 0..<charCount { units.append(try sr.u16()) }
                result.append(String(decoding: units, as: UTF16.self))
            }
        }
        return result
    }

    /// UTF-8 pool length prefix: 1 or 2 bytes, high bit continuation.
    private static func u8Length(_ r: inout ByteReader) throws -> Int {
        let first = Int(try r.u8())
        if first & 0x80 == 0 { return first }
        let second = Int(try r.u8())
        return ((first & 0x7f) << 8) | second
    }

    /// UTF-16 pool length prefix: 1 or 2 u16s, high bit continuation.
    private static func u16Length(_ r: inout ByteReader) throws -> Int {
        let first = Int(try r.u16())
        if first & 0x8000 == 0 { return first }
        let second = Int(try r.u16())
        return ((first & 0x7fff) << 16) | second
    }
}

/// Extension-relevant metadata extracted from an APK manifest, using the
/// keys Mihon's ExtensionLoader reads (`tachiyomi.*` / `tachiyomix.*`).
public struct ExtensionManifest {
    public let packageName: String
    public let appName: String?
    public let sourceClass: String?
    public let sourceFactory: String?
    public let extensionLibVersion: String?
    public let contentWarning: Int?
    public let nsfwLegacy: Bool
    /// `tachiyomi.extension` uses-feature declared.
    public let declaresExtensionFeature: Bool

    init(apkBytes: [UInt8]) throws {
        let zip = try ZipArchive(apkBytes)
        let manifestBytes = try zip.data(named: "AndroidManifest.xml")
        let doc = try BinaryXMLDocument(manifestBytes)

        guard let root = doc.root, root.name == "manifest",
              let pkg = root.attribute("package")?.typedValue.stringValue else {
            throw BinaryXMLDocument.Error.truncated
        }
        packageName = pkg

        var class_: String?
        var factory: String?
        var libVersion: String?
        var warning: Int?
        var tachiName: String?
        var nsfw = false
        var feature = false

        for element in doc.allElements {
            if element.name == "uses-feature",
               element.attribute("name")?.typedValue.stringValue == "tachiyomi.extension" {
                feature = true
            }
            guard element.name == "meta-data" else { continue }
            let key = element.attribute("name")?.typedValue.stringValue
            let value = element.attribute("value")?.typedValue
            switch key {
            case "tachiyomi.extension.class": class_ = value?.stringValue
            case "tachiyomi.extension.factory": factory = value?.stringValue
            case "tachiyomix.name": tachiName = value?.stringValue
            case "tachiyomix.extensionLib": libVersion = value?.stringValue
            case "tachiyomix.contentWarning": warning = value?.intValue.map(Int.init)
            case "tachiyomi.extension.nsfw": nsfw = (value?.intValue ?? 0) != 0
            default: break
            }
        }

        appName = tachiName
        sourceClass = class_
        sourceFactory = factory
        extensionLibVersion = libVersion
        contentWarning = warning
        nsfwLegacy = nsfw
        declaresExtensionFeature = feature
    }

    /// Resolves a possibly-relative class reference (".MySource") against the
    /// APK package name, matching Mihon's ExtensionLoader behavior.
    public func resolvedClassName(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw.hasPrefix(".") { return packageName + raw }
        if raw.contains(".") { return raw }
        return packageName + "." + raw
    }

    public var resolvedSourceClass: String? { resolvedClassName(sourceClass) }
    public var resolvedSourceFactory: String? { resolvedClassName(sourceFactory) }
}
