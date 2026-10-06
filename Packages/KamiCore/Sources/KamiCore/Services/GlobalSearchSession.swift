import Foundation
import MihonCompatKit

/// A small search projection. Full details are fetched through the registered
/// source when opened; large descriptions, memo and chapter data are not kept.
public struct GlobalSearchMatch: Identifiable, Sendable {
    public let url: String
    public let title: String
    public let thumbnailURL: String?
    public let author: String?
    // Swift String equality normalizes Unicode. Persisted source paths do not.
    public var id: Data { Data(url.utf8) }
    public var manga: SMangaCompat {
        .init(url: url, title: title, thumbnailURL: thumbnailURL, author: author)
    }
}

public enum GlobalSearchPhase: Equatable, Sendable {
    case queued, searching, loaded, failed, unavailable, cancelled
}

public struct GlobalSearchGroup: Identifiable, Sendable {
    public let sourceID: Int64
    public let registrationID: UUID
    public let revision: UInt64
    public let name: String
    public let language: String
    public fileprivate(set) var phase: GlobalSearchPhase = .queued
    public fileprivate(set) var matches: [GlobalSearchMatch] = []
    public fileprivate(set) var hasMore = false
    public var id: UUID { registrationID }
}

public enum GlobalSearchInputError: Error, Equatable, Sendable, LocalizedError {
    case queryTooLong, tooManySources, duplicateSource, selectionChanged

    public var errorDescription: String? {
        switch self {
        case .queryTooLong: "Use a shorter search and try again."
        case .tooManySources: "Select up to 64 sources for global search, or search a source individually."
        case .duplicateSource: "The source list changed. Reopen Browse and try again."
        case .selectionChanged: "Your source selection changed. Submit your search again."
        }
    }
}

public struct GlobalSearchState: Sendable {
    public fileprivate(set) var query = ""
    public fileprivate(set) var groups: [GlobalSearchGroup] = []
    public fileprivate(set) var isSearching = false
    public fileprivate(set) var inputError: GlobalSearchInputError?
    public fileprivate(set) var selectionID: UUID?
    public var completedSources: Int {
        groups.filter { $0.phase != .queued && $0.phase != .searching }.count
    }
}

/// One search screen's ordered, bounded first-page fan-out. Each invocation
/// awaits its owned worker, including cancellation drainage. Replacements wait
/// for the old worker, so rapid submissions cannot multiply provider calls.
/// This object neither registers sources nor writes to the library.
@MainActor
public final class GlobalSearchSession {
    public nonisolated static let maximumSources = 64
    public nonisolated static let maximumMatchesPerSource = 20
    public nonisolated static let maximumConcurrentSources = 3

    public private(set) var state = GlobalSearchState() {
        didSet { onChange?(state) }
    }
    public var onChange: ((GlobalSearchState) -> Void)? {
        didSet { onChange?(state) }
    }
    private var generation = UUID()
    private var worker: Task<Void, Never>?

    public init() {}

    public func search(query: String, registrations: [SourceRegistrationSnapshot],
                       selection: SourceDiscoverySelectionSnapshot? = nil) async {
        guard !Task.isCancelled else { return }
        let previous = worker
        previous?.cancel()
        let token = UUID()
        generation = token
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = registrations.filter {
            selection?.preferences.includes(sourceID: $0.sourceID, language: $0.source.language) ?? true
        }
        let error: GlobalSearchInputError?
        if selection?.isCurrent == false { error = .selectionChanged }
        else if query.utf8.count > 1_024 { error = .queryTooLong }
        else if candidates.count > Self.maximumSources { error = .tooManySources }
        else if Set(candidates.map(\.sourceID)).count != candidates.count { error = .duplicateSource }
        else { error = nil }
        let selected = error == nil && !text.isEmpty ? candidates : []
        var initial = GlobalSearchState()
        initial.query = error == .queryTooLong ? "" : text
        initial.inputError = error
        initial.selectionID = selection?.id
        initial.groups = selected.map {
            GlobalSearchGroup(sourceID: $0.sourceID, registrationID: $0.registrationID,
                revision: $0.revision, name: $0.source.name, language: $0.source.language)
        }
        initial.isSearching = !selected.isEmpty
        state = initial
        let task = Task { @MainActor in
            // A provider may acknowledge cancellation late. Keep its owner
            // alive and wait instead of silently starting another fan-out.
            await previous?.value
            guard !Task.isCancelled, self.generation == token,
                  self.selectionIsCurrent(selection, token: token) else { return }
            await self.execute(query: text, registrations: selected, token: token, selection: selection)
        }
        worker = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: { task.cancel() }
        if generation == token {
            worker = nil
            finishCancelledGroups()
        }
    }

    /// Immediately invalidates publication. The search caller still owns the
    /// worker until it drains; cancel is not proof that providers have stopped.
    public func cancel(clearResults: Bool = false) {
        generation = UUID()
        worker?.cancel()
        if clearResults { state = GlobalSearchState() }
        else { finishCancelledGroups() }
    }

    private func finishCancelledGroups() {
        var next = state
        next.isSearching = false
        for index in next.groups.indices where next.groups[index].phase == .queued
                || next.groups[index].phase == .searching {
            next.groups[index].phase = .cancelled
        }
        state = next
    }

    private struct Outcome: Sendable {
        let index: Int
        let phase: GlobalSearchPhase
        var matches: [GlobalSearchMatch] = []
        var hasMore = false
    }

    private func selectionIsCurrent(_ selection: SourceDiscoverySelectionSnapshot?, token: UUID) -> Bool {
        guard selection?.isCurrent == false else { return true }
        if generation == token {
            var cleared = GlobalSearchState()
            cleared.query = state.query
            cleared.selectionID = selection?.id
            cleared.inputError = .selectionChanged
            state = cleared
        }
        return false
    }

    private func execute(query: String, registrations: [SourceRegistrationSnapshot], token: UUID,
                         selection: SourceDiscoverySelectionSnapshot?) async {
        await withTaskGroup(of: Outcome.self) { group in
            var nextIndex = 0
            @MainActor @discardableResult func enqueue() -> Bool {
                guard !Task.isCancelled, generation == token, selectionIsCurrent(selection, token: token),
                      state.groups.indices.contains(nextIndex) else { return false }
                let index = nextIndex
                nextIndex += 1
                state.groups[index].phase = .searching
                // Observers may synchronously cancel/clear the presentation.
                guard !Task.isCancelled, generation == token,
                      selectionIsCurrent(selection, token: token) else { return false }
                let registration = registrations[index]
                group.addTask { await Self.fetch(query: query, registration: registration, index: index,
                                                selection: selection) }
                return true
            }
            while nextIndex < min(Self.maximumConcurrentSources, registrations.count) {
                if !enqueue() { break }
            }
            while let outcome = await group.next() {
                guard !Task.isCancelled, generation == token, selectionIsCurrent(selection, token: token) else {
                    group.cancelAll()
                    continue
                }
                let registration = registrations[outcome.index]
                if (try? registration.checkAvailability()) == nil {
                    state.groups[outcome.index].phase = .unavailable
                } else {
                    var section = state.groups[outcome.index]
                    section.phase = outcome.phase
                    section.matches = outcome.matches
                    section.hasMore = outcome.hasMore
                    state.groups[outcome.index] = section
                }
                if nextIndex < registrations.count { enqueue() }
            }
        }
        if generation == token { finishCancelledGroups() }
    }

    private nonisolated static func fetch(
        query: String, registration: SourceRegistrationSnapshot, index: Int,
        selection: SourceDiscoverySelectionSnapshot?
    ) async -> Outcome {
        do {
            try Task.checkCancellation()
            try registration.checkAvailability()
            guard selection?.isCurrent != false else { throw CancellationError() }
            // Empty filters intentionally preserve each source's own defaults.
            // Global search never refreshes dynamic filters or invokes feeds.
            let request: @Sendable () async throws -> MangasPageCompat = {
                try Task.checkCancellation()
                try registration.checkAvailability()
                return try await registration.source.getSearchManga(page: 1, query: query, filters: [])
            }
            let page: MangasPageCompat
            if let selection { page = try await selection.perform(request) }
            else { page = try await request() }
            try Task.checkCancellation()
            try registration.checkAvailability()
            guard selection?.isCurrent != false else { throw CancellationError() }
            let projection = try project(page)
            return Outcome(index: index, phase: .loaded, matches: projection.matches, hasMore: projection.hasMore)
        } catch {
            let unavailable = (try? registration.checkAvailability()) == nil
            return Outcome(index: index, phase: unavailable ? .unavailable
                : Task.isCancelled || selection?.isCurrent == false ? .cancelled : .failed)
        }
    }

    private enum ResultError: Error { case oversized }

    private nonisolated static func project(_ page: MangasPageCompat) throws -> (
        matches: [GlobalSearchMatch], hasMore: Bool
    ) {
        guard page.mangas.count <= 500 else { throw ResultError.oversized }
        var seen = Set<Data>()
        var matches: [GlobalSearchMatch] = []
        var bytes = 0
        for manga in page.mangas {
            guard !manga.url.isEmpty, manga.url.utf8.count <= 8_192,
                  manga.title.utf8.count <= 4_096,
                  (manga.thumbnailURL?.utf8.count ?? 0) <= 8_192,
                  (manga.author?.utf8.count ?? 0) <= 4_096 else { throw ResultError.oversized }
            guard seen.insert(Data(manga.url.utf8)).inserted else { continue }
            guard matches.count < maximumMatchesPerSource else { continue }
            bytes += manga.url.utf8.count + manga.title.utf8.count
                + (manga.thumbnailURL?.utf8.count ?? 0) + (manga.author?.utf8.count ?? 0)
            guard bytes <= 256 * 1_024 else { throw ResultError.oversized }
            matches.append(.init(url: manga.url, title: manga.title,
                                 thumbnailURL: manga.thumbnailURL, author: manga.author))
        }
        return (matches, page.hasNextPage || seen.count > matches.count)
    }
}
