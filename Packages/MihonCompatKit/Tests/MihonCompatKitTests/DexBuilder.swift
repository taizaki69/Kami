import Foundation


/// Builds minimal, valid DEX images for interpreter tests (mission §30).
/// Emits exactly the structures `DexFile` parses: header, string/type/proto/
/// field/method id tables, one class def with class_data, and code items.
struct DexBuilder {
    struct MethodSpec {
        let name: String
        let registers: Int
        let ins: Int
        let outs: Int
        let insns: [UInt16]
        let isStatic: Bool
        let tryItems: [UInt8] = []   // tries appended raw after insns (advanced tests)
    }

    private var strings: [String] = []
    private var types: [Int] = []                 // type → descriptor string idx
    private var protos: [(shorty: Int, ret: Int)] = []
    private var fieldIds: [(classIdx: UInt16, typeIdx: UInt16, nameIdx: Int)] = []
    private var methodIds: [(classIdx: UInt16, protoIdx: UInt16, nameIdx: Int)] = []
    private var classDescriptorIdx: Int = -1
    private var methods: [MethodSpec] = []
    private var fields: [(name: String, type: String)] = []

    // MARK: registration

    @discardableResult
    mutating func string(_ s: String) -> Int {
        if let i = strings.firstIndex(of: s) { return i }
        strings.append(s)
        return strings.count - 1
    }

    @discardableResult
    mutating func type(_ descriptor: String) -> Int {
        let s = string(descriptor)
        if let i = types.firstIndex(of: s) { return i }
        types.append(s)
        return types.count - 1
    }

    @discardableResult
    mutating func proto(shorty: String, ret: String) -> Int {
        protos.append((string(shorty), type(ret)))
        return protos.count - 1
    }

    @discardableResult
    mutating func method(classDescriptor: String, name: String,
                         shorty: String = "V", ret: String = "V") -> Int {
        let cls = type(classDescriptor)
        let proto = proto(shorty: shorty, ret: ret)
        methodIds.append((UInt16(cls), UInt16(proto), string(name)))
        return methodIds.count - 1
    }

    @discardableResult
    mutating func field(classDescriptor: String, name: String, typeDescriptor: String) -> Int {
        fieldIds.append((UInt16(type(classDescriptor)), UInt16(type(typeDescriptor)), string(name)))
        return fieldIds.count - 1
    }

    mutating func setClass(_ descriptor: String, fields: [(String, String)] = []) {
        classDescriptorIdx = type(descriptor)
        self.fields = []
        for f in fields {
            _ = field(classDescriptor: descriptor, name: f.0, typeDescriptor: f.1)
            self.fields.append((name: f.0, type: f.1))
        }
    }

    mutating func addMethod(_ spec: MethodSpec) {
        // Auto-register the method_id (class = set class, default V proto) so
        // tests that never call `method(...)` still produce a valid table.
        let cls = classDescriptorIdx >= 0 ? classDescriptorIdx : 0
        let protoIdx = proto(shorty: "V", ret: "V")
        methodIds.append((UInt16(cls), UInt16(protoIdx), string(spec.name)))
        methods.append(spec)
    }

    // MARK: emission

    mutating func build() -> [UInt8] {
        // Ensure class descriptor exists.
        let _ = classDescriptorIdx

        // Layout: header(112) stringIds typeIds protoIds fieldIds methodIds
        //         classDefs(1) stringData classData codeItems
        let stringIdsSize = strings.count
        let typeIdsSize = types.count
        let protoIdsSize = protos.count
        let fieldIdsSize = fieldIds.count
        let methodIdsSize = methodIds.count

        var stringData: [UInt8] = []
        var stringOffsets: [Int] = []
        for s in strings {
            stringOffsets.append(stringData.count)
            let utf8 = Array(s.utf8)
            stringData.append(contentsOf: ULEB.encode(UInt64(utf8.count)))
            stringData.append(contentsOf: utf8)
            stringData.append(0)
        }

        struct CodeItemLayout {
            let offset: Int
            let headerSize: Int
            let spec: MethodSpec
        }
        var codeLayouts: [CodeItemLayout] = []
        var codeCursor = 0
        for m in methods {
            let headerSize = 16 + m.insns.count * 2
            codeLayouts.append(CodeItemLayout(offset: codeCursor, headerSize: headerSize, spec: m))
            codeCursor += headerSize
            if m.insns.count % 2 == 1 { codeCursor += 2 } // u32-align next
        }

        // class_data: 0 static fields, N instance fields, M direct methods,
        // 0 virtual methods. Field indices are consecutive: first absolute,
        // then diff 1.
        var classDataHeader: [UInt8] = []
        classDataHeader.append(contentsOf: ULEB.encode(0))                      // static fields
        classDataHeader.append(contentsOf: ULEB.encode(UInt64(fields.count)))   // instance fields
        classDataHeader.append(contentsOf: ULEB.encode(UInt64(methods.count)))  // direct methods
        classDataHeader.append(contentsOf: ULEB.encode(0))                      // virtual methods
        var classData: [UInt8] = []

        // class_data must encode ABSOLUTE code offsets; uleb width depends on
        // the values, so iterate to a fixed point (converges in one pass here).
        var directMethods: [UInt8] = []
        var fieldEntries: [UInt8] = []
        for i in fields.indices {
            fieldEntries.append(contentsOf: ULEB.encode(UInt64(i == 0 ? 0 : 1)))
            fieldEntries.append(contentsOf: ULEB.encode(0x2))                      // private instance
        }
        func buildClassData(codeBaseGuess: Int) -> [UInt8] {
            var out = classDataHeader + fieldEntries
            var prevMethodIdx: UInt64 = 0
            for (i, layout) in codeLayouts.enumerated() {
                let methodIdx = UInt64(methodBase + i)
                out.append(contentsOf: ULEB.encode(methodIdx - (i == 0 ? 0 : prevMethodIdx)))
                prevMethodIdx = methodIdx
                out.append(contentsOf: ULEB.encode(layout.spec.isStatic ? 0x8 : 0))
                out.append(contentsOf: ULEB.encode(UInt64(codeBaseGuess + layout.offset)))
            }
            return out
        }
        var guessedCodeBase = 0
        classData = buildClassData(codeBaseGuess: guessedCodeBase)
        // Fixed-point: recompute until byte length stabilizes.
        for _ in 0..<4 {
            let stringIdsSize2 = strings.count, typeIdsSize2 = types.count
            let protoIdsSize2 = protos.count, fieldIdsSize2 = fieldIds.count, methodIdsSize2 = methodIds.count
            let base = 112 + stringIdsSize2*4 + typeIdsSize2*4 + protoIdsSize2*12
                + fieldIdsSize2*8 + methodIdsSize2*8 + 32
            let newBase = base + stringData.count + classData.count
            if newBase == guessedCodeBase { break }
            guessedCodeBase = newBase
            classData = buildClassData(codeBaseGuess: guessedCodeBase)
        }
        directMethods = []

        let stringIdsOff = 112
        let typeIdsOff = stringIdsOff + stringIdsSize * 4
        let protoIdsOff = typeIdsOff + typeIdsSize * 4
        let fieldIdsOff = protoIdsOff + protoIdsSize * 12
        let methodIdsOff = fieldIdsOff + fieldIdsSize * 8
        let classDefsOff = methodIdsOff + methodIdsSize * 8
        let stringDataOff = classDefsOff + 32
        let classDataOff = stringDataOff + stringData.count
        let codeOff = classDataOff + classData.count
        let fileSize = codeOff + codeCursor

        var out: [UInt8] = []
        out.reserveCapacity(fileSize)

        func u16(_ v: UInt16) { out.append(UInt8(v & 0xFF)); out.append(UInt8(v >> 8)) }
        func u32(_ v: UInt32) { u16(UInt16(v & 0xFFFF)); u16(UInt16(v >> 16)) }
        func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }

        // Header.
        out.append(contentsOf: Array("dex\n035\0".utf8))
        u32(0)      // checksum (unchecked by parser)
        out.append(contentsOf: [UInt8](repeating: 0, count: 20))
        u32(UInt32(fileSize))
        u32(112)
        u32(0x12345678)
        u32(0); u32(0) // link size/off
        u32(0)         // map off (unused by parser)
        u32(UInt32(stringIdsSize)); u32(UInt32(stringIdsOff))
        u32(UInt32(typeIdsSize)); u32(UInt32(typeIdsOff))
        u32(UInt32(protoIdsSize)); u32(UInt32(protoIdsOff))
        u32(UInt32(fieldIdsSize)); u32(UInt32(fieldIdsOff))
        u32(UInt32(methodIdsSize)); u32(UInt32(methodIdsOff))
        u32(1); u32(UInt32(classDefsOff))
        u32(0); u32(UInt32(codeOff)) // data size/off placeholder (unused)

        // string_ids → absolute offsets into stringData
        for off in stringOffsets { u32(UInt32(stringDataOff + off)) }
        // type_ids
        for s in types { u32(UInt32(s)) }
        // proto_ids: shorty_idx, return_type_idx, params_off = 0
        for p in protos { u32(UInt32(p.shorty)); u32(UInt32(p.ret)); u32(0) }
        // field_ids
        for f in fieldIds { u16(f.classIdx); u16(f.typeIdx); u32(UInt32(f.nameIdx)) }
        // method_ids
        for m in methodIds { u16(m.classIdx); u16(m.protoIdx); u32(UInt32(m.nameIdx)) }
        // class_def: class, access, super(-1), ifaces(0), source(-1), ann(0),
        //             class_data_off, static_values(0)
        u32(UInt32(classDescriptorIdx))
        u32(1)                     // PUBLIC
        u32(0xFFFF_FFFF)
        u32(0)
        u32(0xFFFF_FFFF)
        u32(0)
        u32(UInt32(classDataOff))
        u32(0)

        out.append(contentsOf: stringData)
        out.append(contentsOf: classData)

        for layout in codeLayouts {
            let m = layout.spec
            u16(UInt16(m.registers))
            u16(UInt16(m.ins))
            u16(UInt16(m.outs))
            u16(0)                 // tries
            u32(0)                 // debug info off
            u32(UInt32(m.insns.count))
            for unit in m.insns { u16(unit) }
            if m.insns.count % 2 == 1 { u16(0) } // padding to u32
        }

        return out
    }

    /// method index base: methods registered via `method(...)` first.
    var methodBase: Int { methodIds.count - methods.count }

    enum ULEB {
        static func encode(_ v: UInt64) -> [UInt8] {
            var out: [UInt8] = []
            var value = v
            repeat {
                var b = UInt8(value & 0x7f)
                value >>= 7
                if value != 0 { b |= 0x80 }
                out.append(b)
            } while value != 0
            return out
        }
    }
}

// MARK: - Instruction encoding helpers

enum Insn {
    static func nop() -> [UInt16] { [0x00] }
    static func const4(_ reg: Int, _ value: Int8) -> UInt16 {
        UInt16(0x12) | UInt16(reg << 8) | (UInt16(UInt8(bitPattern: value) % 16) << 12)
    }
    static func const4Units(_ reg: Int, _ value: Int8) -> [UInt16] {
        // 11n: high nibble B (signed), low nibble A (register)
        let nib: UInt16
        if value < 0 { nib = UInt16(0x8 | (UInt8(bitPattern: value) & 0x7)) }
        else { nib = UInt16(value & 0xF) }
        return [0x12 | UInt16(reg << 8) | nib << 12]
    }
    static func const16Units(_ reg: Int, _ value: Int16) -> [UInt16] {
        [0x13 | UInt16(reg << 8), UInt16(bitPattern: value)]
    }
    static func constString(_ reg: Int, _ stringIdx: Int) -> [UInt16] {
        [0x1a | UInt16(reg << 8), UInt16(stringIdx)]
    }
    static func binop(_ opcode: UInt8, _ dst: Int, _ lhs: Int, _ rhs: Int) -> [UInt16] {
        [UInt16(opcode) | UInt16(dst << 8), UInt16(lhs) | UInt16(rhs << 8)]
    }
    static func returnVoid() -> [UInt16] { [0x0e] }
    static func returnReg(_ reg: Int) -> [UInt16] { [0x0f | UInt16(reg << 8)] }
    static func returnObjectReg(_ reg: Int) -> [UInt16] { [0x11 | UInt16(reg << 8)] }
    static func moveResult(_ reg: Int) -> [UInt16] { [0x0a | UInt16(reg << 8)] }
    static func goto(_ offset: Int8) -> [UInt16] { [0x28 | (UInt16(UInt8(bitPattern: offset)) << 8)] }
    static func ifEqz(_ reg: Int, _ offset: Int16) -> [UInt16] {
        [0x38 | UInt16(reg << 8), UInt16(bitPattern: offset)]
    }
    static func ifNez(_ reg: Int, _ offset: Int16) -> [UInt16] {
        [0x39 | UInt16(reg << 8), UInt16(bitPattern: offset)]
    }
    static func ifLt(_ a: Int, _ b: Int, _ offset: Int16) -> [UInt16] {
        [0x34 | UInt16(b << 12) | UInt16(a << 8), UInt16(bitPattern: offset)]
    }
    static func invokeStatic(_ methodIdx: Int, _ regs: [Int]) -> [UInt16] {
        invokeKind(0x71, methodIdx, regs)
    }
    static func invokeDirect(_ methodIdx: Int, _ regs: [Int]) -> [UInt16] {
        invokeKind(0x70, methodIdx, regs)
    }
    static func invokeVirtual(_ methodIdx: Int, _ regs: [Int]) -> [UInt16] {
        invokeKind(0x6e, methodIdx, regs)
    }
    static func invokeKind(_ opcode: UInt8, _ methodIdx: Int, _ regs: [Int]) -> [UInt16] {
        let a = regs.count
        let g = a == 5 ? regs[4] : 0
        let c = regs.count > 0 ? regs[0] : 0
        let d = regs.count > 1 ? regs[1] : 0
        let e = regs.count > 2 ? regs[2] : 0
        let f = regs.count > 3 ? regs[3] : 0
        let unit2 = UInt16(c) | UInt16(d << 4) | UInt16(e << 8) | UInt16(f << 12)
        return [UInt16(opcode) | UInt16(g << 8) | UInt16(a << 12), unit2, UInt16(methodIdx)]
    }
    static func newInstance(_ reg: Int, _ typeIdx: Int) -> [UInt16] {
        [0x22 | UInt16(reg << 8), UInt16(typeIdx)]
    }
    static func newArray(_ dst: Int, _ size: Int, _ typeIdx: Int) -> [UInt16] {
        [0x23 | UInt16(size << 12) | UInt16(dst << 8), UInt16(typeIdx)]
    }
    static func aput(_ value: Int, _ array: Int, _ index: Int) -> [UInt16] {
        [0x4b | UInt16(value << 8), UInt16(array) | UInt16(index << 8)]
    }
    static func aget(_ dst: Int, _ array: Int, _ index: Int) -> [UInt16] {
        [0x44 | UInt16(dst << 8), UInt16(array) | UInt16(index << 8)]
    }
    static func arrayLength(_ dst: Int, _ array: Int) -> [UInt16] {
        [0x21 | UInt16(array << 12) | UInt16(dst << 8)]
    }
    static func iput(_ src: Int, _ obj: Int, _ fieldIdx: Int) -> [UInt16] {
        [0x59 | UInt16(obj << 12) | UInt16(src << 8), UInt16(fieldIdx)]
    }
    static func iget(_ dst: Int, _ obj: Int, _ fieldIdx: Int) -> [UInt16] {
        [0x52 | UInt16(obj << 12) | UInt16(dst << 8), UInt16(fieldIdx)]
    }
    static func addLit8(_ dst: Int, _ src: Int, _ lit: Int8) -> [UInt16] {
        [0xd8 | UInt16(dst << 8), UInt16(src) | (UInt16(UInt8(bitPattern: lit)) << 8)]
    }
    static func throwReg(_ reg: Int) -> [UInt16] { [0x27 | UInt16(reg << 8)] }
}
