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

    static func inspect(_ r: ExtensionAnalyzer.Report) {
        print("== Extension ==")
        print("package:            \(r.manifest.packageName)")
        print("name:               \(r.manifest.appName ?? "?")")
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
