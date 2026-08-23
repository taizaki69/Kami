import Foundation

/// Bounded structural verification for one DEX `code_item` before execution.
///
/// This pass deliberately focuses on geometry and control flow. Register-type
/// dataflow remains a later M1 milestone, but malformed code cannot hide a
/// truncated instruction, branch into an operand/payload, or point a switch at
/// the wrong payload family merely because that path was not taken at runtime.
enum DexCodeVerifier {
    static let maximumCodeUnits = 2_000_000

    private enum PayloadKind: String {
        case packedSwitch = "packed-switch"
        case sparseSwitch = "sparse-switch"
        case arrayData = "array-data"
    }

    private struct PayloadInfo {
        let kind: PayloadKind
        let width: Int
    }

    private struct InstructionInfo {
        let address: Int
        let width: Int
        let opcode: UInt8
    }

    private struct BranchReference {
        let source: Int
        let offset: Int64
        let name: String
    }

    private struct PayloadReference {
        let source: Int
        let offset: Int64
        let expectedKind: PayloadKind
    }

    static func verify(
        code: DexFile.CodeItem,
        method: DexFile.EncodedMethod,
        dex: DexFile
    ) throws {
        let reference = dex.methodIds[method.methodIndex]
        let context = "\(reference.declaringClass)->\(reference.signature)"
        guard code.insnsCount > 0 else {
            throw VMError.verify("empty code item for \(context)")
        }
        guard code.insnsCount <= maximumCodeUnits else {
            throw VMError.verify(
                "code item for \(context) has \(code.insnsCount) units; limit is \(maximumCodeUnits)"
            )
        }

        let (byteCount, byteCountOverflow) = code.insnsCount.multipliedReportingOverflow(by: 2)
        guard !byteCountOverflow, code.insnsOffset >= 0,
              byteCount <= dex.source.count,
              code.insnsOffset <= dex.source.count - byteCount else {
            throw VMError.verify("truncated instruction stream for \(context)")
        }

        var units: [UInt16] = []
        units.reserveCapacity(code.insnsCount)
        for index in 0..<code.insnsCount {
            let offset = code.insnsOffset + index * 2
            units.append(UInt16(dex.source[offset]) | UInt16(dex.source[offset + 1]) << 8)
        }

        var instructionStarts: Set<Int> = []
        var instructions: [InstructionInfo] = []
        var payloads: [Int: PayloadInfo] = [:]
        var branches: [BranchReference] = []
        var payloadReferences: [PayloadReference] = []
        var pc = 0

        while pc < units.count {
            let word = units[pc]
            let opcode = UInt8(word & 0xff)
            if opcode == 0 {
                if word == 0 {
                    instructionStarts.insert(pc)
                    instructions.append(InstructionInfo(address: pc, width: 1, opcode: opcode))
                    pc += 1
                    continue
                }
                let payload = try payloadInfo(at: pc, units: units, context: context)
                payloads[pc] = payload
                pc += payload.width
                continue
            }

            let width = try instructionWidth(opcode, address: pc, context: context)
            guard width <= units.count - pc else {
                throw VMError.verify(
                    "truncated opcode 0x\(String(opcode, radix: 16)) at pc \(pc) in \(context)"
                )
            }
            instructionStarts.insert(pc)
            instructions.append(InstructionInfo(address: pc, width: width, opcode: opcode))

            switch opcode {
            case 0x28:
                branches.append(BranchReference(
                    source: pc,
                    offset: Int64(Int8(bitPattern: UInt8(word >> 8))),
                    name: "goto"
                ))
            case 0x29:
                branches.append(BranchReference(
                    source: pc,
                    offset: Int64(Int16(bitPattern: units[pc + 1])),
                    name: "goto/16"
                ))
            case 0x2a:
                branches.append(BranchReference(
                    source: pc,
                    offset: signed32(units[pc + 1], units[pc + 2]),
                    name: "goto/32"
                ))
            case 0x32...0x37:
                branches.append(BranchReference(
                    source: pc,
                    offset: Int64(Int16(bitPattern: units[pc + 1])),
                    name: "if-test"
                ))
            case 0x38...0x3d:
                branches.append(BranchReference(
                    source: pc,
                    offset: Int64(Int16(bitPattern: units[pc + 1])),
                    name: "if-testz"
                ))
            case 0x26:
                payloadReferences.append(PayloadReference(
                    source: pc,
                    offset: signed32(units[pc + 1], units[pc + 2]),
                    expectedKind: .arrayData
                ))
            case 0x2b:
                payloadReferences.append(PayloadReference(
                    source: pc,
                    offset: signed32(units[pc + 1], units[pc + 2]),
                    expectedKind: .packedSwitch
                ))
            case 0x2c:
                payloadReferences.append(PayloadReference(
                    source: pc,
                    offset: signed32(units[pc + 1], units[pc + 2]),
                    expectedKind: .sparseSwitch
                ))
            default:
                break
            }
            pc += width
        }

        for instruction in instructions where hasFallthrough(instruction.opcode) {
            let next = instruction.address + instruction.width
            guard next < units.count, instructionStarts.contains(next) else {
                let destination = next == units.count ? "end of code item" : "non-instruction pc \(next)"
                throw VMError.verify(
                    "opcode 0x\(String(instruction.opcode, radix: 16)) at pc \(instruction.address) "
                        + "falls through to \(destination) in \(context)"
                )
            }
        }

        for branch in branches {
            _ = try executableTarget(
                source: branch.source,
                offset: branch.offset,
                name: branch.name,
                instructionStarts: instructionStarts,
                codeUnitCount: units.count,
                context: context
            )
        }

        for payloadReference in payloadReferences {
            let payloadAddress = try relativeAddress(
                source: payloadReference.source,
                offset: payloadReference.offset,
                name: payloadReference.expectedKind.rawValue + " payload",
                codeUnitCount: units.count,
                context: context
            )
            guard let payload = payloads[payloadAddress],
                  payload.kind == payloadReference.expectedKind else {
                throw VMError.verify(
                    "\(payloadReference.expectedKind.rawValue) at pc \(payloadReference.source) "
                        + "does not reference a matching payload at pc \(payloadAddress) in \(context)"
                )
            }
            try verifyPayloadTargets(
                payloadReference,
                payloadAddress: payloadAddress,
                units: units,
                instructionStarts: instructionStarts,
                context: context
            )
        }
    }

    private static func instructionWidth(
        _ opcode: UInt8,
        address: Int,
        context: String
    ) throws -> Int {
        switch opcode {
        case 0x01, 0x04, 0x07, 0x0a...0x12, 0x1d, 0x1e, 0x21, 0x27, 0x28,
             0x7b...0x8f, 0xb0...0xcf:
            return 1
        case 0x02, 0x05, 0x08, 0x13, 0x15, 0x16, 0x19, 0x1a, 0x1c, 0x1f,
             0x20, 0x22, 0x23, 0x29, 0x2d...0x3d, 0x44...0x6d, 0x90...0xaf,
             0xd0...0xe2, 0xfe, 0xff:
            return 2
        case 0x03, 0x06, 0x09, 0x14, 0x17, 0x1b, 0x24...0x26, 0x2a...0x2c,
             0x6e...0x72, 0x74...0x78, 0xfc, 0xfd:
            return 3
        case 0xfa, 0xfb:
            return 4
        case 0x18:
            return 5
        default:
            throw VMError.verify(
                "invalid DEX opcode 0x\(String(opcode, radix: 16)) at pc \(address) in \(context)"
            )
        }
    }

    private static func payloadInfo(
        at address: Int,
        units: [UInt16],
        context: String
    ) throws -> PayloadInfo {
        guard address % 2 == 0 else {
            throw VMError.verify("unaligned payload at pc \(address) in \(context)")
        }
        let identifier = units[address]
        switch identifier {
        case 0x0100:
            guard address + 4 <= units.count else {
                throw VMError.verify("truncated packed-switch payload at pc \(address) in \(context)")
            }
            let size = Int(units[address + 1])
            let width = 4 + size * 2
            guard width <= units.count - address else {
                throw VMError.verify("truncated packed-switch payload at pc \(address) in \(context)")
            }
            return PayloadInfo(kind: .packedSwitch, width: width)
        case 0x0200:
            guard address + 2 <= units.count else {
                throw VMError.verify("truncated sparse-switch payload at pc \(address) in \(context)")
            }
            let size = Int(units[address + 1])
            let width = 2 + size * 4
            guard width <= units.count - address else {
                throw VMError.verify("truncated sparse-switch payload at pc \(address) in \(context)")
            }
            return PayloadInfo(kind: .sparseSwitch, width: width)
        case 0x0300:
            guard address + 4 <= units.count else {
                throw VMError.verify("truncated array-data payload at pc \(address) in \(context)")
            }
            let elementWidth = UInt64(units[address + 1])
            guard [1, 2, 4, 8].contains(elementWidth) else {
                throw VMError.verify(
                    "array-data payload at pc \(address) has element width \(elementWidth) in \(context)"
                )
            }
            let elementCount = UInt64(units[address + 2])
                | UInt64(units[address + 3]) << 16
            let (byteCount, overflow) = elementCount.multipliedReportingOverflow(by: elementWidth)
            guard !overflow else {
                throw VMError.verify("array-data payload size overflow at pc \(address) in \(context)")
            }
            let dataUnits = (byteCount + 1) / 2
            guard dataUnits <= UInt64(Int.max - 4) else {
                throw VMError.verify("array-data payload is too large at pc \(address) in \(context)")
            }
            let width = 4 + Int(dataUnits)
            guard width <= units.count - address else {
                throw VMError.verify("truncated array-data payload at pc \(address) in \(context)")
            }
            return PayloadInfo(kind: .arrayData, width: width)
        default:
            throw VMError.verify(
                "invalid nop/payload identifier 0x\(String(identifier, radix: 16)) "
                    + "at pc \(address) in \(context)"
            )
        }
    }

    private static func hasFallthrough(_ opcode: UInt8) -> Bool {
        switch opcode {
        case 0x0e...0x11, 0x27...0x2a:
            return false
        default:
            return true
        }
    }

    private static func verifyPayloadTargets(
        _ reference: PayloadReference,
        payloadAddress: Int,
        units: [UInt16],
        instructionStarts: Set<Int>,
        context: String
    ) throws {
        switch reference.expectedKind {
        case .arrayData:
            return
        case .packedSwitch:
            let size = Int(units[payloadAddress + 1])
            for index in 0..<size {
                let offsetAddress = payloadAddress + 4 + index * 2
                _ = try executableTarget(
                    source: reference.source,
                    offset: signed32(units[offsetAddress], units[offsetAddress + 1]),
                    name: "packed-switch case",
                    instructionStarts: instructionStarts,
                    codeUnitCount: units.count,
                    context: context
                )
            }
        case .sparseSwitch:
            let size = Int(units[payloadAddress + 1])
            var previousKey: Int32?
            for index in 0..<size {
                let keyAddress = payloadAddress + 2 + index * 2
                let key = Int32(bitPattern: UInt32(units[keyAddress])
                    | UInt32(units[keyAddress + 1]) << 16)
                if let previousKey, key <= previousKey {
                    throw VMError.verify(
                        "sparse-switch keys are not strictly increasing at pc \(payloadAddress) in \(context)"
                    )
                }
                previousKey = key

                let offsetAddress = payloadAddress + 2 + size * 2 + index * 2
                _ = try executableTarget(
                    source: reference.source,
                    offset: signed32(units[offsetAddress], units[offsetAddress + 1]),
                    name: "sparse-switch case",
                    instructionStarts: instructionStarts,
                    codeUnitCount: units.count,
                    context: context
                )
            }
        }
    }

    private static func executableTarget(
        source: Int,
        offset: Int64,
        name: String,
        instructionStarts: Set<Int>,
        codeUnitCount: Int,
        context: String
    ) throws -> Int {
        let target = try relativeAddress(
            source: source,
            offset: offset,
            name: name,
            codeUnitCount: codeUnitCount,
            context: context
        )
        guard instructionStarts.contains(target) else {
            throw VMError.verify(
                "\(name) at pc \(source) targets non-instruction pc \(target) in \(context)"
            )
        }
        return target
    }

    private static func relativeAddress(
        source: Int,
        offset: Int64,
        name: String,
        codeUnitCount: Int,
        context: String
    ) throws -> Int {
        let (target, overflow) = Int64(source).addingReportingOverflow(offset)
        guard !overflow, target >= 0, target < Int64(codeUnitCount) else {
            throw VMError.verify(
                "\(name) at pc \(source) targets pc \(target) outside code item in \(context)"
            )
        }
        return Int(target)
    }

    private static func signed32(_ low: UInt16, _ high: UInt16) -> Int64 {
        Int64(Int32(bitPattern: UInt32(low) | UInt32(high) << 16))
    }
}
