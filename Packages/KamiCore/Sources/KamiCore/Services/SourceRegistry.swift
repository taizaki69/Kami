import Foundation
import MihonCompatKit

public enum SourceOrigin: Equatable, Sendable {
    case native
    case pinnedCompatibilityProfile
    case downloadedExtension(packageName: String)
}

public enum SourceRegistryError: Error, Equatable, Sendable, LocalizedError {
    case sourceSetMismatch

    public var errorDescription: String? {
        "The replacement sources do not match the admitted extension."
    }
}

/// A captured published registration. Its lifetime only rejects obsolete
/// work; it does not grant signer trust, enable a source, or authorize transport.
/// App cannot manufacture a snapshot for a raw, unregistered source.
public struct SourceRegistrationSnapshot: Sendable {
    public let source: any KamiSource
    public let revision: UInt64
    public let origin: SourceOrigin
    private let scope: SourceRequestScope

    public var sourceID: Int64 { source.id }
    public var registrationID: UUID { scope.id }

    init(source: any KamiSource, revision: UInt64, origin: SourceOrigin, scope: SourceRequestScope) {
        self.source = source
        self.revision = revision
        self.origin = origin
        self.scope = scope
    }

    public func checkAvailability() throws {
        try scope.checkAvailability()
    }

    /// Native projections gain this lifetime; already-bound interpreted
    /// requests must have the exact same original scope and retain their handle.
    public func scopedImageRequest(_ request: ImageRequest) throws -> ImageRequest {
        try request.scoped(to: scope)
    }
}

/// Registry of all installed/available sources. Native and interpreted sources
/// share `KamiSource`, so the app layer does not need source-kind branches.
@MainActor
public final class SourceRegistry {
    public private(set) var sources: [any KamiSource] = []
    private var origins: [Int64: SourceOrigin] = [:]
    private var protectedSourceIDs = Set<Int64>()
    private var scopes: [Int64: SourceRequestScope] = [:]
    private var revisions: [Int64: UInt64] = [:]

    public init() {
        registerDefaults()
    }

    func registerDefaults() {
        let md = MangaDexSource()
        sources.append(md)
        origins[md.id] = .native
        protectedSourceIDs.insert(md.id)
        scopes[md.id] = SourceRequestScope()
        revisions[md.id] = 1
    }

    public func source(id: Int64) -> (any KamiSource)? {
        sources.first { $0.id == id }
    }

    public func origin(of sourceID: Int64) -> SourceOrigin? {
        origins[sourceID]
    }

    public func registrationSnapshot(id: Int64) -> SourceRegistrationSnapshot? {
        guard let source = source(id: id), let origin = origins[id],
              let scope = scopes[id], scope.isActive else { return nil }
        return SourceRegistrationSnapshot(
            source: source, revision: revision(for: id), origin: origin, scope: scope
        )
    }

    /// Retained after removal so an open view can detect a revoked instance.
    public func revision(for sourceID: Int64) -> UInt64 {
        revisions[sourceID, default: 0]
    }

    /// Registers a compiled, exact-hash pinned adapter. The concrete type
    /// prevents this path from accepting an arbitrary downloaded source.
    public func addPinned(_ source: PinnedInterpretedSource) {
        guard self.source(id: source.id) == nil else { return }
        sources.append(source)
        origins[source.id] = .pinnedCompatibilityProfile
        protectedSourceIDs.insert(source.id)
        scopes[source.id] = SourceRequestScope()
        revisions[source.id, default: 0] &+= 1
    }

    /// The only public registration path for a source constructed from a
    /// downloaded APK. The capability is issued after signer trust is
    /// persisted, and the source ID must have been declared by that extension.
    public func addDownloaded(
        _ source: any KamiSource,
        admission: ExtensionAdmission
    ) throws {
        try validate(source, admission: admission)
        let wrapped = registered(source, admission: admission)
        revoke(source.id)
        scopes[source.id] = wrapped.scope
        if let index = sources.firstIndex(where: { $0.id == source.id }) {
            sources[index] = wrapped
        } else {
            sources.append(wrapped)
        }
        origins[source.id] = .downloadedExtension(packageName: admission.packageName)
    }

    /// Validate the complete set before revoking or replacing any source. No
    /// suspension separates validation, publication and revision changes.
    public func replaceDownloaded(
        sources replacements: [any KamiSource],
        admission: ExtensionAdmission
    ) throws {
        let ids = Set(replacements.map(\.id))
        guard ids == admission.sourceIDs, ids.count == replacements.count,
              !ids.isEmpty else { throw SourceRegistryError.sourceSetMismatch }
        for source in replacements { try validate(source, admission: admission) }

        let previous = downloadedIDs(packageName: admission.packageName)
        let insertionIndex = sources.firstIndex(where: { previous.contains($0.id) }) ?? sources.count
        let wrapped = replacements.map { registered($0, admission: admission) }
        for id in previous.union(ids) { revoke(id) }
        sources.removeAll { previous.contains($0.id) }
        for id in previous { origins.removeValue(forKey: id) }
        sources.insert(contentsOf: wrapped, at: min(insertionIndex, sources.count))
        for source in wrapped {
            scopes[source.id] = source.scope
            origins[source.id] = .downloadedExtension(packageName: admission.packageName)
        }
    }

    public func removeDownloaded(packageName: String) {
        removeDownloaded(sourceIDs: downloadedIDs(packageName: packageName), packageName: packageName)
    }

    private func validate(_ source: any KamiSource, admission: ExtensionAdmission) throws {
        guard admission.sourceIDs.contains(source.id) else {
            throw ExtensionAdmissionError.sourceNotDeclared(source.id)
        }
        guard !protectedSourceIDs.contains(source.id) else {
            throw ExtensionAdmissionError.sourceIDCollision(source.id)
        }
        if case let .downloadedExtension(existingPackage) = origins[source.id],
           existingPackage != admission.packageName {
            throw ExtensionAdmissionError.sourceIDCollision(source.id)
        }
    }

    private func registered(_ source: any KamiSource, admission: ExtensionAdmission) -> RegisteredSource {
        RegisteredSource(source: source, scope: SourceRequestScope(), fallbackReport:
            InterpretedCompatibilityRecorder(packageName: admission.packageName,
                versionName: admission.versionName, versionCode: admission.versionCode).report())
    }

    private func downloadedIDs(packageName: String) -> Set<Int64> {
        Set(origins.compactMap { id, origin in
            origin == .downloadedExtension(packageName: packageName) ? id : nil
        })
    }

    private func revoke(_ id: Int64) {
        scopes.removeValue(forKey: id)?.revoke()
        revisions[id, default: 0] &+= 1
    }

    /// Disabling an installed extension removes only its non-built-in source
    /// IDs. Re-enabling reconstructs them through a fresh admission capability.
    public func removeDownloaded(sourceIDs: Set<Int64>, packageName: String) {
        let removable = sourceIDs.subtracting(protectedSourceIDs).filter {
            origins[$0] == .downloadedExtension(packageName: packageName)
        }
        sources.removeAll { removable.contains($0.id) }
        for sourceID in removable {
            revoke(sourceID)
            origins.removeValue(forKey: sourceID)
        }
    }
}

#if canImport(SQLite3)
/// Library-facing service: search/browse coordination and manga metadata
/// refresh, talking to sources and persisting via LibraryStore.
public struct LibraryService {
    let store: LibraryStore

    public init(store: LibraryStore) {
        self.store = store
    }

    /// Fetches details+chapters from a source and persists them, preserving
    /// read state. Downloaded sources require the configuration captured when
    /// their current instance was registered. Returns the updated stored manga.
    public func refresh(
        mangaId: Int64,
        source: any KamiSource,
        expectedConfiguration: ExtensionExecutionConfiguration? = nil
    ) async throws -> Manga? {
        guard var stored = try await store.manga(id: mangaId) else { return nil }
        guard stored.sourceId == source.id else {
            throw SourceUpdatePersistenceError.sourceIdentityMismatch
        }
        try await store.validateSourceExecution(sourceID: stored.sourceId, expectedConfiguration: expectedConfiguration)
        try Task.checkCancellation()
        var compat = SMangaCompat(
            url: stored.url,
            title: stored.title,
            altTitles: stored.altTitles,
            thumbnailURL: stored.thumbnailURL,
            artist: stored.artist,
            author: stored.author,
            status: stored.status,
            description: stored.descriptionText,
            genres: stored.genres,
            updateStrategy: stored.updateStrategy
        )
        let update = try await source.getMangaUpdate(manga: compat)
        let chapters = update.chapters
        compat = update.manga
        compat.initialized = true

        stored.title = compat.title
        stored.altTitles = compat.altTitles
        stored.thumbnailURL = compat.thumbnailURL
        stored.author = compat.author
        stored.artist = compat.artist
        stored.descriptionText = compat.description
        stored.genres = compat.genres
        stored.status = compat.status
        stored.updateStrategy = compat.updateStrategy
        stored.dateUpdated = Int64(Date().timeIntervalSince1970)
        try Task.checkCancellation()
        return try await store.persistSourceUpdate(manga: stored, chapters: chapters,
            expectedConfiguration: expectedConfiguration).manga
    }
}
#endif
