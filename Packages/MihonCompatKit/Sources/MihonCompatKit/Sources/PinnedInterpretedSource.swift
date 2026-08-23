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
    case invalidMetadata(profile: String)
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
        case let .invalidMetadata(profile):
            return "Pinned extension \(profile) returned invalid source metadata."
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
public struct PinnedInterpretedSource: KamiSource {
    public let id: Int64
    public let name: String
    public let language: String
    public let supportsLatest: Bool
    public let baseURL: String

    private let runtime: PinnedInterpretedRuntime

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
        return try Self(profile: profile, apkBytes: apkBytes, transport: transport)
    }

    /// Injection seam for deterministic tests and source-scoped custom hosts.
    public static func batCave169(
        apkBytes: [UInt8],
        transport: any CompatHTTPTransport
    ) throws -> Self {
        try Self(
            profile: .batCave169,
            apkBytes: apkBytes,
            transport: transport
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
        return try Self(profile: profile, apkBytes: apkBytes, transport: transport)
    }

    /// Injection seam for deterministic Kawii Manga tests.
    public static func kawiiManga161(
        apkBytes: [UInt8],
        transport: any CompatHTTPTransport
    ) throws -> Self {
        try Self(
            profile: .kawiiManga161,
            apkBytes: apkBytes,
            transport: transport
        )
    }

    fileprivate init(
        profile: PinnedInterpretedProfile,
        apkBytes: [UInt8],
        transport: any CompatHTTPTransport
    ) throws {
        let runtime = try PinnedInterpretedRuntime(
            profile: profile,
            apkBytes: apkBytes,
            transport: transport
        )
        let metadata = runtime.metadata
        self.id = metadata.id
        self.name = metadata.name
        self.language = metadata.language
        self.supportsLatest = metadata.supportsLatest
        self.baseURL = metadata.baseURL
        self.runtime = runtime
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
        guard filters.isEmpty else {
            throw PinnedInterpretedSourceError.unsupportedOperation("filtered search")
        }
        guard query.utf8.count <= 4_096,
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PinnedInterpretedSourceError.unsupportedOperation("blank search")
        }
        return try await runtime.search(page: page, query: query)
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

    public func getImageRequest(page: PageCompat) -> ImageRequest? {
        guard let rawURL = page.imageURL,
              rawURL.utf8.count <= 8_192,
              let components = URLComponents(string: rawURL),
              components.user == nil,
              components.password == nil,
              components.host?.isEmpty == false,
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.url != nil else { return nil }
        return ImageRequest(url: rawURL)
    }

    public func getFilterList() -> [SourceFilter] { [] }
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
        transportPolicy: CompatHTTPTransportPolicy = .init(allowsInsecureHTTP: false)
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
            transport: transport
        )]
    }

    /// Deterministic transport seam used by the admission/factory integration
    /// tests. One profile currently maps to one source and one scoped client.
    public static func makeSources(
        packageName: String,
        versionName: String,
        versionCode: Int64,
        apkBytes: [UInt8],
        transport: any CompatHTTPTransport
    ) throws -> [any KamiSource] {
        guard let profile = profile(
            packageName: packageName,
            versionName: versionName,
            versionCode: versionCode
        ) else { return [] }

        return [try PinnedInterpretedSource(
            profile: profile,
            apkBytes: apkBytes,
            transport: transport
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

    private static func profile(
        packageName: String,
        versionName: String,
        versionCode: Int64
    ) -> PinnedInterpretedProfile? {
        let profiles: [PinnedInterpretedProfile] = [.batCave169, .kawiiManga161]
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

private struct ExactInterpretedMethod: Sendable {
    let name: String
    let prototype: String
}

private struct PinnedInterpretedProfile: Sendable {
    let identifier: String
    let networkIdentity: String
    let sha256: String
    let signerFingerprint: String
    let maximumAPKBytes: Int
    let packageName: String
    let versionName: String
    let versionCode: Int64
    let extensionLibVersion: String
    let entryClassName: String
    let entryClassDescriptor: String
    let expectedName: String
    let expectedLanguage: String
    let expectedBaseURL: String
    let supportsLatest: Bool
    let popular: ExactInterpretedMethod
    let latest: ExactInterpretedMethod
    let search: ExactInterpretedMethod
    let mangaUpdate: ExactInterpretedMethod
    let pages: ExactInterpretedMethod

    static let batCave169 = PinnedInterpretedProfile(
        identifier: "batcave-1.6.9",
        networkIdentity: "eu.kanade.tachiyomi.extension.en.batcave@1.6.9",
        sha256: "f5338a90f9b9b40c27a2106ceb1e0c94713c38208998fd735bfabda18934fab6",
        signerFingerprint: "9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2",
        maximumAPKBytes: 64 * 1024 * 1024,
        packageName: "eu.kanade.tachiyomi.extension.en.batcave",
        versionName: "1.6.9",
        versionCode: 9,
        extensionLibVersion: "1.6",
        entryClassName: "eu.kanade.tachiyomi.extension.en.batcave.ExtensionGenerated",
        entryClassDescriptor: "Leu/kanade/tachiyomi/extension/en/batcave/ExtensionGenerated;",
        expectedName: "BatCave",
        expectedLanguage: "en",
        expectedBaseURL: "https://batcave.biz",
        supportsLatest: true,
        popular: ExactInterpretedMethod(
            name: "getPopularManga",
            prototype: "(ILkotlin/coroutines/Continuation;)Ljava/lang/Object;"
        ),
        latest: ExactInterpretedMethod(
            name: "getLatestUpdates",
            prototype: "(ILkotlin/coroutines/Continuation;)Ljava/lang/Object;"
        ),
        search: ExactInterpretedMethod(
            name: "getSearchManga",
            prototype: "(ILjava/lang/String;Leu/kanade/tachiyomi/source/model/FilterList;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;"
        ),
        mangaUpdate: ExactInterpretedMethod(
            name: "getMangaUpdate",
            prototype: "(Leu/kanade/tachiyomi/source/model/SManga;Ljava/util/List;ZZLkotlin/coroutines/Continuation;)Ljava/lang/Object;"
        ),
        pages: ExactInterpretedMethod(
            name: "getPageList",
            prototype: "(Leu/kanade/tachiyomi/source/model/SChapter;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;"
        )
    )

    static let kawiiManga161 = PinnedInterpretedProfile(
        identifier: "kawii-manga-1.6.1",
        networkIdentity: "eu.kanade.tachiyomi.extension.ar.kawiimanga@1.6.1",
        sha256: "9e6110b8d1946180e948d3a890347529a5889e636ca6a001170cd206f74dd52a",
        signerFingerprint: "9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2",
        maximumAPKBytes: 64 * 1024 * 1024,
        packageName: "eu.kanade.tachiyomi.extension.ar.kawiimanga",
        versionName: "1.6.1",
        versionCode: 1,
        extensionLibVersion: "1.6",
        entryClassName: "eu.kanade.tachiyomi.extension.ar.kawiimanga.ExtensionGenerated",
        entryClassDescriptor: "Leu/kanade/tachiyomi/extension/ar/kawiimanga/ExtensionGenerated;",
        expectedName: "Kawii Manga",
        expectedLanguage: "ar",
        expectedBaseURL: "https://kawaiimanga.org",
        supportsLatest: true,
        popular: ExactInterpretedMethod(
            name: "getPopularManga",
            prototype: "(ILkotlin/coroutines/Continuation;)Ljava/lang/Object;"
        ),
        latest: ExactInterpretedMethod(
            name: "getLatestUpdates",
            prototype: "(ILkotlin/coroutines/Continuation;)Ljava/lang/Object;"
        ),
        search: ExactInterpretedMethod(
            name: "getSearchManga",
            prototype: "(ILjava/lang/String;Leu/kanade/tachiyomi/source/model/FilterList;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;"
        ),
        mangaUpdate: ExactInterpretedMethod(
            name: "getMangaUpdate",
            prototype: "(Leu/kanade/tachiyomi/source/model/SManga;Ljava/util/List;ZZLkotlin/coroutines/Continuation;)Ljava/lang/Object;"
        ),
        pages: ExactInterpretedMethod(
            name: "getPageList",
            prototype: "(Leu/kanade/tachiyomi/source/model/SChapter;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;"
        )
    )
}

private actor PinnedInterpretedRuntime {
    nonisolated let metadata: PinnedInterpretedMetadata

    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let profile: PinnedInterpretedProfile
    private let vm: DexInterpreter
    private let receiver: RVal
    private let sourceAPIWrapperDescriptor: String
    private var executing = false
    private var waiters: [Waiter] = []
    private var nextWaiterID: UInt64 = 0

    init(
        profile: PinnedInterpretedProfile,
        apkBytes: [UInt8],
        transport: any CompatHTTPTransport
    ) throws {
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
              manifest.extensionLibVersion == profile.extensionLibVersion,
              manifest.resolvedSourceClass == profile.entryClassName else {
            throw PinnedInterpretedSourceError.manifestMismatch(profile: profile.identifier)
        }

        let archive = try ZipArchive(apkBytes)
        let dex = try DexFile(try archive.data(named: "classes.dex"))
        guard dex.classIndexByDescriptor[profile.entryClassDescriptor] != nil else {
            throw PinnedInterpretedSourceError.missingEntryClass(profile: profile.identifier)
        }
        guard let sourceAPIWrapperDescriptor = Self.sourceAPIWrapper(
            dex: dex,
            entryClassDescriptor: profile.entryClassDescriptor,
            requiredMethods: [profile.search, profile.mangaUpdate]
        ) else {
            throw PinnedInterpretedSourceError.missingSourceAPIWrapper(
                profile: profile.identifier
            )
        }

        let vm = DexInterpreter(
            dex: dex,
            bridge: HostBridge.minimal(transport: transport),
            cancelled: { Task.isCancelled }
        )
        let receiver = try vm.instantiate(classDescriptor: profile.entryClassDescriptor)
        let name = try Self.metadataString("getName", vm: vm, receiver: receiver, profile: profile)
        let language = try Self.metadataString("getLang", vm: vm, receiver: receiver, profile: profile)
        let baseURL = try Self.metadataString("getBaseUrl", vm: vm, receiver: receiver, profile: profile)
        let idValue = try vm.call(
            classDescriptor: profile.entryClassDescriptor,
            method: "getId",
            prototype: "()J",
            args: [receiver]
        )
        guard case let .long(id) = idValue,
              id > 0,
              name == profile.expectedName,
              language == profile.expectedLanguage,
              baseURL == profile.expectedBaseURL else {
            throw PinnedInterpretedSourceError.invalidMetadata(profile: profile.identifier)
        }

        self.profile = profile
        self.vm = vm
        self.receiver = receiver
        self.sourceAPIWrapperDescriptor = sourceAPIWrapperDescriptor
        self.metadata = PinnedInterpretedMetadata(
            id: id,
            name: name,
            language: language,
            supportsLatest: profile.supportsLatest,
            baseURL: baseURL
        )
    }

    func popular(page: Int) async throws -> MangasPageCompat {
        let page = try Self.pageNumber(page, operation: "popular manga")
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        let result = try await vm.callAsync(
            classDescriptor: profile.entryClassDescriptor,
            method: profile.popular.name,
            prototype: profile.popular.prototype,
            args: [receiver, .int(page), .null]
        )
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
        let result = try await vm.callAsync(
            classDescriptor: profile.entryClassDescriptor,
            method: profile.latest.name,
            prototype: profile.latest.prototype,
            args: [receiver, .int(page), .null]
        )
        guard let converted = HostBridge.mangasPageCompat(from: result) else {
            throw PinnedInterpretedSourceError.unexpectedResult(operation: "latest updates")
        }
        return converted
    }

    func search(page: Int, query: String) async throws -> MangasPageCompat {
        let page = try Self.pageNumber(page, operation: "search")
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        let result = try await vm.callAsync(
            // Keiyoushi's stable public wrapper routes URL queries and then
            // virtually dispatches to the extension's R8-renamed worker.
            classDescriptor: sourceAPIWrapperDescriptor,
            method: profile.search.name,
            prototype: profile.search.prototype,
            args: [receiver, .int(page), HostBridge.string(query), .null, .null]
        )
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
        let result = try await vm.callAsync(
            // The inherited wrapper owns concurrency protection and initialized
            // state, then virtually dispatches to the extension implementation.
            classDescriptor: sourceAPIWrapperDescriptor,
            method: profile.mangaUpdate.name,
            prototype: profile.mangaUpdate.prototype,
            args: [
                receiver,
                HostBridge.mangaValue(from: manga),
                HostBridge.emptyListValue(),
                .int(1),
                .int(1),
                .null,
            ]
        )
        guard let converted = HostBridge.mangaUpdateCompat(from: result) else {
            throw PinnedInterpretedSourceError.unexpectedResult(operation: "manga update")
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
        let result = try await vm.callAsync(
            classDescriptor: profile.entryClassDescriptor,
            method: profile.pages.name,
            prototype: profile.pages.prototype,
            args: [receiver, HostBridge.chapterValue(from: chapter), .null]
        )
        guard let converted = HostBridge.pagesCompat(from: result) else {
            throw PinnedInterpretedSourceError.unexpectedResult(operation: "page list")
        }
        return converted
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

    private static func metadataString(
        _ method: String,
        vm: DexInterpreter,
        receiver: RVal,
        profile: PinnedInterpretedProfile
    ) throws -> String {
        let result = try vm.call(
            classDescriptor: profile.entryClassDescriptor,
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

    /// R8 may rename a source's abstract implementation workers, but the
    /// app-facing `KeiSource` methods remain public and stable. R8 may keep the
    /// wrapper in a superclass or vertically merge it into the generated entry
    /// class, so walk only that local chain and require one concrete, public,
    /// non-static declaration of every measured wrapper method.
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

    private static func sha256Hex(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }
}
