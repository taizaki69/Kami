import Foundation

/// DEX (Dalvik Executable, formats 035 and 037–040) parser.
///
/// Parses the full structural tables — strings, types, protos, fields, methods,
/// class definitions with encoded fields/methods and code items — and exposes
/// them for analysis and interpretation. Version 041 uses a different
/// container/header contract and is intentionally rejected; minSdk-specific
/// instructions inside `insns` are validated by the interpreter as reached.
public struct DexFile {
    public struct MethodRef {
        public let declaringClass: String   // type descriptor, e.g. "Lokhttp3/Request;"
        public let name: String
        public let prototype: Prototype

        /// Canonical DEX method signature, e.g. `append(Ljava/lang/String;)Ljava/lang/StringBuilder;`.
        public var signature: String { name + prototype.descriptor }
    }

    public struct FieldRef {
        public let declaringClass: String
        public let type: String
        public let name: String
    }

    public struct Prototype {
        public let shorty: String
        public let returnType: String
        public let parameters: [String]

        /// JVM/DEX descriptor form used as the overload identity.
        public var descriptor: String { "(" + parameters.joined() + ")" + returnType }

        /// Number of Dalvik register words occupied by the declared parameters.
        public var parameterWordCount: Int {
            parameters.reduce(0) { $0 + (($1 == "J" || $1 == "D") ? 2 : 1) }
        }
    }

    public struct EncodedMethod {
        public let methodIndex: Int
        public let accessFlags: UInt32
        public let codeOffset: Int
        public let definingClassIndex: Int
    }

    public struct EncodedField {
        public let fieldIndex: Int
        public let accessFlags: UInt32
    }

    public struct CodeItem {
        public let registersSize: UInt16
        public let insSize: UInt16
        public let outsSize: UInt16
        public let triesCount: UInt16
        public let insnsOffset: Int
        public let insnsCount: Int
    }

    public struct ClassDef {
        public let typeIndex: Int
        public let descriptor: String
        public let accessFlags: UInt32
        public let superclassIndex: Int   // -1 when absent
        public let interfaceIndices: [Int]
        public let sourceFileIndex: Int
        public let staticFields: [EncodedField]
        public let instanceFields: [EncodedField]
        public let directMethods: [EncodedMethod]
        public let virtualMethods: [EncodedMethod]
        public let classDataOffset: Int
    }

    enum Error: Swift.Error, CustomStringConvertible {
        case badMagic(String)
        case badEndianTag(UInt32)
        case checksumMismatch
        case truncated(String)

        var description: String {
            switch self {
            case let .badMagic(m): return "not a DEX file (magic \(m.debugDescription))"
            case let .badEndianTag(t): return "unexpected endian tag 0x\(String(t, radix: 16)) (only little-endian DEX supported)"
            case .checksumMismatch: return "DEX failed its Adler-32 checksum"
            case let .truncated(what): return "truncated DEX while reading \(what)"
            }
        }
    }

    public let strings: [String]
    public let typeDescriptors: [String]
    public let prototypes: [Prototype]
    public let fieldIds: [FieldRef]
    public let methodIds: [MethodRef]
    public let classDefs: [ClassDef]
    /// Numeric DEX format version from the magic (`035`, `037`...`040`).
    public let version: Int

    /// descriptor ("La/b/C;") → class def index.
    public let classIndexByDescriptor: [String: Int]

    /// Raw backing bytes, kept for code item parsing and the future interpreter.
    public let source: [UInt8]

    public init(_ bytes: [UInt8]) throws {
        self.source = bytes
        var r = ByteReader(bytes)

        // magic: "dex\n" + 3 version digits + '\0'
        guard bytes.count >= 112 else { throw Error.truncated("header") }
        let magic = String(decoding: bytes[0..<8], as: UTF8.self)
        let supportedMagics = [35, 37, 38, 39, 40].map { String(format: "dex\n%03d\0", $0) }
        guard supportedMagics.contains(magic) else {
            throw Error.badMagic(magic)
        }
        guard let version = Int(magic.dropFirst(4).prefix(3)) else {
            throw Error.badMagic(magic)
        }
        self.version = version
        try r.seek(8)
        let declaredChecksum = try r.u32()
        _ = try r.skip(20) // sha1 signature
        let declaredFileSize = Int(try r.u32())
        let headerSize = Int(try r.u32())
        guard declaredFileSize == bytes.count, headerSize == 112 else { throw Error.truncated("header") }
        guard Self.adler32(bytes, from: 12) == declaredChecksum else { throw Error.checksumMismatch }
        let endian = try r.u32()
        guard endian == 0x12345678 else { throw Error.badEndianTag(endian) }
        _ = try r.u32() // link size
        _ = try r.u32() // link off
        _ = try r.u32() // map off

        let stringIdsSize = Int(try r.u32())
        let stringIdsOff = Int(try r.u32())
        let typeIdsSize = Int(try r.u32())
        let typeIdsOff = Int(try r.u32())
        let protoIdsSize = Int(try r.u32())
        let protoIdsOff = Int(try r.u32())
        let fieldIdsSize = Int(try r.u32())
        let fieldIdsOff = Int(try r.u32())
        let methodIdsSize = Int(try r.u32())
        let methodIdsOff = Int(try r.u32())
        let classDefsSize = Int(try r.u32())
        let classDefsOff = Int(try r.u32())
        let dataSize = Int(try r.u32())
        let dataOff = Int(try r.u32())

        func tableFits(size: Int, offset: Int, width: Int) -> Bool {
            if size == 0 { return offset == 0 }
            guard offset >= headerSize, offset <= bytes.count else { return false }
            let (tableBytes, overflow) = size.multipliedReportingOverflow(by: width)
            return !overflow && tableBytes <= bytes.count - offset
        }
        guard tableFits(size: stringIdsSize, offset: stringIdsOff, width: 4),
              tableFits(size: typeIdsSize, offset: typeIdsOff, width: 4),
              tableFits(size: protoIdsSize, offset: protoIdsOff, width: 12),
              tableFits(size: fieldIdsSize, offset: fieldIdsOff, width: 8),
              tableFits(size: methodIdsSize, offset: methodIdsOff, width: 8),
              tableFits(size: classDefsSize, offset: classDefsOff, width: 32),
              (dataSize == 0 && dataOff == 0) ||
                (dataOff >= headerSize && dataOff <= bytes.count && dataSize <= bytes.count - dataOff) else {
            throw Error.truncated("header tables")
        }

        // --- string_ids → MUTF-8 data
        var strings: [String] = []
        strings.reserveCapacity(stringIdsSize)
        for i in 0..<stringIdsSize {
            let dataOff = Int(try r.u32(at: stringIdsOff + i * 4))
            guard dataOff >= 0, dataOff < bytes.count else { throw Error.truncated("string data") }
            var sr = r
            try sr.seek(dataOff)
            _ = try sr.uleb128()      // utf16 code unit count
            var utf8: [UInt8] = []
            while true {
                let b = try sr.u8()
                if b == 0 { break }
                guard utf8.count < 16 * 1024 * 1024 else { throw Error.truncated("string data") }
                utf8.append(b)
            }
            strings.append(Self.decodeMUTF8(utf8))
        }
        self.strings = strings

        // --- type_ids
        var types: [String] = []
        types.reserveCapacity(typeIdsSize)
        for i in 0..<typeIdsSize {
            let descriptorIdx = Int(try r.u32(at: typeIdsOff + i * 4))
            guard descriptorIdx >= 0, descriptorIdx < strings.count else { throw Error.truncated("type descriptor") }
            types.append(strings[descriptorIdx])
        }
        self.typeDescriptors = types

        // --- proto_ids: shorty_idx, return_type_idx, parameters_off
        var protos: [Prototype] = []
        protos.reserveCapacity(protoIdsSize)
        for i in 0..<protoIdsSize {
            let base = protoIdsOff + i * 12
            let shortyIdx = Int(try r.u32(at: base))
            let returnIdx = Int(try r.u32(at: base + 4))
            let paramsOff = Int(try r.u32(at: base + 8))
            guard shortyIdx >= 0, shortyIdx < strings.count,
                  returnIdx >= 0, returnIdx < types.count else { throw Error.truncated("prototype") }
            var params: [String] = []
            if paramsOff != 0 {
                var pr = r
                try pr.seek(paramsOff)
                let count = Int(try pr.u32())
                guard count <= pr.remaining / 2 else { throw Error.truncated("prototype parameters") }
                params.reserveCapacity(count)
                for _ in 0..<count {
                    let idx = Int(try pr.u16())
                    guard idx >= 0, idx < types.count else { throw Error.truncated("prototype parameter type") }
                    params.append(types[idx])
                }
            }
            protos.append(Prototype(shorty: strings[shortyIdx], returnType: types[returnIdx], parameters: params))
        }
        self.prototypes = protos

        // --- field_ids: class_idx u16, type_idx u16, name_idx u32
        var fields: [FieldRef] = []
        fields.reserveCapacity(fieldIdsSize)
        for i in 0..<fieldIdsSize {
            let base = fieldIdsOff + i * 8
            var fr = r
            try fr.seek(base)
            let classIdx = Int(try fr.u16())
            let typeIdx = Int(try fr.u16())
            let nameIdx = Int(try fr.u32())
            guard classIdx < types.count, typeIdx < types.count, nameIdx < strings.count else {
                throw Error.truncated("field id")
            }
            fields.append(FieldRef(declaringClass: types[classIdx], type: types[typeIdx], name: strings[nameIdx]))
        }
        self.fieldIds = fields

        // --- method_ids: class_idx u16, proto_idx u16, name_idx u32
        var methods: [MethodRef] = []
        methods.reserveCapacity(methodIdsSize)
        for i in 0..<methodIdsSize {
            let base = methodIdsOff + i * 8
            var mr = r
            try mr.seek(base)
            let classIdx = Int(try mr.u16())
            let protoIdx = Int(try mr.u16())
            let nameIdx = Int(try mr.u32())
            guard classIdx < types.count, protoIdx < protos.count, nameIdx < strings.count else {
                throw Error.truncated("method id")
            }
            methods.append(MethodRef(declaringClass: types[classIdx], name: strings[nameIdx], prototype: protos[protoIdx]))
        }
        self.methodIds = methods

        // --- class_defs (32 bytes each) + class_data
        var defs: [ClassDef] = []
        defs.reserveCapacity(classDefsSize)
        var byDescriptor: [String: Int] = [:]
        for i in 0..<classDefsSize {
            let base = classDefsOff + i * 32
            let classIdx = Int(try r.u32(at: base))
            let access = try r.u32(at: base + 4)
            let superIdxRaw = try r.u32(at: base + 8)
            let interfacesOff = Int(try r.u32(at: base + 12))
            let sourceIdxRaw = try r.u32(at: base + 16)
            _ = try r.u32(at: base + 20) // annotations off
            let classDataOff = Int(try r.u32(at: base + 24))
            _ = try r.u32(at: base + 28) // static values off
            guard classIdx >= 0, classIdx < types.count,
                  superIdxRaw == 0xFFFF_FFFF || Int(superIdxRaw) < types.count,
                  sourceIdxRaw == 0xFFFF_FFFF || Int(sourceIdxRaw) < strings.count else {
                throw Error.truncated("class definition")
            }

            var interfaces: [Int] = []
            if interfacesOff != 0 {
                var ir = r
                try ir.seek(interfacesOff)
                let count = Int(try ir.u32())
                guard count <= ir.remaining / 2 else { throw Error.truncated("interface list") }
                interfaces.reserveCapacity(count)
                for _ in 0..<count {
                    let interface = Int(try ir.u16())
                    guard interface < types.count else { throw Error.truncated("interface type") }
                    interfaces.append(interface)
                }
            }

            var staticFields: [EncodedField] = []
            var instanceFields: [EncodedField] = []
            var directMethods: [EncodedMethod] = []
            var virtualMethods: [EncodedMethod] = []

            if classDataOff != 0 {
                var cr = r
                try cr.seek(classDataOff)
                let staticCount = try Self.integer(try cr.uleb128(), "static field count")
                let instanceCount = try Self.integer(try cr.uleb128(), "instance field count")
                let directCount = try Self.integer(try cr.uleb128(), "direct method count")
                let virtualCount = try Self.integer(try cr.uleb128(), "virtual method count")
                guard staticCount <= fieldIdsSize,
                      instanceCount <= fieldIdsSize - staticCount,
                      directCount <= methodIdsSize,
                      virtualCount <= methodIdsSize - directCount else {
                    throw Error.truncated("class data counts")
                }

                staticFields = try Self.readFields(&cr, count: staticCount, maximumIndex: fieldIdsSize)
                instanceFields = try Self.readFields(&cr, count: instanceCount, maximumIndex: fieldIdsSize)
                directMethods = try Self.readMethods(&cr, count: directCount, classIndex: classIdx, maximumIndex: methodIdsSize)
                virtualMethods = try Self.readMethods(&cr, count: virtualCount, classIndex: classIdx, maximumIndex: methodIdsSize)
            }

            let descriptor = types[classIdx]
            guard (staticFields + instanceFields).allSatisfy({ fields[$0.fieldIndex].declaringClass == descriptor }) else {
                throw Error.truncated("encoded field declaring class")
            }
            guard (directMethods + virtualMethods).allSatisfy({ methods[$0.methodIndex].declaringClass == descriptor }) else {
                throw Error.truncated("encoded method declaring class")
            }

            let def = ClassDef(
                typeIndex: classIdx,
                descriptor: descriptor,
                accessFlags: access,
                superclassIndex: superIdxRaw == 0xFFFF_FFFF ? -1 : Int(superIdxRaw),
                interfaceIndices: interfaces,
                sourceFileIndex: sourceIdxRaw == 0xFFFF_FFFF ? -1 : Int(sourceIdxRaw),
                staticFields: staticFields,
                instanceFields: instanceFields,
                directMethods: directMethods,
                virtualMethods: virtualMethods,
                classDataOffset: classDataOff
            )
            byDescriptor[def.descriptor] = i
            defs.append(def)
        }
        self.classDefs = defs
        self.classIndexByDescriptor = byDescriptor
    }

    private static func readFields(_ cr: inout ByteReader, count: Int, maximumIndex: Int) throws -> [EncodedField] {
        var result: [EncodedField] = []
        result.reserveCapacity(count)
        var idx: UInt64 = 0
        for _ in 0..<count {
            let (nextIndex, overflow) = idx.addingReportingOverflow(try cr.uleb128())
            guard !overflow, nextIndex < UInt64(maximumIndex) else { throw Error.truncated("encoded field index") }
            idx = nextIndex
            let flagsRaw = try cr.uleb128()
            guard flagsRaw <= UInt64(UInt32.max) else { throw Error.truncated("field access flags") }
            result.append(EncodedField(fieldIndex: Int(idx), accessFlags: UInt32(flagsRaw)))
        }
        return result
    }

    private static func readMethods(_ cr: inout ByteReader, count: Int, classIndex: Int,
                                    maximumIndex: Int) throws -> [EncodedMethod] {
        var result: [EncodedMethod] = []
        result.reserveCapacity(count)
        var idx: UInt64 = 0
        for _ in 0..<count {
            let (nextIndex, overflow) = idx.addingReportingOverflow(try cr.uleb128())
            guard !overflow, nextIndex < UInt64(maximumIndex) else { throw Error.truncated("encoded method index") }
            idx = nextIndex
            let flagsRaw = try cr.uleb128()
            guard flagsRaw <= UInt64(UInt32.max) else { throw Error.truncated("method access flags") }
            let codeOff = try Self.integer(try cr.uleb128(), "method code offset")
            result.append(EncodedMethod(
                methodIndex: Int(idx), accessFlags: UInt32(flagsRaw), codeOffset: codeOff, definingClassIndex: classIndex
            ))
        }
        return result
    }

    private static func integer(_ value: UInt64, _ what: String) throws -> Int {
        guard value <= UInt64(Int.max) else { throw Error.truncated(what) }
        return Int(value)
    }

    private static func adler32(_ bytes: [UInt8], from start: Int) -> UInt32 {
        let modulus: UInt64 = 65_521
        var a: UInt64 = 1
        var b: UInt64 = 0
        var offset = start
        while offset < bytes.count {
            let end = offset + min(5_552, bytes.count - offset)
            for byte in bytes[offset..<end] {
                a += UInt64(byte)
                b += a
            }
            a %= modulus
            b %= modulus
            offset = end
        }
        return UInt32(b << 16 | a)
    }

    /// Parses the code item for a method; nil when abstract/native.
    public func codeItem(for method: EncodedMethod) -> CodeItem? {
        guard method.codeOffset != 0 else { return nil }
        var r = ByteReader(source)
        guard (try? r.seek(method.codeOffset)) != nil,
              let registers = try? r.u16(),
              let ins = try? r.u16(),
              let outs = try? r.u16(),
              let tries = try? r.u16() else { return nil }
        _ = try? r.u32() // debug info off
        guard let insnsCount = try? r.u32() else { return nil }
        let count = Int(insnsCount)
        guard ins <= registers, count <= r.remaining / 2 else { return nil }
        return CodeItem(
            registersSize: registers,
            insSize: ins,
            outsSize: outs,
            triesCount: tries,
            insnsOffset: r.offset,
            insnsCount: count
        )
    }

    /// Type descriptor → human-readable name: "Lokhttp3/Request;" → "okhttp3.Request".
    public static func readableClassName(_ descriptor: String) -> String {
        guard descriptor.hasPrefix("L"), descriptor.hasSuffix(";") else { return descriptor }
        return String(descriptor.dropFirst().dropLast()).replacingOccurrences(of: "/", with: ".")
    }

    /// Minimal MUTF-8 (CESU-8 variant) decoder: NUL as C0 80, supplementary
    /// characters as surrogate pairs of 3-byte sequences.
    static func decodeMUTF8(_ bytes: [UInt8]) -> String {
        var units: [UInt16] = []
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b < 0x80 {
                units.append(UInt16(b))
                i += 1
            } else if b & 0xE0 == 0xC0, i + 1 < bytes.count {
                units.append(UInt16(b & 0x1F) << 6 | UInt16(bytes[i + 1] & 0x3F))
                i += 2
            } else if b & 0xF0 == 0xE0, i + 2 < bytes.count {
                units.append(UInt16(b & 0x0F) << 12 | UInt16(bytes[i + 1] & 0x3F) << 6 | UInt16(bytes[i + 2] & 0x3F))
                i += 3
            } else {
                units.append(UInt16(b)) // malformed; preserve byte
                i += 1
            }
        }
        return String(decoding: units, as: UTF16.self)
    }
}
