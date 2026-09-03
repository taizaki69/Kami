import Crypto
import Foundation

/// Failures at the pinned extension-to-`KamiSource` boundary. Messages avoid
/// URLs, query strings, response bodies, and extension-controlled text.
public enum PinnedInterpretedSourceError: Error, Sendable, Equatable, LocalizedError {
    case invalidAPKSize(profile: String)
    case apkDigestMismatch(profile: String)
    case apkSignatureInvalid(profile: String)
    case apkSignerMismatch(profile: String)
    case manifestMismatch(profile: String)
    case missingEntryClass(profile: String)
    case missingSourceAPIWrapper(profile: String)
    case unsupportedStructure(profile: String)
    case invalidMetadata(profile: String)
    case invalidPreferences(profile: String)
    case invalidInput(operation: String)
    case unsupportedOperation(String)
    case unexpectedResult(operation: String)
    case runtimeBusy

    public var errorDescription: String? {
        switch self {
        case let .invalidAPKSize(profile):
            return "Pinned extension \(profile) has an invalid APK size."
        case let .apkDigestMismatch(profile):
            return "Pinned extension \(profile) failed its SHA-256 check."
        case let .apkSignatureInvalid(profile):
            return "Pinned extension \(profile) failed APK signature verification."
        case let .apkSignerMismatch(profile):
            return "Pinned extension \(profile) has an unexpected signing identity."
        case let .manifestMismatch(profile):
            return "Pinned extension \(profile) does not match its manifest identity."
        case let .missingEntryClass(profile):
            return "Pinned extension \(profile) is missing its expected source class."
        case let .missingSourceAPIWrapper(profile):
            return "Pinned extension \(profile) is missing its measured source API wrapper."
        case let .unsupportedStructure(profile):
            return "Pinned extension \(profile) does not match the bounded structural execution plan."
        case let .invalidMetadata(profile):
            return "Pinned extension \(profile) returned invalid source metadata."
        case let .invalidPreferences(profile):
            return "Pinned extension \(profile) received unsupported preference values."
        case let .invalidInput(operation):
            return "The interpreted source rejected invalid input for \(operation)."
        case let .unsupportedOperation(operation):
            return "The interpreted source does not yet support \(operation)."
        case let .unexpectedResult(operation):
            return "The interpreted source returned an unexpected result for \(operation)."
        case .runtimeBusy:
            return "The interpreted source has too many queued operations."
        }
    }
}

/// The first app-facing DEX-backed source. Construction is deliberately limited
/// to profiles compiled into Kami. Downloaded adapters use the separate,
/// persisted `ExtensionAdmissionService` capability before registration.
public struct PinnedInterpretedSource: InterpretedCompatibilityReportingSource {
    public let id: Int64
    public let name: String
    public let language: String
    public let supportsLatest: Bool
    public let baseURL: String
    public let transportPolicy: CompatHTTPTransportPolicy

    private let runtime: PinnedInterpretedRuntime
    private let filters: [SourceFilter]
    private let compatibilityRecorder: InterpretedCompatibilityRecorder

    /// Loads the exact BatCave 1.6.9 artifact through the production transport.
    public static func batCave169(
        apkBytes: [UInt8],
        transportPolicy: CompatHTTPTransportPolicy = .init(allowsInsecureHTTP: false)
    ) throws -> Self {
        let profile = PinnedInterpretedProfile.batCave169
        let transport = URLSessionCompatHTTPTransport(
            sourceID: profile.networkIdentity,
            policy: transportPolicy
        )
        return try Self(
            profile: profile,
            apkBytes: apkBytes,
            transport: transport,
            transportPolicy: transportPolicy
        )
    }

    /// Injection seam for deterministic tests and source-scoped custom hosts.
    public static func batCave169(
        apkBytes: [UInt8],
        transport: any CompatHTTPTransport,
        transportPolicy: CompatHTTPTransportPolicy = .init(allowsInsecureHTTP: false)
    ) throws -> Self {
        try Self(
            profile: .batCave169,
            apkBytes: apkBytes,
            transport: transport,
            transportPolicy: transportPolicy
        )
    }

    /// Loads the exact current Kawii Manga 1.6.1 artifact through production transport.
    public static func kawiiManga161(
        apkBytes: [UInt8],
        transportPolicy: CompatHTTPTransportPolicy = .init(allowsInsecureHTTP: false)
    ) throws -> Self {
        let profile = PinnedInterpretedProfile.kawiiManga161
        let transport = URLSessionCompatHTTPTransport(
            sourceID: profile.networkIdentity,
            policy: transportPolicy
        )
        return try Self(
            profile: profile,
            apkBytes: apkBytes,
            transport: transport,
            transportPolicy: transportPolicy
        )
    }

    /// Injection seam for deterministic Kawii Manga tests.
    public static func kawiiManga161(
        apkBytes: [UInt8],
        transport: any CompatHTTPTransport,
        transportPolicy: CompatHTTPTransportPolicy = .init(allowsInsecureHTTP: false)
    ) throws -> Self {
        try Self(
            profile: .kawiiManga161,
            apkBytes: apkBytes,
            transport: transport,
            transportPolicy: transportPolicy
        )
    }

    /// Loads the exact current MangaMelon 1.6.1 artifact through production transport.
    public static func mangaMelon161(
        apkBytes: [UInt8],
        transportPolicy: CompatHTTPTransportPolicy = .init(allowsInsecureHTTP: false)
    ) throws -> Self {
        let profile = PinnedInterpretedProfile.mangaMelon161
        let transport = URLSessionCompatHTTPTransport(
            sourceID: profile.networkIdentity,
            policy: transportPolicy
        )
        return try Self(
            profile: profile,
            apkBytes: apkBytes,
            transport: transport,
            transportPolicy: transportPolicy
        )
    }

    /// Injection seam for deterministic MangaMelon tests.
    public static func mangaMelon161(
        apkBytes: [UInt8],
        transport: any CompatHTTPTransport,
        transportPolicy: CompatHTTPTransportPolicy = .init(allowsInsecureHTTP: false)
    ) throws -> Self {
        try Self(
            profile: .mangaMelon161,
            apkBytes: apkBytes,
            transport: transport,
            transportPolicy: transportPolicy
        )
    }

    /// Loads the exact current Baozi Manhua 1.6.29 artifact through production transport.
    public static func baoziManhua1629(
        apkBytes: [UInt8],
        transportPolicy: CompatHTTPTransportPolicy = .init(allowsInsecureHTTP: false),
        preferences: InterpretedExtensionPreferences = .init()
    ) throws -> Self {
        let profile = PinnedInterpretedProfile.baoziManhua1629
        let transport = URLSessionCompatHTTPTransport(
            sourceID: profile.networkIdentity,
            policy: transportPolicy
        )
        return try Self(
            profile: profile,
            apkBytes: apkBytes,
            transport: transport,
            transportPolicy: transportPolicy,
            preferences: preferences
        )
    }

    /// Injection seam for deterministic Baozi Manhua tests.
    public static func baoziManhua1629(
        apkBytes: [UInt8],
        transport: any CompatHTTPTransport,
        transportPolicy: CompatHTTPTransportPolicy = .init(allowsInsecureHTTP: false),
        preferences: InterpretedExtensionPreferences = .init()
    ) throws -> Self {
        try Self(
            profile: .baoziManhua1629,
            apkBytes: apkBytes,
            transport: transport,
            transportPolicy: transportPolicy,
            preferences: preferences
        )
    }

    /// Loads the exact current TuttoAnimeManga 1.6.10 artifact through production transport.
    public static func tuttoAnimeManga1610(
        apkBytes: [UInt8],
        transportPolicy: CompatHTTPTransportPolicy = .init(allowsInsecureHTTP: false)
    ) throws -> Self {
        let profile = PinnedInterpretedProfile.tuttoAnimeManga1610
        let transport = URLSessionCompatHTTPTransport(
            sourceID: profile.networkIdentity,
            policy: transportPolicy
        )
        return try Self(
            profile: profile,
            apkBytes: apkBytes,
            transport: transport,
            transportPolicy: transportPolicy
        )
    }

    /// Injection seam for deterministic TuttoAnimeManga tests.
    public static func tuttoAnimeManga1610(
        apkBytes: [UInt8],
        transport: any CompatHTTPTransport,
        transportPolicy: CompatHTTPTransportPolicy = .init(allowsInsecureHTTP: false)
    ) throws -> Self {
        try Self(
            profile: .tuttoAnimeManga1610,
            apkBytes: apkBytes,
            transport: transport,
            transportPolicy: transportPolicy
        )
    }

    /// Loads the exact current Mangas-Origines.fr 1.6.58 artifact through production transport.
    public static func mangasOriginesFR1658(
        apkBytes: [UInt8],
        transportPolicy: CompatHTTPTransportPolicy = .init(allowsInsecureHTTP: false)
    ) throws -> Self {
        let profile = PinnedInterpretedProfile.mangasOriginesFR1658
        let transport = URLSessionCompatHTTPTransport(
            sourceID: profile.networkIdentity,
            policy: transportPolicy
        )
        return try Self(
            profile: profile,
            apkBytes: apkBytes,
            transport: transport,
            transportPolicy: transportPolicy
        )
    }

    /// Injection seam for deterministic Mangas-Origines.fr tests.
    public static func mangasOriginesFR1658(
        apkBytes: [UInt8],
        transport: any CompatHTTPTransport,
        transportPolicy: CompatHTTPTransportPolicy = .init(allowsInsecureHTTP: false)
    ) throws -> Self {
        try Self(
            profile: .mangasOriginesFR1658,
            apkBytes: apkBytes,
            transport: transport,
            transportPolicy: transportPolicy
        )
    }

    fileprivate init(
        profile: PinnedInterpretedProfile,
        apkBytes: [UInt8],
        transport: any CompatHTTPTransport,
        transportPolicy: CompatHTTPTransportPolicy = .init(allowsInsecureHTTP: false),
        preferences: InterpretedExtensionPreferences = .init()
    ) throws {
        let compatibilityRecorder = InterpretedCompatibilityRecorder(
            packageName: profile.packageName,
            versionName: profile.versionName,
            versionCode: profile.versionCode
        )
        let runtime = try PinnedInterpretedRuntime(
            profile: profile,
            apkBytes: apkBytes,
            transport: transport,
            transportPolicy: transportPolicy,
            preferences: preferences,
            compatibilityRecorder: compatibilityRecorder
        )
        let metadata = runtime.metadata
        self.id = metadata.id
        self.name = metadata.name
        self.language = metadata.language
        self.supportsLatest = metadata.supportsLatest
        self.baseURL = metadata.baseURL
        self.transportPolicy = transportPolicy
        self.runtime = runtime
        self.filters = runtime.filters
        self.compatibilityRecorder = compatibilityRecorder
    }

    public func getPopularManga(page: Int) async throws -> MangasPageCompat {
        try await runtime.popular(page: page)
    }

    public func getLatestUpdates(page: Int) async throws -> MangasPageCompat {
        try await runtime.latest(page: page)
    }

    public func getSearchManga(
        page: Int,
        query: String,
        filters: [SourceFilter]
    ) async throws -> MangasPageCompat {
        guard filters.isEmpty || !self.filters.isEmpty else {
            throw PinnedInterpretedSourceError.unsupportedOperation("filtered search")
        }
        guard query.utf8.count <= 4_096 else {
            throw PinnedInterpretedSourceError.invalidInput(operation: "search")
        }
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                !self.filters.isEmpty else {
            throw PinnedInterpretedSourceError.unsupportedOperation("blank search")
        }
        return try await runtime.search(
            page: page,
            query: query,
            filters: filters.isEmpty ? self.filters : filters
        )
    }

    public func getMangaDetails(manga: SMangaCompat) async throws -> SMangaCompat {
        try await runtime.mangaUpdate(manga: manga).manga
    }

    public func getChapterList(manga: SMangaCompat) async throws -> [SChapterCompat] {
        try await runtime.mangaUpdate(manga: manga).chapters
    }

    public func getMangaUpdate(manga: SMangaCompat) async throws -> SMangaUpdateCompat {
        try await runtime.mangaUpdate(manga: manga)
    }

    public func getPageList(chapter: SChapterCompat) async throws -> [PageCompat] {
        try await runtime.pages(chapter: chapter)
    }

    public func getImageRequest(page: PageCompat) async -> ImageRequest? {
        await runtime.imageRequest(page: page)
    }

    public func getFilterList() -> [SourceFilter] { filters }

    public func compatibilityReport() -> InterpretedCompatibilityRuntimeReport {
        compatibilityRecorder.report()
    }
}

/// Exact runtime profiles currently proven against real APKs. This catalog is
/// intentionally separate from signer trust: callers must authenticate and
/// admit downloaded bytes before asking the catalog to construct a source.
/// Returning an empty array is an honest unsupported-profile result, not a
/// reason to attempt heuristic execution with unmeasured method mappings.
public enum InterpretedExtensionProfileCatalog {
    public static func makeSources(
        packageName: String,
        versionName: String,
        versionCode: Int64,
        apkBytes: [UInt8],
        transportPolicy: CompatHTTPTransportPolicy = .init(allowsInsecureHTTP: false),
        preferences: InterpretedExtensionPreferences = .init()
    ) throws -> [any KamiSource] {
        guard let profile = profile(
            packageName: packageName,
            versionName: versionName,
            versionCode: versionCode
        ) else { return [] }

        let transport = URLSessionCompatHTTPTransport(
            sourceID: profile.networkIdentity,
            policy: transportPolicy
        )
        return [try PinnedInterpretedSource(
            profile: profile,
            apkBytes: apkBytes,
            transport: transport,
            transportPolicy: transportPolicy,
            preferences: preferences
        )]
    }

    /// Deterministic transport seam used by the admission/factory integration
    /// tests. One profile currently maps to one source and one scoped client.
    public static func makeSources(
        packageName: String,
        versionName: String,
        versionCode: Int64,
        apkBytes: [UInt8],
        transport: any CompatHTTPTransport,
        transportPolicy: CompatHTTPTransportPolicy = .init(allowsInsecureHTTP: false),
        preferences: InterpretedExtensionPreferences = .init()
    ) throws -> [any KamiSource] {
        guard let profile = profile(
            packageName: packageName,
            versionName: versionName,
            versionCode: versionCode
        ) else { return [] }

        return [try PinnedInterpretedSource(
            profile: profile,
            apkBytes: apkBytes,
            transport: transport,
            transportPolicy: transportPolicy,
            preferences: preferences
        )]
    }

    public static func supports(
        packageName: String,
        versionName: String,
        versionCode: Int64
    ) -> Bool {
        profile(
            packageName: packageName,
            versionName: versionName,
            versionCode: versionCode
        ) != nil
    }

    /// Exact source identifiers expected from a measured profile. Admission
    /// callers use this as a pre-Dex gate and must still validate constructed
    /// metadata afterward as defense in depth.
    public static func expectedSourceIDs(
        packageName: String,
        versionName: String,
        versionCode: Int64
    ) -> Set<Int64>? {
        guard let profile = profile(
            packageName: packageName,
            versionName: versionName,
            versionCode: versionCode
        ) else { return nil }
        return [profile.expectedSourceID]
    }

    private static func profile(
        packageName: String,
        versionName: String,
        versionCode: Int64
    ) -> PinnedInterpretedProfile? {
        let profiles: [PinnedInterpretedProfile] = [
            .batCave169,
            .kawiiManga161,
            .mangaMelon161,
            .baoziManhua1629,
            .tuttoAnimeManga1610,
            .mangasOriginesFR1658,
        ]
        return profiles.first {
            $0.packageName == packageName &&
                $0.versionName == versionName &&
                $0.versionCode == versionCode
        }
    }
}

private struct PinnedInterpretedMetadata: Sendable {
    let id: Int64
    let name: String
    let language: String
    let supportsLatest: Bool
    let baseURL: String
}

private struct PinnedInterpretedProfile: Sendable {
    enum FilterSupport: Sendable {
        case none
        case staticList
    }

    enum PreferenceSupport: Sendable {
        case none
        case baoziManhua

        func validates(_ preferences: InterpretedExtensionPreferences) -> Bool {
            switch self {
            case .none:
                return preferences.isEmpty
            case .baoziManhua:
                let allowedStrings: [String: Set<String>] = [
                    "BAOZI_BANNER": ["0", "1", "2"],
                    "CHAPTER_ORDER": ["0", "1", "2"],
                ]
                let allowedBooleans: Set<String> = [
                    "QUICK_PAGES",
                    "REMOVE_DUPLICATE_IMAGES",
                ]
                return preferences.strings.allSatisfy { key, value in
                    allowedStrings[key]?.contains(value) == true
                } && Set(preferences.booleans.keys).isSubset(of: allowedBooleans)
            }
        }
    }

    enum ImageRequestSupport: Sendable {
        case pageURL
        case interpreted
    }

    let identifier: String
    let sha256: String
    let signerFingerprint: String
    let maximumAPKBytes: Int
    let packageName: String
    let versionName: String
    let versionCode: Int64
    let expectedSourceID: Int64
    let filterSupport: FilterSupport
    let preferenceSupport: PreferenceSupport
    let imageRequestSupport: ImageRequestSupport

    var networkIdentity: String { "\(packageName)@\(versionName)" }

    static let batCave169 = PinnedInterpretedProfile(
        identifier: "batcave-1.6.9",
        sha256: "f5338a90f9b9b40c27a2106ceb1e0c94713c38208998fd735bfabda18934fab6",
        signerFingerprint: "9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2",
        maximumAPKBytes: 64 * 1024 * 1024,
        packageName: "eu.kanade.tachiyomi.extension.en.batcave",
        versionName: "1.6.9",
        versionCode: 9,
        expectedSourceID: 7_422_099_479_605_463_706,
        filterSupport: .none,
        preferenceSupport: .none,
        imageRequestSupport: .pageURL
    )

    static let kawiiManga161 = PinnedInterpretedProfile(
        identifier: "kawii-manga-1.6.1",
        sha256: "9e6110b8d1946180e948d3a890347529a5889e636ca6a001170cd206f74dd52a",
        signerFingerprint: "9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2",
        maximumAPKBytes: 64 * 1024 * 1024,
        packageName: "eu.kanade.tachiyomi.extension.ar.kawiimanga",
        versionName: "1.6.1",
        versionCode: 1,
        expectedSourceID: 5_037_404_094_705_788_694,
        filterSupport: .none,
        preferenceSupport: .none,
        imageRequestSupport: .pageURL
    )

    static let mangaMelon161 = PinnedInterpretedProfile(
        identifier: "mangamelon-1.6.1",
        sha256: "aedbd5ba3e3a092a381779f0e6ed610e630799070c1f032c5668f7455970d9aa",
        signerFingerprint: "9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2",
        maximumAPKBytes: 64 * 1024 * 1024,
        packageName: "eu.kanade.tachiyomi.extension.en.mangamelon",
        versionName: "1.6.1",
        versionCode: 1,
        expectedSourceID: 7_505_916_148_185_744_347,
        filterSupport: .staticList,
        preferenceSupport: .none,
        imageRequestSupport: .pageURL
    )

    static let baoziManhua1629 = PinnedInterpretedProfile(
        identifier: "baozi-manhua-1.6.29",
        sha256: "7e8c99fb75fd5e25775c2870bd687f284d3b3ef5fcbd219350b5ce35bd79cbec",
        signerFingerprint: "9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2",
        maximumAPKBytes: 64 * 1024 * 1024,
        packageName: "eu.kanade.tachiyomi.extension.zh.baozimanhua",
        versionName: "1.6.29",
        versionCode: 29,
        expectedSourceID: 5_724_751_873_601_868_259,
        filterSupport: .staticList,
        preferenceSupport: .baoziManhua,
        imageRequestSupport: .interpreted
    )

    static let tuttoAnimeManga1610 = PinnedInterpretedProfile(
        identifier: "tutto-anime-manga-1.6.10",
        sha256: "e50f1bac6e30121b6eb3461e2ce7297de431d98fc0ed1bab510a30ce784edae3",
        signerFingerprint: "9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2",
        maximumAPKBytes: 64 * 1024 * 1024,
        packageName: "eu.kanade.tachiyomi.extension.it.tuttoanimemanga",
        versionName: "1.6.10",
        versionCode: 10,
        expectedSourceID: 2_102_507_871_480_604_746,
        filterSupport: .none,
        preferenceSupport: .none,
        imageRequestSupport: .pageURL
    )

    static let mangasOriginesFR1658 = PinnedInterpretedProfile(
        identifier: "mangas-origines-fr-1.6.58",
        sha256: "b6922bbc5ddc376b50cdcd71123410af96cfddb0d0d6a493a1b50a9363cc718b",
        signerFingerprint: "9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2",
        maximumAPKBytes: 64 * 1024 * 1024,
        packageName: "eu.kanade.tachiyomi.extension.fr.mangasoriginesfr",
        versionName: "1.6.58",
        versionCode: 58,
        expectedSourceID: 4_803_238_581_797_687_746,
        filterSupport: .staticList,
        preferenceSupport: .none,
        imageRequestSupport: .pageURL
    )
}

private actor PinnedInterpretedRuntime {
    private static let maximumRetainedImageRequests = 4_096

    nonisolated let metadata: PinnedInterpretedMetadata
    nonisolated let filters: [SourceFilter]

    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct RetainedImageRequest {
        let request: RVal
        let client: RVal
    }

    private let profile: PinnedInterpretedProfile
    private let transportPolicy: CompatHTTPTransportPolicy
    private let bridge: HostBridge
    private let vm: DexInterpreter
    private let receiver: RVal
    private let entryClassDescriptor: String
    private let sourceAPIWrapperDescriptor: String
    private let filterListValue: RVal?
    private let pageURLImageHeaders: [String: String]
    private let pageURLImageSourceBaseURL: String?
    private let imageClientValue: RVal?
    private let compatibilityRecorder: InterpretedCompatibilityRecorder
    private var retainedImageRequests: [UUID: RetainedImageRequest] = [:]
    private var executing = false
    private var waiters: [Waiter] = []
    private var nextWaiterID: UInt64 = 0

    init(
        profile: PinnedInterpretedProfile,
        apkBytes: [UInt8],
        transport: any CompatHTTPTransport,
        transportPolicy: CompatHTTPTransportPolicy,
        preferences: InterpretedExtensionPreferences,
        compatibilityRecorder: InterpretedCompatibilityRecorder
    ) throws {
        guard profile.preferenceSupport.validates(preferences) else {
            throw PinnedInterpretedSourceError.invalidPreferences(profile: profile.identifier)
        }
        guard !apkBytes.isEmpty, apkBytes.count <= profile.maximumAPKBytes else {
            throw PinnedInterpretedSourceError.invalidAPKSize(profile: profile.identifier)
        }
        guard Self.sha256Hex(apkBytes) == profile.sha256 else {
            throw PinnedInterpretedSourceError.apkDigestMismatch(profile: profile.identifier)
        }
        let signingIdentity: APKSigningIdentity
        do {
            signingIdentity = try APKSignatureVerifier().verify(apkBytes: apkBytes)
        } catch {
            throw PinnedInterpretedSourceError.apkSignatureInvalid(profile: profile.identifier)
        }
        guard signingIdentity.contains(fingerprint: profile.signerFingerprint) else {
            throw PinnedInterpretedSourceError.apkSignerMismatch(profile: profile.identifier)
        }

        let manifest = try ExtensionManifest(apkBytes: apkBytes)
        guard manifest.declaresExtensionFeature,
              manifest.packageName == profile.packageName,
              manifest.versionName == profile.versionName,
              manifest.versionCode == profile.versionCode,
              manifest.extensionLibVersion == "1.6" else {
            throw PinnedInterpretedSourceError.manifestMismatch(profile: profile.identifier)
        }

        let inspection = try InterpretedExtensionPlanInspector().inspect(apkBytes: apkBytes)
        guard let plan = inspection.plan else {
            if inspection.blockers.contains(.entryClassMissing) ||
                inspection.blockers.contains(.entryClassOutsidePrimaryDEX) {
                throw PinnedInterpretedSourceError.missingEntryClass(profile: profile.identifier)
            }
            if inspection.blockers.contains(.stableSourceWrapperMissing) {
                throw PinnedInterpretedSourceError.missingSourceAPIWrapper(
                    profile: profile.identifier
                )
            }
            throw PinnedInterpretedSourceError.unsupportedStructure(profile: profile.identifier)
        }
        guard plan.packageName == profile.packageName,
              plan.versionName == profile.versionName,
              plan.versionCode == profile.versionCode else {
            throw PinnedInterpretedSourceError.manifestMismatch(profile: profile.identifier)
        }

        let archive = try ZipArchive(apkBytes)
        let dex = try DexFile(try archive.data(named: plan.dexEntryName))
        let entryClassDescriptor = plan.entryClassDescriptor
        let sourceAPIWrapperDescriptor = plan.sourceAPIWrapperDescriptor

        let extensionPackageName: String?
        switch profile.preferenceSupport {
        case .none:
            extensionPackageName = nil
        case .baoziManhua:
            extensionPackageName = profile.packageName
        }
        let bridge = HostBridge.minimal(
            transport: transport,
            transportPolicy: transportPolicy,
            extensionPackageName: extensionPackageName,
            preferences: preferences
        )
        let vm = DexInterpreter(
            dex: dex,
            bridge: bridge,
            cancelled: { Task.isCancelled }
        )
        let receiver = try vm.instantiate(classDescriptor: entryClassDescriptor)
        let name = try Self.metadataString(
            "getName",
            vm: vm,
            receiver: receiver,
            entryClassDescriptor: entryClassDescriptor,
            profile: profile
        )
        let language = try Self.metadataString(
            "getLang",
            vm: vm,
            receiver: receiver,
            entryClassDescriptor: entryClassDescriptor,
            profile: profile
        )
        let baseURL = try Self.metadataString(
            "getBaseUrl",
            vm: vm,
            receiver: receiver,
            entryClassDescriptor: entryClassDescriptor,
            profile: profile
        )
        let idValue = try vm.call(
            classDescriptor: entryClassDescriptor,
            method: "getId",
            prototype: "()J",
            args: [receiver]
        )
        let supportsLatestValue = try vm.callVirtualEntry(
            receiver: receiver,
            method: StableInterpretedSourceAPI.supportsLatest.name,
            prototype: StableInterpretedSourceAPI.supportsLatest.prototype,
            args: [receiver]
        )
        let filterListValue: RVal?
        let filters: [SourceFilter]
        switch profile.filterSupport {
        case .none:
            filterListValue = nil
            filters = []
        case .staticList:
            let value = try vm.callVirtualEntry(
                receiver: receiver,
                method: StableInterpretedSourceAPI.filterList.name,
                prototype: StableInterpretedSourceAPI.filterList.prototype,
                args: [receiver]
            )
            guard let converted = HostBridge.sourceFilters(from: value) else {
                throw PinnedInterpretedSourceError.invalidMetadata(profile: profile.identifier)
            }
            filterListValue = value
            filters = converted
        }
        guard case let .long(id) = idValue,
              id == profile.expectedSourceID,
              case let .int(rawSupportsLatest) = supportsLatestValue,
              rawSupportsLatest == 0 || rawSupportsLatest == 1,
              Self.validMetadata(name: name, language: language, baseURL: baseURL) else {
            throw PinnedInterpretedSourceError.invalidMetadata(profile: profile.identifier)
        }

        let pageURLImageHeaders: [String: String]
        let pageURLImageSourceBaseURL: String?
        if case .pageURL = profile.imageRequestSupport {
            guard let getHeaders = bridge.resolve(
                class: "Leu/kanade/tachiyomi/source/online/HttpSource;",
                "getHeaders",
                prototype: "()Lokhttp3/Headers;",
                isStatic: false
            ) else {
                throw PinnedInterpretedSourceError.invalidMetadata(profile: profile.identifier)
            }
            let value = try getHeaders(vm, [receiver])
            guard let headers = HostBridge.imageHeaders(from: value) else {
                throw PinnedInterpretedSourceError.invalidMetadata(profile: profile.identifier)
            }
            pageURLImageHeaders = headers
            pageURLImageSourceBaseURL = baseURL
        } else {
            pageURLImageHeaders = [:]
            pageURLImageSourceBaseURL = nil
        }

        // Baozi's optional banner interceptor requires Android Bitmap pixel
        // operations that the portable bridge does not yet implement. Retain
        // its exact configured client only when that preference is explicitly
        // disabled; otherwise the reader keeps the existing URL/header path
        // instead of turning an optional transform into a page-load failure.
        let imageClientValue: RVal?
        if case .interpreted = profile.imageRequestSupport,
           preferences.strings["BAOZI_BANNER"] == "0" {
            let client = try vm.callVirtualEntry(
                receiver: receiver,
                method: "getClient",
                prototype: "()Lokhttp3/OkHttpClient;",
                args: [receiver]
            )
            guard HostBridge.isOkHttpClient(client) else {
                throw PinnedInterpretedSourceError.invalidMetadata(profile: profile.identifier)
            }
            imageClientValue = client
        } else {
            imageClientValue = nil
        }

        self.profile = profile
        self.transportPolicy = transportPolicy
        self.bridge = bridge
        self.vm = vm
        self.receiver = receiver
        self.entryClassDescriptor = entryClassDescriptor
        self.sourceAPIWrapperDescriptor = sourceAPIWrapperDescriptor
        self.filterListValue = filterListValue
        self.pageURLImageHeaders = pageURLImageHeaders
        self.pageURLImageSourceBaseURL = pageURLImageSourceBaseURL
        self.imageClientValue = imageClientValue
        self.compatibilityRecorder = compatibilityRecorder
        self.filters = filters
        self.metadata = PinnedInterpretedMetadata(
            id: id,
            name: name,
            language: language,
            supportsLatest: rawSupportsLatest != 0,
            baseURL: baseURL
        )
    }

    func popular(page: Int) async throws -> MangasPageCompat {
        let page = try Self.pageNumber(page, operation: "popular manga")
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        let result = try await withFirstCompatibilityGap(stage: .popular) {
            try await vm.callVirtualEntryAsync(
                receiver: receiver,
                method: StableInterpretedSourceAPI.popular.name,
                prototype: StableInterpretedSourceAPI.popular.prototype,
                args: [receiver, .int(page), .null]
            )
        }
        guard let converted = HostBridge.mangasPageCompat(from: result) else {
            throw PinnedInterpretedSourceError.unexpectedResult(operation: "popular manga")
        }
        return converted
    }

    func latest(page: Int) async throws -> MangasPageCompat {
        let page = try Self.pageNumber(page, operation: "latest updates")
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        let result = try await withFirstCompatibilityGap(stage: .latest) {
            try await vm.callVirtualEntryAsync(
                receiver: receiver,
                method: StableInterpretedSourceAPI.latest.name,
                prototype: StableInterpretedSourceAPI.latest.prototype,
                args: [receiver, .int(page), .null]
            )
        }
        guard let converted = HostBridge.mangasPageCompat(from: result) else {
            throw PinnedInterpretedSourceError.unexpectedResult(operation: "latest updates")
        }
        return converted
    }

    func search(
        page: Int,
        query: String,
        filters: [SourceFilter]
    ) async throws -> MangasPageCompat {
        let page = try Self.pageNumber(page, operation: "search")
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        let runtimeFilterValue: RVal
        if let filterListValue {
            guard HostBridge.applySourceFilters(filters, to: filterListValue) else {
                throw PinnedInterpretedSourceError.invalidInput(operation: "search filters")
            }
            runtimeFilterValue = filterListValue
        } else {
            guard filters.isEmpty else {
                throw PinnedInterpretedSourceError.invalidInput(operation: "search filters")
            }
            runtimeFilterValue = .null
        }
        let result = try await withFirstCompatibilityGap(stage: .search) {
            try await vm.callVirtualEntryAsync(
                // Keiyoushi's stable public wrapper routes URL queries and then
                // virtually dispatches to the extension's R8-renamed worker.
                receiver: receiver,
                method: StableInterpretedSourceAPI.search.name,
                prototype: StableInterpretedSourceAPI.search.prototype,
                args: [receiver, .int(page), HostBridge.string(query), runtimeFilterValue, .null]
            )
        }
        guard let converted = HostBridge.mangasPageCompat(from: result) else {
            throw PinnedInterpretedSourceError.unexpectedResult(operation: "search")
        }
        return converted
    }

    func mangaUpdate(manga: SMangaCompat) async throws -> SMangaUpdateCompat {
        guard !manga.url.isEmpty,
              manga.url.utf8.count <= 8_192,
              manga.title.utf8.count <= 4_096 else {
            throw PinnedInterpretedSourceError.invalidInput(operation: "manga update")
        }
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        let result = try await withFirstCompatibilityGap(stage: .mangaUpdate) {
            try await vm.callVirtualEntryAsync(
                // The inherited wrapper owns concurrency protection and initialized
                // state, then virtually dispatches to the extension implementation.
                receiver: receiver,
                method: StableInterpretedSourceAPI.mangaUpdate.name,
                prototype: StableInterpretedSourceAPI.mangaUpdate.prototype,
                args: [
                    receiver,
                    HostBridge.mangaValue(from: manga),
                    HostBridge.emptyListValue(),
                    .int(1),
                    .int(1),
                    .null,
                ]
            )
        }
        guard var converted = HostBridge.mangaUpdateCompat(from: result) else {
            throw PinnedInterpretedSourceError.unexpectedResult(operation: "manga update")
        }
        // Mihon merges sparse detail objects into the requested manga. Some
        // multisrc implementations (including PizzaReader) deliberately leave
        // the returned SManga URL unset, so preserve the authenticated input
        // identity at this adapter boundary instead of leaking an empty URL to
        // callers that consume getMangaDetails directly.
        if converted.manga.url.isEmpty {
            converted.manga.url = manga.url
        }
        return converted
    }

    func pages(chapter: SChapterCompat) async throws -> [PageCompat] {
        guard !chapter.url.isEmpty,
              chapter.url.utf8.count <= 8_192,
              chapter.name.utf8.count <= 4_096 else {
            throw PinnedInterpretedSourceError.invalidInput(operation: "page list")
        }
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        let result = try await withFirstCompatibilityGap(stage: .pages) {
            try await vm.callVirtualEntryAsync(
                receiver: receiver,
                method: StableInterpretedSourceAPI.pages.name,
                prototype: StableInterpretedSourceAPI.pages.prototype,
                args: [receiver, HostBridge.chapterValue(from: chapter), .null]
            )
        }
        guard let converted = HostBridge.pagesCompat(from: result) else {
            throw PinnedInterpretedSourceError.unexpectedResult(operation: "page list")
        }
        return converted
    }

    func imageRequest(page: PageCompat) async -> ImageRequest? {
        guard page.url.utf8.count <= 8_192,
              (page.imageURL?.utf8.count ?? 0) <= 8_192 else { return nil }
        switch profile.imageRequestSupport {
        case .pageURL:
            return Self.pageURLImageRequest(
                page,
                headers: pageURLImageHeaders,
                sourceBaseURL: pageURLImageSourceBaseURL,
                policy: transportPolicy
            )
        case .interpreted:
            do {
                try await acquire()
                defer { release() }
                try Task.checkCancellation()
                let result = try withFirstCompatibilityGap(stage: .imageRequest) {
                    try vm.callVirtualEntry(
                        receiver: receiver,
                        method: "imageRequest",
                        prototype: "(Leu/kanade/tachiyomi/source/model/Page;)Lokhttp3/Request;",
                        args: [receiver, HostBridge.pageValue(from: page)]
                    )
                }
                try Task.checkCancellation()
                guard let request = HostBridge.imageRequest(from: result) else {
                    throw PinnedInterpretedSourceError.unexpectedResult(
                        operation: "image request"
                    )
                }
                guard let validated = Self.validatedImageRequest(
                    request,
                    policy: transportPolicy
                ) else {
                    throw PinnedInterpretedSourceError.unexpectedResult(
                        operation: "image request"
                    )
                }
                guard let imageClientValue else { return validated }
                guard retainedImageRequests.count < Self.maximumRetainedImageRequests else {
                    compatibilityRecorder.record(
                        stage: .imageRequest,
                        error: PinnedInterpretedSourceError.runtimeBusy
                    )
                    return validated
                }

                let id = UUID()
                retainedImageRequests[id] = RetainedImageRequest(
                    request: result,
                    client: imageClientValue
                )
                let runtime = self
                let execution = SourceImageExecution(
                    id: id,
                    operation: {
                        try await runtime.executeRetainedImageRequest(id: id)
                    },
                    release: {
                        _ = Task {
                            await runtime.releaseRetainedImageRequest(id: id)
                        }
                    }
                )
                return ImageRequest(
                    url: validated.url,
                    headers: validated.headers,
                    sourceExecution: execution
                )
            } catch is CancellationError {
                return nil
            } catch let error as VMError {
                if case .cancelled = error { return nil }
                if Task.isCancelled { return nil }
                return nil
            } catch {
                if Task.isCancelled { return nil }
                return nil
            }
        }
    }

    private func executeRetainedImageRequest(id: UUID) async throws -> CompatHTTPResponse {
        do {
            try await acquire()
            defer { release() }
            try Task.checkCancellation()
            guard let retained = retainedImageRequests[id] else {
                throw PinnedInterpretedSourceError.unexpectedResult(
                    operation: "reader image request"
                )
            }
            return try await withFirstCompatibilityGap(stage: .imageRequest) {
                try await bridge.executeImageRequest(
                    requestValue: retained.request,
                    clientValue: retained.client,
                    vm: vm
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as VMError {
            if case .cancelled = error { throw CancellationError() }
            throw error
        } catch {
            throw error
        }
    }

    private func releaseRetainedImageRequest(id: UUID) {
        retainedImageRequests.removeValue(forKey: id)
    }

    private func withFirstCompatibilityGap<T>(
        stage: InterpretedCompatibilityStage,
        operation: () throws -> T
    ) throws -> T {
        try vm.withFirstCompatibilityGapObservation({ [compatibilityRecorder] error in
            compatibilityRecorder.record(stage: stage, error: error)
        }, operation: operation)
    }

    private func withFirstCompatibilityGap<T>(
        stage: InterpretedCompatibilityStage,
        operation: () async throws -> T
    ) async throws -> T {
        try await vm.withFirstCompatibilityGapObservation({ [compatibilityRecorder] error in
            compatibilityRecorder.record(stage: stage, error: error)
        }, operation: operation)
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if !executing {
            executing = true
            return
        }
        guard waiters.count < 64 else {
            throw PinnedInterpretedSourceError.runtimeBusy
        }
        nextWaiterID &+= 1
        let id = nextWaiterID
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        }, onCancel: {
            Task { await self.cancelWaiter(id) }
        })
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    private func cancelWaiter(_ id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release() {
        if waiters.isEmpty {
            executing = false
        } else {
            let waiter = waiters.removeFirst()
            waiter.continuation.resume()
        }
    }

    private static func pageNumber(_ value: Int, operation: String) throws -> Int32 {
        guard value > 0, let page = Int32(exactly: value) else {
            throw PinnedInterpretedSourceError.invalidInput(operation: operation)
        }
        return page
    }

    private static func pageURLImageRequest(
        _ page: PageCompat,
        headers: [String: String],
        sourceBaseURL: String?,
        policy: CompatHTTPTransportPolicy
    ) -> ImageRequest? {
        guard let rawURL = page.imageURL,
              let sourceBaseURL,
              let filteredHeaders = CompatHTTPHeaderPolicy.sourceImageHeaders(
                headers,
                sourceBaseURL: sourceBaseURL,
                imageURL: rawURL
              ) else { return nil }
        return validatedImageRequest(
            ImageRequest(url: rawURL, headers: filteredHeaders),
            policy: policy
        )
    }

    private static func validatedImageRequest(
        _ request: ImageRequest,
        policy: CompatHTTPTransportPolicy
    ) -> ImageRequest? {
        guard request.headers.count <= 128 else { return nil }
        let compatRequest = CompatHTTPRequest(
            url: request.url,
            method: "GET",
            headers: request.headers
                .sorted { lhs, rhs in
                    if lhs.key != rhs.key { return lhs.key < rhs.key }
                    return lhs.value < rhs.value
                }
                .map { CompatHTTPHeader(name: $0.key, value: $0.value) }
        )
        do {
            try policy.validate(request: compatRequest)
            return request
        } catch {
            return nil
        }
    }

    private static func metadataString(
        _ method: String,
        vm: DexInterpreter,
        receiver: RVal,
        entryClassDescriptor: String,
        profile: PinnedInterpretedProfile
    ) throws -> String {
        let result = try vm.call(
            classDescriptor: entryClassDescriptor,
            method: method,
            prototype: "()Ljava/lang/String;",
            args: [receiver]
        )
        guard case let .obj(object) = result,
              let value = object.payload as? String,
              !value.isEmpty,
              value.utf8.count <= 8_192 else {
            throw PinnedInterpretedSourceError.invalidMetadata(profile: profile.identifier)
        }
        return value
    }

    private static func validMetadata(name: String, language: String, baseURL: String) -> Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.utf8.count <= 4_096,
              !language.isEmpty,
              language.utf8.count <= 32,
              language.utf8.allSatisfy({
                  ($0 >= 0x61 && $0 <= 0x7a) || $0 == 0x2d
              }),
              baseURL.utf8.count <= 8_192,
              let components = URLComponents(string: baseURL),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil else { return false }
        return true
    }

    private static func sha256Hex(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }
}
