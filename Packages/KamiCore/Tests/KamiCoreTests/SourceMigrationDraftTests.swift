import Foundation
import XCTest
@testable import KamiCore

final class SourceMigrationDraftTests: XCTestCase {
    private typealias Chapter = LibraryBackupDocument.Chapter
    private let previewID = UUID(uuidString: "75000000-0000-0000-0000-000000000001")!

    private func chapters() -> [Chapter] {
        [1, 2, -1, 3, 3].enumerated().map { .init(url: "/\($0.offset)", name: "Chapter \($0.offset)", number: Double($0.element)) }
    }
    private func draft() throws -> SourceMigrationDraft {
        let input = chapters(), matching = try SourceMigrationMatching.prepare(original: input, destination: input)
        return .init(previewID: previewID, originalCount: input.count, destinationCount: input.count, suggestions: matching.matches)
    }

    func testDefaultsAndManualPairingKeepCoverageAndBasisAccurate() throws {
        var value = try draft()
        XCTAssertEqual(value.matchedCount, 2); XCTAssertEqual(value.unmatchedOriginalCount, 3)
        XCTAssertEqual(value.unmatchedDestinationCount, 3); XCTAssertEqual(value.manualCount, 0)
        try value.assign(destination: 4, to: 2)
        try value.assign(destination: 2, to: 3)
        XCTAssertEqual(value.matchedCount, 4); XCTAssertEqual(value.manualCount, 2)
        XCTAssertEqual(value.unmatchedOriginalCount, 1); XCTAssertEqual(value.unmatchedDestinationCount, 1)
        XCTAssertEqual(value.original(for: 4), 2); XCTAssertEqual(value.destination(for: 3), 2)
        XCTAssertEqual(value.matchedOriginalIndices, [0, 1, 2, 3]); XCTAssertEqual(value.matchedDestinationIndices, [0, 1, 2, 4])
        XCTAssertEqual(value.pairs.map(\.originalIndex), [0, 1, 2, 3])
        XCTAssertEqual(value.pairs.map { value.isNumberSuggestion($0) }, [true, true, false, false])
    }

    func testOccupiedDestinationRejectsAtomicallyAndMustBeFreedExplicitly() throws {
        var value = try draft()
        let before = value.selection, revision = value.revision
        XCTAssertThrowsError(try value.assign(destination: 1, to: 0)) {
            XCTAssertEqual($0 as? SourceMigrationError, .destinationAlreadyMatched)
        }
        XCTAssertEqual(value.selection.pairs, before.pairs); XCTAssertEqual(value.revision, revision)
        try value.assign(destination: nil, to: 1)
        try value.assign(destination: 1, to: 0)
        XCTAssertNil(value.original(for: 0)); XCTAssertEqual(value.original(for: 1), 0)
        try value.assign(destination: 0, to: 1)
        XCTAssertEqual(value.manualCount, 2); XCTAssertEqual(value.matchedCount, 2)
    }

    func testInvalidIndicesAndNoOpEditsDoNotChangeRevisionOrPairs() throws {
        var value = try draft()
        let revision = value.revision, pairs = value.pairs
        for original in [-1, 5, Int.max, Int.min] {
            XCTAssertThrowsError(try value.assign(destination: nil, to: original))
        }
        for destination in [-1, 5, Int.max, Int.min] {
            XCTAssertThrowsError(try value.assign(destination: destination, to: 0))
        }
        try value.assign(destination: 0, to: 0)
        try value.assign(destination: nil, to: 4)
        value.resetToSuggestions()
        XCTAssertEqual(value.revision, revision); XCTAssertEqual(value.pairs, pairs)
    }

    func testSelectionIsImmutableAndResetAndABAAssignmentsInvalidateReviewRevision() throws {
        var value = try draft()
        let initial = value.selection, revision = value.revision
        try value.assign(destination: nil, to: 0)
        let removedRevision = value.revision
        try value.assign(destination: 0, to: 0)
        XCTAssertNotEqual(value.revision, revision); XCTAssertNotEqual(value.revision, removedRevision)
        try value.assign(destination: 3, to: 2)
        let manual = value.selection
        let manualRevision = value.revision
        value.resetToSuggestions()
        XCTAssertEqual(value.selection.pairs, initial.pairs)
        XCTAssertEqual(initial.count, 2); XCTAssertEqual(manual.count, 3)
        XCTAssertEqual(manual.previewID, previewID); XCTAssertEqual(value.selection.previewID, previewID)
        XCTAssertNotEqual(value.revision, manualRevision)
    }

    func testSearchUsesDisplayFieldsWithoutFoldingOrMatchingIdentityURLs() throws {
        let input: [Chapter] = [
            .init(url: "/caf\u{e9}", name: "Árbol", scanlator: "North group", number: -1),
            .init(url: "/cafe\u{301}", name: "Árbol edition B", number: 1.125),
            .init(url: "/north-group", name: "Other", scanlator: "South", number: 2)
        ]
        XCTAssertEqual(try SourceMigrationChapterSearch.search(chapters: input, query: "arbol").indices, [0, 1])
        XCTAssertEqual(try SourceMigrationChapterSearch.search(chapters: input, query: "NORTH").indices, [0])
        XCTAssertEqual(try SourceMigrationChapterSearch.search(chapters: input, query: "1.125").indices, [1])
        XCTAssertEqual(try SourceMigrationChapterSearch.search(chapters: input, query: "/caf").indices, [])
        XCTAssertEqual(try SourceMigrationChapterSearch.search(chapters: input, query: " arbol ", excluding: [0]).indices, [1])
    }

    func testPaginationCoversEveryAvailableChapterWithoutDuplicatesOrIndexRebinding() throws {
        let input: [Chapter] = (0..<450).map { .init(url: "/\($0)", name: "Chapter \($0)", number: Double($0)) }
        var indices: [Int] = [], page = 0
        while true {
            let result = try SourceMigrationChapterSearch.search(chapters: input, query: "", excluding: [7, 400], page: page)
            XCTAssertEqual(result.totalMatches, 448); XCTAssertLessThanOrEqual(result.indices.count, 100)
            indices += result.indices
            if !result.hasNextPage { break }
            page += 1
        }
        XCTAssertEqual(indices, input.indices.filter { $0 != 7 && $0 != 400 })
        let empty = try SourceMigrationChapterSearch.search(chapters: [], query: "")
        XCTAssertEqual(empty.totalMatches, 0); XCTAssertFalse(empty.hasNextPage)
        let missing = try SourceMigrationChapterSearch.search(chapters: input, query: "missing")
        XCTAssertTrue(missing.indices.isEmpty); XCTAssertFalse(missing.hasNextPage)
    }

    func testSearchEnforcesChapterQueryPageAndAggregateMetadataBounds() throws {
        let input = Array(repeating: Chapter(url: "/x", name: "A"), count: 20_000)
        let last = try SourceMigrationChapterSearch.search(chapters: input, query: "", page: 199)
        XCTAssertEqual(last.indices, Array(19_900..<20_000)); XCTAssertFalse(last.hasNextPage)
        XCTAssertThrowsError(try SourceMigrationChapterSearch.search(chapters: input + [input[0]], query: ""))
        XCTAssertThrowsError(try SourceMigrationChapterSearch.search(chapters: input, query: String(repeating: "a", count: 257))) {
            XCTAssertEqual($0 as? SourceMigrationChapterSearchError, .queryTooLong)
        }
        for page in [-1, 200, Int.max] {
            XCTAssertThrowsError(try SourceMigrationChapterSearch.search(chapters: input, query: "", page: page))
        }
        XCTAssertThrowsError(try SourceMigrationChapterSearch.search(chapters: input, query: "", excluding: [Int.max]))
        XCTAssertThrowsError(try SourceMigrationChapterSearch.search(chapters: [.init(url: "/x", name: String(repeating: "a", count: 8193))], query: ""))
        let large = Array(repeating: Chapter(url: "/x", name: String(repeating: "a", count: 8192)), count: 4097)
        XCTAssertThrowsError(try SourceMigrationChapterSearch.search(chapters: large, query: ""))
        XCTAssertThrowsError(try SourceMigrationChapterSearch.search(chapters: [.init(url: "/x", name: "A", number: .infinity)], query: ""))
    }

    @MainActor
    func testCancelledSearchDoesNotReturnResults() async throws {
        let task = Task { @MainActor in
            try SourceMigrationChapterSearch.search(chapters: [.init(url: "/x", name: "A")], query: "")
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
