import Foundation

public enum InterpretedInvocationKind: String, Hashable, Sendable {
    case virtual
    case superMethod = "super"
    case direct
    case staticMethod = "static"
    case interface

    fileprivate init(_ kind: DexInvocationKind) {
        switch kind {
        case .virtual: self = .virtual
        case .superMethod: self = .superMethod
        case .direct: self = .direct
        case .staticMethod: self = .staticMethod
        case .interface: self = .interface
        }
    }
}

/// Exact external DEX method identity referenced by an invoke instruction but
/// not directly registered on its declared class in the current host bridge.
/// Virtual/interface calls can still resolve through a runtime receiver, so
/// this is a prioritization signal rather than an execution-failure claim.
public struct InterpretedExternalMethodSurface: Hashable, Sendable {
    public let classDescriptor: String
    public let name: String
    public let prototype: String
    public let invocationKind: InterpretedInvocationKind

    public var summary: String {
        "\(invocationKind.rawValue) \(classDescriptor)->\(name)\(prototype)"
    }

    fileprivate var sortKey: String {
        classDescriptor + "\u{0}" + name + "\u{0}" + prototype + "\u{0}" + invocationKind.rawValue
    }
}

public struct InterpretedExternalMethodFinding: Equatable, Sendable {
    public let surface: InterpretedExternalMethodSurface
    public let invocationCount: Int
    public let declaringMethodCount: Int
}

public struct InterpretedUnsupportedOpcodeFinding: Equatable, Sendable {
    public let opcode: UInt8
    public let name: String
    public let instructionCount: Int
    public let declaringMethodCount: Int
}

/// Privacy-safe structural status carried by a compatibility report. The full
/// plan inspection also contains raw manifest and archive identities, so it is
/// intentionally not embedded in an exportable diagnostic.
public struct InterpretedCompatibilityPlanStatus: Equatable, Sendable {
    public let isStructuralCandidate: Bool
    public let blockers: [InterpretedExtensionPlanBlocker]
}

/// Non-executing, privacy-safe compatibility-gap report for one APK. It emits
/// package/version plus API/opcode identities only; instruction contexts,
/// strings, paths, requests, URLs, headers, cookies, and source data are absent.
public struct InterpretedCompatibilityStaticReport: Equatable, Sendable {
    public let packageName: String
    public let versionName: String
    public let versionCode: Int64?
    public let planStatus: InterpretedCompatibilityPlanStatus
    public let dexCount: Int
    public let codeMethodCount: Int
    public let instructionCount: Int
    public let unregisteredExternalInvocations: [InterpretedExternalMethodFinding]
    public let omittedExternalInvocationCount: Int
    public let unsupportedOpcodes: [InterpretedUnsupportedOpcodeFinding]

    public var identity: String {
        packageName + "@" + versionName + "(" + (versionCode.map(String.init) ?? "?") + ")"
    }
}

public struct InterpretedCorpusMethodFinding: Equatable, Sendable {
    public let surface: InterpretedExternalMethodSurface
    public let extensionCount: Int
    public let invocationCount: Int
}

public struct InterpretedCorpusOpcodeFinding: Equatable, Sendable {
    public let opcode: UInt8
    public let name: String
    public let extensionCount: Int
    public let instructionCount: Int
}

public struct InterpretedCorpusPlanBlockerFinding: Equatable, Sendable {
    public let blocker: InterpretedExtensionPlanBlocker
    public let extensionCount: Int
}

public struct InterpretedCompatibilityCorpusReport: Equatable, Sendable {
    public let extensionCount: Int
    public let structuralCandidateCount: Int
    public let planBlockers: [InterpretedCorpusPlanBlockerFinding]
    public let unregisteredExternalInvocations: [InterpretedCorpusMethodFinding]
    public let omittedExternalInvocationCount: Int
    public let unsupportedOpcodes: [InterpretedCorpusOpcodeFinding]
}

/// Shared static measurement instrument for ranking runtime work by how many
/// extensions a host API/opcode family can unlock. It never executes DEX and
/// creates no trust or admission state.
public struct InterpretedCompatibilityAudit {
    private struct MethodAccumulator {
        var invocationCount = 0
        var declaringMethods: Set<String> = []
    }

    private struct CorpusMethodAccumulator {
        var invocationCount = 0
        var extensionIdentities: Set<String> = []
    }

    private struct CorpusOpcodeAccumulator {
        var instructionCount = 0
        var extensionIdentities: Set<String> = []
    }

    private let maximumUniqueMethodFindings: Int

    public init(maximumUniqueMethodFindings: Int = 4_096) {
        self.maximumUniqueMethodFindings = max(1, min(maximumUniqueMethodFindings, 32_768))
    }

    public func analyze(apkBytes: [UInt8]) throws -> InterpretedCompatibilityStaticReport {
        let manifest = try ExtensionManifest(apkBytes: apkBytes)
        let planInspection = try InterpretedExtensionPlanInspector().inspect(apkBytes: apkBytes)
        let opcodeReport = try DexOpcodeInventory(maximumExamplesPerOpcode: 0).analyze(apk: apkBytes)
        let archive = try ZipArchive(apkBytes)

        var dexFiles: [(name: String, dex: DexFile)] = []
        dexFiles.reserveCapacity(opcodeReport.dexFiles.count)
        for summary in opcodeReport.dexFiles {
            guard let entry = archive.entries.first(where: { $0.name == summary.name }) else {
                throw DexOpcodeInventory.Error.noDexFiles
            }
            dexFiles.append((summary.name, try DexFile(try archive.data(for: entry))))
        }

        let definedClasses = Set(dexFiles.flatMap { $0.dex.classDefs.map(\.descriptor) })
        let bridge = HostBridge.minimal()
        var methods: [InterpretedExternalMethodSurface: MethodAccumulator] = [:]
        var omittedExternalInvocationCount = 0

        for (dexName, dex) in dexFiles {
            for (definition, method, reference) in DexOpcodeInventory.codeMethods(in: dex) {
                guard let code = dex.codeItem(for: method) else { continue }
                let context = definition.descriptor + "->" + reference.signature
                let instructions = try DexCodeVerifier.decodeInstructions(
                    code: code,
                    dex: dex,
                    context: context
                )
                let declaringMethod = dexName + ":" + context

                for instruction in instructions {
                    guard let invocationKind = DexInvocationKind(opcode: instruction.opcode) else {
                        continue
                    }
                    let methodIndex = try Self.methodIndex(
                        instructionAddress: instruction.address,
                        code: code,
                        dex: dex
                    )
                    guard methodIndex >= 0, methodIndex < dex.methodIds.count else {
                        throw VMError.verify("method index \(methodIndex)")
                    }
                    let invoked = dex.methodIds[methodIndex]
                    guard !definedClasses.contains(invoked.declaringClass) else { continue }
                    guard !bridge.hasRegisteredMethod(
                        class: invoked.declaringClass,
                        invoked.name,
                        prototype: invoked.prototype.descriptor,
                        isStatic: invocationKind.isStatic
                    ) else { continue }

                    let surface = InterpretedExternalMethodSurface(
                        classDescriptor: InterpretedCompatibilityRedaction.safeDEXSymbol(
                            invoked.declaringClass
                        ),
                        name: InterpretedCompatibilityRedaction.safeDEXSymbol(invoked.name),
                        prototype: InterpretedCompatibilityRedaction.safeDEXSymbol(
                            invoked.prototype.descriptor
                        ),
                        invocationKind: InterpretedInvocationKind(invocationKind)
                    )
                    if var accumulator = methods[surface] {
                        accumulator.invocationCount = Self.incremented(accumulator.invocationCount)
                        accumulator.declaringMethods.insert(declaringMethod)
                        methods[surface] = accumulator
                    } else if methods.count < maximumUniqueMethodFindings {
                        methods[surface] = MethodAccumulator(
                            invocationCount: 1,
                            declaringMethods: [declaringMethod]
                        )
                    } else {
                        omittedExternalInvocationCount = Self.incremented(
                            omittedExternalInvocationCount
                        )
                    }
                }
            }
        }

        let methodFindings = methods.map { surface, accumulator in
            InterpretedExternalMethodFinding(
                surface: surface,
                invocationCount: accumulator.invocationCount,
                declaringMethodCount: accumulator.declaringMethods.count
            )
        }.sorted {
            if $0.invocationCount != $1.invocationCount {
                return $0.invocationCount > $1.invocationCount
            }
            return $0.surface.sortKey < $1.surface.sortKey
        }
        let opcodeFindings = opcodeReport.opcodes.filter { !$0.executable }.map {
            InterpretedUnsupportedOpcodeFinding(
                opcode: $0.opcode,
                name: $0.name,
                instructionCount: $0.instructionCount,
                declaringMethodCount: $0.methodCount
            )
        }.sorted { $0.opcode < $1.opcode }

        return InterpretedCompatibilityStaticReport(
            packageName: InterpretedCompatibilityRedaction.safePackage(manifest.packageName),
            versionName: InterpretedCompatibilityRedaction.safeVersion(
                manifest.versionName ?? "unknown"
            ),
            versionCode: manifest.versionCode,
            planStatus: InterpretedCompatibilityPlanStatus(
                isStructuralCandidate: planInspection.isStructuralCandidate,
                blockers: planInspection.blockers
            ),
            dexCount: opcodeReport.dexCount,
            codeMethodCount: opcodeReport.codeMethodCount,
            instructionCount: opcodeReport.instructionCount,
            unregisteredExternalInvocations: methodFindings,
            omittedExternalInvocationCount: omittedExternalInvocationCount,
            unsupportedOpcodes: opcodeFindings
        )
    }

    public static func aggregate(
        _ reports: [InterpretedCompatibilityStaticReport]
    ) -> InterpretedCompatibilityCorpusReport {
        var methodAccumulators: [InterpretedExternalMethodSurface: CorpusMethodAccumulator] = [:]
        var opcodeAccumulators: [UInt8: CorpusOpcodeAccumulator] = [:]
        var blockerExtensions: [InterpretedExtensionPlanBlocker: Set<String>] = [:]
        var omittedExternalInvocationCount = 0

        for report in reports {
            let identity = report.identity
            omittedExternalInvocationCount = addingSaturated(
                omittedExternalInvocationCount,
                report.omittedExternalInvocationCount
            )
            for blocker in Set(report.planStatus.blockers) {
                blockerExtensions[blocker, default: []].insert(identity)
            }
            for finding in report.unregisteredExternalInvocations {
                var accumulator = methodAccumulators[finding.surface] ?? CorpusMethodAccumulator()
                accumulator.invocationCount = addingSaturated(
                    accumulator.invocationCount,
                    finding.invocationCount
                )
                accumulator.extensionIdentities.insert(identity)
                methodAccumulators[finding.surface] = accumulator
            }
            for finding in report.unsupportedOpcodes {
                var accumulator = opcodeAccumulators[finding.opcode] ?? CorpusOpcodeAccumulator()
                accumulator.instructionCount = addingSaturated(
                    accumulator.instructionCount,
                    finding.instructionCount
                )
                accumulator.extensionIdentities.insert(identity)
                opcodeAccumulators[finding.opcode] = accumulator
            }
        }

        let methodFindings = methodAccumulators.map { surface, accumulator in
            InterpretedCorpusMethodFinding(
                surface: surface,
                extensionCount: accumulator.extensionIdentities.count,
                invocationCount: accumulator.invocationCount
            )
        }.sorted {
            if $0.extensionCount != $1.extensionCount {
                return $0.extensionCount > $1.extensionCount
            }
            if $0.invocationCount != $1.invocationCount {
                return $0.invocationCount > $1.invocationCount
            }
            return $0.surface.sortKey < $1.surface.sortKey
        }
        let opcodeFindings = opcodeAccumulators.map { opcode, accumulator in
            InterpretedCorpusOpcodeFinding(
                opcode: opcode,
                name: DexOpcodeInventory.name(for: opcode),
                extensionCount: accumulator.extensionIdentities.count,
                instructionCount: accumulator.instructionCount
            )
        }.sorted {
            if $0.extensionCount != $1.extensionCount {
                return $0.extensionCount > $1.extensionCount
            }
            if $0.instructionCount != $1.instructionCount {
                return $0.instructionCount > $1.instructionCount
            }
            return $0.opcode < $1.opcode
        }
        let blockers = blockerExtensions.map { blocker, identities in
            InterpretedCorpusPlanBlockerFinding(
                blocker: blocker,
                extensionCount: identities.count
            )
        }.sorted {
            if $0.extensionCount != $1.extensionCount {
                return $0.extensionCount > $1.extensionCount
            }
            return $0.blocker.summary < $1.blocker.summary
        }

        return InterpretedCompatibilityCorpusReport(
            extensionCount: reports.count,
            structuralCandidateCount: reports.filter(\.planStatus.isStructuralCandidate).count,
            planBlockers: blockers,
            unregisteredExternalInvocations: methodFindings,
            omittedExternalInvocationCount: omittedExternalInvocationCount,
            unsupportedOpcodes: opcodeFindings
        )
    }

    private static func methodIndex(
        instructionAddress: Int,
        code: DexFile.CodeItem,
        dex: DexFile
    ) throws -> Int {
        let unitAddress = instructionAddress + 1
        guard unitAddress >= 0, unitAddress < code.insnsCount else {
            throw VMError.verify("invoke method index outside code item")
        }
        let byteOffset = code.insnsOffset + unitAddress * 2
        guard byteOffset >= 0, byteOffset + 1 < dex.source.count else {
            throw VMError.verify("invoke method index outside DEX")
        }
        return Int(dex.source[byteOffset]) | Int(dex.source[byteOffset + 1]) << 8
    }

    private static func incremented(_ value: Int) -> Int {
        value == Int.max ? value : value + 1
    }

    private static func addingSaturated(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }
}
