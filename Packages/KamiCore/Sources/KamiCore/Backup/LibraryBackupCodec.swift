import Foundation
import MihonCompatKit

/// Bounded v1 library archive conversion, without database, network or runtime
/// source effects. A successfully validated document still carries no authority
/// to restore its rows or to use its descriptive source binding.
public struct LibraryBackupCodec: Sendable {
    public let policy: LibraryBackupPolicy

    public init(policy: LibraryBackupPolicy = .default) { self.policy = policy }

    public func decode(_ data: Data) throws -> LibraryBackupDocument {
        var preflight = try LibraryBackupJSONPreflight(data: data, policy: policy)
        try preflight.run()
        let document: LibraryBackupDocument
        do {
            document = try JSONDecoder().decode(LibraryBackupWireDocument.self, from: data).value
        } catch let error as LibraryBackupError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LibraryBackupError.invalidSchema
        }
        try validate(document)
        return document
    }

    public func encode(_ document: LibraryBackupDocument) throws -> Data {
        try validate(document)
        var writer = LibraryBackupJSONWriter(policy: policy)
        try writer.write(document)
        let data = writer.data
        // These lower injected limits apply equally to encode and decode.
        var preflight = try LibraryBackupJSONPreflight(data: data, policy: policy)
        try preflight.run()
        return data
    }

    public func validate(_ document: LibraryBackupDocument) throws {
        var validation = LibraryBackupValidation(policy: policy)
        try validation.validate(document)
    }
}

private struct LibraryBackupMangaIdentity: Hashable {
    let sourceID: Int64
    let url: Data
}

private struct LibraryBackupValidation {
    let policy: LibraryBackupPolicy
    var stringBytes = 0
    var chapters = 0
    var history = 0
    var known = 0
    var memberships = 0

    mutating func validate(_ document: LibraryBackupDocument) throws {
        try Task.checkCancellation()
        guard document.exportedAt >= 0 else { throw LibraryBackupError.invalidSchema }
        try limit(document.sources.count, policy.maximumSources, .sources)
        try limit(document.categories.count, policy.maximumCategories, .categories)
        try limit(document.manga.count, policy.maximumManga, .manga)

        var sourceIDs = Set<Int64>()
        for source in document.sources {
            try Task.checkCancellation()
            guard sourceIDs.insert(source.sourceID).inserted else { throw LibraryBackupError.duplicateIdentity }
            try text(source.name, maximum: policy.maximumLabelBytes, limit: .labelBytes)
            try optionalText(source.language, maximum: policy.maximumLabelBytes, limit: .labelBytes)
            try optionalText(source.packageHint, maximum: policy.maximumMetadataBytes, limit: .metadataBytes)
            try binding(source.contentBinding, sourceID: source.sourceID)
        }

        var categoryKeys = Set<Data>()
        var categoryNames = [String]()
        for category in document.categories {
            try Task.checkCancellation()
            try identity(category.key, maximum: policy.maximumLabelBytes, limit: .labelBytes)
            guard categoryKeys.insert(Data(category.key.utf8)).inserted else { throw LibraryBackupError.duplicateIdentity }
            try text(category.name, maximum: policy.maximumLabelBytes, limit: .labelBytes)
            guard let validName = try? Category.validatedName(category.name),
                  Data(validName.utf8) == Data(category.name.utf8) else { throw LibraryBackupError.invalidSchema }
            guard !categoryNames.contains(where: { Category.namesMatch($0, category.name) }) else {
                throw LibraryBackupError.ambiguousCategoryName
            }
            categoryNames.append(category.name)
        }

        var mangaIdentities = Set<LibraryBackupMangaIdentity>()
        for manga in document.manga {
            try Task.checkCancellation()
            guard sourceIDs.contains(manga.sourceID) else { throw LibraryBackupError.danglingReference }
            try identity(manga.url, maximum: policy.maximumURLBytes, limit: .urlBytes)
            let exact = LibraryBackupMangaIdentity(sourceID: manga.sourceID, url: Data(manga.url.utf8))
            guard mangaIdentities.insert(exact).inserted else { throw LibraryBackupError.duplicateIdentity }
            try text(manga.title, maximum: policy.maximumMetadataBytes, limit: .metadataBytes)
            try limit(manga.altTitles.count, policy.maximumAlternateTitles, .alternateTitles)
            for title in manga.altTitles {
                try text(title, maximum: policy.maximumMetadataBytes, limit: .metadataBytes)
            }
            if let url = manga.thumbnailURL {
                try identity(url, maximum: policy.maximumURLBytes, limit: .urlBytes, allowEmpty: true)
            }
            try optionalText(manga.author, maximum: policy.maximumMetadataBytes, limit: .metadataBytes)
            try optionalText(manga.artist, maximum: policy.maximumMetadataBytes, limit: .metadataBytes)
            try optionalText(manga.descriptionText, maximum: policy.maximumDescriptionBytes, limit: .descriptionBytes)
            try limit(manga.genres.count, policy.maximumGenres, .genres)
            for genre in manga.genres {
                try text(genre, maximum: policy.maximumMetadataBytes, limit: .metadataBytes)
            }
            guard manga.dateAdded >= 0, manga.dateUpdated >= 0, manga.lastFetched >= 0 else {
                throw LibraryBackupError.invalidSchema
            }

            try Self.accumulate(manga.categoryKeys.count, total: &memberships,
                           maximum: policy.maximumMemberships, limit: .memberships)
            var memberKeys = Set<Data>()
            for key in manga.categoryKeys {
                try identity(key, maximum: policy.maximumLabelBytes, limit: .labelBytes)
                let bytes = Data(key.utf8)
                guard memberKeys.insert(bytes).inserted else { throw LibraryBackupError.duplicateIdentity }
                guard categoryKeys.contains(bytes) else { throw LibraryBackupError.danglingReference }
            }
            guard manga.inLibrary || manga.categoryKeys.isEmpty else { throw LibraryBackupError.invalidSchema }

            try limit(manga.chapters.count, policy.maximumChaptersPerManga, .chaptersPerManga)
            try Self.accumulate(manga.chapters.count, total: &chapters,
                           maximum: policy.maximumChapters, limit: .chapters)
            var chapterURLs = Set<Data>()
            for chapter in manga.chapters {
                try Task.checkCancellation()
                try identity(chapter.url, maximum: policy.maximumURLBytes, limit: .urlBytes)
                guard chapterURLs.insert(Data(chapter.url.utf8)).inserted else { throw LibraryBackupError.duplicateIdentity }
                try text(chapter.name, maximum: policy.maximumMetadataBytes, limit: .metadataBytes)
                try optionalText(chapter.scanlator, maximum: policy.maximumMetadataBytes, limit: .metadataBytes)
                guard chapter.number.isFinite, chapter.dateUpload >= 0, chapter.dateFetch >= 0,
                      chapter.lastPageRead >= 0 else { throw LibraryBackupError.invalidSchema }
            }

            try Self.accumulate(manga.history.count, total: &history,
                           maximum: policy.maximumHistory, limit: .history)
            var historyURLs = Set<Data>()
            for item in manga.history {
                try Task.checkCancellation()
                try identity(item.chapterURL, maximum: policy.maximumURLBytes, limit: .urlBytes)
                let bytes = Data(item.chapterURL.utf8)
                guard historyURLs.insert(bytes).inserted else { throw LibraryBackupError.duplicateIdentity }
                guard chapterURLs.contains(bytes) else { throw LibraryBackupError.danglingReference }
                guard item.lastRead >= 0, item.readDuration >= 0 else { throw LibraryBackupError.invalidSchema }
            }
            if let baseline = manga.discoveryBaseline {
                guard baseline.establishedAt >= 0 else { throw LibraryBackupError.invalidSchema }
            }
            try Self.accumulate(manga.knownChapters.count, total: &known,
                           maximum: policy.maximumKnownChapters, limit: .knownChapters)
            var knownURLs = Set<Data>()
            for item in manga.knownChapters {
                try Task.checkCancellation()
                try identity(item.url, maximum: policy.maximumURLBytes, limit: .urlBytes)
                guard knownURLs.insert(Data(item.url.utf8)).inserted else { throw LibraryBackupError.duplicateIdentity }
                guard item.firstSeen >= 0, item.detectedAt.map({ $0 >= 0 }) ?? true else {
                    throw LibraryBackupError.invalidSchema
                }
            }
        }
        try Task.checkCancellation()
    }

    private func limit(_ value: Int, _ maximum: Int, _ kind: LibraryBackupError.Limit) throws {
        guard value <= maximum else { throw LibraryBackupError.limitExceeded(kind) }
    }

    private static func accumulate(_ amount: Int, total: inout Int, maximum: Int,
                            limit: LibraryBackupError.Limit) throws {
        guard amount <= maximum - total else { throw LibraryBackupError.limitExceeded(limit) }
        total += amount
    }

    private mutating func text(_ value: String, maximum: Int, limit: LibraryBackupError.Limit) throws {
        try Task.checkCancellation()
        let bytes = value.utf8.count
        guard bytes <= maximum else { throw LibraryBackupError.limitExceeded(limit) }
        guard bytes <= policy.maximumTotalStringBytes - stringBytes else {
            throw LibraryBackupError.limitExceeded(.totalStringBytes)
        }
        guard !value.utf8.contains(0) else { throw LibraryBackupError.invalidSchema }
        stringBytes += bytes
    }

    private mutating func optionalText(_ value: String?, maximum: Int,
                                      limit: LibraryBackupError.Limit) throws {
        if let value { try text(value, maximum: maximum, limit: limit) }
    }

    private mutating func identity(_ value: String, maximum: Int, limit: LibraryBackupError.Limit,
                                   allowEmpty: Bool = false) throws {
        try text(value, maximum: maximum, limit: limit)
        guard (allowEmpty || !value.isEmpty),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw LibraryBackupError.invalidSchema
        }
    }

    private mutating func binding(_ binding: LibraryBackupDocument.ContentBinding, sourceID: Int64) throws {
        // This compiled metadata lookup and pure scalar validation perform no
        // APK execution, admission, preference persistence or network access.
        let schema = InterpretedExtensionProfileCatalog.preferenceSchema(
            packageName: "eu.kanade.tachiyomi.extension.all.foolslidecustomizable",
            versionName: "1.6.6", versionCode: 6
        )
        let knownConfigurable = schema?.identity.sourceIDs.contains(sourceID) == true
        switch binding.kind {
        case .sourceIdentity:
            guard !knownConfigurable, binding.deploymentURL == nil else {
                throw LibraryBackupError.invalidContentBinding
            }
        case .unresolved:
            guard binding.deploymentURL == nil else { throw LibraryBackupError.invalidContentBinding }
        case .deployment:
            guard knownConfigurable, let url = binding.deploymentURL, let schema else {
                throw LibraryBackupError.invalidContentBinding
            }
            try identity(url, maximum: policy.maximumURLBytes, limit: .urlBytes)
            guard (try? schema.validateUserValues([.baseURL: .string(url)])) != nil else {
                throw LibraryBackupError.invalidContentBinding
            }
        }
    }
}
