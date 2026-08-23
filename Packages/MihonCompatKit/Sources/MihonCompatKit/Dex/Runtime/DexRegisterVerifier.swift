import Foundation

/// Bounded category-level register verification for an already structurally
/// verified DEX method.
///
/// Dalvik registers do not carry runtime tags. The verifier must therefore
/// prove that every reachable read has a compatible category before execution;
/// otherwise malformed bytecode could exploit the interpreter's defensive
/// zero/null fallbacks. This pass tracks exact primitive families, narrow
/// integral types, polymorphic constants, typed wide pairs, initialized and
/// allocation-site-specific uninitialized references, undefined values, and
/// merge conflicts. Resolved references retain their common supertype and are
/// checked against assignment targets through the shared DEX/host hierarchy.
enum DexRegisterVerifier {
    static let maximumDataflowStates = 250_000
    static let maximumDataflowCells = 8_000_000
    static let maximumDataflowMerges = 8_000_000

    private enum IntegralType: String {
        case boolean
        case byte
        case char
        case short
        case integer = "int"
    }

    /// ART keeps bounded constant kinds so literals can be consumed as either
    /// integral values or floats, while retaining legal narrow conversions.
    private enum Constant32Type: String {
        case zero
        case boolean
        case positiveByte = "positive-byte"
        case positiveShort = "positive-short"
        case char
        case byte
        case short
        case integer = "int"
    }

    private enum RegisterType: Equatable, CustomStringConvertible {
        case undefined
        case conflict
        case integral(IntegralType)
        case constant32(Constant32Type)
        case float
        case longLow
        case longHigh
        case doubleLow
        case doubleHigh
        case constantWideLow
        case constantWideHigh
        case reference(String?)
        case uninitializedReference(descriptor: String, allocationPC: Int)
        case uninitializedThis(String)

        var description: String {
            switch self {
            case .undefined: return "undefined"
            case .conflict: return "conflict"
            case let .integral(type): return type.rawValue
            case let .constant32(type): return "constant-\(type.rawValue)"
            case .float: return "float"
            case .longLow: return "long-low"
            case .longHigh: return "long-high"
            case .doubleLow: return "double-low"
            case .doubleHigh: return "double-high"
            case .constantWideLow: return "constant-wide-low"
            case .constantWideHigh: return "constant-wide-high"
            case let .reference(descriptor): return descriptor ?? "reference"
            case let .uninitializedReference(descriptor, allocationPC):
                return "uninitialized \(descriptor)@\(allocationPC)"
            case let .uninitializedThis(descriptor):
                return "uninitialized-this \(descriptor)"
            }
        }
    }

    private struct RegisterLine: Equatable {
        var values: [RegisterType]
        var thisInitialized: Bool

        init(count: Int, thisInitialized: Bool = true) {
            values = [RegisterType](repeating: .undefined, count: count)
            self.thisInitialized = thisInitialized
        }

        mutating func write(_ type: RegisterType, to register: Int) {
            invalidateWidePair(containing: register)
            values[register] = type
        }

        mutating func writeWide(_ low: RegisterType, to register: Int) {
            invalidateWidePair(containing: register)
            invalidateWidePair(containing: register + 1)
            values[register] = low
            values[register + 1] = DexRegisterVerifier.highHalf(for: low)
        }

        mutating func copyWide(from source: Int, to destination: Int) {
            writeWide(values[source], to: destination)
        }

        mutating func markInitialized(_ uninitialized: RegisterType) {
            let descriptor: String
            switch uninitialized {
            case let .uninitializedReference(value, _), let .uninitializedThis(value):
                descriptor = value
            default:
                preconditionFailure("markInitialized requires an uninitialized reference")
            }
            for index in values.indices where values[index] == uninitialized {
                values[index] = .reference(descriptor)
            }
            if case .uninitializedThis = uninitialized {
                thisInitialized = true
            }
        }

        private mutating func invalidateWidePair(containing register: Int) {
            guard register >= 0, register < values.count else { return }
            if DexRegisterVerifier.isWideLow(values[register]),
               register + 1 < values.count,
               DexRegisterVerifier.isWidePair(values[register], values[register + 1]) {
                values[register + 1] = .undefined
            } else if DexRegisterVerifier.isWideHigh(values[register]),
                      register > 0,
                      DexRegisterVerifier.isWidePair(values[register - 1], values[register]) {
                values[register - 1] = .undefined
            }
        }

        mutating func merge(_ incoming: RegisterLine, hierarchy: DexTypeHierarchy) -> Bool {
            var changed = false
            for index in values.indices {
                let merged = DexRegisterVerifier.merge(
                    values[index],
                    incoming.values[index],
                    hierarchy: hierarchy
                )
                if merged != values[index] {
                    values[index] = merged
                    changed = true
                }
            }
            for index in values.indices {
                if DexRegisterVerifier.isWideLow(values[index]),
                   index + 1 >= values.count
                    || !DexRegisterVerifier.isWidePair(values[index], values[index + 1]) {
                    values[index] = .conflict
                    changed = true
                } else if DexRegisterVerifier.isWideHigh(values[index]),
                          index == 0
                            || !DexRegisterVerifier.isWidePair(values[index - 1], values[index]) {
                    values[index] = .conflict
                    changed = true
                }
            }
            let mergedThisInitialized = thisInitialized && incoming.thisInitialized
            if mergedThisInitialized != thisInitialized {
                thisInitialized = mergedThisInitialized
                changed = true
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
        let hierarchy = DexTypeHierarchy(dex: dex)
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
        let exceptionTypesByHandler = caughtExceptionTypes(
            in: tryBlocks,
            hierarchy: hierarchy
        )

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
                changed = existing.merge(line, hierarchy: hierarchy)
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
                exceptionTypesByHandler: exceptionTypesByHandler,
                hierarchy: hierarchy,
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
            if reference.name == "<init>" && reference.declaringClass != "Ljava/lang/Object;" {
                line.thisInitialized = false
                line.write(.uninitializedThis(reference.declaringClass), to: register)
            } else {
                line.write(.reference(reference.declaringClass), to: register)
            }
            register += 1
        }
        for descriptor in reference.prototype.parameters {
            try write(descriptor: descriptor, to: register, line: &line, context: context)
            register += wordCount(for: descriptor)
        }
    }

    private static func caughtExceptionTypes(
        in tryBlocks: [DexTryBlock],
        hierarchy: DexTypeHierarchy
    ) -> [Int: RegisterType] {
        var descriptors: [Int: String] = [:]
        for block in tryBlocks {
            for handler in block.handlers {
                let descriptor = handler.type ?? DexTypeHierarchy.throwable
                if let existing = descriptors[handler.address] {
                    let merged = hierarchy.commonSupertype(existing, descriptor)
                    descriptors[handler.address] = hierarchy.assignability(
                        from: merged,
                        to: DexTypeHierarchy.throwable,
                        strict: true
                    ) == .yes ? merged : DexTypeHierarchy.throwable
                } else {
                    descriptors[handler.address] = descriptor
                }
            }
        }
        return descriptors.mapValues(RegisterType.reference)
    }

    private static func merge(
        _ lhs: RegisterType,
        _ rhs: RegisterType,
        hierarchy: DexTypeHierarchy
    ) -> RegisterType {
        if lhs == rhs { return lhs }
        if lhs == .undefined || rhs == .undefined { return .undefined }
        if lhs == .conflict || rhs == .conflict { return .conflict }
        switch (lhs, rhs) {
        case let (.constant32(left), .constant32(right)):
            return .constant32(merge(left, right))
        case (.constant32, .integral), (.integral, .constant32),
             (.integral, .integral):
            return mergeIntegral(lhs, rhs)
        case (.constant32, .float), (.float, .constant32):
            return .float
        case (.constantWideLow, .longLow), (.longLow, .constantWideLow):
            return .longLow
        case (.constantWideHigh, .longHigh), (.longHigh, .constantWideHigh):
            return .longHigh
        case (.constantWideLow, .doubleLow), (.doubleLow, .constantWideLow):
            return .doubleLow
        case (.constantWideHigh, .doubleHigh), (.doubleHigh, .constantWideHigh):
            return .doubleHigh
        case let (.constant32(.zero), .reference(descriptor)),
             let (.reference(descriptor), .constant32(.zero)):
            return .reference(descriptor)
        case let (.reference(left), .reference(right)):
            guard let left, let right else { return .reference(nil) }
            return .reference(hierarchy.commonSupertype(left, right))
        default:
            return .conflict
        }
    }

    private static func merge(_ lhs: Constant32Type, _ rhs: Constant32Type) -> Constant32Type {
        let left = constantRange(lhs)
        let right = constantRange(rhs)
        return constantType(minimum: min(left.lowerBound, right.lowerBound),
                            maximum: max(left.upperBound, right.upperBound))
    }

    private static func constantRange(_ type: Constant32Type) -> ClosedRange<Int64> {
        switch type {
        case .zero: return 0...0
        case .boolean: return 0...1
        case .positiveByte: return 0...127
        case .positiveShort: return 0...32_767
        case .char: return 0...65_535
        case .byte: return -128...127
        case .short: return -32_768...32_767
        case .integer: return Int64(Int32.min)...Int64(Int32.max)
        }
    }

    private static func constantType(minimum: Int64, maximum: Int64) -> Constant32Type {
        if minimum >= 0 {
            if maximum == 0 { return .zero }
            if maximum <= 1 { return .boolean }
            if maximum <= 127 { return .positiveByte }
            if maximum <= 32_767 { return .positiveShort }
            if maximum <= 65_535 { return .char }
        } else {
            if minimum >= -128, maximum <= 127 { return .byte }
            if minimum >= -32_768, maximum <= 32_767 { return .short }
        }
        return .integer
    }

    private static func constantType(for value: Int32) -> Constant32Type {
        constantType(minimum: Int64(value), maximum: Int64(value))
    }

    private static func mergeIntegral(_ lhs: RegisterType, _ rhs: RegisterType) -> RegisterType {
        if isBoolean(lhs), isBoolean(rhs) { return .integral(.boolean) }
        if isByte(lhs), isByte(rhs) { return .integral(.byte) }
        if isShort(lhs), isShort(rhs) { return .integral(.short) }
        if isChar(lhs), isChar(rhs) { return .integral(.char) }
        return .integral(.integer)
    }

    private static func wordCount(for descriptor: String) -> Int {
        descriptor == "J" || descriptor == "D" ? 2 : 1
    }

    private static func descriptorType(_ descriptor: String, context: String) throws -> RegisterType {
        switch descriptor {
        case "Z": return .integral(.boolean)
        case "B": return .integral(.byte)
        case "C": return .integral(.char)
        case "S": return .integral(.short)
        case "I": return .integral(.integer)
        case "F": return .float
        case "J": return .longLow
        case "D": return .doubleLow
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
        if isWideLow(type) {
            line.writeWide(type, to: register)
        } else {
            line.write(type, to: register)
        }
    }

    private static func highHalf(for low: RegisterType) -> RegisterType {
        switch low {
        case .longLow: return .longHigh
        case .doubleLow: return .doubleHigh
        case .constantWideLow: return .constantWideHigh
        default: preconditionFailure("invalid wide low half \(low)")
        }
    }

    private static func isWideLow(_ type: RegisterType) -> Bool {
        type == .longLow || type == .doubleLow || type == .constantWideLow
    }

    private static func isWideHigh(_ type: RegisterType) -> Bool {
        type == .longHigh || type == .doubleHigh || type == .constantWideHigh
    }

    private static func isWidePair(_ low: RegisterType, _ high: RegisterType) -> Bool {
        isWideLow(low) && high == highHalf(for: low)
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
        exceptionTypesByHandler: [Int: RegisterType],
        hierarchy: DexTypeHierarchy,
        context: String
    ) throws {
        let pc = instruction.address
        let op = instruction.opcode
        let first = units[pc]

        func category1(_ register: Int, _ label: String) throws {
            try requireCategory1(line: line, register: register, label: label, pc: pc, context: context)
        }
        func integral(_ register: Int, _ label: String) throws {
            try requireIntegral(line: line, register: register, label: label, pc: pc, context: context)
        }
        func floating(_ register: Int, _ label: String) throws {
            try requireFloat(line: line, register: register, label: label, pc: pc, context: context)
        }
        func wide(_ register: Int, _ label: String, expected: RegisterType? = nil) throws {
            try requireWide(
                line: line, register: register, expectedLow: expected,
                label: label, pc: pc, context: context
            )
        }
        func reference(_ register: Int, _ label: String) throws {
            try requireReference(
                line: line, register: register, allowUninitialized: false,
                label: label, pc: pc, context: context
            )
        }
        func copyableReference(_ register: Int, _ label: String) throws {
            try requireReference(
                line: line, register: register, allowUninitialized: true,
                label: label, pc: pc, context: context
            )
        }
        func compatible(_ register: Int, descriptor: String, label: String) throws {
            try require(
                line: line, register: register, descriptor: descriptor,
                label: label, pc: pc, hierarchy: hierarchy, context: context
            )
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
            line.copyWide(from: source, to: destination)
        case 0x07, 0x08, 0x09:
            let (destination, source) = moveRegisters(op: op, first: first, units: units, pc: pc)
            try copyableReference(source, "move-object source")
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
            let matches = (op == 0x0a && isCategory1(producedType))
                || (op == 0x0b && isWideLow(producedType))
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
            guard let exceptionType = exceptionTypesByHandler[pc] else {
                throw VMError.verify("move-exception at pc \(pc) has no caught type in \(context)")
            }
            line.write(exceptionType, to: Int(first >> 8))
        case 0x0e:
            try verifyConstructorReturn(line: line, method: method, dex: dex, pc: pc, context: context)
            guard dex.methodIds[method.methodIndex].prototype.returnType == "V" else {
                throw VMError.verify("return-void at pc \(pc) in non-void \(context)")
            }
        case 0x0f, 0x10, 0x11:
            try verifyConstructorReturn(line: line, method: method, dex: dex, pc: pc, context: context)
            let descriptor = dex.methodIds[method.methodIndex].prototype.returnType
            guard descriptor != "V" else {
                throw VMError.verify("value return at pc \(pc) in void \(context)")
            }
            let expected = try descriptorType(descriptor, context: context)
            let opcodeMatches = (op == 0x0f && isCategory1(expected))
                || (op == 0x10 && isWideLow(expected))
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
            line.write(.constant32(constantType(for: Int32(literal))), to: Int(first >> 8 & 0x0f))
        case 0x13...0x15:
            let literal: Int32
            if op == 0x13 {
                literal = Int32(Int16(bitPattern: units[pc + 1]))
            } else if op == 0x14 {
                literal = signed32(units[pc + 1], units[pc + 2])
            } else {
                literal = Int32(bitPattern: UInt32(units[pc + 1]) << 16)
            }
            line.write(.constant32(constantType(for: literal)), to: Int(first >> 8))
        case 0x16...0x19:
            line.writeWide(.constantWideLow, to: Int(first >> 8))
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
            line.write(.integral(.boolean), to: Int(first >> 8 & 0x0f))
        case 0x21:
            let source = Int(first >> 12)
            try arrayReference(source, line: line, label: "array-length operand", pc: pc, context: context)
            line.write(.integral(.integer), to: Int(first >> 8 & 0x0f))
        case 0x22:
            let descriptor = dex.typeDescriptors[Int(units[pc + 1])]
            guard descriptor.hasPrefix("L"), descriptor.hasSuffix(";") else {
                throw VMError.verify("new-instance at pc \(pc) targets non-class \(descriptor) in \(context)")
            }
            let allocation = RegisterType.uninitializedReference(descriptor: descriptor, allocationPC: pc)
            guard !line.values.contains(allocation) else {
                throw VMError.verify(
                    "new-instance at pc \(pc) reuses an outstanding uninitialized allocation in \(context)"
                )
            }
            line.write(allocation, to: Int(first >> 8))
        case 0x23:
            try integral(Int(first >> 12), "new-array size")
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
            try require(
                line: line,
                register: Int(first >> 8),
                descriptor: DexTypeHierarchy.throwable,
                label: "throw operand",
                pc: pc,
                hierarchy: hierarchy,
                strictReference: true,
                context: context
            )
        case 0x28...0x2a:
            break
        case 0x2b, 0x2c:
            try integral(Int(first >> 8), "switch key")
        case 0x2d, 0x2e:
            try floating(Int(units[pc + 1] & 0xff), "float compare lhs")
            try floating(Int(units[pc + 1] >> 8), "float compare rhs")
            line.write(.integral(.integer), to: Int(first >> 8))
        case 0x2f, 0x30:
            try wide(Int(units[pc + 1] & 0xff), "double compare lhs", expected: .doubleLow)
            try wide(Int(units[pc + 1] >> 8), "double compare rhs", expected: .doubleLow)
            line.write(.integral(.integer), to: Int(first >> 8))
        case 0x31:
            try wide(Int(units[pc + 1] & 0xff), "long compare lhs", expected: .longLow)
            try wide(Int(units[pc + 1] >> 8), "long compare rhs", expected: .longLow)
            line.write(.integral(.integer), to: Int(first >> 8))
        case 0x32, 0x33:
            let lhs = Int(first >> 8 & 0x0f)
            let rhs = Int(first >> 12)
            guard equalityComparable(line.values[lhs], line.values[rhs]) else {
                throw VMError.verify(
                    "if equality at pc \(pc) compares \(line.values[lhs]) with \(line.values[rhs]) in \(context)"
                )
            }
        case 0x34...0x37:
            try integral(Int(first >> 8 & 0x0f), "if lhs")
            try integral(Int(first >> 12), "if rhs")
        case 0x38, 0x39:
            let register = Int(first >> 8)
            guard isIntegral(line.values[register]) || isReference(line.values[register]) else {
                throw typeError(register, expected: "integral or reference", actual: line.values[register], label: "if operand", pc: pc, context: context)
            }
        case 0x3a...0x3d:
            try integral(Int(first >> 8), "if operand")
        case 0x44...0x51:
            try transferArrayAccess(
                op: op, first: first, units: units, pc: pc, line: &line,
                hierarchy: hierarchy, context: context
            )
        case 0x52...0x6d:
            try transferFieldAccess(
                op: op, first: first, units: units, pc: pc, line: &line,
                method: method, dex: dex, hierarchy: hierarchy, context: context
            )
        case 0x6e...0x72, 0x74...0x78:
            try verifyInvocation(
                op: op, first: first, units: units, pc: pc, line: &line,
                method: method, dex: dex, hierarchy: hierarchy, context: context
            )
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
            try integral(source, "literal operation source")
            line.write(.integral(.integer), to: destination)
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
        line: inout RegisterLine,
        method: DexFile.EncodedMethod,
        dex: DexFile,
        hierarchy: DexTypeHierarchy,
        context: String
    ) throws {
        let methodIndex = Int(units[pc + 1])
        let reference = dex.methodIds[methodIndex]
        let registers = registerList(op: op, first: first, units: units, pc: pc)
        guard let kind = DexInvocationKind(opcode: op) else {
            throw VMError.verify(
                "invalid invoke opcode 0x\(String(op, radix: 16)) at pc \(pc) in \(context)"
            )
        }
        let isStatic = kind.isStatic
        let isDirect = kind == .direct
        let isConstructor = reference.name == "<init>"

        let targetIsInterface = hierarchy.isInterface(reference.declaringClass)
        if kind == .interface, targetIsInterface == false {
            throw VMError.verify(
                "invoke-interface target \(reference.declaringClass) is not an interface "
                    + "at pc \(pc) in \(context)"
            )
        }
        if kind == .virtual, targetIsInterface == true {
            throw VMError.verify(
                "invoke-virtual target \(reference.declaringClass) is an interface "
                    + "at pc \(pc) in \(context)"
            )
        }
        if targetIsInterface == true, dex.version < 37,
           kind == .superMethod || kind == .direct || kind == .staticMethod {
            throw VMError.verify(
                "\(invokeName(kind)) to interface \(reference.declaringClass) requires "
                    + "DEX 037 or newer at pc \(pc) in \(context)"
            )
        }

        let enclosingReference = dex.methodIds[method.methodIndex]
        if kind == .superMethod {
            guard method.accessFlags & 0x8 == 0 else {
                throw VMError.verify(
                    "invoke-super is not permitted in static method \(context) at pc \(pc)"
                )
            }
            guard enclosingReference.declaringClass != reference.declaringClass else {
                throw VMError.verify(
                    "invoke-super target \(reference.declaringClass) is not a strict supertype "
                        + "of \(enclosingReference.declaringClass) at pc \(pc) in \(context)"
                )
            }
            if hierarchy.assignability(
                from: enclosingReference.declaringClass,
                to: reference.declaringClass,
                strict: true
            ) == .no {
                throw VMError.verify(
                    "invoke-super target \(reference.declaringClass) is not a supertype "
                        + "of \(enclosingReference.declaringClass) at pc \(pc) in \(context)"
                )
            }
        }

        let resolver = DexMethodResolver(dex: dex, hierarchy: hierarchy)
        if let targetIndex = dex.classIndexByDescriptor[reference.declaringClass] {
            let target = dex.classDefs[targetIndex]
            let directMatches = target.directMethods.filter {
                let candidate = dex.methodIds[$0.methodIndex]
                return candidate.name == reference.name
                    && candidate.prototype.descriptor == reference.prototype.descriptor
            }
            let virtualMatches = target.virtualMethods.filter {
                let candidate = dex.methodIds[$0.methodIndex]
                return candidate.name == reference.name
                    && candidate.prototype.descriptor == reference.prototype.descriptor
            }
            guard directMatches.count + virtualMatches.count <= 1 else {
                throw VMError.verify(
                    "duplicate local method \(reference.declaringClass).\(reference.signature) "
                        + "at pc \(pc) in \(context)"
                )
            }
            if let encoded = (directMatches + virtualMatches).first {
                let encodedIsStatic = encoded.accessFlags & 0x8 != 0
                let encodedIsDirect = directMatches.contains {
                    $0.methodIndex == encoded.methodIndex
                }
                switch kind {
                case .staticMethod:
                    if !encodedIsStatic {
                        throw invocationKindError(
                            reference: reference, expected: "static", actual: "instance",
                            pc: pc, context: context
                        )
                    }
                case .direct:
                    if encodedIsStatic {
                        throw invocationKindError(
                            reference: reference, expected: "instance", actual: "static",
                            pc: pc, context: context
                        )
                    }
                    if !encodedIsDirect {
                        throw VMError.verify(
                            "\(reference.signature) uses invoke-direct but is encoded as a virtual "
                                + "method at pc \(pc) in \(context)"
                        )
                    }
                case .virtual, .superMethod, .interface:
                    if encodedIsStatic {
                        throw invocationKindError(
                            reference: reference, expected: "instance", actual: "static",
                            pc: pc, context: context
                        )
                    }
                    if encodedIsDirect {
                        throw VMError.verify(
                            "\(reference.signature) uses \(invokeName(kind)) but is encoded as a "
                                + "direct method at pc \(pc) in \(context)"
                        )
                    }
                }
            }

            let referenceLookup = try resolver.referencedMethod(
                declaringType: reference.declaringClass,
                name: reference.name,
                prototype: reference.prototype.descriptor,
                kind: kind
            )
            try verifyReferenceLookup(
                referenceLookup,
                kind: kind,
                reference: reference,
                pc: pc,
                context: context
            )
        }

        if kind == .superMethod {
            let dispatchLookup: DexMethodResolver.Lookup
            if targetIsInterface == true {
                dispatchLookup = try resolver.interfaceSuper(
                    targetInterface: reference.declaringClass,
                    name: reference.name,
                    prototype: reference.prototype.descriptor
                )
            } else {
                dispatchLookup = try resolver.classSuper(
                    callerDescriptor: enclosingReference.declaringClass,
                    name: reference.name,
                    prototype: reference.prototype.descriptor
                )
            }
            try verifySuperDispatchLookup(
                dispatchLookup,
                reference: reference,
                pc: pc,
                context: context
            )
        }

        if isConstructor, !isDirect {
            throw VMError.verify(
                "constructor \(reference.signature) at pc \(pc) must use invoke-direct in \(context)"
            )
        }
        if reference.name.hasPrefix("<"), !isConstructor {
            throw VMError.verify(
                "special method \(reference.signature) cannot be explicitly invoked at pc \(pc) in \(context)"
            )
        }
        let expectedWords = reference.prototype.parameterWordCount + (isStatic ? 0 : 1)
        guard registers.count == expectedWords else {
            throw VMError.verify(
                "\(reference.signature) expects \(expectedWords) invoke register words; "
                    + "instruction at pc \(pc) supplies \(registers.count) in \(context)"
            )
        }

        var word = 0
        var constructorReceiver: RegisterType?
        if !isStatic {
            let register = registers[0]
            let receiver = line.values[register]
            if isConstructor {
                guard isUninitializedReference(receiver) else {
                    throw typeError(
                        register,
                        expected: "uninitialized constructor receiver",
                        actual: receiver,
                        label: "invoke receiver",
                        pc: pc,
                        context: context
                    )
                }
                let receiverDescriptor: String
                switch receiver {
                case let .uninitializedReference(descriptor, _),
                     let .uninitializedThis(descriptor):
                    receiverDescriptor = descriptor
                default:
                    preconditionFailure("validated uninitialized constructor receiver")
                }
                if hierarchy.assignability(
                    from: receiverDescriptor,
                    to: reference.declaringClass,
                    strict: true
                ) == .no {
                    throw typeError(
                        register,
                        expected: "uninitialized reference assignable to \(reference.declaringClass)",
                        actual: receiver,
                        label: "invoke receiver",
                        pc: pc,
                        context: context
                    )
                }
                constructorReceiver = receiver
            } else {
                try require(
                    line: line,
                    register: register,
                    descriptor: reference.declaringClass,
                    label: "invoke receiver",
                    pc: pc,
                    hierarchy: hierarchy,
                    context: context
                )
            }
            word = 1
        }
        for (argument, descriptor) in reference.prototype.parameters.enumerated() {
            let register = registers[word]
            try require(
                line: line,
                register: register,
                descriptor: descriptor,
                label: "invoke argument \(argument)",
                pc: pc,
                hierarchy: hierarchy,
                context: context
            )
            if wordCount(for: descriptor) == 2 {
                guard word + 1 < registers.count, registers[word + 1] == register + 1 else {
                    throw VMError.verify(
                        "wide invoke argument \(argument) at pc \(pc) is not an adjacent register pair in \(context)"
                    )
                }
            }
            word += wordCount(for: descriptor)
        }
        if let constructorReceiver {
            line.markInitialized(constructorReceiver)
        }
    }

    private static func invokeName(_ kind: DexInvocationKind) -> String {
        switch kind {
        case .virtual: return "invoke-virtual"
        case .superMethod: return "invoke-super"
        case .direct: return "invoke-direct"
        case .staticMethod: return "invoke-static"
        case .interface: return "invoke-interface"
        }
    }

    private static func invocationKindError(
        reference: DexFile.MethodRef,
        expected: String,
        actual: String,
        pc: Int,
        context: String
    ) -> VMError {
        .verify(
            "\(reference.signature) invoked as \(expected) but encoded method is \(actual) "
                + "at pc \(pc) in \(context)"
        )
    }

    private static func verifyReferenceLookup(
        _ lookup: DexMethodResolver.Lookup,
        kind: DexInvocationKind,
        reference: DexFile.MethodRef,
        pc: Int,
        context: String
    ) throws {
        switch lookup {
        case .found, .unresolved:
            return
        case .abstract where kind == .virtual
            || kind == .superMethod
            || kind == .interface:
            return
        case .abstract:
            throw VMError.verify(
                "\(invokeName(kind)) cannot target abstract method \(reference.signature) "
                    + "at pc \(pc) in \(context)"
            )
        case let .conflict(interfaces):
            throw VMError.verify(
                "method reference \(reference.signature) has conflicting interface defaults "
                    + "\(interfaces.joined(separator: ", ")) at pc \(pc) in \(context)"
            )
        case .missing:
            throw VMError.verify(
                "method reference \(reference.declaringClass)->\(reference.signature) does not "
                    + "resolve at pc \(pc) in \(context)"
            )
        }
    }

    private static func verifySuperDispatchLookup(
        _ lookup: DexMethodResolver.Lookup,
        reference: DexFile.MethodRef,
        pc: Int,
        context: String
    ) throws {
        switch lookup {
        case .found, .abstract, .unresolved:
            return
        case let .conflict(interfaces):
            throw VMError.verify(
                "invoke-super target \(reference.signature) has conflicting defaults "
                    + "\(interfaces.joined(separator: ", ")) at pc \(pc) in \(context)"
            )
        case .missing:
            throw VMError.verify(
                "invoke-super target \(reference.declaringClass)->\(reference.signature) has no "
                    + "super implementation at pc \(pc) in \(context)"
            )
        }
    }

    private static func transferFieldAccess(
        op: UInt8,
        first: UInt16,
        units: [UInt16],
        pc: Int,
        line: inout RegisterLine,
        method: DexFile.EncodedMethod,
        dex: DexFile,
        hierarchy: DexTypeHierarchy,
        context: String
    ) throws {
        let field = dex.fieldIds[Int(units[pc + 1])]
        let isInstance = op <= 0x5f
        let isGet = (0x52...0x58).contains(op) || (0x60...0x66).contains(op)
        let register = isInstance ? Int(first >> 8 & 0x0f) : Int(first >> 8)
        if isInstance {
            let receiver = Int(first >> 12)
            let receiverType = line.values[receiver]
            if isReference(receiverType) {
                try require(
                    line: line,
                    register: receiver,
                    descriptor: field.declaringClass,
                    label: "field receiver",
                    pc: pc,
                    hierarchy: hierarchy,
                    context: context
                )
            } else {
                let enclosing = dex.methodIds[method.methodIndex]
                let ownUninitializedThis: Bool
                if case let .uninitializedThis(descriptor) = receiverType {
                    ownUninitializedThis = enclosing.name == "<init>"
                        && enclosing.declaringClass == descriptor
                        && field.declaringClass == descriptor
                } else {
                    ownUninitializedThis = false
                }
                guard ownUninitializedThis else {
                    throw typeError(
                        receiver,
                        expected: "initialized reference or own uninitialized-this",
                        actual: receiverType,
                        label: "field receiver",
                        pc: pc,
                        context: context
                    )
                }
            }
        }
        guard fieldOpcode(op, matches: field.type) else {
            throw VMError.verify(
                "field opcode 0x\(String(op, radix: 16)) at pc \(pc) does not match \(field.type) in \(context)"
            )
        }
        if isGet {
            try write(descriptor: field.type, to: register, line: &line, context: context)
        } else {
            try require(
                line: line, register: register, descriptor: field.type,
                label: "field value", pc: pc, hierarchy: hierarchy,
                context: context
            )
        }
    }

    private static func fieldOpcode(_ opcode: UInt8, matches descriptor: String) -> Bool {
        let normalized: UInt8
        switch opcode {
        case 0x52...0x58: normalized = opcode
        case 0x59...0x5f: normalized = opcode - 7
        case 0x60...0x66: normalized = opcode - 14
        case 0x67...0x6d: normalized = opcode - 21
        default: return false
        }
        switch normalized {
        case 0x52: return descriptor == "I" || descriptor == "F"
        case 0x53: return descriptor == "J" || descriptor == "D"
        case 0x54: return isReferenceDescriptor(descriptor)
        case 0x55: return descriptor == "Z"
        case 0x56: return descriptor == "B"
        case 0x57: return descriptor == "C"
        case 0x58: return descriptor == "S"
        default: return false
        }
    }

    private static func transferArrayAccess(
        op: UInt8,
        first: UInt16,
        units: [UInt16],
        pc: Int,
        line: inout RegisterLine,
        hierarchy: DexTypeHierarchy,
        context: String
    ) throws {
        let valueRegister = Int(first >> 8)
        let arrayRegister = Int(units[pc + 1] & 0xff)
        let indexRegister = Int(units[pc + 1] >> 8)
        try arrayReference(arrayRegister, line: line, label: "array operand", pc: pc, context: context)
        try requireIntegral(line: line, register: indexRegister, label: "array index", pc: pc, context: context)

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
            let output = arrayGetType(op, component: component)
            if isWideLow(output) { line.writeWide(output, to: valueRegister) }
            else { line.write(output, to: valueRegister) }
        } else {
            if let component {
                try require(
                    line: line,
                    register: valueRegister,
                    descriptor: component,
                    label: "array value",
                    pc: pc,
                    hierarchy: hierarchy,
                    context: context
                )
            } else {
                try requireArrayOpcodeValue(
                    UInt8(op - 7),
                    line: line,
                    register: valueRegister,
                    pc: pc,
                    context: context
                )
            }
        }
    }

    private static func arrayGetType(_ opcode: UInt8, component: String?) -> RegisterType {
        switch opcode {
        case 0x44: return component == "F" ? .float : .integral(.integer)
        case 0x45: return component == "D" ? .doubleLow : .longLow
        case 0x46: return .reference(component)
        case 0x47: return .integral(.boolean)
        case 0x48: return .integral(.byte)
        case 0x49: return .integral(.char)
        case 0x4a: return .integral(.short)
        default: preconditionFailure("not an array-get opcode")
        }
    }

    private static func requireArrayOpcodeValue(
        _ opcode: UInt8,
        line: RegisterLine,
        register: Int,
        pc: Int,
        context: String
    ) throws {
        switch opcode {
        case 0x44:
            try requireCategory1(line: line, register: register, label: "array value", pc: pc, context: context)
        case 0x45:
            try requireWide(line: line, register: register, expectedLow: nil, label: "array value", pc: pc, context: context)
        case 0x46:
            try requireReference(line: line, register: register, allowUninitialized: false, label: "array value", pc: pc, context: context)
        case 0x47...0x4a:
            try requireIntegral(line: line, register: register, label: "array value", pc: pc, context: context)
        default:
            preconditionFailure("not an array-put opcode family")
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
        switch op {
        case 0x7b, 0x7c:
            try requireIntegral(line: line, register: source, label: "unary source", pc: pc, context: context)
            line.write(.integral(.integer), to: destination)
        case 0x7d, 0x7e:
            try requireWide(line: line, register: source, expectedLow: .longLow, label: "unary source", pc: pc, context: context)
            line.writeWide(.longLow, to: destination)
        case 0x7f:
            try requireFloat(line: line, register: source, label: "unary source", pc: pc, context: context)
            line.write(.float, to: destination)
        case 0x80:
            try requireWide(line: line, register: source, expectedLow: .doubleLow, label: "unary source", pc: pc, context: context)
            line.writeWide(.doubleLow, to: destination)
        case 0x81:
            try requireIntegral(line: line, register: source, label: "conversion source", pc: pc, context: context)
            line.writeWide(.longLow, to: destination)
        case 0x82:
            try requireIntegral(line: line, register: source, label: "conversion source", pc: pc, context: context)
            line.write(.float, to: destination)
        case 0x83:
            try requireIntegral(line: line, register: source, label: "conversion source", pc: pc, context: context)
            line.writeWide(.doubleLow, to: destination)
        case 0x84:
            try requireWide(line: line, register: source, expectedLow: .longLow, label: "conversion source", pc: pc, context: context)
            line.write(.integral(.integer), to: destination)
        case 0x85:
            try requireWide(line: line, register: source, expectedLow: .longLow, label: "conversion source", pc: pc, context: context)
            line.write(.float, to: destination)
        case 0x86:
            try requireWide(line: line, register: source, expectedLow: .longLow, label: "conversion source", pc: pc, context: context)
            line.writeWide(.doubleLow, to: destination)
        case 0x87:
            try requireFloat(line: line, register: source, label: "conversion source", pc: pc, context: context)
            line.write(.integral(.integer), to: destination)
        case 0x88:
            try requireFloat(line: line, register: source, label: "conversion source", pc: pc, context: context)
            line.writeWide(.longLow, to: destination)
        case 0x89:
            try requireFloat(line: line, register: source, label: "conversion source", pc: pc, context: context)
            line.writeWide(.doubleLow, to: destination)
        case 0x8a:
            try requireWide(line: line, register: source, expectedLow: .doubleLow, label: "conversion source", pc: pc, context: context)
            line.write(.integral(.integer), to: destination)
        case 0x8b:
            try requireWide(line: line, register: source, expectedLow: .doubleLow, label: "conversion source", pc: pc, context: context)
            line.writeWide(.longLow, to: destination)
        case 0x8c:
            try requireWide(line: line, register: source, expectedLow: .doubleLow, label: "conversion source", pc: pc, context: context)
            line.write(.float, to: destination)
        case 0x8d:
            try requireIntegral(line: line, register: source, label: "conversion source", pc: pc, context: context)
            line.write(.integral(.byte), to: destination)
        case 0x8e:
            try requireIntegral(line: line, register: source, label: "conversion source", pc: pc, context: context)
            line.write(.integral(.char), to: destination)
        case 0x8f:
            try requireIntegral(line: line, register: source, label: "conversion source", pc: pc, context: context)
            line.write(.integral(.short), to: destination)
        default:
            preconditionFailure("not a unary opcode")
        }
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
        if (0x90...0x9a).contains(base) {
            try requireIntegral(line: line, register: lhs, label: "binary lhs", pc: pc, context: context)
            try requireIntegral(line: line, register: rhs, label: "binary rhs", pc: pc, context: context)
            if (0x95...0x97).contains(base), isBoolean(line.values[lhs]), isBoolean(line.values[rhs]) {
                line.write(.integral(.boolean), to: destination)
            } else {
                line.write(.integral(.integer), to: destination)
            }
        } else if (0x9b...0xa5).contains(base) {
            try requireWide(line: line, register: lhs, expectedLow: .longLow, label: "binary lhs", pc: pc, context: context)
            if isWideShiftOpcode(base) {
                try requireIntegral(line: line, register: rhs, label: "shift distance", pc: pc, context: context)
            } else {
                try requireWide(
                    line: line,
                    register: rhs,
                    expectedLow: .longLow,
                    label: "binary rhs for opcode 0x\(String(op, radix: 16))",
                    pc: pc,
                    context: context
                )
            }
            line.writeWide(.longLow, to: destination)
        } else if (0xa6...0xaa).contains(base) {
            try requireFloat(line: line, register: lhs, label: "binary lhs", pc: pc, context: context)
            try requireFloat(line: line, register: rhs, label: "binary rhs", pc: pc, context: context)
            line.write(.float, to: destination)
        } else if (0xab...0xaf).contains(base) {
            try requireWide(line: line, register: lhs, expectedLow: .doubleLow, label: "binary lhs", pc: pc, context: context)
            try requireWide(line: line, register: rhs, expectedLow: .doubleLow, label: "binary rhs", pc: pc, context: context)
            line.writeWide(.doubleLow, to: destination)
        } else {
            preconditionFailure("not a binary opcode")
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
        if case .integral = type { return true }
        if case .constant32 = type { return true }
        return type == .float
    }

    private static func isIntegral(_ type: RegisterType) -> Bool {
        if case .integral = type { return true }
        if case .constant32 = type { return true }
        return false
    }

    private static func isFloat(_ type: RegisterType) -> Bool {
        type == .float || {
            if case .constant32 = type { return true }
            return false
        }()
    }

    private static func isBoolean(_ type: RegisterType) -> Bool {
        switch type {
        case .integral(.boolean): return true
        case let .constant32(kind):
            let range = constantRange(kind)
            return range.lowerBound >= 0 && range.upperBound <= 1
        default: return false
        }
    }

    private static func isByte(_ type: RegisterType) -> Bool {
        switch type {
        case .integral(.boolean), .integral(.byte): return true
        case let .constant32(kind):
            let range = constantRange(kind)
            return range.lowerBound >= -128 && range.upperBound <= 127
        default: return false
        }
    }

    private static func isShort(_ type: RegisterType) -> Bool {
        switch type {
        case .integral(.boolean), .integral(.byte), .integral(.short): return true
        case let .constant32(kind):
            let range = constantRange(kind)
            return range.lowerBound >= -32_768 && range.upperBound <= 32_767
        default: return false
        }
    }

    private static func isChar(_ type: RegisterType) -> Bool {
        switch type {
        case .integral(.boolean), .integral(.char): return true
        case let .constant32(kind):
            let range = constantRange(kind)
            return range.lowerBound >= 0 && range.upperBound <= 65_535
        default: return false
        }
    }

    private static func isReference(_ type: RegisterType) -> Bool {
        if type == .constant32(.zero) { return true }
        if case .reference = type { return true }
        return false
    }

    private static func isUninitializedReference(_ type: RegisterType) -> Bool {
        switch type {
        case .uninitializedReference, .uninitializedThis: return true
        default: return false
        }
    }

    private static func equalityComparable(_ lhs: RegisterType, _ rhs: RegisterType) -> Bool {
        (isIntegral(lhs) && isIntegral(rhs)) || (isReference(lhs) && isReference(rhs))
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

    private static func requireIntegral(
        line: RegisterLine,
        register: Int,
        label: String,
        pc: Int,
        context: String
    ) throws {
        guard isIntegral(line.values[register]) else {
            throw typeError(register, expected: "integral", actual: line.values[register], label: label, pc: pc, context: context)
        }
    }

    private static func requireFloat(
        line: RegisterLine,
        register: Int,
        label: String,
        pc: Int,
        context: String
    ) throws {
        guard isFloat(line.values[register]) else {
            throw typeError(register, expected: "float", actual: line.values[register], label: label, pc: pc, context: context)
        }
    }

    private static func requireWide(
        line: RegisterLine,
        register: Int,
        expectedLow: RegisterType?,
        label: String,
        pc: Int,
        context: String
    ) throws {
        guard register + 1 < line.values.count,
              isWidePair(line.values[register], line.values[register + 1]) else {
            throw typeError(register, expected: "wide pair", actual: line.values[register], label: label, pc: pc, context: context)
        }
        let actual = line.values[register]
        let matches: Bool
        switch expectedLow {
        case nil:
            matches = true
        case .longLow?:
            matches = actual == .longLow || actual == .constantWideLow
        case .doubleLow?:
            matches = actual == .doubleLow || actual == .constantWideLow
        default:
            preconditionFailure("invalid expected wide type \(String(describing: expectedLow))")
        }
        guard matches else {
            throw typeError(
                register,
                expected: expectedLow == .longLow ? "long pair" : "double pair",
                actual: actual,
                label: label,
                pc: pc,
                context: context
            )
        }
    }

    private static func requireReference(
        line: RegisterLine,
        register: Int,
        allowUninitialized: Bool,
        label: String,
        pc: Int,
        context: String
    ) throws {
        let actual = line.values[register]
        guard isReference(actual) || (allowUninitialized && isUninitializedReference(actual)) else {
            throw typeError(
                register,
                expected: allowUninitialized ? "reference" : "initialized reference",
                actual: actual,
                label: label,
                pc: pc,
                context: context
            )
        }
    }

    private static func require(
        line: RegisterLine,
        register: Int,
        descriptor: String,
        label: String,
        pc: Int,
        hierarchy: DexTypeHierarchy,
        strictReference: Bool = false,
        context: String
    ) throws {
        let expected = try descriptorType(descriptor, context: context)
        switch expected {
        case .integral:
            // ART intentionally treats invocation/field/return integral
            // descriptors as one assignability family. The narrower kinds
            // remain useful for merges and typed opcode results.
            try requireIntegral(line: line, register: register, label: label, pc: pc, context: context)
        case .float:
            try requireFloat(line: line, register: register, label: label, pc: pc, context: context)
        case .longLow:
            try requireWide(line: line, register: register, expectedLow: .longLow, label: label, pc: pc, context: context)
        case .doubleLow:
            try requireWide(line: line, register: register, expectedLow: .doubleLow, label: label, pc: pc, context: context)
        case .reference:
            try requireReference(line: line, register: register, allowUninitialized: false, label: label, pc: pc, context: context)
            if case let .reference(actualDescriptor?) = line.values[register],
               hierarchy.assignability(
                   from: actualDescriptor,
                   to: descriptor,
                   strict: strictReference
               ) == .no {
                throw typeError(
                    register,
                    expected: "reference assignable to \(descriptor)",
                    actual: line.values[register],
                    label: label,
                    pc: pc,
                    context: context
                )
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
        try requireReference(
            line: line,
            register: register,
            allowUninitialized: false,
            label: label,
            pc: pc,
            context: context
        )
        if case let .reference(descriptor?) = line.values[register], !descriptor.hasPrefix("[") {
            throw typeError(register, expected: "array reference", actual: line.values[register], label: label, pc: pc, context: context)
        }
    }

    private static func verifyConstructorReturn(
        line: RegisterLine,
        method: DexFile.EncodedMethod,
        dex: DexFile,
        pc: Int,
        context: String
    ) throws {
        let reference = dex.methodIds[method.methodIndex]
        guard reference.name == "<init>", reference.declaringClass != "Ljava/lang/Object;" else {
            return
        }
        guard line.thisInitialized else {
            throw VMError.verify(
                "constructor returns at pc \(pc) before initializing this in \(context)"
            )
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
