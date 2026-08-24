import Foundation

/// A non-executing structural plan for one extension source entry. Producing a
/// plan does not authenticate an APK, admit it, or prove its network operations
/// compatible. It proves only that the bounded parser found the currently
/// supported manifest/DEX shape and stable lib 1.6 source wrappers.
public struct InterpretedExtensionExecutionPlan: Equatable, Sendable {
    public let packageName: String
    public let versionName: String
    public let versionCode: Int64
    public let extensionLibVersion: String
    public let dexEntryName: String
    public let entryClassDescriptor: String
    public let sourceAPIWrapperDescriptor: String
}

/// Deterministic reasons why an APK cannot yet produce a structural execution
/// plan. These are deliberately capability-oriented and omit filesystem paths,
/// URLs, signer material, and source-returned values so they are safe to export
/// in a compatibility report.
public enum InterpretedExtensionPlanBlocker: Hashable, Sendable {
    case missingExtensionFeature
    case invalidManifestIdentity
    case unsupportedLibraryVersion(String?)
    case sourceFactoryUnsupported
    case missingSourceClass
    case invalidSourceClass
    case missingPrimaryDEX
    case duplicateDEXEntry
    case multipleDEXFiles(Int)
    case nativeLibrariesPresent(Int)
    case entryClassMissing
    case entryClassOutsidePrimaryDEX
    case stableSourceWrapperMissing

    public var summary: String {
        switch self {
        case .missingExtensionFeature:
            return "the manifest does not declare the Tachiyomi extension feature"
        case .invalidManifestIdentity:
            return "the manifest package or version identity is missing or invalid"
        case let .unsupportedLibraryVersion(version):
            return "extension library \(version ?? "unknown") is not supported by the plan builder"
        case .sourceFactoryUnsupported:
            return "manifest source factories are not supported by the single-source runtime"
        case .missingSourceClass:
            return "the manifest does not declare a source class"
        case .invalidSourceClass:
            return "the manifest source class is not a valid JVM class name"
        case .missingPrimaryDEX:
            return "classes.dex is missing"
        case .duplicateDEXEntry:
            return "the APK contains ambiguous duplicate DEX entry names"
        case let .multipleDEXFiles(count):
            return "the APK contains \(count) DEX files but the runtime is single-DEX"
        case let .nativeLibrariesPresent(count):
            return "the APK contains \(count) native library entries that Kami will not load"
        case .entryClassMissing:
            return "the declared source class is absent from the parsed DEX files"
        case .entryClassOutsidePrimaryDEX:
            return "the declared source class is outside classes.dex"
        case .stableSourceWrapperMissing:
            return "the source class chain is missing the required stable Mihon wrappers"
        }
    }
}

extension InterpretedExtensionPlanBlocker: LocalizedError {
    public var errorDescription: String? { summary }
}

/// Full structural inspection result. A nil `plan` is an honest unsupported
/// result accompanied by stable blockers, not permission to guess private R8
/// workers or execute the APK heuristically.
public struct InterpretedExtensionPlanInspection: Equatable, Sendable {
    public let packageName: String
    public let versionName: String?
    public let versionCode: Int64?
    public let extensionLibVersion: String?
    public let dexEntryNames: [String]
    public let nativeLibraryCount: Int
    public let blockers: [InterpretedExtensionPlanBlocker]
    public let plan: InterpretedExtensionExecutionPlan?

    public var isStructuralCandidate: Bool { plan != nil }
}

/// Bounded, deterministic discovery shared by the exact runtime catalog and
/// `compat-audit`. It performs no DEX execution and establishes no signer trust.
public struct InterpretedExtensionPlanInspector: Sendable {
    public static let supportedLibraryVersions: Set<String> = ["1.6"]

    public init() {}

    public func inspect(apkBytes: [UInt8]) throws -> InterpretedExtensionPlanInspection {
        let manifest = try ExtensionManifest(apkBytes: apkBytes)
        let archive = try ZipArchive(apkBytes)
        let dexEntries = archive.entries.compactMap { entry -> (Int, ZipArchive.Entry)? in
            guard let order = Self.dexOrder(entry.name) else { return nil }
            return (order, entry)
        }.sorted {
            if $0.0 != $1.0 { return $0.0 < $1.0 }
            return $0.1.name < $1.1.name
        }
        let dexEntryNames = dexEntries.map { $0.1.name }
        let nativeLibraryCount = archive.entries.reduce(into: 0) { count, entry in
            let name = entry.name.lowercased()
            if name.hasSuffix(".so") { count += 1 }
        }

        var blockers: [InterpretedExtensionPlanBlocker] = []
        if !manifest.declaresExtensionFeature {
            blockers.append(.missingExtensionFeature)
        }
        if manifest.packageName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            manifest.packageName.utf8.count > 512 ||
            manifest.versionName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false ||
            (manifest.versionName?.utf8.count ?? 0) > 128 ||
            (manifest.versionCode ?? -1) < 0 {
            blockers.append(.invalidManifestIdentity)
        }
        if !Self.supportedLibraryVersions.contains(manifest.extensionLibVersion ?? "") {
            blockers.append(.unsupportedLibraryVersion(manifest.extensionLibVersion))
        }
        if manifest.resolvedSourceFactory != nil {
            blockers.append(.sourceFactoryUnsupported)
        }
        if manifest.resolvedSourceClass == nil,
           manifest.resolvedSourceFactory == nil {
            blockers.append(.missingSourceClass)
        }
        if nativeLibraryCount > 0 {
            blockers.append(.nativeLibrariesPresent(nativeLibraryCount))
        }

        let uniqueDEXNames = Set(dexEntryNames)
        if uniqueDEXNames.count != dexEntryNames.count {
            blockers.append(.duplicateDEXEntry)
        }
        guard let primaryEntry = dexEntries.first(where: { $0.1.name == "classes.dex" })?.1 else {
            blockers.append(.missingPrimaryDEX)
            return Self.inspection(
                manifest: manifest,
                dexEntryNames: dexEntryNames,
                nativeLibraryCount: nativeLibraryCount,
                blockers: blockers,
                plan: nil
            )
        }
        if dexEntries.count > 1 {
            blockers.append(.multipleDEXFiles(dexEntries.count))
        }

        guard let entryClassName = manifest.resolvedSourceClass else {
            return Self.inspection(
                manifest: manifest,
                dexEntryNames: dexEntryNames,
                nativeLibraryCount: nativeLibraryCount,
                blockers: blockers,
                plan: nil
            )
        }
        guard let entryClassDescriptor = Self.classDescriptor(from: entryClassName) else {
            blockers.append(.invalidSourceClass)
            return Self.inspection(
                manifest: manifest,
                dexEntryNames: dexEntryNames,
                nativeLibraryCount: nativeLibraryCount,
                blockers: blockers,
                plan: nil
            )
        }

        let primaryDEX = try DexFile(try archive.data(for: primaryEntry))
        if primaryDEX.classIndexByDescriptor[entryClassDescriptor] == nil {
            var foundOutsidePrimary = false
            for (_, entry) in dexEntries where entry.name != primaryEntry.name {
                let dex = try DexFile(try archive.data(for: entry))
                if dex.classIndexByDescriptor[entryClassDescriptor] != nil {
                    foundOutsidePrimary = true
                    break
                }
            }
            blockers.append(foundOutsidePrimary ? .entryClassOutsidePrimaryDEX : .entryClassMissing)
            return Self.inspection(
                manifest: manifest,
                dexEntryNames: dexEntryNames,
                nativeLibraryCount: nativeLibraryCount,
                blockers: blockers,
                plan: nil
            )
        }

        let wrapperDescriptor = Self.sourceAPIWrapper(
            dex: primaryDEX,
            entryClassDescriptor: entryClassDescriptor,
            requiredMethods: StableInterpretedSourceAPI.wrapperMethods
        )
        if wrapperDescriptor == nil {
            blockers.append(.stableSourceWrapperMissing)
        }

        let plan: InterpretedExtensionExecutionPlan?
        if blockers.isEmpty,
           let versionName = manifest.versionName,
           let versionCode = manifest.versionCode,
           let libraryVersion = manifest.extensionLibVersion,
           let wrapperDescriptor {
            plan = InterpretedExtensionExecutionPlan(
                packageName: manifest.packageName,
                versionName: versionName,
                versionCode: versionCode,
                extensionLibVersion: libraryVersion,
                dexEntryName: primaryEntry.name,
                entryClassDescriptor: entryClassDescriptor,
                sourceAPIWrapperDescriptor: wrapperDescriptor
            )
        } else {
            plan = nil
        }
        return Self.inspection(
            manifest: manifest,
            dexEntryNames: dexEntryNames,
            nativeLibraryCount: nativeLibraryCount,
            blockers: blockers,
            plan: plan
        )
    }

    private static func inspection(
        manifest: ExtensionManifest,
        dexEntryNames: [String],
        nativeLibraryCount: Int,
        blockers: [InterpretedExtensionPlanBlocker],
        plan: InterpretedExtensionExecutionPlan?
    ) -> InterpretedExtensionPlanInspection {
        InterpretedExtensionPlanInspection(
            packageName: manifest.packageName,
            versionName: manifest.versionName,
            versionCode: manifest.versionCode,
            extensionLibVersion: manifest.extensionLibVersion,
            dexEntryNames: dexEntryNames,
            nativeLibraryCount: nativeLibraryCount,
            blockers: blockers,
            plan: plan
        )
    }

    private static func dexOrder(_ name: String) -> Int? {
        if name == "classes.dex" { return 1 }
        guard name.hasPrefix("classes"), name.hasSuffix(".dex") else { return nil }
        let start = name.index(name.startIndex, offsetBy: "classes".count)
        let end = name.index(name.endIndex, offsetBy: -".dex".count)
        let suffix = name[start..<end]
        guard !suffix.isEmpty,
              suffix.first != "0",
              suffix.allSatisfy({ $0.isASCII && $0.isNumber }),
              let order = Int(suffix),
              order >= 2 else { return nil }
        return order
    }

    private static func classDescriptor(from className: String) -> String? {
        guard !className.isEmpty,
              className.utf8.count <= 1_024,
              !className.hasPrefix("."),
              !className.hasSuffix("."),
              className.split(separator: ".").allSatisfy({ component in
                  !component.isEmpty && component.utf8.allSatisfy {
                      ($0 >= 0x30 && $0 <= 0x39) ||
                          ($0 >= 0x41 && $0 <= 0x5a) ||
                          ($0 >= 0x61 && $0 <= 0x7a) ||
                          $0 == 0x24 || $0 == 0x5f
                  }
              }) else { return nil }
        return "L" + className.replacingOccurrences(of: ".", with: "/") + ";"
    }

    /// R8 may rename implementation workers but the public source methods are
    /// stable. Walk only the entry's local superclass chain and require one
    /// concrete public instance declaration of every measured wrapper.
    private static func sourceAPIWrapper(
        dex: DexFile,
        entryClassDescriptor: String,
        requiredMethods: [ExactInterpretedMethod]
    ) -> String? {
        guard let entryIndex = dex.classIndexByDescriptor[entryClassDescriptor] else {
            return nil
        }
        var classIndex: Int? = entryIndex
        var visited: Set<String> = []

        while let currentIndex = classIndex {
            let definition = dex.classDefs[currentIndex]
            let descriptor = definition.descriptor
            guard visited.insert(descriptor).inserted else { return nil }
            let hasRequiredMethods = requiredMethods.allSatisfy { required in
                let matches = definition.virtualMethods.filter { encoded in
                    let reference = dex.methodIds[encoded.methodIndex]
                    return reference.name == required.name &&
                        reference.prototype.descriptor == required.prototype
                }
                guard matches.count == 1, let method = matches.first else {
                    return false
                }
                let isPublic = method.accessFlags & 0x1 != 0
                let isStatic = method.accessFlags & 0x8 != 0
                let isAbstract = method.accessFlags & 0x400 != 0
                return isPublic && !isStatic && !isAbstract && method.codeOffset != 0
            }
            if hasRequiredMethods { return descriptor }
            let superclassIndex = definition.superclassIndex
            guard superclassIndex >= 0,
                  superclassIndex < dex.typeDescriptors.count else { return nil }
            classIndex = dex.classIndexByDescriptor[dex.typeDescriptors[superclassIndex]]
        }
        return nil
    }
}

struct ExactInterpretedMethod: Sendable {
    let name: String
    let prototype: String
}

/// Stable lib 1.6 source entrypoints shared by plan inspection and execution.
enum StableInterpretedSourceAPI {
    static let popular = ExactInterpretedMethod(
        name: "getPopularManga",
        prototype: "(ILkotlin/coroutines/Continuation;)Ljava/lang/Object;"
    )
    static let latest = ExactInterpretedMethod(
        name: "getLatestUpdates",
        prototype: "(ILkotlin/coroutines/Continuation;)Ljava/lang/Object;"
    )
    static let search = ExactInterpretedMethod(
        name: "getSearchManga",
        prototype: "(ILjava/lang/String;Leu/kanade/tachiyomi/source/model/FilterList;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;"
    )
    static let mangaUpdate = ExactInterpretedMethod(
        name: "getMangaUpdate",
        prototype: "(Leu/kanade/tachiyomi/source/model/SManga;Ljava/util/List;ZZLkotlin/coroutines/Continuation;)Ljava/lang/Object;"
    )
    static let pages = ExactInterpretedMethod(
        name: "getPageList",
        prototype: "(Leu/kanade/tachiyomi/source/model/SChapter;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;"
    )
    static let filterList = ExactInterpretedMethod(
        name: "getFilterList",
        prototype: "()Leu/kanade/tachiyomi/source/model/FilterList;"
    )
    static let supportsLatest = ExactInterpretedMethod(
        name: "getSupportsLatest",
        prototype: "()Z"
    )

    static let wrapperMethods = [search, mangaUpdate, filterList, supportsLatest]
}
