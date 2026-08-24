import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import MihonCompatKit

/// compat-audit — extension APK analyzer (mission §47/§48).
///
/// Usage:
///   compat-audit inspect <path.apk>       Parse manifest + DEX, print report.
///   compat-audit missing <path.apk> [N]   Top-N missing external classes.
///   compat-audit index <url-or-file>      Dump an extension store index.
///   compat-audit methods <path.apk> [q]   Exact first-DEX method references.
///   compat-audit opcodes <apk-or-dir>      Exact all-DEX opcode inventory.
///   compat-audit plan <apk-or-dir>         Structural execution-plan blockers.
///   compat-audit gaps <apk-or-dir>         Redacted static gap/corpus report.
///
/// Works on any Swift host (Windows/Linux/macOS); pure Foundation.

@main
struct CompatAudit {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            print("""
            usage:
              compat-audit inspect <path.apk>
              compat-audit missing <path.apk> [count]
              compat-audit index <url-or-path>
              compat-audit disasm <path.apk> [class-filter]
              compat-audit methods <path.apk> [text-or-decimal-index]
              compat-audit opcodes <apk-or-directory>
              compat-audit plan <apk-or-directory>
              compat-audit gaps <apk-or-directory>
            """)
            exit(64)
        }

        switch args[1] {
        case "inspect", "missing":
            let path = args[2]
            guard let data = FileManager.default.contents(atPath: path) else {
                print("error: cannot read \(path)")
                exit(66)
            }
            do {
                let analyzer = ExtensionAnalyzer()
                let report = try analyzer.analyze(apk: [UInt8](data))
                if args[1] == "inspect" {
                    inspect(report)
                } else {
                    let n = args.count > 3 ? Int(args[3]) ?? 25 : 25
                    missing(report, limit: n)
                }
            } catch {
                print("error: \(error)")
                exit(70)
            }

        case "index":
            await dumpIndex(args[2])

        case "disasm":
            guard let data = FileManager.default.contents(atPath: args[2]) else {
                print("error: cannot read \(args[2])")
                exit(66)
            }
            let filter = args.count > 3 ? args[3] : ""
            disasm([UInt8](data), filter: filter)

        case "methods":
            guard let data = FileManager.default.contents(atPath: args[2]) else {
                print("error: cannot read \(args[2])")
                exit(66)
            }
            let filter = args.count > 3 ? args[3] : ""
            methods([UInt8](data), filter: filter)

        case "opcodes":
            opcodeReport(at: args[2])

        case "plan":
            executionPlanReport(at: args[2])

        case "gaps":
            compatibilityGapReport(at: args[2])

        default:
            print("unknown subcommand \(args[1])")
            exit(64)
        }
    }

    /// Portable download via continuation (async URLSession conveniences are
    /// Darwin-only).
    static func download(_ url: URL) async throws -> ([UInt8], Int) {
        try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.dataTask(with: url) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 200
                continuation.resume(returning: ([UInt8](data ?? Data()), code))
            }
            task.resume()
        }
    }

    /// Lists classes/methods of the first dex; for each method prints a short
    /// disassembly (opcode names for common families) to locate methods with
    /// shallow dependency graphs for runtime execution tests.
    static func disasm(_ bytes: [UInt8], filter: String) {
        do {
            let zip = try ZipArchive(bytes)
            let dexBytes = try zip.data(named: "classes.dex")
            let dex = try DexFile(dexBytes)
            let vm = DexInterpreter(dex: dex)
            _ = vm
            for (ci, def) in dex.classDefs.enumerated() {
                let cls = DexFile.readableClassName(def.descriptor)
                if !filter.isEmpty && !cls.lowercased().contains(filter.lowercased()) { continue }
                print("== [\(ci)] \(cls)")
                for m in def.directMethods + def.virtualMethods {
                    let ref = m.methodIndex < dex.methodIds.count ? dex.methodIds[m.methodIndex] : nil
                    let name = ref?.name ?? "?"
                    let proto = ref.map { r in "\(r.prototype.returnType) (\(r.prototype.parameters.joined(separator: ",")))" } ?? "?"
                    guard let code = dex.codeItem(for: m) else {
                        print("    \(name)\(proto) [abstract/native]")
                        continue
                    }
                    var insnsText: [String] = []
                    for i in 0..<min(code.insnsCount, 12) {
                        let off = code.insnsOffset + i * 2
                        let unit = UInt16(dex.source[off]) | UInt16(dex.source[off + 1]) << 8
                        insnsText.append(String(format: "%04x", unit))
                    }
                    let more = code.insnsCount > 12 ? " … (\(code.insnsCount)u)" : ""
                    print("    \(name): \(proto) [regs=\(code.registersSize)] \(insnsText.joined(separator: " "))\(more)")
                }
            }
        } catch {
            print("error: \(error)")
            exit(70)
        }
    }

    /// Prints canonical overload identities instead of the lossy name/shorty
    /// view. A decimal filter selects one method_id directly; text matches the
    /// declaring class or signature case-insensitively.
    static func methods(_ bytes: [UInt8], filter: String) {
        do {
            let zip = try ZipArchive(bytes)
            let dex = try DexFile(try zip.data(named: "classes.dex"))
            let selectedIndex = Int(filter)
            let needle = filter.lowercased()
            for (index, reference) in dex.methodIds.enumerated() {
                if let selectedIndex {
                    if index != selectedIndex { continue }
                } else if !needle.isEmpty {
                    let searchable = reference.declaringClass + "." + reference.signature
                    if !searchable.lowercased().contains(needle) { continue }
                }
                let defined = dex.classIndexByDescriptor[reference.declaringClass] == nil ? "external" : "defined"
                print(String(format: "method@%-6d [%@] %@->%@", index, defined,
                             reference.declaringClass, reference.signature))
            }
        } catch {
            print("error: \(error)")
            exit(70)
        }
    }

    /// Inventories exact decoded instructions across every classes*.dex entry.
    /// A directory is processed offline in deterministic APK-name order.
    static func opcodeReport(at path: String) {
        do {
            let urls = try opcodeInputURLs(at: path)
            var reports: [(name: String, report: DexOpcodeInventory.Report)] = []
            let inventory = DexOpcodeInventory()
            for url in urls {
                let bytes = [UInt8](try Data(contentsOf: url))
                reports.append((url.lastPathComponent, try inventory.analyze(apk: bytes)))
            }

            for (index, item) in reports.enumerated() {
                if index > 0 { print("") }
                printOpcodeReport(name: item.name, report: item.report)
            }
            if reports.count > 1 {
                print("")
                printCorpusOpcodeTotals(reports)
            }
        } catch {
            print("error: \(error)")
            exit(70)
        }
    }

    /// Inspects one APK or a directory in deterministic filename order without
    /// executing DEX or establishing signer trust. Unsupported artifacts are a
    /// successful report with blockers; malformed/unreadable artifacts fail.
    static func executionPlanReport(at path: String) {
        do {
            let urls = try opcodeInputURLs(at: path)
            let inspector = InterpretedExtensionPlanInspector()
            var encounteredError = false
            for (index, url) in urls.enumerated() {
                if index > 0 { print("") }
                print("== \(url.lastPathComponent) ==")
                do {
                    let bytes = try boundedAPKBytes(at: url)
                    let inspection = try inspector.inspect(apkBytes: bytes)
                    print("package:            \(inspection.packageName)")
                    print("version:            \(inspection.versionName ?? "?") (\(inspection.versionCode.map(String.init) ?? "?"))")
                    print("extensionLib:       \(inspection.extensionLibVersion ?? "?")")
                    print("dex files:          \(inspection.dexEntryNames.joined(separator: ", "))")
                    print("native libraries:   \(inspection.nativeLibraryCount)")
                    if let plan = inspection.plan {
                        print("structural plan:    candidate (not admitted or execution-proven)")
                        print("entry:              \(plan.entryClassDescriptor)")
                        print("stable wrapper:     \(plan.sourceAPIWrapperDescriptor)")
                    } else {
                        print("structural plan:    blocked")
                        for blocker in inspection.blockers {
                            print("  - \(blocker.summary)")
                        }
                    }
                } catch {
                    encounteredError = true
                    print("error: \(error)")
                }
            }
            if encounteredError { exit(70) }
        } catch {
            print("error: \(error)")
            exit(70)
        }
    }

    static func boundedAPKBytes(at url: URL) throws -> [UInt8] {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true,
              let size = values.fileSize,
              size <= APKSignatureVerifier.maximumAPKSize else {
            throw CocoaError(.fileReadTooLarge)
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count == size else { throw CocoaError(.fileReadUnknown) }
        return [UInt8](data)
    }

    /// Produces a redirectable privacy-safe report. Artifact ordinals replace
    /// filenames, and per-file failures are intentionally generic; only
    /// manifest package/version plus DEX API/opcode identities are exported.
    static func compatibilityGapReport(at path: String) {
        do {
            let urls = try opcodeInputURLs(at: path)
            let auditor = InterpretedCompatibilityAudit()
            var reports: [InterpretedCompatibilityStaticReport] = []
            var encounteredErrors = 0

            print("Kami static compatibility gaps v1")
            print("artifacts: \(urls.count)")
            for (index, url) in urls.enumerated() {
                print("")
                print("== artifact \(index + 1) ==")
                do {
                    let report = try auditor.analyze(apkBytes: boundedAPKBytes(at: url))
                    reports.append(report)
                    print("identity:            \(report.identity)")
                    print("structural plan:     \(report.planStatus.isStructuralCandidate ? "candidate (not admitted or execution-proven)" : "blocked")")
                    for blocker in report.planStatus.blockers {
                        print("  blocker: \(blocker.summary)")
                    }
                    print("dex/code/instructions: \(report.dexCount)/\(report.codeMethodCount)/\(report.instructionCount)")
                    print("unregistered invokes: \(report.unregisteredExternalInvocations.count) (prioritization only)")
                    for finding in report.unregisteredExternalInvocations.prefix(50) {
                        print("  \(finding.surface.summary) | invokes=\(finding.invocationCount) methods=\(finding.declaringMethodCount)")
                    }
                    if report.unregisteredExternalInvocations.count > 50 {
                        print("  ... \(report.unregisteredExternalInvocations.count - 50) more")
                    }
                    if report.omittedExternalInvocationCount > 0 {
                        print("  omitted invokes after unique-finding cap: \(report.omittedExternalInvocationCount)")
                    }
                    print("unsupported opcodes: \(report.unsupportedOpcodes.count)")
                    for finding in report.unsupportedOpcodes {
                        print(String(
                            format: "  0x%02x %@ | instructions=%d methods=%d",
                            finding.opcode,
                            finding.name,
                            finding.instructionCount,
                            finding.declaringMethodCount
                        ))
                    }
                } catch {
                    encounteredErrors += 1
                    print("error: malformed or unreadable artifact")
                }
            }

            let aggregate = InterpretedCompatibilityAudit.aggregate(reports)
            print("")
            print("== aggregate ==")
            print("analyzed/errors:     \(aggregate.extensionCount)/\(encounteredErrors)")
            print("structural candidates: \(aggregate.structuralCandidateCount)")
            print("plan blockers:       \(aggregate.planBlockers.count)")
            for finding in aggregate.planBlockers {
                print("  extensions=\(finding.extensionCount) | \(finding.blocker.summary)")
            }
            print("unregistered invokes: \(aggregate.unregisteredExternalInvocations.count) (ranked signal, not runtime proof)")
            for finding in aggregate.unregisteredExternalInvocations.prefix(100) {
                print("  extensions=\(finding.extensionCount) invokes=\(finding.invocationCount) | \(finding.surface.summary)")
            }
            if aggregate.unregisteredExternalInvocations.count > 100 {
                print("  ... \(aggregate.unregisteredExternalInvocations.count - 100) more")
            }
            if aggregate.omittedExternalInvocationCount > 0 {
                print("  omitted invokes after unique-finding caps: \(aggregate.omittedExternalInvocationCount)")
            }
            print("unsupported opcodes: \(aggregate.unsupportedOpcodes.count)")
            for finding in aggregate.unsupportedOpcodes {
                print(String(
                    format: "  extensions=%d instructions=%d | 0x%02x %@",
                    finding.extensionCount,
                    finding.instructionCount,
                    finding.opcode,
                    finding.name
                ))
            }
            if encounteredErrors > 0 { exit(70) }
        } catch {
            print("error: unable to enumerate bounded APK inputs")
            exit(70)
        }
    }

    static func opcodeInputURLs(at path: String) throws -> [URL] {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let url = URL(fileURLWithPath: path)
        if !isDirectory.boolValue { return [url] }

        let urls = try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension.lowercased() == "apk" }.sorted {
            let lhs = $0.lastPathComponent.lowercased()
            let rhs = $1.lastPathComponent.lowercased()
            return lhs == rhs ? $0.lastPathComponent < $1.lastPathComponent : lhs < rhs
        }
        guard !urls.isEmpty else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return urls
    }

    static func printOpcodeReport(name: String, report: DexOpcodeInventory.Report) {
        print("== \(name) ==")
        print("dex files:          \(report.dexCount)")
        print("methods with code:  \(report.codeMethodCount)")
        print("instructions:       \(report.instructionCount)")
        for dex in report.dexFiles {
            print("  \(dex.name): DEX \(String(format: "%03d", dex.version)), "
                + "methods=\(dex.codeMethodCount), instructions=\(dex.instructionCount)")
        }
        print("opcodes:")
        for opcode in report.opcodes {
            let value = String(format: "0x%02x", opcode.opcode)
            let example = opcode.examples.map {
                "\($0.dexName):\($0.declaringClass)->\($0.methodSignature)@\($0.address)"
            }.joined(separator: ", ")
            print("  \(value) \(opcode.name): count=\(opcode.instructionCount), "
                + "methods=\(opcode.methodCount), decode=\(yesNo(opcode.structurallyDecoded)), "
                + "verify=\(yesNo(opcode.registerVerified)), execute=\(yesNo(opcode.executable))"
                + (example.isEmpty ? "" : ", examples=\(example)"))
        }
    }

    static func printCorpusOpcodeTotals(
        _ reports: [(name: String, report: DexOpcodeInventory.Report)]
    ) {
        struct Total {
            let name: String
            let structurallyDecoded: Bool
            let registerVerified: Bool
            let executable: Bool
            var instructionCount: Int
            var methodCount: Int
        }

        var totals: [UInt8: Total] = [:]
        for item in reports {
            for opcode in item.report.opcodes {
                if var total = totals[opcode.opcode] {
                    total.instructionCount += opcode.instructionCount
                    total.methodCount += opcode.methodCount
                    totals[opcode.opcode] = total
                } else {
                    totals[opcode.opcode] = Total(
                        name: opcode.name,
                        structurallyDecoded: opcode.structurallyDecoded,
                        registerVerified: opcode.registerVerified,
                        executable: opcode.executable,
                        instructionCount: opcode.instructionCount,
                        methodCount: opcode.methodCount
                    )
                }
            }
        }

        let dexCount = reports.reduce(0) { $0 + $1.report.dexCount }
        let methodCount = reports.reduce(0) { $0 + $1.report.codeMethodCount }
        let instructionCount = reports.reduce(0) { $0 + $1.report.instructionCount }
        print("== Corpus total ==")
        print("APKs:               \(reports.count)")
        print("dex files:          \(dexCount)")
        print("methods with code:  \(methodCount)")
        print("instructions:       \(instructionCount)")
        print("opcodes:")
        for opcode in totals.keys.sorted() {
            let total = totals[opcode]!
            let value = String(format: "0x%02x", opcode)
            print("  \(value) \(total.name): count=\(total.instructionCount), "
                + "methods=\(total.methodCount), decode=\(yesNo(total.structurallyDecoded)), "
                + "verify=\(yesNo(total.registerVerified)), execute=\(yesNo(total.executable))")
        }
    }

    static func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }

    static func inspect(_ r: ExtensionAnalyzer.Report) {
        print("== Extension ==")
        print("package:            \(r.manifest.packageName)")
        print("name:               \(r.manifest.appName ?? "?")")
        print("version:            \(r.manifest.versionName ?? "?") (\(r.manifest.versionCode.map(String.init) ?? "?"))")
        print("extensionLib:       \(r.manifest.extensionLibVersion ?? "?")")
        print("source class:       \(r.manifest.resolvedSourceClass ?? "?")")
        print("source factory:     \(r.manifest.resolvedSourceFactory ?? "?")")
        print("feature declared:   \(r.manifest.declaresExtensionFeature)")
        print("== DEX ==")
        print("dex files:          \(r.dexCount)")
        print("defined classes:    \(r.definedClassCount)")
        print("source classes found in dex: \(r.sourceClassesInDex.joined(separator: ", "))")
        print("== Compatibility ==")
        print("external class refs: \(r.externalReferences.count)")
        print("supported refs:      \(r.supportedClasses.count)")
        let pct = Int((r.predictedCompatibility * 100).rounded())
        print("class-coverage:      \(pct)% (heuristic; see docs)")
        print("top missing classes:")
        missing(r, limit: 15)
    }

    static func missing(_ r: ExtensionAnalyzer.Report, limit: Int) {
        for (descriptor, refs) in r.missingClasses.prefix(limit) {
            print(String(format: "  %6d  %@", refs, DexFile.readableClassName(descriptor)))
        }
    }

    static func dumpIndex(_ arg: String) async {
        do {
            let bytes: [UInt8]
            if arg.hasPrefix("http://") || arg.hasPrefix("https://") {
                guard let url = URL(string: arg) else {
                    print("error: bad URL"); exit(66)
                }
                let client = ExtensionStoreClient()
                do {
                    let (data, statusCode) = try await download(url)
                    guard (200..<300).contains(statusCode) else {
                        print("error: HTTP \(statusCode)")
                        exit(69)
                    }
                    bytes = data
                } catch {
                    print("error: \(error)"); exit(69)
                }
                _ = client
            } else {
                guard let data = FileManager.default.contents(atPath: arg) else {
                    print("error: cannot read \(arg)"); exit(66)
                }
                bytes = [UInt8](data)
            }
            let index = try ExtensionRepositoryIndex(bytes: bytes, url: URL(fileURLWithPath: "index"))
            print("store:      \(index.storeName)")
            print("badge:      \(index.badgeLabel ?? "-")")
            print("signingKey: \(index.signingKey?.prefix(24) ?? "-")…")
            print("extensions: \(index.extensions.count)")
            for ext in index.extensions.prefix(40) {
                let langs = Set(ext.sources.map(\.language)).sorted().joined(separator: ",")
                print(String(format: "  %@ %@ (%@) lib=%@ sources=%d [%@]",
                             ext.packageName, ext.versionName, ext.name,
                             ext.extensionLib.isEmpty ? "-" : ext.extensionLib,
                             ext.sources.count, langs))
            }
            if index.extensions.count > 40 { print("  …") }
        } catch {
            print("error: \(error)")
            exit(70)
        }
    }
}
