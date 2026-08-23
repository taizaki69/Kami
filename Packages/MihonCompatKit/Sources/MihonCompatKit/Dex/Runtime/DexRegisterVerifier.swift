import Foundation

/// Bounded category-level register verification for an already structurally
/// verified DEX method.
///
/// Dalvik registers do not carry runtime tags. The verifier must therefore
/// prove that every reachable read has a compatible category before execution;
/// otherwise malformed bytecode could exploit the interpreter's defensive
/// zero/null fallbacks. This pass tracks category-1 primitives, wide pairs,
/// references, the verifier-polymorphic zero constant, undefined values, and
/// merge conflicts. Exact resolved-class assignability is deliberately left to
/// the reference-hierarchy verifier milestone.
enum DexRegisterVerifier {
    static let maximumDataflowStates = 250_000
    static let maximumDataflowCells = 8_000_000
    static let maximumDataflowMerges = 8_000_000

    private enum RegisterType: Equatable, CustomStringConvertible {
        case undefined
        case conflict
        case zero
        case category1
        case wideLow
        case wideHigh
        case reference(String?)

        var description: String {
            switch self {
            case .undefined: return "undefined"
            case .conflict: return "conflict"
            case .zero: return "zero"
            case .category1: return "category-1"
            case .wideLow: return "wide-low"
            case .wideHigh: return "wide-high"
            case let .reference(descriptor): return descriptor ?? "reference"
            }
        }
    }

    private struct RegisterLine: Equatable {
        var values: [RegisterType]

        init(count: Int) {
            values = [RegisterType](repeating: .undefined, count: count)
        }

        mutating func write(_ type: RegisterType, to register: Int) {
            invalidateWidePair(containing: register)
            values[register] = type
        }

        mutating func writeWide(to register: Int) {
            invalidateWidePair(containing: register)
            invalidateWidePair(containing: register + 1)
            values[register] = .wideLow
            values[register + 1] = .wideHigh
        }

        private mutating func invalidateWidePair(containing register: Int) {
            guard register >= 0, register < values.count else { return }
            if values[register] == .wideLow,
               register + 1 < values.count,
               values[register + 1] == .wideHigh {
                values[register + 1] = .undefined
            } else if values[register] == .wideHigh,
                      register > 0,
                      values[register - 1] == .wideLow {
                values[register - 1] = .undefined
            }
        }

        mutating func merge(_ incoming: RegisterLine) -> Bool {
            var changed = false
            for index in values.indices {
                let merged = DexRegisterVerifier.merge(values[index], incoming.values[index])
                if merged != values[index] {
                    values[index] = merged
                    changed = true
                }
            }
            for index in values.indices {
                switch values[index] {
                case .wideLow where index + 1 >= values.count || values[index + 1] != .wideHigh:
                    values[index] = .conflict
                    changed = true
                case .wideHigh where index == 0 || values[index - 1] != .wideLow:
                    values[index] = .conflict
                    changed = true
                default:
                    break
                }
            }
            return changed
        }
    }

    static func verify(
        code: DexFile.CodeItem,
        method: DexFile.EncodedMethod,
        dex: DexFile,
        units: [UInt16],
        instructions: [DexCodeVerifier.InstructionInfo],
        instructionStarts: Set<Int>,
        tryBlocks: [DexTryBlock],
        context: String
    ) throws {
        let registerCount = Int(code.registersSize)
        guard instructions.count <= maximumDataflowStates else {
            throw VMError.verify(
                "register dataflow for \(context) has \(instructions.count) instructions; "
                    + "limit is \(maximumDataflowStates)"
            )
        }
        let (cellCount, cellOverflow) = instructions.count.multipliedReportingOverflow(
            by: max(registerCount, 1)
        )
        guard !cellOverflow, cellCount <= maximumDataflowCells else {
            throw VMError.verify(
                "register dataflow for \(context) needs \(cellOverflow ? Int.max : cellCount) cells; "
                    + "limit is \(maximumDataflowCells)"
            )
        }

        let byAddress = Dictionary(uniqueKeysWithValues: instructions.map { ($0.address, $0) })
        let byEndAddress = Dictionary(uniqueKeysWithValues: instructions.map {
            ($0.address + $0.width, $0)
        })
        try validateStaticOperands(
            code: code,
            dex: dex,
            units: units,
            instructions: instructions,
            registerCount: registerCount,
            context: context
        )

        var entry = RegisterLine(count: registerCount)
        try seedParameters(
            line: &entry,
            code: code,
            method: method,
            dex: dex,
            context: context
        )

        var incoming: [Int: RegisterLine] = [0: entry]
        var worklist = [0]
        var queued: Set<Int> = [0]
        var cursor = 0
        var mergeCount = 0

        var exceptionSuccessors: [Int: [Int]] = [:]
        var tryIndex = 0
        for instruction in instructions {
            while tryIndex < tryBlocks.count,
                  instruction.address >= tryBlocks[tryIndex].endAddress {
                tryIndex += 1
            }
            guard tryIndex < tryBlocks.count,
                  instruction.address >= tryBlocks[tryIndex].startAddress,
                  instruction.address < tryBlocks[tryIndex].endAddress,
                  mayThrow(instruction.opcode) else { continue }
            exceptionSuccessors[instruction.address] = Array(
                Set(tryBlocks[tryIndex].handlers.map(\.address))
            ).sorted()
        }

        func merge(
            _ line: RegisterLine,
            into address: Int,
            incoming: inout [Int: RegisterLine],
            worklist: inout [Int],
            queued: inout Set<Int>,
            mergeCount: inout Int
        ) throws {
            guard instructionStarts.contains(address) else {
                throw VMError.verify("register flow targets non-instruction pc \(address) in \(context)")
            }
            mergeCount += 1
            guard mergeCount <= maximumDataflowMerges else {
                throw VMError.verify(
                    "register dataflow for \(context) exceeds \(maximumDataflowMerges) merges"
                )
            }
            let changed: Bool
            if var existing = incoming[address] {
                changed = existing.merge(line)
                if changed { incoming[address] = existing }
            } else {
                incoming[address] = line
                changed = true
            }
            if changed, queued.insert(address).inserted {
                worklist.append(address)
            }
        }

        while cursor < worklist.count {
            let address = worklist[cursor]
            cursor += 1
            queued.remove(address)
            guard let instruction = byAddress[address], let input = incoming[address] else {
                throw VMError.verify("missing register state for pc \(address) in \(context)")
            }

            for handler in exceptionSuccessors[address] ?? [] {
                try merge(
                    input,
                    into: handler,
                    incoming: &incoming,
                    worklist: &worklist,
                    queued: &queued,
                    mergeCount: &mergeCount
                )
            }

            var output = input
            try transfer(
                instruction,
                line: &output,
                method: method,
                dex: dex,
                units: units,
                instructionEndingAt: byEndAddress,
                context: context
            )
            for successor in normalSuccessors(
                of: instruction,
                units: units,
                instructionStarts: instructionStarts
            ) {
                try merge(
                    output,
                    into: successor,
                    incoming: &incoming,
                    worklist: &worklist,
                    queued: &queued,
                    mergeCount: &mergeCount
                )
            }
        }
    }

    // MARK: - Entry state and lattice

    private static func seedParameters(
        line: inout RegisterLine,
        code: DexFile.CodeItem,
        method: DexFile.EncodedMethod,
        dex: DexFile,
        context: String
    ) throws {
        let reference = dex.methodIds[method.methodIndex]
        let hasReceiver = method.accessFlags & 0x8 == 0
        let expectedWords = reference.prototype.parameterWordCount + (hasReceiver ? 1 : 0)
        guard expectedWords == Int(code.insSize) else {
            throw VMError.verify(
                "ins_size \(code.insSize) does not match \(expectedWords) prototype words for \(context)"
            )
        }
        guard expectedWords <= line.values.count else {
            throw VMError.verify("incoming registers exceed register file for \(context)")
        }

        var register = line.values.count - expectedWords
        if hasReceiver {
            line.write(.reference(reference.declaringClass), to: register)
            register += 1
        }
        for descriptor in reference.prototype.parameters {
            try write(descriptor: descriptor, to: register, line: &line, context: context)
            register += wordCount(for: descriptor)
        }
    }

    private static func merge(_ lhs: RegisterType, _ rhs: RegisterType) -> RegisterType {
        if lhs == rhs { return lhs }
        if lhs == .conflict || rhs == .conflict { return .conflict }
        switch (lhs, rhs) {
        case (.zero, .category1), (.category1, .zero):
            return .category1
        case let (.zero, .reference(descriptor)), let (.reference(descriptor), .zero):
            return .reference(descriptor)
        case (.reference, .reference):
            return .reference(nil)
        default:
            return .conflict
        }
    }

    private static func wordCount(for descriptor: String) -> Int {
        descriptor == "J" || descriptor == "D" ? 2 : 1
    }

    private static func descriptorType(_ descriptor: String, context: String) throws -> RegisterType {
        switch descriptor {
        case "Z", "B", "C", "S", "I", "F": return .category1
        case "J", "D": return .wideLow
        case let value where isReferenceDescriptor(value): return .reference(value)
        default: throw VMError.verify("invalid value descriptor \(descriptor) in \(context)")
        }
    }

    private static func write(
        descriptor: String,
        to register: Int,
        line: inout RegisterLine,
        context: String
    ) throws {
        let type = try descriptorType(descriptor, context: context)
        if type == .wideLow {
            line.writeWide(to: register)
        } else {
            line.write(type, to: register)
        }
    }

    private static func isReferenceDescriptor(_ descriptor: String) -> Bool {
        (descriptor.hasPrefix("L") && descriptor.hasSuffix(";")) || descriptor.hasPrefix("[")
    }

    // MARK: - Static operand bounds

    private static func validateStaticOperands(
        code: DexFile.CodeItem,
        dex: DexFile,
        units: [UInt16],
        instructions: [DexCodeVerifier.InstructionInfo],
        registerCount: Int,
        context: String
    ) throws {
        func register(_ index: Int, width: Int = 1, at address: Int) throws {
            guard index >= 0, width > 0, index <= registerCount - width else {
                let suffix = width == 2 ? "..v\(index + 1)" : ""
                throw VMError.verify(
                    "register v\(index)\(suffix) at pc \(address) is outside \(registerCount)-register file in \(context)"
                )
            }
        }
        func index(_ value: Int, count: Int, kind: String, at address: Int) throws {
            guard value >= 0, value < count else {
                throw VMError.verify("\(kind) index \(value) at pc \(address) is invalid in \(context)")
            }
        }

        for instruction in instructions {
            let pc = instruction.address
            let op = instruction.opcode
            let first = units[pc]
            switch op {
            case 0x00, 0x0e, 0x28...0x2a:
                break
            case 0x01, 0x07, 0x7b, 0x7c, 0x7f, 0x82, 0x87, 0x8d...0x8f:
                try register(Int(first >> 8 & 0x0f), at: pc)
                try register(Int(first >> 12), at: pc)
            case 0x04, 0x7d, 0x7e, 0x80:
                try register(Int(first >> 8 & 0x0f), width: 2, at: pc)
                try register(Int(first >> 12), width: 2, at: pc)
            case 0x81, 0x83, 0x88, 0x89:
                try register(Int(first >> 8 & 0x0f), width: 2, at: pc)
                try register(Int(first >> 12), at: pc)
            case 0x84, 0x85, 0x8a, 0x8c:
                try register(Int(first >> 8 & 0x0f), at: pc)
                try register(Int(first >> 12), width: 2, at: pc)
            case 0x86, 0x8b:
                try register(Int(first >> 8 & 0x0f), width: 2, at: pc)
                try register(Int(first >> 12), width: 2, at: pc)
            case 0x02, 0x08:
                try register(Int(first >> 8), at: pc)
                try register(Int(units[pc + 1]), at: pc)
            case 0x05:
                try register(Int(first >> 8), width: 2, at: pc)
                try register(Int(units[pc + 1]), width: 2, at: pc)
            case 0x03, 0x09:
                try register(Int(units[pc + 1]), at: pc)
                try register(Int(units[pc + 2]), at: pc)
            case 0x06:
                try register(Int(units[pc + 1]), width: 2, at: pc)
                try register(Int(units[pc + 2]), width: 2, at: pc)
            case 0x0a, 0x0c, 0x0d, 0x0f, 0x11, 0x13...0x15, 0x1a...0x1f,
                 0x22, 0x26, 0x27, 0x2b, 0x2c, 0x38...0x3d,
                 0x60, 0x62...0x67, 0x69...0x6d, 0xfe, 0xff:
                try register(Int(first >> 8), at: pc)
            case 0x12:
                try register(Int(first >> 8 & 0x0f), at: pc)
            case 0x0b, 0x10, 0x16...0x19, 0x61, 0x68:
                try register(Int(first >> 8), width: 2, at: pc)
            case 0x20, 0x21, 0x23, 0x52, 0x54...0x59, 0x5b...0x5f:
                try register(Int(first >> 8 & 0x0f), at: pc)
                try register(Int(first >> 12), at: pc)
            case 0x53, 0x5a:
                try register(Int(first >> 8 & 0x0f), width: 2, at: pc)
                try register(Int(first >> 12), at: pc)
            case 0x24, 0x6e...0x72, 0xfc:
                let count = Int(first >> 12)
                guard count <= 5 else {
                    throw VMError.verify("register list count \(count) at pc \(pc) exceeds 5 in \(context)")
                }
                var registers = [
                    Int(units[pc + 2] & 0x0f), Int(units[pc + 2] >> 4 & 0x0f),
                    Int(units[pc + 2] >> 8 & 0x0f), Int(units[pc + 2] >> 12),
                ]
                if count == 5 { registers.append(Int(first >> 8 & 0x0f)) }
                for value in registers.prefix(count) { try register(value, at: pc) }
                if (0x6e...0x72).contains(op) {
                    try index(Int(units[pc + 1]), count: dex.methodIds.count, kind: "method", at: pc)
                }
                if op != 0x24, count > Int(code.outsSize) {
                    throw VMError.verify("invoke at pc \(pc) needs \(count) outs words in \(context)")
                }
            case 0x25, 0x74...0x78, 0xfd:
                let count = Int(first >> 8)
                let start = Int(units[pc + 2])
                if count > 0 { try register(start, width: count, at: pc) }
                if (0x74...0x78).contains(op) {
                    try index(Int(units[pc + 1]), count: dex.methodIds.count, kind: "method", at: pc)
                }
                if op != 0x25, count > Int(code.outsSize) {
                    throw VMError.verify("invoke/range at pc \(pc) needs \(count) outs words in \(context)")
                }
            case 0x2d, 0x2e:
                try register(Int(first >> 8), at: pc)
                try register(Int(units[pc + 1] & 0xff), at: pc)
                try register(Int(units[pc + 1] >> 8), at: pc)
            case 0x2f...0x31:
                try register(Int(first >> 8), at: pc)
                try register(Int(units[pc + 1] & 0xff), width: 2, at: pc)
                try register(Int(units[pc + 1] >> 8), width: 2, at: pc)
            case 0x32...0x37:
                try register(Int(first >> 8 & 0x0f), at: pc)
                try register(Int(first >> 12), at: pc)
            case 0x44, 0x46...0x4a, 0x4b, 0x4d...0x51, 0x90...0x9a, 0xa6...0xaa:
                try register(Int(first >> 8), at: pc)
                try register(Int(units[pc + 1] & 0xff), at: pc)
                try register(Int(units[pc + 1] >> 8), at: pc)
            case 0x45, 0x4c, 0x9b...0xa2, 0xab...0xaf:
                try register(Int(first >> 8), width: 2, at: pc)
                try register(Int(units[pc + 1] & 0xff), width: op >= 0x90 ? 2 : 1, at: pc)
                try register(Int(units[pc + 1] >> 8), width: op >= 0x90 ? 2 : 1, at: pc)
            case 0xa3...0xa5:
                try register(Int(first >> 8), width: 2, at: pc)
                try register(Int(units[pc + 1] & 0xff), width: 2, at: pc)
                try register(Int(units[pc + 1] >> 8), at: pc)
            case 0xb0...0xcf:
                let wide = isWideBinaryOpcode(UInt8(op - 0x20))
                try register(Int(first >> 8 & 0x0f), width: wide ? 2 : 1, at: pc)
                let rhsWide = wide && !isWideShiftOpcode(UInt8(op - 0x20))
                try register(Int(first >> 12), width: rhsWide ? 2 : 1, at: pc)
            case 0xd0...0xd7:
                try register(Int(first >> 8 & 0x0f), at: pc)
                try register(Int(first >> 12), at: pc)
            case 0xd8...0xe2:
                try register(Int(first >> 8), at: pc)
                try register(Int(units[pc + 1] & 0xff), at: pc)
            case 0xfa:
                let count = Int(first >> 12)
                guard count <= 5 else {
                    throw VMError.verify("invoke-polymorphic count \(count) at pc \(pc) exceeds 5 in \(context)")
                }
                var registers = [
                    Int(units[pc + 2] & 0x0f), Int(units[pc + 2] >> 4 & 0x0f),
                    Int(units[pc + 2] >> 8 & 0x0f), Int(units[pc + 2] >> 12),
                ]
                if count == 5 { registers.append(Int(first >> 8 & 0x0f)) }
                for value in registers.prefix(count) { try register(value, at: pc) }
                guard count <= Int(code.outsSize) else {
                    throw VMError.verify(
                        "invoke-polymorphic at pc \(pc) needs \(count) outs words in \(context)"
                    )
                }
            case 0xfb:
                let count = Int(first >> 8)
                if count > 0 { try register(Int(units[pc + 2]), width: count, at: pc) }
                guard count <= Int(code.outsSize) else {
                    throw VMError.verify(
                        "invoke-polymorphic/range at pc \(pc) needs \(count) outs words in \(context)"
                    )
                }
            default:
                throw VMError.verify(
                    "register verifier has no operand format for opcode 0x\(String(op, radix: 16)) at pc \(pc) in \(context)"
                )
            }

            switch op {
            case 0x1a:
                try index(Int(units[pc + 1]), count: dex.strings.count, kind: "string", at: pc)
            case 0x1b:
                let value = Int(UInt32(units[pc + 1]) | UInt32(units[pc + 2]) << 16)
                try index(value, count: dex.strings.count, kind: "string", at: pc)
            case 0x1c, 0x1f, 0x20, 0x22...0x25:
                try index(Int(units[pc + 1]), count: dex.typeDescriptors.count, kind: "type", at: pc)
            case 0x52...0x6d:
                try index(Int(units[pc + 1]), count: dex.fieldIds.count, kind: "field", at: pc)
            case 0xfa, 0xfb:
                try index(Int(units[pc + 1]), count: dex.methodIds.count, kind: "method", at: pc)
                try index(Int(units[pc + 3]), count: dex.prototypes.count, kind: "prototype", at: pc)
            case 0xff:
                try index(Int(units[pc + 1]), count: dex.prototypes.count, kind: "prototype", at: pc)
            default:
                break
            }
        }
    }

    // MARK: - Transfer semantics

    private static func transfer(
        _ instruction: DexCodeVerifier.InstructionInfo,
        line: inout RegisterLine,
        method: DexFile.EncodedMethod,
        dex: DexFile,
        units: [UInt16],
        instructionEndingAt: [Int: DexCodeVerifier.InstructionInfo],
        context: String
    ) throws {
        let pc = instruction.address
        let op = instruction.opcode
        let first = units[pc]

        func category1(_ register: Int, _ label: String) throws {
            guard line.values[register] == .category1 || line.values[register] == .zero else {
                throw typeError(register, expected: "category-1", actual: line.values[register], label: label, pc: pc, context: context)
            }
        }
        func wide(_ register: Int, _ label: String) throws {
            guard register + 1 < line.values.count,
                  line.values[register] == .wideLow,
                  line.values[register + 1] == .wideHigh else {
                throw typeError(register, expected: "wide pair", actual: line.values[register], label: label, pc: pc, context: context)
            }
        }
        func reference(_ register: Int, _ label: String) throws {
            switch line.values[register] {
            case .reference, .zero: return
            default:
                throw typeError(register, expected: "reference", actual: line.values[register], label: label, pc: pc, context: context)
            }
        }
        func compatible(_ register: Int, descriptor: String, label: String) throws {
            let expected = try descriptorType(descriptor, context: context)
            switch expected {
            case .category1: try category1(register, label)
            case .wideLow: try wide(register, label)
            case .reference: try reference(register, label)
            default: preconditionFailure("descriptorType returned non-value type")
            }
        }

        switch op {
        case 0x00:
            return
        case 0x01, 0x02, 0x03:
            let (destination, source) = moveRegisters(op: op, first: first, units: units, pc: pc)
            try category1(source, "move source")
            line.write(line.values[source], to: destination)
        case 0x04, 0x05, 0x06:
            let (destination, source) = moveRegisters(op: op, first: first, units: units, pc: pc)
            try wide(source, "move-wide source")
            line.writeWide(to: destination)
        case 0x07, 0x08, 0x09:
            let (destination, source) = moveRegisters(op: op, first: first, units: units, pc: pc)
            try reference(source, "move-object source")
            line.write(line.values[source], to: destination)
        case 0x0a...0x0c:
            guard let producer = instructionEndingAt[pc] else {
                throw VMError.verify("move-result at pc \(pc) has no producer in \(context)")
            }
            let produced = try resultDescriptor(
                producer: producer,
                dex: dex,
                units: units,
                context: context
            )
            guard produced != "V" else {
                throw VMError.verify("move-result at pc \(pc) follows a void producer in \(context)")
            }
            let destination = Int(first >> 8)
            let producedType = try descriptorType(produced, context: context)
            let matches = (op == 0x0a && producedType == .category1)
                || (op == 0x0b && producedType == .wideLow)
                || (op == 0x0c && {
                    if case .reference = producedType { return true }
                    return false
                }())
            guard matches else {
                throw VMError.verify(
                    "move-result opcode 0x\(String(op, radix: 16)) at pc \(pc) does not match result \(produced) in \(context)"
                )
            }
            try write(descriptor: produced, to: destination, line: &line, context: context)
        case 0x0d:
            line.write(.reference("Ljava/lang/Throwable;"), to: Int(first >> 8))
        case 0x0e:
            guard dex.methodIds[method.methodIndex].prototype.returnType == "V" else {
                throw VMError.verify("return-void at pc \(pc) in non-void \(context)")
            }
        case 0x0f, 0x10, 0x11:
            let descriptor = dex.methodIds[method.methodIndex].prototype.returnType
            guard descriptor != "V" else {
                throw VMError.verify("value return at pc \(pc) in void \(context)")
            }
            let expected = try descriptorType(descriptor, context: context)
            let opcodeMatches = (op == 0x0f && expected == .category1)
                || (op == 0x10 && expected == .wideLow)
                || (op == 0x11 && {
                    if case .reference = expected { return true }
                    return false
                }())
            guard opcodeMatches else {
                throw VMError.verify(
                    "return opcode 0x\(String(op, radix: 16)) at pc \(pc) does not match \(descriptor) in \(context)"
                )
            }
            try compatible(Int(first >> 8), descriptor: descriptor, label: "return value")
        case 0x12:
            let nibble = Int8(bitPattern: UInt8(first >> 12 & 0x0f))
            let literal = (nibble << 4) >> 4
            line.write(literal == 0 ? .zero : .category1, to: Int(first >> 8 & 0x0f))
        case 0x13...0x15:
            let isZero: Bool
            if op == 0x13 { isZero = units[pc + 1] == 0 }
            else if op == 0x14 { isZero = units[pc + 1] == 0 && units[pc + 2] == 0 }
            else { isZero = units[pc + 1] == 0 }
            line.write(isZero ? .zero : .category1, to: Int(first >> 8))
        case 0x16...0x19:
            line.writeWide(to: Int(first >> 8))
        case 0x1a, 0x1b:
            line.write(.reference("Ljava/lang/String;"), to: Int(first >> 8))
        case 0x1c:
            line.write(.reference("Ljava/lang/Class;"), to: Int(first >> 8))
        case 0x1d, 0x1e:
            try reference(Int(first >> 8), "monitor operand")
        case 0x1f:
            let register = Int(first >> 8)
            try reference(register, "check-cast operand")
            let descriptor = dex.typeDescriptors[Int(units[pc + 1])]
            guard isReferenceDescriptor(descriptor) else {
                throw VMError.verify("check-cast at pc \(pc) targets non-reference \(descriptor) in \(context)")
            }
            line.write(.reference(descriptor), to: register)
        case 0x20:
            let source = Int(first >> 12)
            try reference(source, "instance-of operand")
            let descriptor = dex.typeDescriptors[Int(units[pc + 1])]
            guard isReferenceDescriptor(descriptor) else {
                throw VMError.verify("instance-of at pc \(pc) targets non-reference \(descriptor) in \(context)")
            }
            line.write(.category1, to: Int(first >> 8 & 0x0f))
        case 0x21:
            let source = Int(first >> 12)
            try arrayReference(source, line: line, label: "array-length operand", pc: pc, context: context)
            line.write(.category1, to: Int(first >> 8 & 0x0f))
        case 0x22:
            let descriptor = dex.typeDescriptors[Int(units[pc + 1])]
            guard descriptor.hasPrefix("L"), descriptor.hasSuffix(";") else {
                throw VMError.verify("new-instance at pc \(pc) targets non-class \(descriptor) in \(context)")
            }
            line.write(.reference(descriptor), to: Int(first >> 8))
        case 0x23:
            try category1(Int(first >> 12), "new-array size")
            let descriptor = dex.typeDescriptors[Int(units[pc + 1])]
            guard descriptor.hasPrefix("[") else {
                throw VMError.verify("new-array at pc \(pc) targets non-array \(descriptor) in \(context)")
            }
            line.write(.reference(descriptor), to: Int(first >> 8 & 0x0f))
        case 0x24, 0x25:
            let descriptor = dex.typeDescriptors[Int(units[pc + 1])]
            guard descriptor.hasPrefix("[") else {
                throw VMError.verify("filled-new-array at pc \(pc) targets non-array \(descriptor) in \(context)")
            }
            let component = String(descriptor.dropFirst())
            guard wordCount(for: component) == 1 else {
                throw VMError.verify("filled-new-array at pc \(pc) has wide component \(component) in \(context)")
            }
            for register in registerList(op: op, first: first, units: units, pc: pc) {
                try compatible(register, descriptor: component, label: "filled-new-array element")
            }
        case 0x26:
            let register = Int(first >> 8)
            try arrayReference(register, line: line, label: "fill-array-data operand", pc: pc, context: context)
            if case let .reference(descriptor?) = line.values[register] {
                guard let expectedWidth = primitiveArrayElementWidth(descriptor) else {
                    throw VMError.verify("fill-array-data at pc \(pc) uses non-primitive array \(descriptor) in \(context)")
                }
                let payload = pc + Int(signed32(units[pc + 1], units[pc + 2]))
                let actualWidth = Int(units[payload + 1])
                guard expectedWidth == actualWidth else {
                    throw VMError.verify(
                        "fill-array-data at pc \(pc) has width \(actualWidth), expected \(expectedWidth) for \(descriptor) in \(context)"
                    )
                }
            }
        case 0x27:
            try reference(Int(first >> 8), "throw operand")
        case 0x28...0x2a:
            break
        case 0x2b, 0x2c:
            try category1(Int(first >> 8), "switch key")
        case 0x2d, 0x2e:
            try category1(Int(units[pc + 1] & 0xff), "float compare lhs")
            try category1(Int(units[pc + 1] >> 8), "float compare rhs")
            line.write(.category1, to: Int(first >> 8))
        case 0x2f...0x31:
            try wide(Int(units[pc + 1] & 0xff), "wide compare lhs")
            try wide(Int(units[pc + 1] >> 8), "wide compare rhs")
            line.write(.category1, to: Int(first >> 8))
        case 0x32, 0x33:
            let lhs = Int(first >> 8 & 0x0f)
            let rhs = Int(first >> 12)
            guard equalityComparable(line.values[lhs], line.values[rhs]) else {
                throw VMError.verify(
                    "if equality at pc \(pc) compares \(line.values[lhs]) with \(line.values[rhs]) in \(context)"
                )
            }
        case 0x34...0x37:
            try category1(Int(first >> 8 & 0x0f), "if lhs")
            try category1(Int(first >> 12), "if rhs")
        case 0x38, 0x39:
            let register = Int(first >> 8)
            guard isCategory1(line.values[register]) || isReference(line.values[register]) else {
                throw typeError(register, expected: "category-1 or reference", actual: line.values[register], label: "if operand", pc: pc, context: context)
            }
        case 0x3a...0x3d:
            try category1(Int(first >> 8), "if operand")
        case 0x44...0x51:
            try transferArrayAccess(op: op, first: first, units: units, pc: pc, line: &line, context: context)
        case 0x52...0x6d:
            try transferFieldAccess(op: op, first: first, units: units, pc: pc, line: &line, dex: dex, context: context)
        case 0x6e...0x72, 0x74...0x78:
            try verifyInvocation(op: op, first: first, units: units, pc: pc, line: line, dex: dex, context: context)
        case 0x7b...0x8f:
            try transferUnary(op: op, first: first, line: &line, pc: pc, context: context)
        case 0x90...0xcf:
            try transferBinary(op: op, first: first, units: units, pc: pc, line: &line, context: context)
        case 0xd0...0xe2:
            let destination: Int
            let source: Int
            if op <= 0xd7 {
                destination = Int(first >> 8 & 0x0f)
                source = Int(first >> 12)
            } else {
                destination = Int(first >> 8)
                source = Int(units[pc + 1] & 0xff)
            }
            try category1(source, "literal operation source")
            line.write(.category1, to: destination)
        case 0xfa...0xfd:
            // These formats are structurally/register-bounds checked, but the
            // interpreter does not execute them yet. Keep any eventual
            // move-result unusable instead of inventing a call-site type.
            break
        case 0xfe, 0xff:
            line.write(.reference(nil), to: Int(first >> 8))
        default:
            throw VMError.verify(
                "register verifier has no transfer rule for opcode 0x\(String(op, radix: 16)) at pc \(pc) in \(context)"
            )
        }
    }

    private static func typeError(
        _ register: Int,
        expected: String,
        actual: RegisterType,
        label: String,
        pc: Int,
        context: String
    ) -> VMError {
        .verify(
            "\(label) v\(register) at pc \(pc) has \(actual), expected \(expected) in \(context)"
        )
    }

    private static func moveRegisters(
        op: UInt8,
        first: UInt16,
        units: [UInt16],
        pc: Int
    ) -> (Int, Int) {
        switch op {
        case 0x01, 0x04, 0x07:
            return (Int(first >> 8 & 0x0f), Int(first >> 12))
        case 0x02, 0x05, 0x08:
            return (Int(first >> 8), Int(units[pc + 1]))
        default:
            return (Int(units[pc + 1]), Int(units[pc + 2]))
        }
    }

    private static func resultDescriptor(
        producer: DexCodeVerifier.InstructionInfo,
        dex: DexFile,
        units: [UInt16],
        context: String
    ) throws -> String {
        switch producer.opcode {
        case 0x24, 0x25:
            return dex.typeDescriptors[Int(units[producer.address + 1])]
        case 0x6e...0x72, 0x74...0x78:
            let methodIndex = Int(units[producer.address + 1])
            guard methodIndex < dex.methodIds.count else {
                throw VMError.verify("invalid result method index at pc \(producer.address) in \(context)")
            }
            return dex.methodIds[methodIndex].prototype.returnType
        case 0xfa, 0xfb:
            let prototypeIndex = Int(units[producer.address + 3])
            guard prototypeIndex < dex.prototypes.count else {
                throw VMError.verify(
                    "invalid result prototype index at pc \(producer.address) in \(context)"
                )
            }
            return dex.prototypes[prototypeIndex].returnType
        default:
            throw VMError.verify(
                "result type for opcode 0x\(String(producer.opcode, radix: 16)) is unavailable at pc \(producer.address) in \(context)"
            )
        }
    }

    private static func registerList(
        op: UInt8,
        first: UInt16,
        units: [UInt16],
        pc: Int
    ) -> [Int] {
        if op == 0x25 || (0x74...0x78).contains(op) || op == 0xfb || op == 0xfd {
            let count = Int(first >> 8)
            let start = Int(units[pc + 2])
            return Array(start..<(start + count))
        }
        let count = Int(first >> 12)
        var result = [
            Int(units[pc + 2] & 0x0f), Int(units[pc + 2] >> 4 & 0x0f),
            Int(units[pc + 2] >> 8 & 0x0f), Int(units[pc + 2] >> 12),
        ]
        if count == 5 { result.append(Int(first >> 8 & 0x0f)) }
        return Array(result.prefix(count))
    }

    private static func verifyInvocation(
        op: UInt8,
        first: UInt16,
        units: [UInt16],
        pc: Int,
        line: RegisterLine,
        dex: DexFile,
        context: String
    ) throws {
        let methodIndex = Int(units[pc + 1])
        let reference = dex.methodIds[methodIndex]
        let registers = registerList(op: op, first: first, units: units, pc: pc)
        let isStatic = op == 0x71 || op == 0x77
        let expectedWords = reference.prototype.parameterWordCount + (isStatic ? 0 : 1)
        guard registers.count == expectedWords else {
            throw VMError.verify(
                "\(reference.signature) expects \(expectedWords) invoke register words; "
                    + "instruction at pc \(pc) supplies \(registers.count) in \(context)"
            )
        }

        func requireReference(_ register: Int, label: String) throws {
            guard isReference(line.values[register]) else {
                throw typeError(register, expected: "reference", actual: line.values[register], label: label, pc: pc, context: context)
            }
        }
        func requireDescriptor(_ register: Int, descriptor: String, label: String) throws {
            let expected = try descriptorType(descriptor, context: context)
            switch expected {
            case .category1:
                guard isCategory1(line.values[register]) else {
                    throw typeError(register, expected: "category-1", actual: line.values[register], label: label, pc: pc, context: context)
                }
            case .wideLow:
                guard register + 1 < line.values.count,
                      line.values[register] == .wideLow,
                      line.values[register + 1] == .wideHigh else {
                    throw typeError(register, expected: "wide pair", actual: line.values[register], label: label, pc: pc, context: context)
                }
            case .reference:
                try requireReference(register, label: label)
            default:
                preconditionFailure("non-value descriptor")
            }
        }

        var word = 0
        if !isStatic {
            try requireReference(registers[0], label: "invoke receiver")
            word = 1
        }
        for (argument, descriptor) in reference.prototype.parameters.enumerated() {
            let register = registers[word]
            try requireDescriptor(register, descriptor: descriptor, label: "invoke argument \(argument)")
            if wordCount(for: descriptor) == 2 {
                guard word + 1 < registers.count, registers[word + 1] == register + 1 else {
                    throw VMError.verify(
                        "wide invoke argument \(argument) at pc \(pc) is not an adjacent register pair in \(context)"
                    )
                }
            }
            word += wordCount(for: descriptor)
        }
    }

    private static func transferFieldAccess(
        op: UInt8,
        first: UInt16,
        units: [UInt16],
        pc: Int,
        line: inout RegisterLine,
        dex: DexFile,
        context: String
    ) throws {
        let field = dex.fieldIds[Int(units[pc + 1])]
        let isInstance = op <= 0x5f
        let isGet = (0x52...0x58).contains(op) || (0x60...0x66).contains(op)
        let register = isInstance ? Int(first >> 8 & 0x0f) : Int(first >> 8)
        if isInstance {
            let receiver = Int(first >> 12)
            guard isReference(line.values[receiver]) else {
                throw typeError(receiver, expected: "reference", actual: line.values[receiver], label: "field receiver", pc: pc, context: context)
            }
        }
        let opcodeCategory = fieldCategory(for: op)
        let descriptorCategory = try descriptorType(field.type, context: context)
        guard sameStorageCategory(opcodeCategory, descriptorCategory) else {
            throw VMError.verify(
                "field opcode 0x\(String(op, radix: 16)) at pc \(pc) does not match \(field.type) in \(context)"
            )
        }
        if isGet {
            try write(descriptor: field.type, to: register, line: &line, context: context)
        } else {
            try require(line: line, register: register, descriptor: field.type, label: "field value", pc: pc, context: context)
        }
    }

    private static func fieldCategory(for opcode: UInt8) -> RegisterType {
        switch opcode {
        case 0x53, 0x5a, 0x61, 0x68: return .wideLow
        case 0x54, 0x5b, 0x62, 0x69: return .reference(nil)
        default: return .category1
        }
    }

    private static func sameStorageCategory(_ lhs: RegisterType, _ rhs: RegisterType) -> Bool {
        switch (lhs, rhs) {
        case (.category1, .category1), (.wideLow, .wideLow), (.reference, .reference): return true
        default: return false
        }
    }

    private static func transferArrayAccess(
        op: UInt8,
        first: UInt16,
        units: [UInt16],
        pc: Int,
        line: inout RegisterLine,
        context: String
    ) throws {
        let valueRegister = Int(first >> 8)
        let arrayRegister = Int(units[pc + 1] & 0xff)
        let indexRegister = Int(units[pc + 1] >> 8)
        try arrayReference(arrayRegister, line: line, label: "array operand", pc: pc, context: context)
        try requireCategory1(line: line, register: indexRegister, label: "array index", pc: pc, context: context)

        let descriptor: String?
        if case let .reference(value) = line.values[arrayRegister] { descriptor = value }
        else { descriptor = nil }
        let component = descriptor.flatMap { $0.hasPrefix("[") ? String($0.dropFirst()) : nil }
        if let descriptor, component == nil {
            throw VMError.verify("array operation at pc \(pc) uses non-array \(descriptor) in \(context)")
        }
        if let component, !arrayOpcode(op, matches: component) {
            throw VMError.verify(
                "array opcode 0x\(String(op, radix: 16)) at pc \(pc) does not match component \(component) in \(context)"
            )
        }

        if op <= 0x4a {
            let output = arrayOpcodeCategory(op)
            if output == .wideLow { line.writeWide(to: valueRegister) }
            else if output == .reference(nil) {
                line.write(.reference(component), to: valueRegister)
            } else { line.write(.category1, to: valueRegister) }
        } else {
            let expected = arrayOpcodeCategory(UInt8(op - 7))
            switch expected {
            case .category1:
                try requireCategory1(line: line, register: valueRegister, label: "array value", pc: pc, context: context)
            case .wideLow:
                try requireWide(line: line, register: valueRegister, label: "array value", pc: pc, context: context)
            case .reference:
                guard isReference(line.values[valueRegister]) else {
                    throw typeError(valueRegister, expected: "reference", actual: line.values[valueRegister], label: "array value", pc: pc, context: context)
                }
            default: break
            }
        }
    }

    private static func arrayOpcodeCategory(_ opcode: UInt8) -> RegisterType {
        switch opcode {
        case 0x45: return .wideLow
        case 0x46: return .reference(nil)
        default: return .category1
        }
    }

    private static func arrayOpcode(_ opcode: UInt8, matches component: String) -> Bool {
        let normalized = opcode > 0x4a ? UInt8(opcode - 7) : opcode
        switch normalized {
        case 0x44: return component == "I" || component == "F"
        case 0x45: return component == "J" || component == "D"
        case 0x46: return isReferenceDescriptor(component)
        case 0x47: return component == "Z"
        case 0x48: return component == "B"
        case 0x49: return component == "C"
        case 0x4a: return component == "S"
        default: return false
        }
    }

    private static func transferUnary(
        op: UInt8,
        first: UInt16,
        line: inout RegisterLine,
        pc: Int,
        context: String
    ) throws {
        let destination = Int(first >> 8 & 0x0f)
        let source = Int(first >> 12)
        let sourceWide = [0x7d, 0x7e, 0x80, 0x84, 0x85, 0x86, 0x8a, 0x8b, 0x8c].contains(op)
        let destinationWide = [0x7d, 0x7e, 0x80, 0x81, 0x83, 0x86, 0x88, 0x89, 0x8b].contains(op)
        if sourceWide {
            try requireWide(line: line, register: source, label: "unary source", pc: pc, context: context)
        } else {
            try requireCategory1(line: line, register: source, label: "unary source", pc: pc, context: context)
        }
        if destinationWide { line.writeWide(to: destination) }
        else { line.write(.category1, to: destination) }
    }

    private static func transferBinary(
        op: UInt8,
        first: UInt16,
        units: [UInt16],
        pc: Int,
        line: inout RegisterLine,
        context: String
    ) throws {
        let base = op >= 0xb0 ? UInt8(op - 0x20) : op
        let destination: Int
        let lhs: Int
        let rhs: Int
        if op >= 0xb0 {
            destination = Int(first >> 8 & 0x0f)
            lhs = destination
            rhs = Int(first >> 12)
        } else {
            destination = Int(first >> 8)
            lhs = Int(units[pc + 1] & 0xff)
            rhs = Int(units[pc + 1] >> 8)
        }
        if isWideBinaryOpcode(base) {
            let opcodeLabel = "binary lhs for opcode 0x\(String(op, radix: 16))"
            try requireWide(line: line, register: lhs, label: opcodeLabel, pc: pc, context: context)
            if isWideShiftOpcode(base) {
                try requireCategory1(line: line, register: rhs, label: "shift distance", pc: pc, context: context)
            } else {
                try requireWide(
                    line: line,
                    register: rhs,
                    label: "binary rhs for opcode 0x\(String(op, radix: 16))",
                    pc: pc,
                    context: context
                )
            }
            line.writeWide(to: destination)
        } else {
            try requireCategory1(line: line, register: lhs, label: "binary lhs", pc: pc, context: context)
            try requireCategory1(line: line, register: rhs, label: "binary rhs", pc: pc, context: context)
            line.write(.category1, to: destination)
        }
    }

    private static func isWideBinaryOpcode(_ opcode: UInt8) -> Bool {
        (0x9b...0xa5).contains(opcode) || (0xab...0xaf).contains(opcode)
    }

    private static func isWideShiftOpcode(_ opcode: UInt8) -> Bool {
        (0xa3...0xa5).contains(opcode)
    }

    // MARK: - Shared type checks

    private static func isCategory1(_ type: RegisterType) -> Bool {
        type == .category1 || type == .zero
    }

    private static func isReference(_ type: RegisterType) -> Bool {
        if type == .zero { return true }
        if case .reference = type { return true }
        return false
    }

    private static func equalityComparable(_ lhs: RegisterType, _ rhs: RegisterType) -> Bool {
        (isCategory1(lhs) && isCategory1(rhs)) || (isReference(lhs) && isReference(rhs))
    }

    private static func requireCategory1(
        line: RegisterLine,
        register: Int,
        label: String,
        pc: Int,
        context: String
    ) throws {
        guard isCategory1(line.values[register]) else {
            throw typeError(register, expected: "category-1", actual: line.values[register], label: label, pc: pc, context: context)
        }
    }

    private static func requireWide(
        line: RegisterLine,
        register: Int,
        label: String,
        pc: Int,
        context: String
    ) throws {
        guard register + 1 < line.values.count,
              line.values[register] == .wideLow,
              line.values[register + 1] == .wideHigh else {
            throw typeError(register, expected: "wide pair", actual: line.values[register], label: label, pc: pc, context: context)
        }
    }

    private static func require(
        line: RegisterLine,
        register: Int,
        descriptor: String,
        label: String,
        pc: Int,
        context: String
    ) throws {
        let expected = try descriptorType(descriptor, context: context)
        switch expected {
        case .category1:
            try requireCategory1(line: line, register: register, label: label, pc: pc, context: context)
        case .wideLow:
            try requireWide(line: line, register: register, label: label, pc: pc, context: context)
        case .reference:
            guard isReference(line.values[register]) else {
                throw typeError(register, expected: "reference", actual: line.values[register], label: label, pc: pc, context: context)
            }
        default:
            preconditionFailure("non-value descriptor")
        }
    }

    private static func arrayReference(
        _ register: Int,
        line: RegisterLine,
        label: String,
        pc: Int,
        context: String
    ) throws {
        guard isReference(line.values[register]) else {
            throw typeError(register, expected: "array reference", actual: line.values[register], label: label, pc: pc, context: context)
        }
        if case let .reference(descriptor?) = line.values[register], !descriptor.hasPrefix("[") {
            throw typeError(register, expected: "array reference", actual: line.values[register], label: label, pc: pc, context: context)
        }
    }

    private static func primitiveArrayElementWidth(_ descriptor: String) -> Int? {
        switch descriptor {
        case "[Z", "[B": return 1
        case "[C", "[S": return 2
        case "[I", "[F": return 4
        case "[J", "[D": return 8
        default: return nil
        }
    }

    // MARK: - Control flow

    private static func normalSuccessors(
        of instruction: DexCodeVerifier.InstructionInfo,
        units: [UInt16],
        instructionStarts: Set<Int>
    ) -> [Int] {
        let pc = instruction.address
        let op = instruction.opcode
        switch op {
        case 0x0e...0x11, 0x27:
            return []
        case 0x28:
            return [pc + Int(Int8(bitPattern: UInt8(units[pc] >> 8)))]
        case 0x29:
            return [pc + Int(Int16(bitPattern: units[pc + 1]))]
        case 0x2a:
            return [pc + Int(signed32(units[pc + 1], units[pc + 2]))]
        case 0x32...0x3d:
            return [pc + Int(Int16(bitPattern: units[pc + 1])), pc + instruction.width]
        case 0x2b, 0x2c:
            var result = [pc + instruction.width]
            let payload = pc + Int(signed32(units[pc + 1], units[pc + 2]))
            let size = Int(units[payload + 1])
            let offsetsBase = op == 0x2b ? payload + 4 : payload + 2 + size * 2
            for index in 0..<size {
                let offsetAddress = offsetsBase + index * 2
                result.append(pc + Int(signed32(units[offsetAddress], units[offsetAddress + 1])))
            }
            return Array(Set(result)).sorted()
        default:
            let next = pc + instruction.width
            return instructionStarts.contains(next) ? [next] : []
        }
    }

    private static func mayThrow(_ opcode: UInt8) -> Bool {
        switch opcode {
        case 0x1a...0x1f, 0x21...0x27, 0x44...0x78,
             0x93, 0x94, 0x9e, 0x9f, 0xb3, 0xb4, 0xbe, 0xbf,
             0xd3, 0xd4, 0xdb, 0xdc, 0xfa...0xff:
            return true
        default:
            return false
        }
    }

    private static func signed32(_ low: UInt16, _ high: UInt16) -> Int32 {
        Int32(bitPattern: UInt32(low) | UInt32(high) << 16)
    }
}
