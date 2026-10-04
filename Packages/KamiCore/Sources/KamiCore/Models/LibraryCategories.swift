import Foundation

public enum LibraryCategoryFilter: Hashable, Sendable {
    case all
    case uncategorized
    case category(Int64)
}

/// One consistent library read, including the ordered categories and membership.
public struct LibrarySnapshot: Sendable {
    public let manga: [Manga]
    public let categories: [Category]
    public let categoryIDsByManga: [Int64: Set<Int64>]
    public let mutationContext: LibraryMutationContext?

    public init(
        manga: [Manga] = [],
        categories: [Category] = [],
        categoryIDsByManga: [Int64: Set<Int64>] = [:]
    ) {
        self.manga = manga
        self.categories = categories
        self.mutationContext = nil
        let mangaIDs = Set(manga.compactMap(\.id))
        let categoryIDs = Set(categories.compactMap(\.id))
        self.categoryIDsByManga = categoryIDsByManga.reduce(into: [:]) { result, entry in
            guard mangaIDs.contains(entry.key) else { return }
            let valid = entry.value.intersection(categoryIDs)
            if !valid.isEmpty { result[entry.key] = valid }
        }
    }

    init(manga: [Manga], categories: [Category],
         categoryIDsByManga: [Int64: Set<Int64>], mutationContext: LibraryMutationContext) {
        let values = LibrarySnapshot(manga: manga, categories: categories, categoryIDsByManga: categoryIDsByManga)
        self.manga = values.manga
        self.categories = values.categories
        self.categoryIDsByManga = values.categoryIDsByManga
        self.mutationContext = mutationContext
    }

    public func filteredManga(
        category: LibraryCategoryFilter = .all,
        search: String = ""
    ) -> [Manga] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return manga.filter { manga in
            let membership = manga.id.flatMap { categoryIDsByManga[$0] } ?? []
            let inCategory: Bool
            switch category {
            case .all: inCategory = true
            case .uncategorized: inCategory = membership.isEmpty
            case let .category(id): inCategory = membership.contains(id)
            }
            return inCategory && (query.isEmpty
                || manga.title.localizedCaseInsensitiveContains(query)
                || manga.altTitles.contains { $0.localizedCaseInsensitiveContains(query) })
        }
    }

    public func mangaCount(in category: LibraryCategoryFilter) -> Int {
        filteredManga(category: category).count
    }

    /// A deleted category must not leave the library stranded on an empty filter.
    public func availableFilter(_ filter: LibraryCategoryFilter) -> LibraryCategoryFilter {
        if case let .category(id) = filter,
           !categories.contains(where: { $0.id == id }) {
            return .all
        }
        return filter
    }
}

public enum LibraryCategoryError: Error, Equatable, LocalizedError, Sendable {
    case emptyName
    case nameTooLong
    case invalidName
    case duplicateName
    case categoryNotFound(Int64)
    case mangaNotInLibrary(Int64)
    case invalidCategoryOrder
    case conflictingCategoryChanges

    public var errorDescription: String? {
        switch self {
        case .emptyName: return "Enter a category name."
        case .nameTooLong: return "Category names can contain up to 100 characters."
        case .invalidName: return "Use a single line for the category name."
        case .duplicateName: return "A category with this name already exists."
        case .categoryNotFound: return "This category no longer exists. Please refresh and try again."
        case .mangaNotInLibrary: return "One of these manga is no longer in your library."
        case .invalidCategoryOrder: return "The categories changed. Please refresh before reordering them."
        case .conflictingCategoryChanges: return "A category cannot be added and removed at the same time."
        }
    }
}

extension Category {
    public static func validatedName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LibraryCategoryError.emptyName }
        guard trimmed.count <= 100 else { throw LibraryCategoryError.nameTooLong }
        guard trimmed.rangeOfCharacter(from: CharacterSet.controlCharacters.union(.newlines)) == nil else {
            throw LibraryCategoryError.invalidName
        }
        return trimmed
    }

    public static func namesMatch(_ first: String, _ second: String) -> Bool {
        first.compare(second, options: .caseInsensitive,
                      locale: Locale(identifier: "en_US_POSIX")) == .orderedSame
    }

    public static func validateOrder(_ ids: [Int64], existingIDs: Set<Int64>) throws {
        guard ids.count == existingIDs.count, Set(ids) == existingIDs else {
            throw LibraryCategoryError.invalidCategoryOrder
        }
    }
}

/// Bulk editing records only explicit changes. Untouched mixed memberships survive.
public struct CategoryAssignmentDraft: Sendable {
    public enum Membership: Equatable, Sendable {
        case none, some, all
    }

    public let mangaIDs: Set<Int64>
    public private(set) var additions = Set<Int64>()
    public private(set) var removals = Set<Int64>()
    private var initialMembership: [Int64: Set<Int64>]

    public init(mangaIDs: Set<Int64>, categoryIDsByManga: [Int64: Set<Int64>]) {
        self.mangaIDs = mangaIDs
        self.initialMembership = categoryIDsByManga.filter { mangaIDs.contains($0.key) }
    }

    public var hasChanges: Bool { !additions.isEmpty || !removals.isEmpty }

    public func membership(of categoryID: Int64) -> Membership {
        if additions.contains(categoryID) { return mangaIDs.isEmpty ? .none : .all }
        if removals.contains(categoryID) { return .none }
        return initialState(of: categoryID)
    }

    public mutating func toggle(_ categoryID: Int64) {
        setIncluded(membership(of: categoryID) != .all, categoryID: categoryID)
    }

    public mutating func clear(categoryIDs: Set<Int64>) {
        for id in categoryIDs { setIncluded(false, categoryID: id) }
    }

    public mutating func restrict(to categoryIDs: Set<Int64>) {
        additions.formIntersection(categoryIDs)
        removals.formIntersection(categoryIDs)
        initialMembership = initialMembership.mapValues { $0.intersection(categoryIDs) }
    }

    private func initialState(of categoryID: Int64) -> Membership {
        let count = mangaIDs.filter { initialMembership[$0]?.contains(categoryID) == true }.count
        if count == 0 { return .none }
        return count == mangaIDs.count ? .all : .some
    }

    private mutating func setIncluded(_ included: Bool, categoryID: Int64) {
        additions.remove(categoryID)
        removals.remove(categoryID)
        if included {
            if initialState(of: categoryID) != .all { additions.insert(categoryID) }
        } else if initialState(of: categoryID) != .none {
            removals.insert(categoryID)
        }
    }
}
