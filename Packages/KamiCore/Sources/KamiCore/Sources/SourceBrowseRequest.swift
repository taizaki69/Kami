import Foundation
import MihonCompatKit

/// One immutable Browse request. Keeping feed/search routing outside SwiftUI
/// makes blank-query filtered searches explicit and independently testable.
public struct SourceBrowseRequest: Sendable {
    public enum Feed: Sendable {
        case popular
        case latest
    }

    public let page: Int
    public let feed: Feed
    public let query: String
    public let filters: [SourceFilter]
    public let forceSearch: Bool

    public init(
        page: Int,
        feed: Feed,
        query: String,
        filters: [SourceFilter],
        forceSearch: Bool = false
    ) {
        self.page = page
        self.feed = feed
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.filters = filters
        self.forceSearch = forceSearch
    }

    public func execute(on source: any KamiSource) async throws -> MangasPageCompat {
        if forceSearch || !query.isEmpty {
            return try await source.getSearchManga(
                page: page,
                query: query,
                filters: filters
            )
        }

        switch feed {
        case .popular:
            return try await source.getPopularManga(page: page)
        case .latest:
            return try await source.getLatestUpdates(page: page)
        }
    }
}
