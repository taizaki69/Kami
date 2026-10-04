import Foundation
import XCTest
@testable import KamiCore
import MihonCompatKit

#if canImport(SQLite3)
/// Fresh fixture actions only. Retained-operation tests pass an explicit
/// captured context to the production APIs; these overloads are not in Core.
extension LibraryStore {
    func mutationContextForTest() throws -> LibraryMutationContext {
        let snapshot = try librarySnapshot()
        return try XCTUnwrap(snapshot.mutationContext)
    }

    func setLibrary(_ value: Bool, mangaId: Int64) throws {
        try setLibrary(value, mangaId: mangaId, context: mutationContextForTest())
    }

    @discardableResult
    func createCategory(name: String) throws -> Category {
        try createCategory(name: name, context: mutationContextForTest())
    }

    func renameCategory(id: Int64, name: String) throws {
        try renameCategory(id: id, name: name, context: mutationContextForTest())
    }

    func reorderCategories(ids: [Int64]) throws {
        try reorderCategories(ids: ids, context: mutationContextForTest())
    }

    func deleteCategories(ids: Set<Int64>) throws {
        try deleteCategories(ids: ids, context: mutationContextForTest())
    }

    func setCategories(_ ids: Set<Int64>, mangaId: Int64) throws {
        try setCategories(ids, mangaId: mangaId, context: mutationContextForTest())
    }

    func setCategories(_ ids: Set<Int64>, mangaIDs: Set<Int64>) throws {
        try setCategories(ids, mangaIDs: mangaIDs, context: mutationContextForTest())
    }

    func updateCategories(adding: Set<Int64>, removing: Set<Int64>, mangaIDs: Set<Int64>) throws {
        try updateCategories(adding: adding, removing: removing, mangaIDs: mangaIDs, context: mutationContextForTest())
    }

    func persistSourceUpdate(
        manga: Manga, chapters: [SChapterCompat], expectedConfiguration: ExtensionExecutionConfiguration?
    ) throws -> SourceMangaUpdate {
        try persistSourceUpdate(manga: manga, chapters: chapters, expectedConfiguration: expectedConfiguration,
                                context: mutationContextForTest())
    }

    func recordLibraryUpdateSuccess(
        scanID: UUID, manga: Manga, chapters: [SChapterCompat], expectedConfiguration: ExtensionExecutionConfiguration?
    ) throws -> LibraryUpdateCommitResult {
        try recordLibraryUpdateSuccess(scanID: scanID, manga: manga, chapters: chapters,
                                       expectedConfiguration: expectedConfiguration, context: mutationContextForTest())
    }

    func validateSourceExecution(
        sourceID: Int64, expectedConfiguration: ExtensionExecutionConfiguration?
    ) throws {
        try validateSourceExecution(sourceID: sourceID, expectedConfiguration: expectedConfiguration,
                                    context: mutationContextForTest())
    }

    func verifyLibraryUpdateSourceConfiguration(
        sourceID: Int64, expectedConfiguration: ExtensionExecutionConfiguration?
    ) throws {
        try verifyLibraryUpdateSourceConfiguration(sourceID: sourceID, expectedConfiguration: expectedConfiguration,
                                                   context: mutationContextForTest())
    }
}

extension LibraryService {
    func refresh(
        mangaId: Int64, source: any KamiSource, expectedConfiguration: ExtensionExecutionConfiguration? = nil
    ) async throws -> Manga? {
        let context = try await store.mutationContextForTest()
        return try await refresh(mangaId: mangaId, source: source, context: context,
                                 expectedConfiguration: expectedConfiguration)
    }
}
#endif
