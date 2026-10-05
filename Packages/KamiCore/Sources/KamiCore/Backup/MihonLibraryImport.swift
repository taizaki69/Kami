import Foundation
import MihonCompatKit

public enum MihonLibraryImportError: Error, Equatable, Sendable, LocalizedError {
    case invalidData, ambiguousCategories, limitExceeded
    public var errorDescription: String? {
        switch self {
        case .invalidData: "This Mihon backup contains data that cannot be imported safely."
        case .ambiguousCategories: "This backup has ambiguous category orders or names. Resolve them in the original app and export again."
        case .limitExceeded: "This Mihon backup exceeds the supported import limits."
        }
    }
}

/// Finite aggregate reasons. Original files stay outside the database; excluded
/// identities must never become operational rows just because an ID is known.
public struct MihonLibraryImportReport: Sendable, Equatable {
    public enum Exclusion: String, CaseIterable, Sendable {
        case unsupportedSource, mangaURL, chapterURL, chapterParent, historyReference
        case removedHistory, categoryReference, nonLibraryMembership
    }
    public struct Issue: Sendable, Equatable, Identifiable {
        public let reason: Exclusion
        public let count: Int
        public var id: String { reason.rawValue }
    }
    public let adapterVersion: Int
    public let compression: TachibkReader.Compression
    public let coverage: TachibkReader.CoverageReport
    public let inputManga: Int
    public let inputChapters: Int
    public let inputHistory: Int
    public let mappedManga: Int
    public let mappedChapters: Int
    public let mappedHistory: Int
    public let reusedStoredChapters: Int
    public let excludedManga: Int
    public let excludedChapters: Int
    public let excludedHistory: Int
    public let duplicateManga: Int
    public let duplicateChapters: Int
    public let duplicateHistory: Int
    public let normalizedCategories: Int
    public let roundedTimestamps: Int
    public let unsupportedSourceIDs: [Int64]
    public let issues: [Issue]
    public var hasImportableData: Bool { mappedManga > 0 }
}

/// Only the measured English MangaDex identity and persisted path grammar are
/// adapted. No registry, source factory, transport or request authority is used.
enum MihonLibraryImport {
    typealias Doc = LibraryBackupDocument
    static let version = 1
    static let sourceID: Int64 = 2_499_283_573_021_220_255
    struct Result {
        let document: Doc
        let report: MihonLibraryImportReport
    }
    private struct Group {
        let first: TachibkReader.BackupManga
        var favorite: Bool
        var categoryOrders = Set<Int64>()
        var chapters: [String: Doc.Chapter] = [:]
        var history: [String: Doc.History] = [:]
        var historyOccurrences: [String: Int] = [:]
    }

    static func uuid(_ path: String, prefix: String) -> String? {
        let bytes = Array(path.utf8), p = Array(prefix.utf8)
        guard bytes.count == p.count + 36, bytes.starts(with: p) else { return nil }
        let u = Array(bytes.dropFirst(p.count))
        for i in u.indices {
            if [8,13,18,23].contains(i) { guard u[i] == 45 else { return nil } }
            else { guard (48...57).contains(u[i]) || (97...102).contains(u[i]) else { return nil } }
        }
        guard (49...53).contains(u[14]), [56,57,97,98].contains(u[19]) else { return nil }
        return String(decoding: u, as: UTF8.self)
    }

    static func decode(_ data: Data, decodingPolicy: TachibkReader.Policy,
                       policy: LibraryBackupPolicy, target: Doc? = nil) throws -> Result {
        guard data.count <= min(decodingPolicy.maximumInputBytes, policy.maximumInputBytes) else {
            throw MihonLibraryImportError.limitExceeded
        }
        let backup: TachibkReader.DecodedBackup
        do { backup = try TachibkReader(policy: decodingPolicy).decode(Array(data)) }
        catch is CancellationError { throw CancellationError() }
        catch let error as TachibkReader.Error {
            if case .limitExceeded = error { throw MihonLibraryImportError.limitExceeded }
            throw MihonLibraryImportError.invalidData
        } catch { throw MihonLibraryImportError.invalidData }
        var issues: [MihonLibraryImportReport.Exclusion: Int] = [:]
        func issue(_ reason: MihonLibraryImportReport.Exclusion, _ count: Int = 1) { issues[reason, default: 0] += count }
        var rounded = 0
        func seconds(_ milliseconds: Int64) throws -> Int64 {
            guard milliseconds >= 0 else { throw MihonLibraryImportError.invalidData }
            if milliseconds % 1_000 != 0 { rounded += 1 }
            return milliseconds / 1_000
        }
        var categories: [Doc.Category] = [], categoryKeys: [Int64: String] = [:]
        var normalized = 0
        for item in backup.categories {
            try Task.checkCancellation()
            guard let name = try? Category.validatedName(item.name) else { throw MihonLibraryImportError.ambiguousCategories }
            if !name.utf8.elementsEqual(item.name.utf8) { normalized += 1 }
            if let key = categoryKeys[item.order], let existing = categories.first(where: { $0.key == key }) {
                guard existing.name.utf8.elementsEqual(name.utf8), existing.flags == item.flags else {
                    throw MihonLibraryImportError.ambiguousCategories
                }
                continue
            }
            guard !categories.contains(where: { Category.namesMatch($0.name, name) }) else {
                throw MihonLibraryImportError.ambiguousCategories
            }
            let key = "mihon-\(categories.count)"
            categoryKeys[item.order] = key
            categories.append(.init(key: key, name: name, sortOrder: item.order, flags: item.flags))
        }
        // Detect a claimed chapter under multiple supported manga before any
        // first-wins dictionary can accidentally assign its progress to a parent.
        var parents: [String: String] = [:], ambiguous = Set<String>()
        var storedChapters: [String: [String: Doc.Chapter]] = [:]
        for manga in target?.manga ?? [] where manga.sourceID == sourceID {
            try Task.checkCancellation()
            guard let m = uuid("/manga/" + manga.url, prefix: "/manga/") else { continue }
            for chapter in manga.chapters {
                try Task.checkCancellation()
                guard let c = uuid("/chapter/" + chapter.url, prefix: "/chapter/") else { continue }
                if let old = parents[c], old != m { ambiguous.insert(c) } else { parents[c] = m }
                storedChapters[m, default: [:]][c] = chapter
            }
        }
        for manga in backup.manga where manga.sourceId == sourceID {
            try Task.checkCancellation()
            guard let m = uuid(manga.url, prefix: "/manga/") else { continue }
            for chapter in manga.chapters {
                try Task.checkCancellation()
                guard let c = uuid(chapter.url, prefix: "/chapter/") else { continue }
                if let old = parents[c], old != m { ambiguous.insert(c) } else { parents[c] = m }
            }
        }
        var groups: [String: Group] = [:], unsupported = Set<Int64>()
        var excludedManga = 0, excludedChapters = 0, excludedHistory = 0
        var duplicateManga = 0, duplicateChapters = 0, duplicateHistory = 0
        let inputChapters = backup.manga.reduce(0) { $0 + $1.chapters.count }
        let inputHistory = backup.manga.reduce(0) { $0 + $1.history.count }
        for item in backup.manga {
            try Task.checkCancellation()
            guard item.sourceId == sourceID, let id = uuid(item.url, prefix: "/manga/") else {
                let reason: MihonLibraryImportReport.Exclusion = item.sourceId == sourceID ? .mangaURL : .unsupportedSource
                issue(reason); if item.sourceId != sourceID { unsupported.insert(item.sourceId) }
                excludedManga += 1; excludedChapters += item.chapters.count; excludedHistory += item.history.count
                continue
            }
            if groups[id] != nil { duplicateManga += 1 }
            // Remove before mutation to avoid repeated copy-on-write of large
            // chapter/history dictionaries across duplicate manga records.
            var group = groups.removeValue(forKey: id) ?? Group(first: item, favorite: item.favorite)
            group.favorite = group.favorite || item.favorite
            group.categoryOrders.formUnion(item.categories)
            for chapter in item.chapters {
                try Task.checkCancellation()
                guard let c = uuid(chapter.url, prefix: "/chapter/") else {
                    issue(.chapterURL); excludedChapters += 1; continue
                }
                guard !ambiguous.contains(c) else { issue(.chapterParent); excludedChapters += 1; continue }
                guard chapter.lastPageRead >= 0, chapter.dateFetch >= 0, chapter.dateUpload >= 0 else {
                    throw MihonLibraryImportError.invalidData
                }
                if let old = group.chapters[c] {
                    duplicateChapters += 1
                    group.chapters[c] = .init(sourceOrder: old.sourceOrder, url: c, name: old.name,
                        scanlator: old.scanlator, number: old.number, dateUpload: old.dateUpload, dateFetch: old.dateFetch,
                        read: old.read || chapter.read, bookmark: old.bookmark || chapter.bookmark,
                        lastPageRead: max(old.lastPageRead, chapter.lastPageRead))
                } else {
                    group.chapters[c] = .init(sourceOrder: chapter.sourceOrder, url: c, name: chapter.name,
                        scanlator: chapter.scanlator, number: Double(chapter.chapterNumber), dateUpload: chapter.dateUpload,
                        dateFetch: chapter.dateFetch, read: chapter.read, bookmark: chapter.bookmark,
                        lastPageRead: chapter.lastPageRead)
                }
            }
            // History may reference a chapter in another duplicate of this manga;
            // defer its relation check until all chapter records are collected.
            for history in item.history {
                try Task.checkCancellation()
                guard history.lastRead >= 0, history.readDuration >= 0 else { throw MihonLibraryImportError.invalidData }
                guard history.lastRead > 0 else { issue(.removedHistory); excludedHistory += 1; continue }
                guard let c = uuid(history.url, prefix: "/chapter/"), !ambiguous.contains(c) else {
                    issue(.historyReference); excludedHistory += 1; continue
                }
                let time = try seconds(history.lastRead)
                group.historyOccurrences[c, default: 0] += 1
                if let old = group.history[c] {
                    duplicateHistory += 1
                    group.history[c] = .init(chapterURL: c, lastRead: max(old.lastRead, time),
                                             readDuration: max(old.readDuration, history.readDuration))
                } else { group.history[c] = .init(chapterURL: c, lastRead: time, readDuration: history.readDuration) }
            }
            groups[id] = group
        }
        var manga: [Doc.Manga] = [], reusedStoredChapters = 0
        for id in groups.keys.sorted() {
            try Task.checkCancellation()
            guard var group = groups.removeValue(forKey: id), let status = MangaStatus(rawValue: group.first.status) else {
                throw MihonLibraryImportError.invalidData
            }
            var keys: [String] = []
            for order in group.categoryOrders.sorted() {
                guard let key = categoryKeys[order] else { issue(.categoryReference); continue }
                guard group.favorite else { issue(.nonLibraryMembership); continue }
                keys.append(key)
            }
            var history: [Doc.History] = []
            for (c, item) in group.history.sorted(by: { $0.key < $1.key }) {
                try Task.checkCancellation()
                if group.chapters[c] == nil, let saved = storedChapters[id]?[c] {
                    group.chapters[c] = saved
                    reusedStoredChapters += 1
                }
                guard group.chapters[c] != nil else {
                    let count = group.historyOccurrences[c, default: 1]
                    issue(.historyReference, count); excludedHistory += count
                    duplicateHistory -= count - 1
                    continue
                }
                history.append(item)
            }
            let first = group.first
            guard first.dateAdded >= 0, (first.favoriteModifiedAt ?? 0) >= 0 else { throw MihonLibraryImportError.invalidData }
            // Native manga/history clocks are seconds; chapter timestamps and
            // stored read duration remain milliseconds, matching the upstream DTO.
            let added = first.dateAdded == 0 ? (group.favorite ? first.favoriteModifiedAt ?? 0 : 0) : try seconds(first.dateAdded)
            manga.append(.init(sourceID: sourceID, url: id, title: first.title, thumbnailURL: first.thumbnailURL,
                author: first.author, artist: first.artist, descriptionText: first.descriptionText, genres: first.genre,
                status: status, inLibrary: group.favorite, dateAdded: added,
                updateStrategy: first.updateStrategy == .onlyFetchOnce ? .onlyFetchOnce : .alwaysUpdate,
                initialized: first.initialized, categoryKeys: keys,
                chapters: group.chapters.sorted { $0.key < $1.key }.map(\.value), history: history,
                knownChapters: group.chapters.keys.sorted().map { .init(url: $0, firstSeen: 0) }))
        }
        let document = Doc(exportID: UUID(), exportedAt: 0,
            sources: manga.isEmpty ? [] : [.init(sourceID: sourceID, name: "MangaDex", language: "en")],
            categories: categories, manga: manga)
        do { try LibraryBackupCodec(policy: policy).validate(document) }
        catch is CancellationError { throw CancellationError() }
        catch let error as LibraryBackupError {
            if case .limitExceeded = error { throw MihonLibraryImportError.limitExceeded }
            throw MihonLibraryImportError.invalidData
        }
        return .init(document: document, report: .init(adapterVersion: version, compression: backup.compression,
            coverage: backup.coverage, inputManga: backup.manga.count, inputChapters: inputChapters, inputHistory: inputHistory,
            mappedManga: manga.count, mappedChapters: manga.reduce(0) { $0 + $1.chapters.count } - reusedStoredChapters,
            mappedHistory: manga.reduce(0) { $0 + $1.history.count }, reusedStoredChapters: reusedStoredChapters,
            excludedManga: excludedManga,
            excludedChapters: excludedChapters, excludedHistory: excludedHistory, duplicateManga: duplicateManga,
            duplicateChapters: duplicateChapters, duplicateHistory: duplicateHistory, normalizedCategories: normalized,
            roundedTimestamps: rounded, unsupportedSourceIDs: unsupported.sorted(),
            issues: MihonLibraryImportReport.Exclusion.allCases.compactMap { reason in
                issues[reason].map { .init(reason: reason, count: $0) }
            }))
    }
}
