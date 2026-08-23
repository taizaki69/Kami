import Foundation

/// Deterministic, instruction-boundary-aware opcode inventory for extension
/// APKs. Every `classes*.dex` entry is decoded with the same geometry logic as
/// the runtime verifier; operand words and payload bodies are never counted as
/// instructions.
public struct DexOpcodeInventory {
    public enum Error: Swift.Error, CustomStringConvertible {
        case noDexFiles
        case duplicateDexOrdinal(Int)
        case malformedCodeItem(dexName: String, method: String)

        public var description: String {
            switch self {
            case .noDexFiles:
                return "APK contains no classes*.dex entries"
            case let .duplicateDexOrdinal(ordinal):
                return "APK contains more than one DEX entry for ordinal \(ordinal)"
            case let .malformedCodeItem(dexName, method):
                return "\(dexName) has a malformed code item for \(method)"
            }
        }
    }

    public struct Occurrence: Equatable {
        public let dexName: String
        public let dexVersion: Int
        public let declaringClass: String
        public let methodSignature: String
        public let address: Int
    }

    public struct DexSummary: Equatable {
        public let name: String
        public let version: Int
        public let codeMethodCount: Int
        public let instructionCount: Int
    }

    public struct OpcodeSummary: Equatable {
        public let opcode: UInt8
        public let name: String
        public let instructionCount: Int
        public let methodCount: Int
        public let structurallyDecoded: Bool
        public let registerVerified: Bool
        public let executable: Bool
        public let examples: [Occurrence]
    }

    public struct Report: Equatable {
        public let dexFiles: [DexSummary]
        public let opcodes: [OpcodeSummary]

        public var dexCount: Int { dexFiles.count }
        public var codeMethodCount: Int { dexFiles.reduce(0) { $0 + $1.codeMethodCount } }
        public var instructionCount: Int { dexFiles.reduce(0) { $0 + $1.instructionCount } }
    }

    private struct DexTarget {
        let ordinal: Int
        let entry: ZipArchive.Entry
    }

    private struct Accumulator {
        var instructionCount = 0
        var methods: Set<String> = []
        var examples: [Occurrence] = []
    }

    private let maximumExamplesPerOpcode: Int

    public init(maximumExamplesPerOpcode: Int = 3) {
        self.maximumExamplesPerOpcode = max(0, min(maximumExamplesPerOpcode, 20))
    }

    public func analyze(apk bytes: [UInt8]) throws -> Report {
        let archive = try ZipArchive(bytes)
        let targets = try Self.dexTargets(in: archive)
        var dexSummaries: [DexSummary] = []
        var accumulators: [UInt8: Accumulator] = [:]

        for target in targets {
            let dex = try DexFile(try archive.data(for: target.entry))
            let methods = Self.codeMethods(in: dex)
            var dexInstructionCount = 0

            for (definition, method, reference) in methods {
                let context = "\(definition.descriptor)->\(reference.signature)"
                guard let code = dex.codeItem(for: method) else {
                    if method.codeOffset != 0 {
                        throw Error.malformedCodeItem(dexName: target.entry.name, method: context)
                    }
                    continue
                }
                let instructions = try DexCodeVerifier.decodeInstructions(
                    code: code,
                    dex: dex,
                    context: context
                )
                dexInstructionCount += instructions.count
                let methodKey = target.entry.name + ":" + context

                for instruction in instructions {
                    var accumulator = accumulators[instruction.opcode] ?? Accumulator()
                    accumulator.instructionCount += 1
                    accumulator.methods.insert(methodKey)
                    if accumulator.examples.count < maximumExamplesPerOpcode {
                        accumulator.examples.append(Occurrence(
                            dexName: target.entry.name,
                            dexVersion: dex.version,
                            declaringClass: definition.descriptor,
                            methodSignature: reference.signature,
                            address: instruction.address
                        ))
                    }
                    accumulators[instruction.opcode] = accumulator
                }
            }

            dexSummaries.append(DexSummary(
                name: target.entry.name,
                version: dex.version,
                codeMethodCount: methods.count,
                instructionCount: dexInstructionCount
            ))
        }

        let opcodeSummaries = accumulators.keys.sorted().map { opcode in
            let accumulator = accumulators[opcode]!
            return OpcodeSummary(
                opcode: opcode,
                name: Self.name(for: opcode),
                instructionCount: accumulator.instructionCount,
                methodCount: accumulator.methods.count,
                structurallyDecoded: Self.isStructurallyDecoded(opcode),
                registerVerified: Self.isRegisterVerified(opcode),
                executable: Self.isExecutable(opcode),
                examples: accumulator.examples
            )
        }
        return Report(dexFiles: dexSummaries, opcodes: opcodeSummaries)
    }

    public static func name(for opcode: UInt8) -> String {
        opcodeNames[opcode] ?? "reserved"
    }

    private static func dexTargets(in archive: ZipArchive) throws -> [DexTarget] {
        let targets = archive.entries.compactMap { entry -> DexTarget? in
            guard let ordinal = dexOrdinal(entry.name) else { return nil }
            return DexTarget(ordinal: ordinal, entry: entry)
        }.sorted {
            if $0.ordinal != $1.ordinal { return $0.ordinal < $1.ordinal }
            return $0.entry.name < $1.entry.name
        }
        guard !targets.isEmpty else { throw Error.noDexFiles }
        for pair in zip(targets, targets.dropFirst()) where pair.0.ordinal == pair.1.ordinal {
            throw Error.duplicateDexOrdinal(pair.0.ordinal)
        }
        return targets
    }

    private static func dexOrdinal(_ name: String) -> Int? {
        guard name.hasPrefix("classes"), name.hasSuffix(".dex") else { return nil }
        let suffixStart = name.index(name.startIndex, offsetBy: 7)
        let suffixEnd = name.index(name.endIndex, offsetBy: -4)
        let suffix = name[suffixStart..<suffixEnd]
        if suffix.isEmpty { return 1 }
        guard suffix.allSatisfy(\.isNumber),
              !suffix.hasPrefix("0"),
              let ordinal = Int(suffix), ordinal >= 2 else { return nil }
        return ordinal
    }

    private static func codeMethods(
        in dex: DexFile
    ) -> [(DexFile.ClassDef, DexFile.EncodedMethod, DexFile.MethodRef)] {
        var result: [(DexFile.ClassDef, DexFile.EncodedMethod, DexFile.MethodRef)] = []
        for definition in dex.classDefs.sorted(by: { $0.descriptor < $1.descriptor }) {
            for method in (definition.directMethods + definition.virtualMethods).sorted(by: {
                let lhs = dex.methodIds[$0.methodIndex]
                let rhs = dex.methodIds[$1.methodIndex]
                if lhs.signature != rhs.signature { return lhs.signature < rhs.signature }
                return $0.methodIndex < $1.methodIndex
            }) where method.codeOffset != 0 {
                result.append((definition, method, dex.methodIds[method.methodIndex]))
            }
        }
        return result
    }

    private static func isStructurallyDecoded(_ opcode: UInt8) -> Bool {
        switch opcode {
        case 0x00...0x3d, 0x44...0x72, 0x74...0x78, 0x7b...0xe2, 0xfa...0xff:
            return true
        default:
            return false
        }
    }

    private static func isRegisterVerified(_ opcode: UInt8) -> Bool {
        // DexRegisterVerifier currently has bounds and transfer handling for
        // every instruction accepted by the structural decoder.
        isStructurallyDecoded(opcode)
    }

    private static func isExecutable(_ opcode: UInt8) -> Bool {
        switch opcode {
        case 0x00...0x3d, 0x44...0x72, 0x74...0x78, 0x7b...0xe2:
            return true
        default:
            return false
        }
    }

    private static let opcodeNames: [UInt8: String] = {
        var names: [UInt8: String] = [:]
        func add(_ start: UInt8, _ values: [String]) {
            for (offset, value) in values.enumerated() {
                names[UInt8(Int(start) + offset)] = value
            }
        }

        add(0x00, [
            "nop", "move", "move/from16", "move/16", "move-wide",
            "move-wide/from16", "move-wide/16", "move-object",
            "move-object/from16", "move-object/16", "move-result",
            "move-result-wide", "move-result-object", "move-exception",
            "return-void", "return", "return-wide", "return-object",
            "const/4", "const/16", "const", "const/high16", "const-wide/16",
            "const-wide/32", "const-wide", "const-wide/high16", "const-string",
            "const-string/jumbo", "const-class", "monitor-enter", "monitor-exit",
            "check-cast", "instance-of", "array-length", "new-instance",
            "new-array", "filled-new-array", "filled-new-array/range",
            "fill-array-data", "throw", "goto", "goto/16", "goto/32",
            "packed-switch", "sparse-switch", "cmpl-float", "cmpg-float",
            "cmpl-double", "cmpg-double", "cmp-long", "if-eq", "if-ne",
            "if-lt", "if-ge", "if-gt", "if-le", "if-eqz", "if-nez",
            "if-ltz", "if-gez", "if-gtz", "if-lez",
        ])
        add(0x44, [
            "aget", "aget-wide", "aget-object", "aget-boolean", "aget-byte",
            "aget-char", "aget-short", "aput", "aput-wide", "aput-object",
            "aput-boolean", "aput-byte", "aput-char", "aput-short", "iget",
            "iget-wide", "iget-object", "iget-boolean", "iget-byte", "iget-char",
            "iget-short", "iput", "iput-wide", "iput-object", "iput-boolean",
            "iput-byte", "iput-char", "iput-short", "sget", "sget-wide",
            "sget-object", "sget-boolean", "sget-byte", "sget-char", "sget-short",
            "sput", "sput-wide", "sput-object", "sput-boolean", "sput-byte",
            "sput-char", "sput-short", "invoke-virtual", "invoke-super",
            "invoke-direct", "invoke-static", "invoke-interface",
        ])
        add(0x74, [
            "invoke-virtual/range", "invoke-super/range", "invoke-direct/range",
            "invoke-static/range", "invoke-interface/range",
        ])
        add(0x7b, [
            "neg-int", "not-int", "neg-long", "not-long", "neg-float",
            "neg-double", "int-to-long", "int-to-float", "int-to-double",
            "long-to-int", "long-to-float", "long-to-double", "float-to-int",
            "float-to-long", "float-to-double", "double-to-int", "double-to-long",
            "double-to-float", "int-to-byte", "int-to-char", "int-to-short",
        ])
        add(0x90, [
            "add-int", "sub-int", "mul-int", "div-int", "rem-int", "and-int",
            "or-int", "xor-int", "shl-int", "shr-int", "ushr-int", "add-long",
            "sub-long", "mul-long", "div-long", "rem-long", "and-long", "or-long",
            "xor-long", "shl-long", "shr-long", "ushr-long", "add-float",
            "sub-float", "mul-float", "div-float", "rem-float", "add-double",
            "sub-double", "mul-double", "div-double", "rem-double",
        ])
        add(0xb0, [
            "add-int/2addr", "sub-int/2addr", "mul-int/2addr", "div-int/2addr",
            "rem-int/2addr", "and-int/2addr", "or-int/2addr", "xor-int/2addr",
            "shl-int/2addr", "shr-int/2addr", "ushr-int/2addr", "add-long/2addr",
            "sub-long/2addr", "mul-long/2addr", "div-long/2addr", "rem-long/2addr",
            "and-long/2addr", "or-long/2addr", "xor-long/2addr", "shl-long/2addr",
            "shr-long/2addr", "ushr-long/2addr", "add-float/2addr",
            "sub-float/2addr", "mul-float/2addr", "div-float/2addr",
            "rem-float/2addr", "add-double/2addr", "sub-double/2addr",
            "mul-double/2addr", "div-double/2addr", "rem-double/2addr",
        ])
        add(0xd0, [
            "add-int/lit16", "rsub-int", "mul-int/lit16", "div-int/lit16",
            "rem-int/lit16", "and-int/lit16", "or-int/lit16", "xor-int/lit16",
            "add-int/lit8", "rsub-int/lit8", "mul-int/lit8", "div-int/lit8",
            "rem-int/lit8", "and-int/lit8", "or-int/lit8", "xor-int/lit8",
            "shl-int/lit8", "shr-int/lit8", "ushr-int/lit8",
        ])
        add(0xfa, [
            "invoke-polymorphic", "invoke-polymorphic/range", "invoke-custom",
            "invoke-custom/range", "const-method-handle", "const-method-type",
        ])
        return names
    }()
}
