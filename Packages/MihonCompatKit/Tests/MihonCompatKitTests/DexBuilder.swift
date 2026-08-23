import Foundation


/// Builds minimal, valid DEX images for interpreter tests (mission §30).
/// Emits exactly the structures `DexFile` parses: header, string/type/proto/
/// field/method id tables, class defs with class_data, and code items.
struct DexBuilder {
    struct MethodSpec {
        let name: String
        let registers: Int
        let ins: Int
        let outs: Int
        let insns: [UInt16]
        let isStatic: Bool
        let isVirtual: Bool
        let accessFlags: UInt32
        let hasCode: Bool
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
             isVirtual: Bool? = nil, accessFlags: UInt32? = nil,
             hasCode: Bool = true) {
            self.name = name
            self.registers = registers
            self.ins = ins
            self.outs = outs
            self.insns = insns
            self.isStatic = isStatic
            self.isVirtual = isVirtual ?? (!isStatic && name != "<init>")
            self.accessFlags = accessFlags
                ?? (isStatic ? 0x8 : (self.isVirtual ? 0x1 : 0))
            self.hasCode = hasCode
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
    private struct RegisteredMethod {
        let methodIndex: Int
        let spec: MethodSpec
    }
    private struct RegisteredField {
        let fieldIndex: Int
        let accessFlags: UInt32
    }
    private struct ClassSpec {
        let descriptorIdx: Int
        let superclassIdx: Int
        let interfaceTypeIndices: [Int]
        let accessFlags: UInt32
        var methods: [RegisteredMethod]
        var staticFields: [RegisteredField]
        var instanceFields: [RegisteredField]
    }
    private var classes: [ClassSpec] = []
    private var activeClassIndex: Int?
    private let version: Int

    init(version: Int = 35) {
        precondition([35, 37, 38, 39, 40].contains(version))
        self.version = version
    }

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
                           fields: [(String, String)] = [],
                           accessFlags: UInt32 = 0x1) {
        let descriptorIdx = type(descriptor)
        precondition(!classes.contains { $0.descriptorIdx == descriptorIdx })
        let superclassIdx = superclass.map { type($0) } ?? -1
        let interfaceTypeIndices = interfaces.map { type($0) }
        var registeredStaticFields: [RegisteredField] = []
        var registeredInstanceFields: [RegisteredField] = []
        for fieldSpec in staticFields {
            let index = field(
                classDescriptor: descriptor,
                name: fieldSpec.0,
                typeDescriptor: fieldSpec.1
            )
            registeredStaticFields.append(RegisteredField(fieldIndex: index, accessFlags: 0x8))
        }
        for fieldSpec in fields {
            let index = field(
                classDescriptor: descriptor,
                name: fieldSpec.0,
                typeDescriptor: fieldSpec.1
            )
            registeredInstanceFields.append(RegisteredField(fieldIndex: index, accessFlags: 0x2))
        }
        classes.append(ClassSpec(
            descriptorIdx: descriptorIdx,
            superclassIdx: superclassIdx,
            interfaceTypeIndices: interfaceTypeIndices,
            accessFlags: accessFlags,
            methods: [],
            staticFields: registeredStaticFields,
            instanceFields: registeredInstanceFields
        ))
        activeClassIndex = classes.count - 1
    }

    @discardableResult
    mutating func addMethod(_ spec: MethodSpec) -> Int {
        // Auto-register the exact method_id so class_data and invoke tests use
        // the same prototype identity as production DEX files.
        guard let activeClassIndex else {
            preconditionFailure("setClass must be called before addMethod")
        }
        let cls = classes[activeClassIndex].descriptorIdx
        let shorty = Self.shorty(returnType: spec.returnType, parameters: spec.parameters)
        let protoIdx = proto(shorty: shorty, ret: spec.returnType, parameters: spec.parameters)
        methodIds.append((UInt16(cls), UInt16(protoIdx), string(spec.name)))
        let methodIndex = methodIds.count - 1
        classes[activeClassIndex].methods.append(RegisteredMethod(
            methodIndex: methodIndex,
            spec: spec
        ))
        return methodIndex
    }

    private static func shorty(returnType: String, parameters: [String]) -> String {
        ([returnType] + parameters).map { descriptor in
            descriptor.hasPrefix("L") || descriptor.hasPrefix("[") ? "L" : String(descriptor.prefix(1))
        }.joined()
    }

    // MARK: emission

    mutating func build() -> [UInt8] {
        precondition(!classes.isEmpty)

        // Layout: header(112) stringIds typeIds protoIds fieldIds methodIds
        //         classDefs stringData proto/interface type lists classData codeItems
        let stringIdsSize = strings.count
        let typeIdsSize = types.count
        let protoIdsSize = protos.count
        let fieldIdsSize = fieldIds.count
        let methodIdsSize = methodIds.count
        let classDefsSize = classes.count

        let stringIdsOff = 112
        let typeIdsOff = stringIdsOff + stringIdsSize * 4
        let protoIdsOff = typeIdsOff + typeIdsSize * 4
        let fieldIdsOff = protoIdsOff + protoIdsSize * 12
        let methodIdsOff = fieldIdsOff + fieldIdsSize * 8
        let classDefsOff = methodIdsOff + methodIdsSize * 8
        let stringDataOff = classDefsOff + classDefsSize * 32

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
        var tableData: [UInt8] = []
        var protoParameterOffsets: [Int] = []
        for proto in protos {
            guard !proto.parameters.isEmpty else {
                protoParameterOffsets.append(0)
                continue
            }
            while (stringDataOff + stringData.count + tableData.count) % 4 != 0 {
                tableData.append(0)
            }
            protoParameterOffsets.append(stringDataOff + stringData.count + tableData.count)
            let count = UInt32(proto.parameters.count)
            tableData.append(UInt8(count & 0xFF))
            tableData.append(UInt8((count >> 8) & 0xFF))
            tableData.append(UInt8((count >> 16) & 0xFF))
            tableData.append(UInt8(count >> 24))
            for parameter in proto.parameters {
                let value = UInt16(parameter)
                tableData.append(UInt8(value & 0xFF))
                tableData.append(UInt8(value >> 8))
            }
        }

        var interfaceOffsets = [Int](repeating: 0, count: classes.count)
        for (classIndex, classSpec) in classes.enumerated() {
            guard !classSpec.interfaceTypeIndices.isEmpty else { continue }
            while (stringDataOff + stringData.count + tableData.count) % 4 != 0 {
                tableData.append(0)
            }
            interfaceOffsets[classIndex] = stringDataOff + stringData.count + tableData.count
            let count = UInt32(classSpec.interfaceTypeIndices.count)
            tableData.append(UInt8(count & 0xFF))
            tableData.append(UInt8((count >> 8) & 0xFF))
            tableData.append(UInt8((count >> 16) & 0xFF))
            tableData.append(UInt8(count >> 24))
            for interface in classSpec.interfaceTypeIndices {
                let value = UInt16(interface)
                tableData.append(UInt8(value & 0xFF))
                tableData.append(UInt8(value >> 8))
            }
        }

        struct CodeItemLayout {
            let offset: Int
            let methodIndex: Int
            let spec: MethodSpec
        }
        var codeLayouts: [CodeItemLayout] = []
        var codeCursor = 0
        for registered in classes.flatMap(\.methods) where registered.spec.hasCode {
            let method = registered.spec
            precondition((0...Int(UInt16.max)).contains(method.triesCount))
            codeLayouts.append(CodeItemLayout(
                offset: codeCursor,
                methodIndex: registered.methodIndex,
                spec: method
            ))
            codeCursor += 16 + method.insns.count * 2
            if method.triesCount > 0, method.insns.count % 2 == 1 { codeCursor += 2 }
            codeCursor += method.tryItems.count
            codeCursor = (codeCursor + 3) & ~3 // every code_item begins on a u32 boundary
        }
        let codeLayoutByMethodIndex = Dictionary(
            uniqueKeysWithValues: codeLayouts.map { ($0.methodIndex, $0) }
        )

        // class_data must encode ABSOLUTE code offsets; uleb width depends on
        // the values, so iterate all class_data blocks to a fixed point.
        func buildClassData(_ classSpec: ClassSpec, codeBaseGuess: Int) -> [UInt8] {
            let staticFields = classSpec.staticFields.sorted { $0.fieldIndex < $1.fieldIndex }
            let instanceFields = classSpec.instanceFields.sorted { $0.fieldIndex < $1.fieldIndex }
            let directMethods = classSpec.methods
                .filter { !$0.spec.isVirtual }
                .sorted { $0.methodIndex < $1.methodIndex }
            let virtualMethods = classSpec.methods
                .filter(\.spec.isVirtual)
                .sorted { $0.methodIndex < $1.methodIndex }
            var out: [UInt8] = []
            out.append(contentsOf: ULEB.encode(UInt64(staticFields.count)))
            out.append(contentsOf: ULEB.encode(UInt64(instanceFields.count)))
            out.append(contentsOf: ULEB.encode(UInt64(directMethods.count)))
            out.append(contentsOf: ULEB.encode(UInt64(virtualMethods.count)))

            func appendFields(_ fields: [RegisteredField], to output: inout [UInt8]) {
                var previousIndex = 0
                for (listIndex, field) in fields.enumerated() {
                    output.append(contentsOf: ULEB.encode(UInt64(
                        field.fieldIndex - (listIndex == 0 ? 0 : previousIndex)
                    )))
                    previousIndex = field.fieldIndex
                    output.append(contentsOf: ULEB.encode(UInt64(field.accessFlags)))
                }
            }
            appendFields(staticFields, to: &out)
            appendFields(instanceFields, to: &out)

            func appendMethods(_ methods: [RegisteredMethod], to output: inout [UInt8]) {
                var previousMethodIndex = 0
                for (listIndex, registered) in methods.enumerated() {
                    let methodIndex = registered.methodIndex
                    output.append(contentsOf: ULEB.encode(
                        UInt64(methodIndex - (listIndex == 0 ? 0 : previousMethodIndex))
                    ))
                    previousMethodIndex = methodIndex
                    output.append(contentsOf: ULEB.encode(UInt64(registered.spec.accessFlags)))
                    let codeOffset = codeLayoutByMethodIndex[methodIndex].map {
                        codeBaseGuess + $0.offset
                    } ?? 0
                    output.append(contentsOf: ULEB.encode(
                        UInt64(codeOffset)
                    ))
                }
            }
            appendMethods(directMethods, to: &out)
            appendMethods(virtualMethods, to: &out)
            return out
        }

        var guessedCodeBase = 0
        var classDataBlocks = classes.map { buildClassData($0, codeBaseGuess: guessedCodeBase) }
        let classDataBase = stringDataOff + stringData.count + tableData.count
        for _ in 0..<8 {
            classDataBlocks = classes.map { buildClassData($0, codeBaseGuess: guessedCodeBase) }
            let unalignedBase = classDataBase + classDataBlocks.reduce(0) { $0 + $1.count }
            let newBase = (unalignedBase + 3) & ~3
            if newBase == guessedCodeBase { break }
            guessedCodeBase = newBase
        }
        classDataBlocks = classes.map { buildClassData($0, codeBaseGuess: guessedCodeBase) }
        var classDataOffsets: [Int] = []
        var classDataCursor = classDataBase
        for block in classDataBlocks {
            classDataOffsets.append(classDataCursor)
            classDataCursor += block.count
        }
        let codeOff = guessedCodeBase
        let codePadding = codeOff - classDataCursor
        let fileSize = codeOff + codeCursor

        var out: [UInt8] = []
        out.reserveCapacity(fileSize)

        func u16(_ v: UInt16) { out.append(UInt8(v & 0xFF)); out.append(UInt8(v >> 8)) }
        func u32(_ v: UInt32) { u16(UInt16(v & 0xFFFF)); u16(UInt16(v >> 16)) }
        func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }

        // Header.
        out.append(contentsOf: Array(String(format: "dex\n%03d\0", version).utf8))
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
        u32(UInt32(classDefsSize)); u32(UInt32(classDefsOff))
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
        // class_defs are sorted by class_idx as required by the DEX format.
        for classIndex in classes.indices.sorted(by: {
            classes[$0].descriptorIdx < classes[$1].descriptorIdx
        }) {
            let classSpec = classes[classIndex]
            u32(UInt32(classSpec.descriptorIdx))
            u32(classSpec.accessFlags)
            u32(classSpec.superclassIdx >= 0 ? UInt32(classSpec.superclassIdx) : 0xFFFF_FFFF)
            u32(UInt32(interfaceOffsets[classIndex]))
            u32(0xFFFF_FFFF)
            u32(0)
            u32(UInt32(classDataOffsets[classIndex]))
            u32(0)
        }

        out.append(contentsOf: stringData)
        out.append(contentsOf: tableData)
        for block in classDataBlocks { out.append(contentsOf: block) }
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
    static func moveResultObject(_ reg: Int) -> [UInt16] { [0x0c | UInt16(reg << 8)] }
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
    static func invokeSuper(_ methodIdx: Int, _ regs: [Int]) -> [UInt16] {
        invokeKind(0x6f, methodIdx, regs)
    }
    static func invokeInterface(_ methodIdx: Int, _ regs: [Int]) -> [UInt16] {
        invokeKind(0x72, methodIdx, regs)
    }
    static func invokeSuperRange(_ methodIdx: Int, start: Int, count: Int) -> [UInt16] {
        invokeRangeKind(0x75, methodIdx, start: start, count: count)
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
    static func invokeRangeKind(
        _ opcode: UInt8,
        _ methodIdx: Int,
        start: Int,
        count: Int
    ) -> [UInt16] {
        precondition((0...Int(UInt8.max)).contains(count))
        precondition((0...Int(UInt16.max)).contains(start))
        return [
            UInt16(opcode) | UInt16(count << 8),
            UInt16(methodIdx),
            UInt16(start),
        ]
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
