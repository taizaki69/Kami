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
        let isVirtual: Bool
        let returnType: String
        let parameters: [String]
        let triesCount: Int
        let tryPadding: UInt16
        /// Raw `try_item[]` plus `encoded_catch_handler_list` bytes.
        let tryItems: [UInt8]

        init(name: String, registers: Int, ins: Int, outs: Int,
             insns: [UInt16], isStatic: Bool, returnType: String = "V",
             parameters: [String] = [], triesCount: Int = 0,
             tryPadding: UInt16 = 0, tryItems: [UInt8] = [],
             isVirtual: Bool? = nil) {
            self.name = name
            self.registers = registers
            self.ins = ins
            self.outs = outs
            self.insns = insns
            self.isStatic = isStatic
            self.isVirtual = isVirtual ?? (!isStatic && name != "<init>")
            self.returnType = returnType
            self.parameters = parameters
            self.triesCount = triesCount
            self.tryPadding = tryPadding
            self.tryItems = tryItems
        }
    }

    private var strings: [String] = []
    private var types: [Int] = []                 // type → descriptor string idx
    private var protos: [(shorty: Int, ret: Int, parameters: [Int])] = []
    private var fieldIds: [(classIdx: UInt16, typeIdx: UInt16, nameIdx: Int)] = []
    private var methodIds: [(classIdx: UInt16, protoIdx: UInt16, nameIdx: Int)] = []
    private var classDescriptorIdx: Int = -1
    private var superclassIdx: Int = -1
    private var interfaceTypeIndices: [Int] = []
    private var methods: [MethodSpec] = []
    private var staticFields: [(name: String, type: String)] = []
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
    mutating func proto(shorty: String, ret: String, parameters: [String] = []) -> Int {
        let shortyIdx = string(shorty)
        let returnIdx = type(ret)
        let parameterIndices = parameters.map { type($0) }
        protos.append((shortyIdx, returnIdx, parameterIndices))
        return protos.count - 1
    }

    @discardableResult
    mutating func method(classDescriptor: String, name: String,
                         shorty: String = "V", ret: String = "V",
                         parameters: [String] = []) -> Int {
        let cls = type(classDescriptor)
        let proto = proto(shorty: shorty, ret: ret, parameters: parameters)
        methodIds.append((UInt16(cls), UInt16(proto), string(name)))
        return methodIds.count - 1
    }

    @discardableResult
    mutating func field(classDescriptor: String, name: String, typeDescriptor: String) -> Int {
        fieldIds.append((UInt16(type(classDescriptor)), UInt16(type(typeDescriptor)), string(name)))
        return fieldIds.count - 1
    }

    mutating func setClass(_ descriptor: String,
                           superclass: String? = nil,
                           interfaces: [String] = [],
                           staticFields: [(String, String)] = [],
                           fields: [(String, String)] = []) {
        classDescriptorIdx = type(descriptor)
        if let superclass {
            superclassIdx = type(superclass)
        } else {
            superclassIdx = -1
        }
        interfaceTypeIndices = []
        for interface in interfaces {
            interfaceTypeIndices.append(type(interface))
        }
        self.staticFields = []
        self.fields = []
        for field in staticFields {
            _ = self.field(classDescriptor: descriptor, name: field.0, typeDescriptor: field.1)
            self.staticFields.append((name: field.0, type: field.1))
        }
        for f in fields {
            _ = field(classDescriptor: descriptor, name: f.0, typeDescriptor: f.1)
            self.fields.append((name: f.0, type: f.1))
        }
    }

    mutating func addMethod(_ spec: MethodSpec) {
        // Auto-register the exact method_id so class_data and invoke tests use
        // the same prototype identity as production DEX files.
        let cls = classDescriptorIdx >= 0 ? classDescriptorIdx : 0
        let shorty = Self.shorty(returnType: spec.returnType, parameters: spec.parameters)
        let protoIdx = proto(shorty: shorty, ret: spec.returnType, parameters: spec.parameters)
        methodIds.append((UInt16(cls), UInt16(protoIdx), string(spec.name)))
        methods.append(spec)
    }

    private static func shorty(returnType: String, parameters: [String]) -> String {
        ([returnType] + parameters).map { descriptor in
            descriptor.hasPrefix("L") || descriptor.hasPrefix("[") ? "L" : String(descriptor.prefix(1))
        }.joined()
    }

    // MARK: emission

    mutating func build() -> [UInt8] {
        // Ensure class descriptor exists.
        let _ = classDescriptorIdx

        // Layout: header(112) stringIds typeIds protoIds fieldIds methodIds
        //         classDefs(1) stringData protoTypeLists classData codeItems
        let stringIdsSize = strings.count
        let typeIdsSize = types.count
        let protoIdsSize = protos.count
        let fieldIdsSize = fieldIds.count
        let methodIdsSize = methodIds.count

        let stringIdsOff = 112
        let typeIdsOff = stringIdsOff + stringIdsSize * 4
        let protoIdsOff = typeIdsOff + typeIdsSize * 4
        let fieldIdsOff = protoIdsOff + protoIdsSize * 12
        let methodIdsOff = fieldIdsOff + fieldIdsSize * 8
        let classDefsOff = methodIdsOff + methodIdsSize * 8
        let stringDataOff = classDefsOff + 32

        var stringData: [UInt8] = []
        var stringOffsets: [Int] = []
        for s in strings {
            stringOffsets.append(stringData.count)
            let utf8 = Array(s.utf8)
            stringData.append(contentsOf: ULEB.encode(UInt64(utf8.count)))
            stringData.append(contentsOf: utf8)
            stringData.append(0)
        }

        // Every non-empty proto parameter list is a 4-byte-aligned type_list.
        var protoData: [UInt8] = []
        var protoParameterOffsets: [Int] = []
        for proto in protos {
            guard !proto.parameters.isEmpty else {
                protoParameterOffsets.append(0)
                continue
            }
            while (stringDataOff + stringData.count + protoData.count) % 4 != 0 {
                protoData.append(0)
            }
            protoParameterOffsets.append(stringDataOff + stringData.count + protoData.count)
            let count = UInt32(proto.parameters.count)
            protoData.append(UInt8(count & 0xFF))
            protoData.append(UInt8((count >> 8) & 0xFF))
            protoData.append(UInt8((count >> 16) & 0xFF))
            protoData.append(UInt8(count >> 24))
            for parameter in proto.parameters {
                let value = UInt16(parameter)
                protoData.append(UInt8(value & 0xFF))
                protoData.append(UInt8(value >> 8))
            }
        }

        var interfacesOff = 0
        if !interfaceTypeIndices.isEmpty {
            while (stringDataOff + stringData.count + protoData.count) % 4 != 0 {
                protoData.append(0)
            }
            interfacesOff = stringDataOff + stringData.count + protoData.count
            let count = UInt32(interfaceTypeIndices.count)
            protoData.append(UInt8(count & 0xFF))
            protoData.append(UInt8((count >> 8) & 0xFF))
            protoData.append(UInt8((count >> 16) & 0xFF))
            protoData.append(UInt8(count >> 24))
            for interface in interfaceTypeIndices {
                let value = UInt16(interface)
                protoData.append(UInt8(value & 0xFF))
                protoData.append(UInt8(value >> 8))
            }
        }

        struct CodeItemLayout {
            let offset: Int
            let spec: MethodSpec
        }
        var codeLayouts: [CodeItemLayout] = []
        var codeCursor = 0
        for m in methods {
            precondition((0...Int(UInt16.max)).contains(m.triesCount))
            codeLayouts.append(CodeItemLayout(offset: codeCursor, spec: m))
            codeCursor += 16 + m.insns.count * 2
            if m.triesCount > 0, m.insns.count % 2 == 1 { codeCursor += 2 }
            codeCursor += m.tryItems.count
            codeCursor = (codeCursor + 3) & ~3 // every code_item begins on a u32 boundary
        }

        let directLayouts = codeLayouts.enumerated().filter { !$0.element.spec.isVirtual }
        let virtualLayouts = codeLayouts.enumerated().filter { $0.element.spec.isVirtual }

        // class_data: each field and method list has its own index-delta stream.
        var classDataHeader: [UInt8] = []
        classDataHeader.append(contentsOf: ULEB.encode(UInt64(staticFields.count)))
        classDataHeader.append(contentsOf: ULEB.encode(UInt64(fields.count)))   // instance fields
        classDataHeader.append(contentsOf: ULEB.encode(UInt64(directLayouts.count)))
        classDataHeader.append(contentsOf: ULEB.encode(UInt64(virtualLayouts.count)))
        var classData: [UInt8] = []

        // class_data must encode ABSOLUTE code offsets; uleb width depends on
        // the values, so iterate to a fixed point (converges in one pass here).
        var fieldEntries: [UInt8] = []
        for index in staticFields.indices {
            fieldEntries.append(contentsOf: ULEB.encode(UInt64(index == 0 ? 0 : 1)))
            fieldEntries.append(contentsOf: ULEB.encode(0x8)) // static
        }
        for i in fields.indices {
            let absoluteIndex = staticFields.count + i
            fieldEntries.append(contentsOf: ULEB.encode(UInt64(i == 0 ? absoluteIndex : 1)))
            fieldEntries.append(contentsOf: ULEB.encode(0x2)) // private instance
        }
        func buildClassData(codeBaseGuess: Int) -> [UInt8] {
            var out = classDataHeader + fieldEntries
            func appendMethods(
                _ layouts: [(offset: Int, element: CodeItemLayout)],
                to output: inout [UInt8]
            ) {
                var previousMethodIndex: UInt64 = 0
                for (listIndex, item) in layouts.enumerated() {
                    let methodIndex = UInt64(methodBase + item.offset)
                    output.append(contentsOf: ULEB.encode(
                        methodIndex - (listIndex == 0 ? 0 : previousMethodIndex)
                    ))
                    previousMethodIndex = methodIndex
                    let flags: UInt64 = item.element.spec.isStatic ? 0x8 :
                        (item.element.spec.isVirtual ? 0x1 : 0)
                    output.append(contentsOf: ULEB.encode(flags))
                    output.append(contentsOf: ULEB.encode(
                        UInt64(codeBaseGuess + item.element.offset)
                    ))
                }
            }
            appendMethods(directLayouts, to: &out)
            appendMethods(virtualLayouts, to: &out)
            return out
        }
        var guessedCodeBase = 0
        classData = buildClassData(codeBaseGuess: guessedCodeBase)
        // Fixed-point: recompute until byte length stabilizes.
        for _ in 0..<8 {
            let unalignedBase = stringDataOff + stringData.count + protoData.count + classData.count
            let newBase = (unalignedBase + 3) & ~3
            if newBase == guessedCodeBase { break }
            guessedCodeBase = newBase
            classData = buildClassData(codeBaseGuess: guessedCodeBase)
        }
        let classDataOff = stringDataOff + stringData.count + protoData.count
        let codeOff = guessedCodeBase
        let codePadding = codeOff - (classDataOff + classData.count)
        let fileSize = codeOff + codeCursor

        var out: [UInt8] = []
        out.reserveCapacity(fileSize)

        func u16(_ v: UInt16) { out.append(UInt8(v & 0xFF)); out.append(UInt8(v >> 8)) }
        func u32(_ v: UInt32) { u16(UInt16(v & 0xFFFF)); u16(UInt16(v >> 16)) }
        func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }

        // Header.
        out.append(contentsOf: Array("dex\n035\0".utf8))
        u32(0)      // checksum, filled after the rest of the file is assembled
        out.append(contentsOf: [UInt8](repeating: 0, count: 20))
        u32(UInt32(fileSize))
        u32(112)
        u32(0x12345678)
        u32(0); u32(0) // link size/off
        u32(0)         // map off (unused by parser)
        u32(UInt32(stringIdsSize)); u32(stringIdsSize == 0 ? 0 : UInt32(stringIdsOff))
        u32(UInt32(typeIdsSize)); u32(typeIdsSize == 0 ? 0 : UInt32(typeIdsOff))
        u32(UInt32(protoIdsSize)); u32(protoIdsSize == 0 ? 0 : UInt32(protoIdsOff))
        u32(UInt32(fieldIdsSize)); u32(fieldIdsSize == 0 ? 0 : UInt32(fieldIdsOff))
        u32(UInt32(methodIdsSize)); u32(methodIdsSize == 0 ? 0 : UInt32(methodIdsOff))
        u32(1); u32(UInt32(classDefsOff))
        u32(UInt32(fileSize - stringDataOff)); u32(UInt32(stringDataOff))

        // string_ids → absolute offsets into stringData
        for off in stringOffsets { u32(UInt32(stringDataOff + off)) }
        // type_ids
        for s in types { u32(UInt32(s)) }
        // proto_ids: shorty_idx, return_type_idx, absolute params_off
        for (index, p) in protos.enumerated() {
            u32(UInt32(p.shorty)); u32(UInt32(p.ret)); u32(UInt32(protoParameterOffsets[index]))
        }
        // field_ids
        for f in fieldIds { u16(f.classIdx); u16(f.typeIdx); u32(UInt32(f.nameIdx)) }
        // method_ids
        for m in methodIds { u16(m.classIdx); u16(m.protoIdx); u32(UInt32(m.nameIdx)) }
        // class_def: class, access, super, interfaces, source(-1), ann(0),
        //             class_data_off, static_values(0)
        u32(UInt32(classDescriptorIdx))
        u32(1)                     // PUBLIC
        u32(superclassIdx >= 0 ? UInt32(superclassIdx) : 0xFFFF_FFFF)
        u32(UInt32(interfacesOff))
        u32(0xFFFF_FFFF)
        u32(0)
        u32(UInt32(classDataOff))
        u32(0)

        out.append(contentsOf: stringData)
        out.append(contentsOf: protoData)
        out.append(contentsOf: classData)
        out.append(contentsOf: [UInt8](repeating: 0, count: codePadding))

        for (index, layout) in codeLayouts.enumerated() {
            let m = layout.spec
            u16(UInt16(m.registers))
            u16(UInt16(m.ins))
            u16(UInt16(m.outs))
            u16(UInt16(m.triesCount))
            u32(0)                 // debug info off
            u32(UInt32(m.insns.count))
            for unit in m.insns { u16(unit) }
            if m.triesCount > 0, m.insns.count % 2 == 1 { u16(m.tryPadding) }
            out.append(contentsOf: m.tryItems)
            let nextOffset = index + 1 < codeLayouts.count
                ? codeLayouts[index + 1].offset
                : codeCursor
            let expectedSize = codeOff + nextOffset
            precondition(out.count <= expectedSize)
            out.append(contentsOf: [UInt8](repeating: 0, count: expectedSize - out.count))
        }

        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in out.dropFirst(12) {
            a = (a + UInt32(byte)) % 65_521
            b = (b + a) % 65_521
        }
        let checksum = b << 16 | a
        out[8] = UInt8(checksum & 0xff)
        out[9] = UInt8((checksum >> 8) & 0xff)
        out[10] = UInt8((checksum >> 16) & 0xff)
        out[11] = UInt8(checksum >> 24)
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
    static func invokeInterface(_ methodIdx: Int, _ regs: [Int]) -> [UInt16] {
        invokeKind(0x72, methodIdx, regs)
    }
    static func invokeKind(_ opcode: UInt8, _ methodIdx: Int, _ regs: [Int]) -> [UInt16] {
        let a = regs.count
        let g = a == 5 ? regs[4] : 0
        let c = regs.count > 0 ? regs[0] : 0
        let d = regs.count > 1 ? regs[1] : 0
        let e = regs.count > 2 ? regs[2] : 0
        let f = regs.count > 3 ? regs[3] : 0
        let registerWord = UInt16(c) | UInt16(d << 4) | UInt16(e << 8) | UInt16(f << 12)
        return [UInt16(opcode) | UInt16(g << 8) | UInt16(a << 12), UInt16(methodIdx), registerWord]
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
    static func sget(_ dst: Int, _ fieldIdx: Int) -> [UInt16] {
        [0x60 | UInt16(dst << 8), UInt16(fieldIdx)]
    }
    static func sput(_ src: Int, _ fieldIdx: Int) -> [UInt16] {
        [0x67 | UInt16(src << 8), UInt16(fieldIdx)]
    }
    static func addLit8(_ dst: Int, _ src: Int, _ lit: Int8) -> [UInt16] {
        [0xd8 | UInt16(dst << 8), UInt16(src) | (UInt16(UInt8(bitPattern: lit)) << 8)]
    }
    static func throwReg(_ reg: Int) -> [UInt16] { [0x27 | UInt16(reg << 8)] }
}
