import Foundation

/// Pure conservative union. Database IDs, execution settings and download
/// evidence never come from this document. All URL dictionaries use UTF-8.
enum LibraryRestorePlanner {
    typealias Document = LibraryBackupDocument
    static let foolSlideID: Int64 = 6_351_052_922_295_965_587
    private typealias Identity = LibraryRestoreMangaIdentity

    static func plan(input: Document, target: Document,
                     foolSlideBinding: Document.ContentBinding?,
                     policy: LibraryBackupPolicy) throws -> LibraryRestorePlan {
        let codec = LibraryBackupCodec(policy: policy)
        try codec.validate(input)
        try codec.validate(target)
        var summary = LibraryRestoreSummary()
        var conflicts: [LibraryRestoreConflict] = []
        var newBinding: Document.ContentBinding?
        let populatedFoo = target.manga.contains { $0.sourceID == foolSlideID }
        let sourceCounts = Dictionary(input.manga.map { ($0.sourceID, 1) }, uniquingKeysWith: +)
        for source in input.sources {
            try Task.checkCancellation()
            let count = sourceCounts[source.sourceID, default: 0]
            guard count > 0 else { continue }
            if source.sourceID == foolSlideID {
                if let current = foolSlideBinding {
                    let same = current.kind == .deployment && source.contentBinding.kind == .deployment
                        && current.deploymentURL.map { Data($0.utf8) } == source.contentBinding.deploymentURL.map { Data($0.utf8) }
                    let emptyUnresolved = !populatedFoo && current.kind == .unresolved && source.contentBinding.kind == .unresolved
                    if !same && !emptyUnresolved {
                        conflicts.append(.init(sourceID: source.sourceID,
                            reason: current.kind == .unresolved || source.contentBinding.kind == .unresolved
                                ? .unresolvedDeployment : .differentDeployment, mangaCount: count,
                            incomingDeployment: source.contentBinding.deploymentURL, storedDeployment: current.deploymentURL))
                    } else if emptyUnresolved { summary.unresolvedManga += count }
                } else {
                    guard !populatedFoo else { throw LibraryRestoreError.invalidStoredData }
                    newBinding = source.contentBinding
                    if source.contentBinding.kind == .unresolved { summary.unresolvedManga += count }
                }
            } else if source.contentBinding.kind != .sourceIdentity {
                // No persisted inert namespace exists for arbitrary source IDs.
                conflicts.append(.init(sourceID: source.sourceID, reason: .unresolvedDeployment, mangaCount: count,
                                       incomingDeployment: source.contentBinding.deploymentURL, storedDeployment: nil))
            }
        }
        let excluded = Set(conflicts.map(\.sourceID))
        summary.excludedManga = conflicts.reduce(0) { $0 + $1.mangaCount }

        var categories = target.categories
        var categoryMapping: [Data: String] = [:]
        var nextOrder = categories.map(\.sortOrder).max() ?? -1
        for category in input.categories.sorted(by: {
            $0.sortOrder == $1.sortOrder ? Data($0.key.utf8).lexicographicallyPrecedes(Data($1.key.utf8))
                : $0.sortOrder < $1.sortOrder
        }) {
            try Task.checkCancellation()
            if let existing = categories.first(where: { Category.namesMatch($0.name, category.name) }) {
                categoryMapping[Data(category.key.utf8)] = existing.key
            } else {
                guard categories.count < policy.maximumCategories else { throw LibraryRestoreError.resultLimitExceeded }
                guard nextOrder < Int64.max else { throw LibraryRestoreError.categoryOrderOverflow }
                nextOrder += 1
                let key = "restored-\(summary.newCategories)"
                // Target snapshot uses cNNNN keys, and added keys use one prefix.
                guard !categories.contains(where: { Data($0.key.utf8) == Data(key.utf8) }) else {
                    throw LibraryRestoreError.invalidStoredData
                }
                categoryMapping[Data(category.key.utf8)] = key
                categories.append(.init(key: key, name: category.name, sortOrder: nextOrder, flags: category.flags))
                summary.newCategories += 1
            }
        }

        var manga = target.manga
        var indexes = Dictionary(uniqueKeysWithValues: manga.enumerated().map { (Identity($0.element), $0.offset) })
        for incoming in input.manga where !excluded.contains(incoming.sourceID) {
            try Task.checkCancellation()
            let mapped = try incoming.categoryKeys.map { key in
                guard let value = categoryMapping[Data(key.utf8)] else { throw LibraryBackupError.danglingReference }
                return value
            }
            if let index = indexes[Identity(incoming)] {
                summary.existingManga += 1
                manga[index] = try merge(incoming, into: manga[index], categories: mapped, summary: &summary,
                                         policy: policy)
            } else {
                guard manga.count < policy.maximumManga else { throw LibraryRestoreError.resultLimitExceeded }
                indexes[Identity(incoming)] = manga.count
                // Imported known URLs establish knowledge, not new Updates.
                let known = incoming.knownChapters.map { Document.KnownChapter(url: $0.url, firstSeen: $0.firstSeen) }
                manga.append(copy(incoming, categories: mapped, known: known))
                summary.newManga += 1
                summary.newChapters += incoming.chapters.count
                summary.historyEntries += incoming.history.count
            }
        }
        let sourceIDs = Set(manga.map(\.sourceID))
        var sources = Dictionary(uniqueKeysWithValues: target.sources.map { ($0.sourceID, $0) })
        for source in input.sources where !excluded.contains(source.sourceID) && sources[source.sourceID] == nil {
            sources[source.sourceID] = source
        }
        let result = Document(exportID: target.exportID, exportedAt: target.exportedAt,
            sources: sources.values.filter { sourceIDs.contains($0.sourceID) }.sorted { $0.sourceID < $1.sourceID },
            categories: categories, manga: manga)
        do { try codec.validate(result) }
        catch is CancellationError { throw CancellationError() }
        catch { throw LibraryRestoreError.resultLimitExceeded }
        return .init(document: result, summary: summary, conflicts: conflicts.sorted { $0.sourceID < $1.sourceID },
                     newFoolSlideBinding: newBinding,
                     affectedManga: Set(input.manga.filter { !excluded.contains($0.sourceID) }.map(Identity.init)))
    }

    private static func merge(_ incoming: Document.Manga, into saved: Document.Manga,
                              categories: [String], summary: inout LibraryRestoreSummary,
                              policy: LibraryBackupPolicy) throws -> Document.Manga {
        var chapters = saved.chapters
        var chapterIndexes = Dictionary(uniqueKeysWithValues: chapters.enumerated().map { (Data($0.element.url.utf8), $0.offset) })
        for item in incoming.chapters {
            try Task.checkCancellation()
            if let index = chapterIndexes[Data(item.url.utf8)] {
                let old = chapters[index]
                chapters[index] = .init(sourceOrder: old.sourceOrder, url: old.url, name: old.name,
                    scanlator: old.scanlator, number: old.number, dateUpload: old.dateUpload, dateFetch: old.dateFetch,
                    read: old.read || item.read, bookmark: old.bookmark || item.bookmark,
                    lastPageRead: max(old.lastPageRead, item.lastPageRead), isCurrent: old.isCurrent)
                summary.existingChapters += 1
            } else {
                guard chapters.count < policy.maximumChaptersPerManga else { throw LibraryRestoreError.resultLimitExceeded }
                chapterIndexes[Data(item.url.utf8)] = chapters.count
                chapters.append(.init(sourceOrder: item.sourceOrder, url: item.url, name: item.name,
                    scanlator: item.scanlator, number: item.number, dateUpload: item.dateUpload, dateFetch: item.dateFetch,
                    read: item.read, bookmark: item.bookmark, lastPageRead: item.lastPageRead,
                    isCurrent: saved.discoveryBaseline == nil && saved.chapters.isEmpty ? item.isCurrent : false))
                summary.newChapters += 1
            }
        }
        var history = Dictionary(uniqueKeysWithValues: saved.history.map { (Data($0.chapterURL.utf8), $0) })
        for item in incoming.history {
            try Task.checkCancellation()
            let old = history[Data(item.chapterURL.utf8)]
            history[Data(item.chapterURL.utf8)] = .init(chapterURL: item.chapterURL,
                lastRead: max(old?.lastRead ?? 0, item.lastRead), readDuration: max(old?.readDuration ?? 0, item.readDuration))
            summary.historyEntries += 1
        }
        var known = Dictionary(uniqueKeysWithValues: saved.knownChapters.map { (Data($0.url.utf8), $0) })
        for item in incoming.knownChapters where known[Data(item.url.utf8)] == nil {
            try Task.checkCancellation()
            known[Data(item.url.utf8)] = .init(url: item.url, firstSeen: item.firstSeen)
        }
        var memberKeys = saved.categoryKeys
        var memberSet = Set(memberKeys.map { Data($0.utf8) })
        for key in categories where memberSet.insert(Data(key.utf8)).inserted {
            try Task.checkCancellation()
            memberKeys.append(key)
        }
        return copy(saved, inLibrary: saved.inLibrary || incoming.inLibrary, categories: memberKeys,
                    chapters: chapters, history: history.sorted { $0.key.lexicographicallyPrecedes($1.key) }.map(\.value),
                    baseline: saved.discoveryBaseline ?? incoming.discoveryBaseline,
                    known: known.sorted { $0.key.lexicographicallyPrecedes($1.key) }.map(\.value))
    }

    private static func copy(_ value: Document.Manga, inLibrary: Bool? = nil, categories: [String],
                             chapters: [Document.Chapter]? = nil, history: [Document.History]? = nil,
                             baseline: Document.DiscoveryBaseline? = nil, known: [Document.KnownChapter]) -> Document.Manga {
        .init(sourceID: value.sourceID, url: value.url, title: value.title, altTitles: value.altTitles,
              thumbnailURL: value.thumbnailURL, author: value.author, artist: value.artist,
              descriptionText: value.descriptionText, genres: value.genres, status: value.status,
              inLibrary: inLibrary ?? value.inLibrary, dateAdded: value.dateAdded, dateUpdated: value.dateUpdated,
              lastFetched: value.lastFetched, updateStrategy: value.updateStrategy, initialized: value.initialized,
              categoryKeys: categories, chapters: chapters ?? value.chapters, history: history ?? value.history,
              discoveryBaseline: baseline ?? value.discoveryBaseline, knownChapters: known)
    }
}
