import XCTest
@testable import KamiCore

final class LibraryCategoryModelTests: XCTestCase {
    private var snapshot: LibrarySnapshot {
        LibrarySnapshot(
            manga: [
                Manga(id: 1, sourceId: 1, url: "/a", title: "Alpha", inLibrary: true),
                Manga(id: 2, sourceId: 1, url: "/b", title: "Beta", altTitles: ["Second title"], inLibrary: true),
                Manga(id: 3, sourceId: 1, url: "/c", title: "Gamma", inLibrary: true),
            ],
            categories: [Category(id: 10, name: "Reading"), Category(id: 20, name: "Favorites")],
            categoryIDsByManga: [1: [10, 20], 2: [20], 3: [999], 999: [10]]
        )
    }

    func testCategoryAndSearchIntersectWithoutDuplicatingSharedManga() {
        let library = snapshot
        XCTAssertEqual(library.filteredManga().compactMap(\.id), [1, 2, 3])
        XCTAssertEqual(library.filteredManga(category: .category(20)).compactMap(\.id), [1, 2])
        XCTAssertEqual(library.filteredManga(category: .category(20), search: " ALPHA ").compactMap(\.id), [1])
        XCTAssertEqual(library.filteredManga(category: .category(10), search: "Beta").count, 0)
        XCTAssertEqual(library.filteredManga(search: "second TITLE").compactMap(\.id), [2])
        XCTAssertEqual(library.filteredManga(category: .uncategorized).compactMap(\.id), [3])
        XCTAssertEqual(library.mangaCount(in: .category(20)), 2)
        XCTAssertNil(library.categoryIDsByManga[999])
    }

    func testDeletedFilterRecoversWhileAnExistingEmptyCategoryStaysSelected() {
        let library = snapshot
        XCTAssertEqual(library.availableFilter(.category(999)), .all)
        XCTAssertEqual(library.availableFilter(.category(10)), .category(10))
        XCTAssertEqual(library.availableFilter(.uncategorized), .uncategorized)
        let empty = LibrarySnapshot(categories: [Category(id: 10, name: "Reading")])
        XCTAssertEqual(empty.availableFilter(.category(10)), .category(10))
    }

    func testNamesAreTrimmedBoundedAndComparedWithoutCase() throws {
        XCTAssertEqual(try Category.validatedName(" \nCafé\t "), "Café")
        XCTAssertTrue(Category.namesMatch("Café", "CAFÉ"))
        XCTAssertFalse(Category.namesMatch("Reading", "Completed"))
        XCTAssertEqual(try Category.validatedName(String(repeating: "漫", count: 100)).count, 100)
        for (input, expected) in [
            (" \n\t", LibraryCategoryError.emptyName),
            (String(repeating: "a", count: 101), .nameTooLong),
            ("Line\nBreak", .invalidName),
            ("Line\u{2028}Break", .invalidName),
            ("Embedded\0NUL", .invalidName),
        ] {
            XCTAssertThrowsError(try Category.validatedName(input)) { error in
                XCTAssertEqual(error as? LibraryCategoryError, expected)
            }
        }
    }

    func testBulkDraftPreservesMixedMembershipUntilExplicitlyEdited() {
        var draft = CategoryAssignmentDraft(mangaIDs: [1, 2], categoryIDsByManga: [1: [10, 20], 2: [20]])
        XCTAssertEqual(draft.membership(of: 10), .some)
        XCTAssertEqual(draft.membership(of: 20), .all)
        XCTAssertFalse(draft.hasChanges)

        draft.toggle(30)
        XCTAssertEqual(draft.additions, [30])
        XCTAssertEqual(draft.membership(of: 10), .some)
        XCTAssertEqual(draft.removals, [])
        draft.toggle(30)
        XCTAssertFalse(draft.hasChanges)

        draft.toggle(20)
        XCTAssertEqual(draft.removals, [20])
        draft.toggle(20)
        XCTAssertFalse(draft.hasChanges)
        draft.toggle(10)
        XCTAssertEqual(draft.membership(of: 10), .all)
        XCTAssertEqual(draft.additions, [10])
        draft.restrict(to: [20, 30])
        XCTAssertFalse(draft.hasChanges)
        XCTAssertEqual(draft.membership(of: 10), .none)
        draft.clear(categoryIDs: [20, 30])
        XCTAssertEqual(draft.removals, [20])
        XCTAssertEqual(draft.membership(of: 20), .none)
    }

    func testReorderingRequiresEveryCategoryExactlyOnce() throws {
        try Category.validateOrder([20, 10], existingIDs: [10, 20])
        try Category.validateOrder([], existingIDs: [])
        let invalidOrders: [[Int64]] = [[10], [10, 10], [10, 999], [10, 20, 30]]
        for ids in invalidOrders {
            XCTAssertThrowsError(try Category.validateOrder(ids, existingIDs: [10, 20])) { error in
                XCTAssertEqual(error as? LibraryCategoryError, .invalidCategoryOrder)
            }
        }
    }
}

#if canImport(SQLite3)

final class LibraryCategoryStoreTests: XCTestCase {
    private func addManga(_ title: String, to store: LibraryStore, inLibrary: Bool = true) async throws -> Int64 {
        try await store.upsert(Manga(sourceId: 1, url: "/\(title)", title: title, inLibrary: inLibrary))
    }

    private func categoryID(_ name: String, in store: LibraryStore) async throws -> Int64 {
        let category = try await store.createCategory(name: name)
        return try XCTUnwrap(category.id)
    }

    private func expectError(
        _ expected: LibraryCategoryError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)")
        } catch {
            XCTAssertEqual(error as? LibraryCategoryError, expected)
        }
    }

    private func databasePath() throws -> (URL, String) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, directory.appendingPathComponent("categories.sqlite").path)
    }

    func testCategoryNamesOrderingAndAssignmentsSurviveReopening() async throws {
        let (directory, path) = try databasePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(path: path)
        let mangaID = try await addManga("Alpha", to: store)
        let reading = try await store.createCategory(name: " Reading ")
        let favorites = try await store.createCategory(name: "Favorites")
        let readingID = try XCTUnwrap(reading.id)
        let favoritesID = try XCTUnwrap(favorites.id)
        try await store.setCategories([readingID, favoritesID], mangaId: mangaID)
        try await store.renameCategory(id: readingID, name: "In progress")
        try await store.reorderCategories(ids: [favoritesID, readingID])

        let reopened = try LibraryStore(path: path)
        let snapshot = try await reopened.librarySnapshot()
        XCTAssertEqual(snapshot.categories.map(\.name), ["Favorites", "In progress"])
        XCTAssertEqual(snapshot.categories.map(\.order), [0, 1])
        XCTAssertEqual(snapshot.categoryIDsByManga[mangaID], [readingID, favoritesID])
        XCTAssertEqual(snapshot.filteredManga(category: .category(readingID)).compactMap(\.id), [mangaID])
    }

    func testDuplicateNamesAndInvalidReordersLeaveExistingCategoriesIntact() async throws {
        let store = try LibraryStore(inMemory: true)
        let readingID = try await categoryID("Reading", in: store)
        let favoritesID = try await categoryID("Favorites", in: store)
        await expectError(.duplicateName) { _ = try await store.createCategory(name: " reading ") }
        await expectError(.duplicateName) { try await store.renameCategory(id: favoritesID, name: "READING") }
        await expectError(.categoryNotFound(999)) { try await store.renameCategory(id: 999, name: "Missing") }
        for ids in [[readingID], [readingID, readingID], [readingID, 999]] {
            await expectError(.invalidCategoryOrder) { try await store.reorderCategories(ids: ids) }
        }
        try await store.renameCategory(id: readingID, name: "READING")
        let stored = try await store.categories()
        XCTAssertEqual(stored.map(\.name), ["READING", "Favorites"])
        XCTAssertEqual(stored.compactMap(\.id), [readingID, favoritesID])
        XCTAssertEqual(stored.map(\.order), [0, 1])
    }

    func testInvalidCategoryAndMangaIDsCannotPartiallyChangeMembership() async throws {
        let store = try LibraryStore(inMemory: true)
        let first = try await addManga("Alpha", to: store)
        let second = try await addManga("Beta", to: store)
        let outside = try await addManga("Browse only", to: store, inLibrary: false)
        let readingID = try await categoryID("Reading", in: store)
        let otherID = try await categoryID("Other", in: store)
        try await store.setCategories([readingID], mangaIDs: [first, second])
        await expectError(.categoryNotFound(999)) {
            try await store.setCategories([otherID, 999], mangaIDs: [first, second])
        }
        await expectError(.mangaNotInLibrary(999)) {
            try await store.setCategories([otherID], mangaIDs: [first, 999])
        }
        await expectError(.mangaNotInLibrary(outside)) {
            try await store.updateCategories(adding: [otherID], removing: [readingID], mangaIDs: [first, outside])
        }
        await expectError(.conflictingCategoryChanges) {
            try await store.updateCategories(adding: [readingID], removing: [readingID], mangaIDs: [first])
        }
        let snapshot = try await store.librarySnapshot()
        XCTAssertEqual(snapshot.categoryIDsByManga, [first: [readingID], second: [readingID]])
    }

    func testBulkChangesPreserveUntouchedMembershipAndOtherManga() async throws {
        let store = try LibraryStore(inMemory: true)
        let first = try await addManga("Alpha", to: store)
        let second = try await addManga("Beta", to: store)
        let third = try await addManga("Gamma", to: store)
        let readingID = try await categoryID("Reading", in: store)
        let favoritesID = try await categoryID("Favorites", in: store)
        let laterID = try await categoryID("Later", in: store)
        try await store.setCategories([readingID, favoritesID], mangaId: first)
        try await store.setCategories([readingID], mangaId: second)
        try await store.setCategories([laterID], mangaId: third)
        try await store.updateCategories(adding: [laterID], removing: [readingID], mangaIDs: [first, second])
        var snapshot = try await store.librarySnapshot()
        XCTAssertEqual(snapshot.categoryIDsByManga[first], [favoritesID, laterID])
        XCTAssertEqual(snapshot.categoryIDsByManga[second], [laterID])
        XCTAssertEqual(snapshot.categoryIDsByManga[third], [laterID])
        try await store.updateCategories(adding: [], removing: [favoritesID, laterID], mangaIDs: [first, second])
        snapshot = try await store.librarySnapshot()
        XCTAssertEqual(snapshot.filteredManga(category: .uncategorized).compactMap(\.id), [first, second])
        XCTAssertEqual(snapshot.categoryIDsByManga[third], [laterID])
    }

    func testStaleMetadataCannotUndoLibraryMembershipOrCategoryChanges() async throws {
        let store = try LibraryStore(inMemory: true)
        let mangaID = try await addManga("Alpha", to: store, inLibrary: false)
        let beforeAdding = try await store.manga(id: mangaID)
        var staleBeforeAdding = try XCTUnwrap(beforeAdding)
        try await store.setLibrary(true, mangaId: mangaID)
        let readingID = try await categoryID("Reading", in: store)
        try await store.setCategories([readingID], mangaId: mangaID)
        staleBeforeAdding.title = "Refreshed after adding"
        _ = try await store.upsert(staleBeforeAdding)
        var snapshot = try await store.librarySnapshot()
        XCTAssertEqual(snapshot.manga.first?.title, "Refreshed after adding")
        XCTAssertEqual(snapshot.categoryIDsByManga[mangaID], [readingID])

        let beforeRemoving = try await store.manga(id: mangaID)
        var staleBeforeRemoving = try XCTUnwrap(beforeRemoving)
        try await store.setLibrary(false, mangaId: mangaID)
        staleBeforeRemoving.title = "Refreshed after removing"
        _ = try await store.upsert(staleBeforeRemoving)
        snapshot = try await store.librarySnapshot()
        let persisted = try await store.manga(id: mangaID)
        XCTAssertTrue(snapshot.manga.isEmpty)
        XCTAssertEqual(persisted?.inLibrary, false)
        XCTAssertEqual(persisted?.title, "Refreshed after removing")
        _ = try await store.upsert(staleBeforeRemoving, inLibrary: true)
        snapshot = try await store.librarySnapshot()
        XCTAssertEqual(snapshot.manga.compactMap(\.id), [mangaID])
        XCTAssertNil(snapshot.categoryIDsByManga[mangaID])
    }

    func testDeletingCategoriesAndRemovingLibraryMembershipPreserveReaderState() async throws {
        let store = try LibraryStore(inMemory: true)
        let mangaID = try await addManga("Alpha", to: store)
        let readingID = try await categoryID("Reading", in: store)
        let favoritesID = try await categoryID("Favorites", in: store)
        try await store.setCategories([readingID, favoritesID], mangaId: mangaID)
        try await store.replaceChapters(mangaId: mangaID, with: [
            Chapter(mangaId: mangaID, url: "/chapter", name: "Chapter", read: true,
                    bookmark: true, lastPageRead: 7),
        ])
        let initialChapters = try await store.chapters(mangaId: mangaID)
        let chapterID = try XCTUnwrap(initialChapters.first?.id)
        try await store.recordHistory(mangaId: mangaID, chapterId: chapterID)
        await expectError(.categoryNotFound(999)) {
            try await store.deleteCategories(ids: [readingID, 999])
        }
        try await store.deleteCategories(ids: [readingID])
        var snapshot = try await store.librarySnapshot()
        XCTAssertEqual(snapshot.categories.compactMap(\.id), [favoritesID])
        XCTAssertEqual(snapshot.categories.map(\.order), [0])
        XCTAssertEqual(snapshot.availableFilter(.category(readingID)), .all)
        XCTAssertEqual(snapshot.categoryIDsByManga[mangaID], [favoritesID])
        try await store.deleteCategories(ids: [favoritesID])
        snapshot = try await store.librarySnapshot()
        XCTAssertEqual(snapshot.filteredManga(category: .uncategorized).compactMap(\.id), [mangaID])

        let remainingID = try await categoryID("Remaining", in: store)
        try await store.setCategories([remainingID], mangaId: mangaID)
        try await store.setLibrary(false, mangaId: mangaID)
        try await store.setLibrary(true, mangaId: mangaID)
        snapshot = try await store.librarySnapshot()
        XCTAssertNil(snapshot.categoryIDsByManga[mangaID])
        let storedChapters = try await store.chapters(mangaId: mangaID)
        let storedHistory = try await store.history()
        XCTAssertEqual(storedChapters.first?.id, chapterID)
        XCTAssertEqual(storedChapters.first?.read, true)
        XCTAssertEqual(storedChapters.first?.bookmark, true)
        XCTAssertEqual(storedChapters.first?.lastPageRead, 7)
        XCTAssertEqual(storedHistory.count, 1)
        XCTAssertEqual(storedHistory.first?.1.id, chapterID)
    }

    func testWriteFailureRollsBackEarlierMangaAssignments() async throws {
        let (directory, path) = try databasePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(path: path)
        let first = try await addManga("Alpha", to: store)
        let second = try await addManga("Beta", to: store)
        let originalID = try await categoryID("Original", in: store)
        let targetID = try await categoryID("Target", in: store)
        try await store.setCategories([originalID], mangaIDs: [first, second])
        let fixtureDB = try SQLiteDatabase(path: path)
        try fixtureDB.execute("""
            CREATE TRIGGER fail_second_assignment BEFORE INSERT ON manga_category
            WHEN NEW.manga_id = \(second) AND NEW.category_id = \(targetID)
            BEGIN SELECT RAISE(ABORT, 'deterministic fixture failure'); END;
            """)
        do {
            try await store.setCategories([targetID], mangaIDs: [first, second])
            XCTFail("Expected the fixture write failure")
        } catch is SQLiteDatabase.SQLiteError {}
        let snapshot = try await store.librarySnapshot()
        XCTAssertEqual(snapshot.categoryIDsByManga, [first: [originalID], second: [originalID]])
        do {
            try await store.updateCategories(adding: [targetID], removing: [originalID], mangaIDs: [first, second])
            XCTFail("Expected the fixture write failure on the UI's delta path")
        } catch is SQLiteDatabase.SQLiteError {}
        let afterDeltaFailure = try await store.librarySnapshot()
        XCTAssertEqual(afterDeltaFailure.categoryIDsByManga, snapshot.categoryIDsByManga)
    }
}

#endif
