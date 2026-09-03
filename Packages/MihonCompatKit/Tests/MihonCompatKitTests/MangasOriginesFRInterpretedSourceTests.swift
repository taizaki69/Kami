import Foundation
import XCTest
@testable import MihonCompatKit

final class MangasOriginesFRInterpretedSourceTests: XCTestCase {
    private enum RoutingError: Error {
        case missingResponse(method: String, url: String)
    }

    private struct RouteKey: Hashable, Sendable {
        let method: String
        let url: String
    }

    private actor RoutingTransport: CompatHTTPTransport {
        nonisolated let sourceID = "mangas-origines-fr-routing-test"
        private let responses: [RouteKey: CompatHTTPResponse]
        private var requests: [CompatHTTPRequest] = []

        init(responses: [RouteKey: CompatHTTPResponse]) {
            self.responses = responses
        }

        func execute(_ request: CompatHTTPRequest) async throws -> CompatHTTPResponse {
            requests.append(request)
            let key = RouteKey(method: request.method, url: request.url)
            guard let response = responses[key] else {
                throw RoutingError.missingResponse(method: request.method, url: request.url)
            }
            return response
        }

        func snapshot() -> [CompatHTTPRequest] { requests }
    }

    private actor EmptyCatalogueTransport: CompatHTTPTransport {
        nonisolated let sourceID = "mangas-origines-fr-profile-test"
        private var requests: [CompatHTTPRequest] = []

        func execute(_ request: CompatHTTPRequest) async throws -> CompatHTTPResponse {
            requests.append(request)
            return CompatHTTPResponse(
                finalURL: request.url,
                statusCode: 200,
                headers: [CompatHTTPHeader(
                    name: "Content-Type",
                    value: "application/json; charset=utf-8"
                )],
                body: Array(#"{"data":{"html":"","more":false}}"#.utf8)
            )
        }

        func snapshot() -> [CompatHTTPRequest] { requests }
    }

    private func corpusAPK() throws -> [UInt8] {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tests/corpus/mangasoriginesfr.apk")
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw XCTSkip(
                "corpus APK mangasoriginesfr.apk not present — run scripts/fetch_corpus.sh"
            )
        }
        return [UInt8](try Data(contentsOf: path))
    }

    private func response(
        url: String,
        contentType: String,
        body: String
    ) -> CompatHTTPResponse {
        CompatHTTPResponse(
            finalURL: url,
            statusCode: 200,
            headers: [CompatHTTPHeader(name: "Content-Type", value: contentType)],
            body: Array(body.utf8)
        )
    }

    private func catalogueJSON(html: String, more: Bool) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [
            "data": ["html": html, "more": more],
        ])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    func testCurrentMangasOriginesFRProfileExposesStaticFilters() async throws {
        let transport = EmptyCatalogueTransport()
        let source = try PinnedInterpretedSource.mangasOriginesFR1658(
            apkBytes: corpusAPK(),
            transport: transport
        )

        XCTAssertEqual(source.id, 4_803_238_581_797_687_746)
        XCTAssertEqual(source.name, "Mangas-Origines.fr")
        XCTAssertEqual(source.language, "fr")
        XCTAssertEqual(source.baseURL, "https://mangas-origines.fr")
        XCTAssertTrue(source.supportsLatest)

        let filters = source.getFilterList()
        XCTAssertEqual(filters.count, 7)
        XCTAssertEqual(filters.map(\.name), [
            "Origine",
            "Genres",
            "Statut",
            "Note minimum",
            "Trier par",
            "Chapitres (min)",
            "Chapitres (max)",
        ])
        guard case let .group(originName, origins) = filters[0],
              case let .group(genreName, genres) = filters[1],
              case let .select(statusName, statuses, statusState) = filters[2],
              case let .select(ratingName, ratings, ratingState) = filters[3],
              case let .select(sortName, sorts, sortState) = filters[4],
              case let .text(minimumName, minimumState) = filters[5],
              case let .text(maximumName, maximumState) = filters[6] else {
            return XCTFail("expected exact Mangas-Origines.fr filter schema")
        }
        XCTAssertEqual(originName, "Origine")
        XCTAssertEqual(origins.map(\.name), ["Manhwa", "Manhua", "Manga"])
        XCTAssertEqual(genreName, "Genres")
        XCTAssertEqual(genres.count, 61)
        XCTAssertEqual(genres.prefix(6).map(\.name), [
            "Action", "Adventure", "Amitié", "Amour", "Art Martiaux", "Aventure",
        ])
        XCTAssertEqual(genres.suffix(6).map(\.name), [
            "Surnaturel", "Tragédie", "Vengeance", "Webcomic", "Yuri", "École",
        ])
        XCTAssertEqual(statusName, "Statut")
        XCTAssertEqual(statuses, ["Tous", "En cours", "Terminé"])
        XCTAssertEqual(statusState, 0)
        XCTAssertEqual(ratingName, "Note minimum")
        XCTAssertEqual(ratings, [
            "Toutes", "1 étoile et plus", "2 étoiles et plus",
            "3 étoiles et plus", "4 étoiles et plus", "5 étoiles",
        ])
        XCTAssertEqual(ratingState, 0)
        XCTAssertEqual(sortName, "Trier par")
        XCTAssertEqual(sorts, ["Récents", "Populaire", "Mieux notés", "A → Z"])
        XCTAssertEqual(sortState, 0)
        XCTAssertEqual(minimumName, "Chapitres (min)")
        XCTAssertEqual(minimumState, "")
        XCTAssertEqual(maximumName, "Chapitres (max)")
        XCTAssertEqual(maximumState, "")
        let requests = await transport.snapshot()
        XCTAssertTrue(requests.isEmpty)
        XCTAssertTrue(source.compatibilityReport().findings.isEmpty)
    }

    func testCurrentMangasOriginesFRProfileExecutesCatalogueOperationsAndFilters() async throws {
        let listingURL = "https://mangas-origines.fr/wp-admin/admin-ajax.php"
        let cardHTML = #"""
        <a class="ori-card" href="/oeuvre/hero/?tracking=1#card">
          <span class="ori-card-title">Hero &amp; Alpha</span>
          <img src="/covers/hero.jpg">
        </a>
        """#
        let transport = RoutingTransport(responses: [
            RouteKey(method: "POST", url: listingURL): response(
                url: listingURL,
                contentType: "application/json; charset=utf-8",
                body: try catalogueJSON(html: cardHTML, more: true)
            ),
        ])
        let source = try PinnedInterpretedSource.mangasOriginesFR1658(
            apkBytes: corpusAPK(),
            transport: transport
        )

        let popular = try await source.getPopularManga(page: 2)
        XCTAssertEqual(popular.mangas.count, 1)
        XCTAssertEqual(popular.mangas[0].title, "Hero & Alpha")
        XCTAssertEqual(popular.mangas[0].url, "hero")
        XCTAssertEqual(
            popular.mangas[0].thumbnailURL,
            "https://mangas-origines.fr/covers/hero.jpg"
        )
        XCTAssertTrue(popular.hasNextPage)

        let latest = try await source.getLatestUpdates(page: 4)
        XCTAssertEqual(latest.mangas.map(\.title), ["Hero & Alpha"])
        XCTAssertTrue(latest.hasNextPage)

        let defaults = source.getFilterList()
        guard case let .group(originName, origins) = defaults[0],
              case let .group(genreName, genres) = defaults[1],
              case let .select(statusName, statuses, _) = defaults[2],
              case let .select(ratingName, ratings, _) = defaults[3],
              case let .select(sortName, sorts, _) = defaults[4],
              case let .text(minimumName, _) = defaults[5],
              case let .text(maximumName, _) = defaults[6] else {
            return XCTFail("expected exact Mangas-Origines.fr filter schema")
        }
        let selectedOrigins = origins.map { filter -> SourceFilter in
            .checkBox(name: filter.name, state: filter.name == "Manhwa" || filter.name == "Manga")
        }
        let selectedGenres = genres.map { filter -> SourceFilter in
            .checkBox(name: filter.name, state: filter.name == "Action" || filter.name == "Romance")
        }
        let search = try await source.getSearchManga(
            page: 3,
            query: "hero",
            filters: [
                .group(name: originName, filters: selectedOrigins),
                .group(name: genreName, filters: selectedGenres),
                .select(name: statusName, values: statuses, state: 1),
                .select(name: ratingName, values: ratings, state: 3),
                .select(name: sortName, values: sorts, state: 2),
                .text(name: minimumName, state: "12"),
                .text(name: maximumName, state: " 20 "),
            ]
        )
        XCTAssertEqual(search.mangas.map(\.url), ["hero"])
        XCTAssertTrue(search.hasNextPage)

        let requests = await transport.snapshot()
        XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(requests.allSatisfy { request in
            request.url == listingURL &&
                request.method == "POST" &&
                request.headers == [
                    CompatHTTPHeader(name: "Referer", value: "https://mangas-origines.fr/"),
                    CompatHTTPHeader(name: "Origin", value: "https://mangas-origines.fr"),
                ]
        })
        XCTAssertEqual(requests.map(\.body), [
            .form(fields: Self.catalogueFields(
                query: "", genres: "", status: "tous", rating: "0",
                origins: "", sort: "populaire", minimum: "0", maximum: "0", page: 2
            )),
            .form(fields: Self.catalogueFields(
                query: "", genres: "", status: "tous", rating: "0",
                origins: "", sort: "recents", minimum: "0", maximum: "0", page: 4
            )),
            .form(fields: Self.catalogueFields(
                query: "hero", genres: "action,romance", status: "en-cours", rating: "3",
                origins: "manhwa,manga", sort: "notes", minimum: "12", maximum: "20", page: 3
            )),
        ])
        XCTAssertTrue(source.compatibilityReport().findings.isEmpty)
    }

    func testCurrentMangasOriginesFRProfileRejectsMutatedAndForgedFiltersBeforeTransport() async throws {
        let transport = RoutingTransport(responses: [:])
        let source = try PinnedInterpretedSource.mangasOriginesFR1658(
            apkBytes: corpusAPK(),
            transport: transport
        )
        let defaults = source.getFilterList()
        guard case let .group(genreName, genres) = defaults[1],
              case let .select(statusName, statuses, statusState) = defaults[2] else {
            return XCTFail("expected exact Mangas-Origines.fr filter schema")
        }

        var appendedGenre = defaults
        appendedGenre[1] = .group(
            name: genreName,
            filters: genres + [.checkBox(name: "Injected", state: true)]
        )
        var forgedStatusOptions = defaults
        forgedStatusOptions[2] = .select(
            name: statusName,
            values: statuses + ["Injected"],
            state: statusState
        )
        var invalidStatusState = defaults
        invalidStatusState[2] = .select(
            name: statusName,
            values: statuses,
            state: statuses.count
        )
        var wrongStatusShape = defaults
        wrongStatusShape[2] = .text(name: statusName, state: "0")

        for filters in [
            appendedGenre,
            forgedStatusOptions,
            invalidStatusState,
            wrongStatusShape,
        ] {
            do {
                _ = try await source.getSearchManga(
                    page: 1,
                    query: "hero",
                    filters: filters
                )
                XCTFail("mutated filter schema must fail closed")
            } catch let error as PinnedInterpretedSourceError {
                XCTAssertEqual(error, .invalidInput(operation: "search filters"))
            } catch {
                XCTFail("expected invalid search-filter input, got \(error)")
            }
        }

        let requests = await transport.snapshot()
        XCTAssertTrue(requests.isEmpty)
        XCTAssertTrue(source.compatibilityReport().findings.isEmpty)
    }

    func testCurrentMangasOriginesFRProfileRejectsUnexpectedPreferencesBeforeTransport() async throws {
        let invalidPreferences = [
            try InterpretedExtensionPreferences(strings: ["unexpected": "value"]),
            try InterpretedExtensionPreferences(booleans: ["unexpected": true]),
        ]

        for preferences in invalidPreferences {
            let transport = RoutingTransport(responses: [:])
            XCTAssertThrowsError(try InterpretedExtensionProfileCatalog.makeSources(
                packageName: "eu.kanade.tachiyomi.extension.fr.mangasoriginesfr",
                versionName: "1.6.58",
                versionCode: 58,
                apkBytes: corpusAPK(),
                transport: transport,
                preferences: preferences
            )) { error in
                XCTAssertEqual(
                    error as? PinnedInterpretedSourceError,
                    .invalidPreferences(profile: "mangas-origines-fr-1.6.58")
                )
            }
            let requests = await transport.snapshot()
            XCTAssertTrue(requests.isEmpty)
        }
    }

    func testCurrentMangasOriginesFRProfileExecutesDetailsChaptersPagesAndImageRequest() async throws {
        let detailsURL = "https://mangas-origines.fr/oeuvre/hero/"
        let chaptersURL = "https://mangas-origines.fr/oeuvre/hero/ajax/chapters/"
        let pagesURL = "https://mangas-origines.fr/oeuvre/hero/chapter-7/"
        let detailsHTML = #"""
        <html><body>
          <h1 class="ori-sr-title">Hero &amp; Alpha</h1>
          <div class="ori-sr-cover"><img src="/covers/hero-detail.jpg"></div>
          <div class="ori-sr-infos"><dl>
              <dt>Auteur</dt><dd>Measured Writer</dd>
              <dt>Dessin</dt><dd>Measured Artist</dd>
              <dt>Type</dt><dd>Manhwa</dd>
              <dt>Nom alternatif</dt><dd>Alternative Hero</dd>
              <dt>Statut</dt><dd>En pause</dd>
          </dl></div>
          <div class="ori-sr-syn-texte">
            <p>First measured paragraph.</p>
            <p>Second &amp; final paragraph.</p>
          </div>
          <div class="ori-sr-genres">
            <a class="ori-sr-genre">Action</a>
            <a class="ori-sr-genre">Adventure</a>
          </div>
        </body></html>
        """#
        let chaptersHTML = #"""
        <html><body>
          <div class="ori-chl-row">
            <a class="ori-chl-corps" href="/oeuvre/hero/chapter-7/?tracking=1#reader">
              <span class="link-copy">Fallback Seven</span>
            </a>
            <span class="ori-chl-nom">Chapitre 7</span>
            <span class="ori-chl-date">8 Août 2026</span>
          </div>
          <div class="ori-chl-row">
            <a class="ori-chl-corps" href="https://mangas-origines.fr/oeuvre/hero/chapter-6/">
              Chapitre 6 fallback
            </a>
            <span class="ori-chl-date">date inconnue</span>
          </div>
        </body></html>
        """#
        let pagesHTML = #"""
        <html><body>
          <div class="reading-content">
            <img class="wp-manga-chapter-img" src="/reader/fallback.jpg" data-src="/reader/page-1.jpg">
            <img class="wp-manga-chapter-img" src="https://cdn.example/page-2.jpg">
          </div>
        </body></html>
        """#
        let transport = RoutingTransport(responses: [
            RouteKey(method: "GET", url: detailsURL): response(
                url: detailsURL,
                contentType: "text/html; charset=utf-8",
                body: detailsHTML
            ),
            RouteKey(method: "POST", url: chaptersURL): response(
                url: chaptersURL,
                contentType: "text/html; charset=utf-8",
                body: chaptersHTML
            ),
            RouteKey(method: "GET", url: pagesURL): response(
                url: pagesURL,
                contentType: "text/html; charset=utf-8",
                body: pagesHTML
            ),
        ])
        let source = try PinnedInterpretedSource.mangasOriginesFR1658(
            apkBytes: corpusAPK(),
            transport: transport
        )
        let input = SMangaCompat(
            url: "/catalogues/hero/?legacy=1#saved",
            title: "Old title"
        )

        let update = try await source.getMangaUpdate(manga: input)
        XCTAssertEqual(update.manga.url, input.url)
        XCTAssertEqual(update.manga.title, "Hero & Alpha")
        XCTAssertEqual(update.manga.thumbnailURL, "https://mangas-origines.fr/covers/hero-detail.jpg")
        XCTAssertEqual(update.manga.author, "Measured Writer")
        XCTAssertEqual(update.manga.artist, "Measured Artist")
        XCTAssertEqual(
            update.manga.description,
            "First measured paragraph.\nSecond & final paragraph.\n\nNom alternatif: Alternative Hero"
        )
        XCTAssertEqual(update.manga.genres, ["Action", "Adventure", "Manhwa"])
        XCTAssertEqual(update.manga.status.rawValue, MangaStatus.onHiatus.rawValue)
        XCTAssertEqual(update.chapters.count, 2)
        XCTAssertEqual(update.chapters.map(\.url), ["hero/chapter-7", "hero/chapter-6"])
        XCTAssertEqual(update.chapters.map(\.name), ["Chapitre 7", "Chapitre 6 fallback"])
        XCTAssertEqual(update.chapters.map(\.dateUpload), [1_786_140_000_000, 0])

        let details = try await source.getMangaDetails(manga: input)
        XCTAssertEqual(details.title, "Hero & Alpha")
        XCTAssertEqual(details.url, input.url)
        let chapters = try await source.getChapterList(manga: input)
        XCTAssertEqual(chapters.map(\.url), ["hero/chapter-7", "hero/chapter-6"])

        let pages = try await source.getPageList(chapter: update.chapters[0])
        XCTAssertEqual(pages.map(\.index), [0, 1])
        XCTAssertEqual(pages.map(\.url), ["", ""])
        XCTAssertEqual(pages.map(\.imageURL), [
            "https://mangas-origines.fr/reader/page-1.jpg",
            "https://cdn.example/page-2.jpg",
        ])
        let generatedImageRequest = await source.getImageRequest(page: pages[0])
        let imageRequest = try XCTUnwrap(generatedImageRequest)
        XCTAssertEqual(imageRequest.url, "https://mangas-origines.fr/reader/page-1.jpg")
        XCTAssertEqual(imageRequest.headers, [
            "Referer": "https://mangas-origines.fr/",
            "Origin": "https://mangas-origines.fr",
        ])
        XCTAssertNil(imageRequest.sourceExecutionID)
        let sourceExecutedResponse = try await imageRequest.executeSourceRequest()
        XCTAssertNil(sourceExecutedResponse)

        let requests = await transport.snapshot()
        XCTAssertEqual(requests.map(\.method), [
            "GET", "POST", "GET", "POST", "GET", "POST", "GET",
        ])
        XCTAssertEqual(requests.map(\.url), [
            detailsURL,
            chaptersURL,
            detailsURL,
            chaptersURL,
            detailsURL,
            chaptersURL,
            pagesURL,
        ])
        XCTAssertEqual(
            requests.filter { $0.method == "POST" }.map(\.body),
            Array(repeating: .form(fields: []), count: 3)
        )
        XCTAssertTrue(requests.filter { $0.method == "GET" }.allSatisfy {
            $0.body == nil && $0.cachePolicy == CompatHTTPCachePolicy(maxAgeSeconds: 600)
        })
        XCTAssertTrue(requests.allSatisfy {
            $0.headers == [
                CompatHTTPHeader(name: "Referer", value: "https://mangas-origines.fr/"),
                CompatHTTPHeader(name: "Origin", value: "https://mangas-origines.fr"),
            ]
        })
        XCTAssertTrue(source.compatibilityReport().findings.isEmpty)
    }

    private static func catalogueFields(
        query: String,
        genres: String,
        status: String,
        rating: String,
        origins: String,
        sort: String,
        minimum: String,
        maximum: String,
        page: Int
    ) -> [CompatHTTPFormField] {
        [
            .init(name: "action", value: "madara_child_catalogue"),
            .init(name: "s", value: query),
            .init(name: "genres", value: genres),
            .init(name: "statut", value: status),
            .init(name: "note", value: rating),
            .init(name: "origine", value: origins),
            .init(name: "tri", value: sort),
            .init(name: "chmin", value: minimum),
            .init(name: "chmax", value: maximum),
            .init(name: "page", value: String(page)),
            .init(name: "auteur", value: ""),
            .init(name: "artiste", value: ""),
            .init(name: "annee", value: ""),
        ]
    }
}
