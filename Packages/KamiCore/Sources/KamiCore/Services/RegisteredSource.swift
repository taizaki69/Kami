import MihonCompatKit

/// The registry publishes this lifetime-bound facade instead of its raw source.
/// Old references and already-created image capabilities become unusable when
/// the owning registration is disabled or replaced.
struct RegisteredSource: InterpretedCompatibilityReportingSource {
    let source: any KamiSource
    let scope: SourceRequestScope
    let fallbackReport: InterpretedCompatibilityRuntimeReport

    var id: Int64 { source.id }
    var name: String { source.name }
    var language: String { source.language }
    var supportsLatest: Bool { source.supportsLatest }
    var supportsFilterFetching: Bool { source.supportsFilterFetching }
    var baseURL: String { source.baseURL }
    var transportPolicy: CompatHTTPTransportPolicy { source.transportPolicy }

    func getPopularManga(page: Int) async throws -> MangasPageCompat {
        try await scope.perform { try await source.getPopularManga(page: page) }
    }

    func getLatestUpdates(page: Int) async throws -> MangasPageCompat {
        try await scope.perform { try await source.getLatestUpdates(page: page) }
    }

    func getSearchManga(page: Int, query: String, filters: [SourceFilter]) async throws -> MangasPageCompat {
        try await scope.perform { try await source.getSearchManga(page: page, query: query, filters: filters) }
    }

    func getMangaDetails(manga: SMangaCompat) async throws -> SMangaCompat {
        try await scope.perform { try await source.getMangaDetails(manga: manga) }
    }

    func getChapterList(manga: SMangaCompat) async throws -> [SChapterCompat] {
        try await scope.perform { try await source.getChapterList(manga: manga) }
    }

    func getMangaUpdate(manga: SMangaCompat) async throws -> SMangaUpdateCompat {
        try await scope.perform { try await source.getMangaUpdate(manga: manga) }
    }

    func getPageList(chapter: SChapterCompat) async throws -> [PageCompat] {
        try await scope.perform { try await source.getPageList(chapter: chapter) }
    }

    func getImageRequest(page: PageCompat) async -> ImageRequest? {
        do {
            let request = try await scope.perform { await source.getImageRequest(page: page) }
            return try request?.scoped(to: scope)
        } catch { return nil }
    }

    func getFilterList() -> [SourceFilter] {
        scope.isActive ? source.getFilterList() : []
    }

    func refreshFilterList() async throws -> [SourceFilter] {
        try await scope.perform { try await source.refreshFilterList() }
    }

    func compatibilityReport() -> InterpretedCompatibilityRuntimeReport {
        (source as? any InterpretedCompatibilityReportingSource)?.compatibilityReport() ?? fallbackReport
    }
}
