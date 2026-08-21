import Foundation

/// Audits an extension APK: parses manifest + DEX, classifies every external
/// (non-APK-defined) class reference, and scores predicted compatibility
/// against the runtime's currently implemented API surface.
///
/// This is the measurement instrument that drives which compatibility APIs
/// get implemented next (mission §47): point it at a corpus of real APKs and
/// sort by `missingClasses` reference counts.
public struct ExtensionAnalyzer {
    public struct Report {
        public let manifest: ExtensionManifest
        public let dexCount: Int
        public let definedClassCount: Int
        /// External class descriptor → reference count (methods + fields).
        public let externalReferences: [String: Int]
        /// Classes the runtime implements, intersected with references.
        public let supportedClasses: [String]
        /// Referenced but unimplemented, sorted by reference count desc.
        public let missingClasses: [(descriptor: String, references: Int)]
        /// 0–1: fraction of external references covered by the runtime.
        public let predictedCompatibility: Double
        /// Method-level findings for the extension's own entry class, when found.
        public let entryClassFound: Bool
        public let sourceClassesInDex: [String]
    }

    /// API surface implemented by the Kami runtime today. Grows as the
    /// compatibility layer does; keep in sync with MihonCompatKit/Runtime.
    public static var implementedClasses: Set<String> = [
        // tachiyomix API stubs are mirrored structurally by the analyzer,
        // the Swift runtime treats these as "available".
        "Leu/kanade/tachiyomi/source/Source;",
        "Leu/kanade/tachiyomi/source/CatalogueSource;",
        "Leu/kanade/tachiyomi/source/ConfigurableSource;",
        "Leu/kanade/tachiyomi/source/SourceFactory;",
        "Leu/kanade/tachiyomi/source/UnmeteredSource;",
        "Leu/kanade/tachiyomi/source/model/SManga;",
        "Leu/kanade/tachiyomi/source/model/SChapter;",
        "Leu/kanade/tachiyomi/source/model/Page;",
        "Leu/kanade/tachiyomi/source/model/MangasPage;",
        "Leu/kanade/tachiyomi/source/model/Filter;",
        "Leu/kanade/tachiyomi/source/model/FilterList;",
        "Leu/kanade/tachiyomi/source/online/HttpSource;",
        "Leu/kanade/tachiyomi/source/online/ParsedHttpSource;",
        "Leu/kanade/tachiyomi/util/JsoupExtensionsKt;",
    ]

    public init() {}

    public func analyze(apk bytes: [UInt8], dexIndex: Int? = nil) throws -> Report {
        let manifest = try ExtensionManifest(apkBytes: bytes)
        let zip = try ZipArchive(bytes)
        let dexNames = zip.entries.filter { $0.name.hasPrefix("classes") && $0.name.hasSuffix(".dex") }
            .sorted { $0.name < $1.name }
        guard !dexNames.isEmpty else {
            throw ZipArchive.Error.entryMissing("classes.dex")
        }

        let targets: [ZipArchive.Entry]
        if let dexIndex {
            guard dexIndex < dexNames.count else {
                throw ZipArchive.Error.entryMissing(dexNames[dexNames.count - 1].name)
            }
            targets = [dexNames[dexIndex]]
        } else {
            targets = dexNames
        }

        var external: [String: Int] = [:]
        var defined: Set<String> = []
        var sourceClasses: [String] = []
        var dexCount = 0

        for entry in targets {
            let dexBytes = try zip.data(for: entry)
            let dex = try DexFile(dexBytes)
            dexCount += 1
            for def in dex.classDefs {
                defined.insert(def.descriptor)
            }
            for ref in dex.methodIds where !defined.contains(ref.declaringClass) {
                external[ref.declaringClass, default: 0] += 1
            }
            for ref in dex.fieldIds where !defined.contains(ref.declaringClass) {
                external[ref.declaringClass, default: 0] += 1
            }
            // Find declared source/factory classes inside this dex.
            for def in dex.classDefs {
                let name = DexFile.readableClassName(def.descriptor)
                if let cls = manifest.resolvedSourceClass, name == cls { sourceClasses.append(name) }
                if let f = manifest.resolvedSourceFactory, name == f { sourceClasses.append(name) }
            }
        }

        let supported = external.keys.filter { Self.implementedClasses.contains($0) }
        let missing = external
            .filter { !Self.implementedClasses.contains($0.key) }
            .map { (descriptor: $0.key, references: $0.value) }
            .sorted { $0.references > $1.references }

        let totalRefs = external.values.reduce(0, +)
        let coveredRefs = supported.reduce(0) { $0 + (external[$1] ?? 0) }
        let entryFound = !sourceClasses.isEmpty
        let predicted = totalRefs == 0 ? 1.0 : Double(coveredRefs) / Double(totalRefs)

        return Report(
            manifest: manifest,
            dexCount: dexCount,
            definedClassCount: defined.count,
            externalReferences: external,
            supportedClasses: supported.sorted(),
            missingClasses: missing,
            predictedCompatibility: predicted,
            entryClassFound: entryFound,
            sourceClassesInDex: sourceClasses
        )
    }
}
