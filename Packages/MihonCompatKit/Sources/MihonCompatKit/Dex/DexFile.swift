import Foundation

/// DEX (Dalvik Executable, format 035–039) parser.
///
/// Parses the full structural tables — strings, types, protos, fields, methods,
/// class definitions with encoded fields/methods and code items — and exposes
/// them for analysis and (later) interpretation. Admissible magic values cover
/// all versions emitted by current Android toolchains; minSdk-specific
/// instructions inside `insns` are not validated here.
public struct DexFile {
    struct MethodRef {
        let declaringClass: String   // type descriptor, e.g. "Lokhttp3/Request;"
        let name: String
        let prototype: Prototype
    }

    struct FieldRef {
        let declaringClass: String
        let type: String
        let name: String
    }

    struct Prototype {
        let shorty: String
        let returnType: String
        let parameters: [String]
    }

    struct EncodedMethod {
        let methodIndex: Int
        let accessFlags: UInt32
        let codeOffset: Int
        let definingClassIndex: Int
    }

    struct EncodedField {
        let fieldIndex: Int
        let accessFlags: UInt32
    }

    struct CodeItem {
        let registersSize: UInt16
        let insSize: UInt16
        let outsSize: UInt16
        let insnsOffset: Int
        let insnsCount: Int
    }

    struct ClassDef {
        let typeIndex: Int
        let descriptor: String
        let accessFlags: UInt32
        let superclassIndex: Int   // -1 when absent
        let interfaceIndices: [Int]
        let sourceFileIndex: Int
        let staticFields: [EncodedField]
        let instanceFields: [EncodedField]
        let directMethods: [EncodedMethod]
        let virtualMethods: [EncodedMethod]
        let classDataOffset: Int
    }

    enum Error: Swift.Error, CustomStringConvertible {
        case badMagic(String)
        case badEndianTag(UInt32)
        case truncated(String)

        var description: String {
            switch self {
            case let .badMagic(m): return "not a DEX file (magic \(m.debugDescription))"
            case let .badEndianTag(t): return "unexpected endian tag 0x\(String(t, radix: 16)) (only little-endian DEX supported)"
            case let .truncated(what): return "truncated DEX while reading \(what)"
            }
        }
    }

    let strings: [String]
    let typeDescriptors: [String]
    let prototypes: [Prototype]
    let fieldIds: [FieldRef]
    let methodIds: [MethodRef]
    let classDefs: [ClassDef]

    /// descriptor ("La/b/C;") → class def index.
    let classIndexByDescriptor: [String: Int]

    /// Raw backing bytes, kept for code item parsing and the future interpreter.
    let source: [UInt8]

    init(_ bytes: [UInt8]) throws {
        self.source = bytes
        var r = ByteReader(bytes)

        // magic: "dex\n" + 3 version digits + '\0'
        guard bytes.count >= 36 else { throw Error.truncated("header") }
        let magic = String(decoding: bytes[0..<8], as: UTF8.self)
        guard magic.hasPrefix("dex\n"), magic.hasSuffix("\0") else {
            throw Error.badMagic(magic)
        }
        try r.seek(8)
        _ = try r.u32() // checksum (adler32)
        _ = try r.skip(20) // sha1 signature
        _ = try r.u32() // file size
        _ = try r.u32() // header size
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

        // --- string_ids → MUTF-8 data
        var strings: [String] = []
        strings.reserveCapacity(stringIdsSize)
        for i in 0..<stringIdsSize {
            let dataOff = try Int(r.u32(at: stringIdsOff + i * 4))
            var sr = r
            try sr.seek(dataOff)
            _ = try sr.uleb128()      // utf16 code unit count
            var utf8: [UInt8] = []
            while true {
                let b = try sr.u8()
                if b == 0 { break }
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
            var params: [String] = []
            if paramsOff != 0 {
                var pr = r
                try pr.seek(paramsOff)
                let count = Int(try pr.u32())
                for _ in 0..<count {
                    let idx = Int(try pr.u16())
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

            var interfaces: [Int] = []
            if interfacesOff != 0 {
                var ir = r
                try ir.seek(interfacesOff)
                let count = Int(try ir.u32())
                for _ in 0..<count { interfaces.append(Int(try ir.u16())) }
            }

            var staticFields: [EncodedField] = []
            var instanceFields: [EncodedField] = []
            var directMethods: [EncodedMethod] = []
            var virtualMethods: [EncodedMethod] = []

            if classDataOff != 0 {
                var cr = r
                try cr.seek(classDataOff)
                let staticCount = Int(try cr.uleb128())
                let instanceCount = Int(try cr.uleb128())
                let directCount = Int(try cr.uleb128())
                let virtualCount = Int(try cr.uleb128())

                staticFields = try Self.readFields(&cr, count: staticCount)
                instanceFields = try Self.readFields(&cr, count: instanceCount)
                directMethods = try Self.readMethods(&cr, count: directCount, classIndex: classIdx)
                virtualMethods = try Self.readMethods(&cr, count: virtualCount, classIndex: classIdx)
            }

            let def = ClassDef(
                typeIndex: classIdx,
                descriptor: types[classIdx],
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

    private static func readFields(_ cr: inout ByteReader, count: Int) throws -> [EncodedField] {
        var result: [EncodedField] = []
        result.reserveCapacity(count)
        var idx: UInt64 = 0
        for _ in 0..<count {
            idx += try cr.uleb128() // diff-encoded field index
            let flags = UInt32(try cr.uleb128())
            result.append(EncodedField(fieldIndex: Int(idx), accessFlags: flags))
        }
        return result
    }

    private static func readMethods(_ cr: inout ByteReader, count: Int, classIndex: Int) throws -> [EncodedMethod] {
        var result: [EncodedMethod] = []
        result.reserveCapacity(count)
        var idx: UInt64 = 0
        for _ in 0..<count {
            idx += try cr.uleb128()
            let flags = UInt32(try cr.uleb128())
            let codeOff = Int(try cr.uleb128())
            result.append(EncodedMethod(methodIndex: Int(idx), accessFlags: flags, codeOffset: codeOff, definingClassIndex: classIndex))
        }
        return result
    }

    /// Parses the code item for a method; nil when abstract/native.
    func codeItem(for method: EncodedMethod) -> CodeItem? {
        guard method.codeOffset != 0 else { return nil }
        var r = ByteReader(source)
        guard (try? r.seek(method.codeOffset)) != nil,
              let registers = try? r.u16(),
              let ins = try? r.u16(),
              let outs = try? r.u16(),
              let _ = try? r.u16() else { return nil }
        _ = try? r.u32() // debug info off
        guard let insnsCount = try? r.u32() else { return nil }
        return CodeItem(
            registersSize: registers,
            insSize: ins,
            outsSize: outs,
            insnsOffset: r.offset,
            insnsCount: Int(insnsCount)
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
