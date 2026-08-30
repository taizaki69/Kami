import XCTest
@testable import MihonCompatKit

/// Executes REAL methods from REAL current extension APKs (mission §31/§38).
/// The corpus is fetched by `scripts/fetch_corpus.sh` (CI does this too);
/// tests skip when the corpus is absent so unit runs stay deterministic.
final class RealExtensionExecutionTests: XCTestCase {
    private actor StaticTransport: CompatHTTPTransport {
        nonisolated let sourceID = "batcave-test"
        private let response: CompatHTTPResponse
        private var recordedRequests: [CompatHTTPRequest] = []

        init(response: CompatHTTPResponse) {
            self.response = response
        }

        func execute(_ request: CompatHTTPRequest) async throws -> CompatHTTPResponse {
            recordedRequests.append(request)
            await Task.yield()
            return response
        }

        func requests() -> [CompatHTTPRequest] {
            recordedRequests
        }
    }

    private var batCaveHeaders: [CompatHTTPHeader] {
        [
            CompatHTTPHeader(name: "Referer", value: "https://batcave.biz/"),
            CompatHTTPHeader(name: "Origin", value: "https://batcave.biz"),
        ]
    }

    private func corpusAPK(_ name: String) throws -> [UInt8] {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/MihonCompatKitTests
            .deletingLastPathComponent()   // …/Tests
            .deletingLastPathComponent()   // …/MihonCompatKit
            .deletingLastPathComponent()   // …/Packages
            .deletingLastPathComponent()   // …/Kami (repo root)
            .appendingPathComponent("Tests/corpus/\(name).apk")
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw XCTSkip("corpus APK \(name).apk not present — run scripts/fetch_corpus.sh")
        }
        return [UInt8](try Data(contentsOf: path))
    }

    private func loadVM(
        _ apk: String,
        transport: (any CompatHTTPTransport)? = nil
    ) throws -> (DexInterpreter, ExtensionManifest) {
        let bytes = try corpusAPK(apk)
        let manifest = try ExtensionManifest(apkBytes: bytes)
        let zip = try ZipArchive(bytes)
        let dex = try DexFile(try zip.data(named: "classes.dex"))
        return (
            DexInterpreter(dex: dex, bridge: HostBridge.minimal(transport: transport)),
            manifest
        )
    }

    private func httpURL(_ rawValue: String, vm: DexInterpreter) throws -> RVal {
        let companion = try XCTUnwrap(vm.bridge.staticFields["Lokhttp3/HttpUrl;->Companion"])
        let get = try XCTUnwrap(vm.bridge.resolve(
            class: "Lokhttp3/HttpUrl$Companion;",
            "get",
            prototype: "(Ljava/lang/String;)Lokhttp3/HttpUrl;",
            isStatic: false
        ))
        return try get(vm, [companion, HostBridge.string(rawValue)])
    }

    private func manga(
        url: String,
        title: String,
        vm: DexInterpreter
    ) throws -> RVal {
        let companion = try XCTUnwrap(
            vm.bridge.staticFields[
                "Leu/kanade/tachiyomi/source/model/SManga;->Companion"
            ]
        )
        let create = try XCTUnwrap(vm.bridge.resolve(
            class: "Leu/kanade/tachiyomi/source/model/SManga$Companion;",
            "create",
            prototype: "()Leu/kanade/tachiyomi/source/model/SManga;",
            isStatic: false
        ))
        let value = try create(vm, [companion])
        for (name, propertyValue) in [("setUrl", url), ("setTitle", title)] {
            let setter = try XCTUnwrap(vm.bridge.resolve(
                class: "Leu/kanade/tachiyomi/source/model/SManga;",
                name,
                prototype: "(Ljava/lang/String;)V",
                isStatic: false
            ))
            _ = try setter(vm, [value, HostBridge.string(propertyValue)])
        }
        return value
    }

    private func emptyList(vm: DexInterpreter) throws -> RVal {
        let method = try XCTUnwrap(vm.bridge.resolve(
            class: "Lkotlin/collections/CollectionsKt;",
            "emptyList",
            prototype: "()Ljava/util/List;",
            isStatic: true
        ))
        return try method(vm, [])
    }

    private func chapter(
        url: String,
        name: String,
        vm: DexInterpreter
    ) throws -> RVal {
        let companion = try XCTUnwrap(
            vm.bridge.staticFields[
                "Leu/kanade/tachiyomi/source/model/SChapter;->Companion"
            ]
        )
        let create = try XCTUnwrap(vm.bridge.resolve(
            class: "Leu/kanade/tachiyomi/source/model/SChapter$Companion;",
            "create",
            prototype: "()Leu/kanade/tachiyomi/source/model/SChapter;",
            isStatic: false
        ))
        let value = try create(vm, [companion])
        for (method, propertyValue) in [("setUrl", url), ("setName", name)] {
            let setter = try XCTUnwrap(vm.bridge.resolve(
                class: "Leu/kanade/tachiyomi/source/model/SChapter;",
                method,
                prototype: "(Ljava/lang/String;)V",
                isStatic: false
            ))
            _ = try setter(vm, [value, HostBridge.string(propertyValue)])
        }
        return value
    }

    /// BatCave 1.6.9 (lib 1.6): getBaseUrl() = const-string/return-object —
    /// the first method from a real extension APK executed by Kami's VM.
    func testBatCaveGetBaseUrl() throws {
        let (vm, _) = try loadVM("batcave")
        let cls = "Leu/kanade/tachiyomi/extension/en/batcave/ExtensionGenerated;"
        let receiver = RVal.obj(ObjInstance(dexType: cls))
        let result = try vm.call(
            classDescriptor: cls,
            method: "getBaseUrl",
            args: [receiver]
        )
        let url = vmStringValue(result)
        XCTAssertTrue(url.hasPrefix("https://"), "expected a URL, got: \(url)")
        XCTAssertFalse(url.isEmpty)
    }

    func testBatCaveGetLang() throws {
        let (vm, _) = try loadVM("batcave")
        let cls = "Leu/kanade/tachiyomi/extension/en/batcave/ExtensionGenerated;"
        let receiver = RVal.obj(ObjInstance(dexType: cls))
        let result = try vm.call(
            classDescriptor: cls,
            method: "getLang",
            args: [receiver]
        )
        XCTAssertEqual(vmStringValue(result), "en")
    }

    func testBatCaveGetName() throws {
        let (vm, _) = try loadVM("batcave")
        let cls = "Leu/kanade/tachiyomi/extension/en/batcave/ExtensionGenerated;"
        let receiver = RVal.obj(ObjInstance(dexType: cls))
        let result = try vm.call(
            classDescriptor: cls,
            method: "getName",
            args: [receiver]
        )
        XCTAssertEqual(vmStringValue(result), "BatCave")
    }

    /// getId(): const-wide + return-wide — 64-bit path from a real APK.
    func testBatCaveGetId() throws {
        let (vm, _) = try loadVM("batcave")
        let cls = "Leu/kanade/tachiyomi/extension/en/batcave/ExtensionGenerated;"
        let receiver = RVal.obj(ObjInstance(dexType: cls))
        let result = try vm.call(
            classDescriptor: cls,
            method: "getId",
            args: [receiver]
        )
        guard case let .long(id) = result else {
            return XCTFail("expected long, got \(result)")
        }
        XCTAssertGreaterThan(id, 0, "Mihon source ids are positive 63-bit values")
    }

    /// The real generated source constructor now executes through its Kotlin
    /// lazy/reflection/atomic setup instead of using a fabricated receiver.
    func testBatCaveConstructorExecutes() throws {
        let (vm, _) = try loadVM("batcave")
        let cls = "Leu/kanade/tachiyomi/extension/en/batcave/ExtensionGenerated;"
        let value = try vm.instantiate(classDescriptor: cls)
        guard case let .obj(object) = value else {
            return XCTFail("expected BatCave object, got \(value)")
        }
        XCTAssertEqual(object.dexType, cls)
    }

    /// Characterizes the honest transport boundary for a complete popular-
    /// manga request. All request construction is pure; no network is touched.
    func testBatCavePopularBuildsRequestAndStopsBeforeTransport() throws {
        let (vm, _) = try loadVM("batcave")
        let cls = "Leu/kanade/tachiyomi/extension/en/batcave/ExtensionGenerated;"
        let receiver = try vm.instantiate(classDescriptor: cls)
        XCTAssertThrowsError(try vm.call(
            classDescriptor: cls,
            method: "getPopularManga",
            prototype: "(ILkotlin/coroutines/Continuation;)Ljava/lang/Object;",
            args: [receiver, .int(1), .null]
        )) { error in
            guard case let VMError.asyncExecutionRequired(classDescriptor, signature) = error else {
                return XCTFail("expected exact OkHttp frontier, got \(error)")
            }
            XCTAssertEqual(classDescriptor, "Leu/kanade/tachiyomi/network/OkHttpExtensionsKt;")
            XCTAssertEqual(
                signature,
                "awaitSuccess(Lokhttp3/Call;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;"
            )
        }
        guard let request = vm.bridge.lastPreparedRequest else {
            return XCTFail("expected a pure request model before the transport boundary")
        }
        XCTAssertEqual(request, CompatHTTPRequest(
            url: "https://batcave.biz/comix/",
            method: "POST",
            headers: batCaveHeaders,
            body: .form(fields: [
                CompatHTTPFormField(name: "dlenewssortby", value: "rating"),
                CompatHTTPFormField(name: "dledirection", value: "desc"),
                CompatHTTPFormField(name: "set_new_sort", value: "dle_sort_cat_1"),
                CompatHTTPFormField(name: "set_direction_sort", value: "dle_direction_cat_1"),
            ])
        ))
    }

    /// A deterministic fake response proves that the real suspend call crosses
    /// the injected transport, resumes its complete DEX call stack, parses the
    /// source's production selectors, and returns app-facing manga models.
    func testBatCavePopularParsesMangasPageAfterTransport() async throws {
        let html = """
        <html><body>
        <div id="dle-content">
          <article class="readed">
            <div class="readed__title"><a href="/comic/alpha?from=popular#top">Alpha &amp; Omega</a></div>
            <img data-src="/uploads/alpha.jpg">
          </article>
          <article class="readed">
            <div class="readed__title"><a href="https://mirror.example/series/beta">Beta</a></div>
            <img data-src="https://images.example/beta.png">
          </article>
        </div>
        <div class="pagination__pages"><span>1</span><a href="/comix/page/2/">2</a></div>
        </body></html>
        """
        let transport = StaticTransport(response: CompatHTTPResponse(
            finalURL: "https://batcave.biz/comix/",
            statusCode: 200,
            headers: [CompatHTTPHeader(name: "Content-Type", value: "text/html; charset=utf-8")],
            body: Array(html.utf8)
        ))
        let (vm, _) = try loadVM("batcave", transport: transport)
        let cls = "Leu/kanade/tachiyomi/extension/en/batcave/ExtensionGenerated;"
        let receiver = try vm.instantiate(classDescriptor: cls)

        let result = try await vm.callAsync(
            classDescriptor: cls,
            method: "getPopularManga",
            prototype: "(ILkotlin/coroutines/Continuation;)Ljava/lang/Object;",
            args: [receiver, .int(1), .null]
        )
        guard let page = HostBridge.mangasPageCompat(from: result) else {
            return XCTFail("expected a converted MangasPage, got \(result)")
        }
        XCTAssertEqual(page.mangas.count, 2)
        XCTAssertEqual(page.mangas[0].url, "/comic/alpha?from=popular#top")
        XCTAssertEqual(page.mangas[0].title, "Alpha & Omega")
        XCTAssertEqual(page.mangas[0].thumbnailURL, "https://batcave.biz/uploads/alpha.jpg")
        XCTAssertEqual(page.mangas[1].url, "/series/beta")
        XCTAssertEqual(page.mangas[1].title, "Beta")
        XCTAssertEqual(page.mangas[1].thumbnailURL, "https://images.example/beta.png")
        XCTAssertTrue(page.hasNextPage)

        let expected = CompatHTTPRequest(
            url: "https://batcave.biz/comix/",
            method: "POST",
            headers: batCaveHeaders,
            body: .form(fields: [
                CompatHTTPFormField(name: "dlenewssortby", value: "rating"),
                CompatHTTPFormField(name: "dledirection", value: "desc"),
                CompatHTTPFormField(name: "set_new_sort", value: "dle_sort_cat_1"),
                CompatHTTPFormField(name: "set_direction_sort", value: "dle_direction_cat_1"),
            ])
        )
        let requests = await transport.requests()
        XCTAssertEqual(requests, [expected])
        XCTAssertEqual(vm.bridge.lastPreparedRequest, expected)
    }

    func testBatCaveLatestUpdatesBuildsGETAndParsesPage() async throws {
        let html = """
        <div id="content-load">
          <article class="latest grid-item">
            <div class="latest__title"><a href="/comic/latest-hit">Latest Hit</a></div>
            <div class="latest__img"><img src="/uploads/latest-hit.jpg"></div>
          </article>
        </div>
        <li class="pagination"><a href="/page/4">Next</a></li>
        """
        let transport = StaticTransport(response: CompatHTTPResponse(
            finalURL: "https://batcave.biz/page/3",
            statusCode: 200,
            headers: [CompatHTTPHeader(name: "Content-Type", value: "text/html; charset=utf-8")],
            body: Array(html.utf8)
        ))
        let (vm, _) = try loadVM("batcave", transport: transport)
        let cls = "Leu/kanade/tachiyomi/extension/en/batcave/ExtensionGenerated;"
        let receiver = try vm.instantiate(classDescriptor: cls)

        let result = try await vm.callAsync(
            classDescriptor: cls,
            method: "getLatestUpdates",
            prototype: "(ILkotlin/coroutines/Continuation;)Ljava/lang/Object;",
            args: [receiver, .int(3), .null]
        )
        guard let page = HostBridge.mangasPageCompat(from: result) else {
            return XCTFail("expected a converted latest MangasPage, got \(result)")
        }
        XCTAssertEqual(page.mangas.count, 1)
        XCTAssertEqual(page.mangas[0].url, "/comic/latest-hit")
        XCTAssertEqual(page.mangas[0].title, "Latest Hit")
        XCTAssertEqual(page.mangas[0].thumbnailURL, "https://batcave.biz/uploads/latest-hit.jpg")
        XCTAssertTrue(page.hasNextPage)

        let expected = CompatHTTPRequest(
            url: "https://batcave.biz/page/3",
            headers: batCaveHeaders,
            cachePolicy: CompatHTTPCachePolicy(maxAgeSeconds: 600)
        )
        let requests = await transport.requests()
        XCTAssertEqual(requests, [expected])
        XCTAssertEqual(vm.bridge.lastPreparedRequest, expected)
    }

    /// BatCave's generated search worker is R8-renamed to `k`; calling that
    /// exact pinned method drives the real nonblank-query branch without
    /// fabricating an implementation of its external KeiSource superclass.
    func testBatCaveTextSearchBuildsEncodedGETAndParsesPage() async throws {
        let html = """
        <div id="dle-content">
          <article class="readed">
            <div class="readed__title"><a href="/comic/search-hit">Search Hit</a></div>
            <img data-src="/uploads/search-hit.jpg">
          </article>
        </div>
        <div class="pagination__pages"><span>1</span></div>
        """
        let transport = StaticTransport(response: CompatHTTPResponse(
            finalURL: "https://batcave.biz/search/alpha+beta/page/2/",
            statusCode: 200,
            headers: [CompatHTTPHeader(name: "Content-Type", value: "text/html; charset=utf-8")],
            body: Array(html.utf8)
        ))
        let (vm, _) = try loadVM("batcave", transport: transport)
        let cls = "Leu/kanade/tachiyomi/extension/en/batcave/ExtensionGenerated;"
        let receiver = try vm.instantiate(classDescriptor: cls)

        let result = try await vm.callAsync(
            classDescriptor: cls,
            method: "k",
            prototype: "(Leu/kanade/tachiyomi/extension/en/batcave/ExtensionGenerated;ILjava/lang/String;Leu/kanade/tachiyomi/source/model/FilterList;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;",
            args: [receiver, .int(2), HostBridge.string("  alpha beta  "), .null, .null]
        )
        guard let page = HostBridge.mangasPageCompat(from: result) else {
            return XCTFail("expected a converted search MangasPage, got \(result)")
        }
        XCTAssertEqual(page.mangas.count, 1)
        XCTAssertEqual(page.mangas[0].url, "/comic/search-hit")
        XCTAssertEqual(page.mangas[0].title, "Search Hit")
        XCTAssertEqual(page.mangas[0].thumbnailURL, "https://batcave.biz/uploads/search-hit.jpg")
        XCTAssertFalse(page.hasNextPage)

        let expected = CompatHTTPRequest(
            url: "https://batcave.biz/search/alpha+beta/page/2/",
            headers: batCaveHeaders,
            cachePolicy: CompatHTTPCachePolicy(maxAgeSeconds: 600)
        )
        let requests = await transport.requests()
        XCTAssertEqual(requests, [expected])
        XCTAssertEqual(vm.bridge.lastPreparedRequest, expected)
    }

    func testBatCaveMangaByURLBuildsGETAndParsesCoreDetails() async throws {
        let html = """
        <header class="page__header"><h1>Detail Hero</h1></header>
        <div class="page__poster"><img src="/uploads/detail-hero.jpg"></div>
        <ul class="page__list">
          <li><div>Publisher</div><a>Bat Publisher</a></li>
          <li><div>Year</div><a>2024</a></li>
          <li><div>Writer</div><a>Writer Name</a></li>
          <li><div>Artist</div><a>Artist Name</a></li>
          <li><div>Release type</div>Ongoing</li>
        </ul>
        <div class="page__text">A deterministic description.</div>
        <div class="page__tags"><a>Action</a><a>Adventure</a></div>
        """
        let detailURL = "https://batcave.biz/comic/detail-hero"
        let transport = StaticTransport(response: CompatHTTPResponse(
            finalURL: detailURL,
            statusCode: 200,
            headers: [CompatHTTPHeader(name: "Content-Type", value: "text/html; charset=utf-8")],
            body: Array(html.utf8)
        ))
        let (vm, _) = try loadVM("batcave", transport: transport)
        let cls = "Leu/kanade/tachiyomi/extension/en/batcave/ExtensionGenerated;"
        let receiver = try vm.instantiate(classDescriptor: cls)
        let url = try httpURL(detailURL, vm: vm)

        let result = try await vm.callAsync(
            classDescriptor: cls,
            method: "h",
            prototype: "(Leu/kanade/tachiyomi/extension/en/batcave/ExtensionGenerated;Lokhttp3/HttpUrl;Lkotlin/coroutines/jvm/internal/ContinuationImpl;)Ljava/lang/Object;",
            args: [receiver, url, .null]
        )
        guard let manga = HostBridge.mangaCompat(from: result) else {
            return XCTFail("expected converted manga details, got \(result)")
        }
        XCTAssertEqual(manga.url, "/comic/detail-hero")
        XCTAssertEqual(manga.title, "Detail Hero")
        XCTAssertEqual(manga.thumbnailURL, "https://batcave.biz/uploads/detail-hero.jpg")
        XCTAssertEqual(manga.description, "Bat Publisher — 2024\n\nA deterministic description.")
        XCTAssertEqual(manga.author, "Writer Name")
        XCTAssertEqual(manga.artist, "Artist Name")
        XCTAssertEqual(manga.genres, ["Action", "Adventure", "Comic"])
        XCTAssertEqual(manga.status, .ongoing)

        let expected = CompatHTTPRequest(
            url: detailURL,
            headers: batCaveHeaders,
            cachePolicy: CompatHTTPCachePolicy(maxAgeSeconds: 600)
        )
        let requests = await transport.requests()
        XCTAssertEqual(requests, [expected])
        XCTAssertEqual(vm.bridge.lastPreparedRequest, expected)
    }

    func testBatCaveMangaUpdateParsesChaptersFromScriptJSON() async throws {
        let html = """
        <header class="page__header"><h1>Chapter Hero</h1></header>
        <div class="page__text">Chapter frontier.</div>
        <script>
        window.__DATA__ = {"news_id":42,"chapters":[{"id":7,"posi":1.5,"title":"Chapter 1.5","date":"23.8.2026"},{"id":8,"posi":2.0,"title":"Chapter 2","date":"not-a-date"}],"xhash":"?token=test"};
        </script>
        """
        let detailURL = "https://batcave.biz/comic/chapter-hero"
        let transport = StaticTransport(response: CompatHTTPResponse(
            finalURL: detailURL,
            statusCode: 200,
            headers: [CompatHTTPHeader(name: "Content-Type", value: "text/html; charset=utf-8")],
            body: Array(html.utf8)
        ))
        let (vm, _) = try loadVM("batcave", transport: transport)
        let cls = "Leu/kanade/tachiyomi/extension/en/batcave/ExtensionGenerated;"
        let receiver = try vm.instantiate(classDescriptor: cls)
        let sourceManga = try manga(url: "/comic/chapter-hero", title: "Chapter Hero", vm: vm)

        let result = try await vm.callAsync(
            classDescriptor: cls,
            method: "f",
            prototype: "(Leu/kanade/tachiyomi/extension/en/batcave/ExtensionGenerated;Leu/kanade/tachiyomi/source/model/SManga;Ljava/util/List;ZZLkotlin/coroutines/jvm/internal/ContinuationImpl;)Ljava/lang/Object;",
            args: [receiver, sourceManga, try emptyList(vm: vm), .int(1), .int(1), .null]
        )
        guard let update = HostBridge.mangaUpdateCompat(from: result) else {
            return XCTFail("expected converted manga update, got \(result)")
        }
        XCTAssertEqual(update.manga.url, "/comic/chapter-hero")
        XCTAssertEqual(update.manga.title, "Chapter Hero")
        XCTAssertEqual(update.manga.description, "\nChapter frontier.")
        XCTAssertEqual(update.chapters.count, 2)
        let firstChapter = update.chapters[0]
        XCTAssertEqual(firstChapter.url, "/reader/42/7?token=test")
        XCTAssertEqual(firstChapter.name, "Chapter 1.5")
        XCTAssertEqual(firstChapter.chapterNumber, 1.5)
        XCTAssertNil(firstChapter.number)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let expectedDate = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 23
        )))
        XCTAssertEqual(
            firstChapter.dateUpload,
            Int64((expectedDate.timeIntervalSince1970 * 1_000).rounded())
        )

        let secondChapter = update.chapters[1]
        XCTAssertEqual(secondChapter.url, "/reader/42/8?token=test")
        XCTAssertEqual(secondChapter.name, "Chapter 2")
        XCTAssertEqual(secondChapter.chapterNumber, 2)
        XCTAssertNil(secondChapter.number)
        XCTAssertEqual(secondChapter.dateUpload, 0)

        let expected = CompatHTTPRequest(
            url: detailURL,
            headers: batCaveHeaders,
            cachePolicy: CompatHTTPCachePolicy(maxAgeSeconds: 600)
        )
        let requests = await transport.requests()
        XCTAssertEqual(requests, [expected])
        XCTAssertEqual(vm.bridge.lastPreparedRequest, expected)
    }

    func testBatCaveMangaUpdateRejectsInvalidChapterJSON() async throws {
        let detailURL = "https://batcave.biz/comic/invalid-chapters"
        let cases = [
            (name: "malformed", payload: #"{"news_id":42,"chapters":[}"#),
            (name: "missing required news_id", payload: #"{"chapters":[]}"#),
        ]

        for testCase in cases {
            let html = """
            <header class="page__header"><h1>Invalid Chapters</h1></header>
            <div class="page__text">Invalid fixture.</div>
            <script>window.__DATA__ = \(testCase.payload);</script>
            """
            let transport = StaticTransport(response: CompatHTTPResponse(
                finalURL: detailURL,
                statusCode: 200,
                headers: [CompatHTTPHeader(
                    name: "Content-Type",
                    value: "text/html; charset=utf-8"
                )],
                body: Array(html.utf8)
            ))
            let (vm, _) = try loadVM("batcave", transport: transport)
            let cls = "Leu/kanade/tachiyomi/extension/en/batcave/ExtensionGenerated;"
            let receiver = try vm.instantiate(classDescriptor: cls)
            let sourceManga = try manga(
                url: "/comic/invalid-chapters",
                title: "Invalid Chapters",
                vm: vm
            )

            do {
                _ = try await vm.callAsync(
                    classDescriptor: cls,
                    method: "f",
                    prototype: "(Leu/kanade/tachiyomi/extension/en/batcave/ExtensionGenerated;Leu/kanade/tachiyomi/source/model/SManga;Ljava/util/List;ZZLkotlin/coroutines/jvm/internal/ContinuationImpl;)Ljava/lang/Object;",
                    args: [
                        receiver,
                        sourceManga,
                        try emptyList(vm: vm),
                        .int(1),
                        .int(1),
                        .null,
                    ]
                )
                XCTFail("expected SerializationException for \(testCase.name)")
            } catch let thrown as DEXThrowable {
                guard case let .obj(object) = thrown.value else {
                    XCTFail("expected host SerializationException for \(testCase.name)")
                    continue
                }
                XCTAssertEqual(
                    object.dexType,
                    "Lkotlinx/serialization/SerializationException;",
                    testCase.name
                )
            } catch {
                XCTFail("unexpected error for \(testCase.name): \(error)")
            }

            let requests = await transport.requests()
            XCTAssertEqual(
                requests,
                [CompatHTTPRequest(
                    url: detailURL,
                    headers: batCaveHeaders,
                    cachePolicy: CompatHTTPCachePolicy(maxAgeSeconds: 600)
                )],
                testCase.name
            )
        }
    }

    func testBatCavePageListBuildsJSONPostAndParsesImages() async throws {
        let endpoint = "https://batcave.biz/engine/ajax/controller.php?mod=api&action=reader/getChapterData"
        let json = #"{"data":{"images":[" /uploads/page-one.jpg ","https://cdn.example/page-two.jpg "]}}"#
        let transport = StaticTransport(response: CompatHTTPResponse(
            finalURL: endpoint,
            statusCode: 200,
            headers: [CompatHTTPHeader(
                name: "Content-Type",
                value: "application/json; charset=utf-8"
            )],
            body: Array(json.utf8)
        ))
        let (vm, _) = try loadVM("batcave", transport: transport)
        let cls = "Leu/kanade/tachiyomi/extension/en/batcave/ExtensionGenerated;"
        let receiver = try vm.instantiate(classDescriptor: cls)
        let sourceChapter = try chapter(
            url: "/reader/42/7?token=test",
            name: "Chapter 1.5",
            vm: vm
        )

        let result = try await vm.callAsync(
            classDescriptor: cls,
            method: "getPageList",
            prototype: "(Leu/kanade/tachiyomi/source/model/SChapter;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;",
            args: [receiver, sourceChapter, .null]
        )
        let pages = try XCTUnwrap(HostBridge.pagesCompat(from: result))
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(pages[0].index, 0)
        XCTAssertEqual(pages[0].url, "")
        XCTAssertEqual(
            pages[0].imageURL,
            "https://batcave.biz/uploads/page-one.jpg"
        )
        XCTAssertEqual(pages[1].index, 1)
        XCTAssertEqual(pages[1].url, "")
        XCTAssertEqual(pages[1].imageURL, "https://cdn.example/page-two.jpg")

        let expected = CompatHTTPRequest(
            url: endpoint,
            method: "POST",
            headers: batCaveHeaders,
            body: .text(
                value: #"{"news_id":"42","chapter_id":"7"}"#,
                mediaType: "application/json"
            )
        )
        let requests = await transport.requests()
        XCTAssertEqual(requests, [expected])
        XCTAssertEqual(vm.bridge.lastPreparedRequest, expected)
    }

    func testBatCavePageListRejectsMalformedJSONResponses() async throws {
        let endpoint = "https://batcave.biz/engine/ajax/controller.php?mod=api&action=reader/getChapterData"
        let cases: [(name: String, body: [UInt8])] = [
            ("malformed JSON", Array(#"{"data":}"#.utf8)),
            ("invalid UTF-8", [0xFF]),
            ("wrong images type", Array(#"{"data":{"images":"not-an-array"}}"#.utf8)),
        ]

        for testCase in cases {
            let transport = StaticTransport(response: CompatHTTPResponse(
                finalURL: endpoint,
                statusCode: 200,
                headers: [CompatHTTPHeader(
                    name: "Content-Type",
                    value: "application/json"
                )],
                body: testCase.body
            ))
            let (vm, _) = try loadVM("batcave", transport: transport)
            let cls = "Leu/kanade/tachiyomi/extension/en/batcave/ExtensionGenerated;"
            let receiver = try vm.instantiate(classDescriptor: cls)
            let sourceChapter = try chapter(
                url: "/reader/42/7",
                name: "Chapter 1.5",
                vm: vm
            )

            do {
                _ = try await vm.callAsync(
                    classDescriptor: cls,
                    method: "getPageList",
                    prototype: "(Leu/kanade/tachiyomi/source/model/SChapter;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;",
                    args: [receiver, sourceChapter, .null]
                )
                XCTFail("expected SerializationException for \(testCase.name)")
            } catch let thrown as DEXThrowable {
                guard case let .obj(object) = thrown.value else {
                    return XCTFail("expected typed exception for \(testCase.name): \(thrown)")
                }
                XCTAssertEqual(
                    object.dexType,
                    "Lkotlinx/serialization/SerializationException;",
                    testCase.name
                )
            } catch {
                XCTFail("unexpected error for \(testCase.name): \(error)")
            }

            let requests = await transport.requests()
            XCTAssertEqual(requests.count, 1, testCase.name)
            XCTAssertEqual(requests.first?.url, endpoint, testCase.name)
            XCTAssertEqual(requests.first?.method, "POST", testCase.name)
        }
    }

    func testBatCaveAwaitSuccessRejectsNonSuccessfulHTTPStatus() async throws {
        let transport = StaticTransport(response: CompatHTTPResponse(
            finalURL: "https://batcave.biz/comix/",
            statusCode: 503,
            body: Array("unavailable".utf8)
        ))
        let (vm, _) = try loadVM("batcave", transport: transport)
        let cls = "Leu/kanade/tachiyomi/extension/en/batcave/ExtensionGenerated;"
        let receiver = try vm.instantiate(classDescriptor: cls)

        do {
            _ = try await vm.callAsync(
                classDescriptor: cls,
                method: "getPopularManga",
                prototype: "(ILkotlin/coroutines/Continuation;)Ljava/lang/Object;",
                args: [receiver, .int(1), .null]
            )
            XCTFail("expected HttpException")
        } catch let thrown as DEXThrowable {
            guard case let .obj(object) = thrown.value else {
                return XCTFail("expected host HttpException, got \(thrown)")
            }
            XCTAssertEqual(object.dexType, "Leu/kanade/tachiyomi/network/HttpException;")
            guard case let .int(code)? = object.fields["code"] else {
                return XCTFail("expected HttpException status code")
            }
            XCTAssertEqual(code, 503)
        }
        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 1)
    }

    func testTuttoAnimeMangaConstructorMetadataAndFiltersExecute() throws {
        let apkBytes = try corpusAPK("tuttoanimemanga")
        let signingIdentity = try APKSignatureVerifier().verify(apkBytes: apkBytes)
        XCTAssertEqual(
            signingIdentity.signers.first?.currentFingerprint,
            "9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2"
        )
        let (vm, manifest) = try loadVM("tuttoanimemanga")
        let cls = "L" + (manifest.resolvedSourceClass ?? "")
            .replacingOccurrences(of: ".", with: "/") + ";"
        let receiver = try vm.instantiate(classDescriptor: cls)

        let name = try vm.call(
            classDescriptor: cls,
            method: "getName",
            prototype: "()Ljava/lang/String;",
            args: [receiver]
        )
        let language = try vm.call(
            classDescriptor: cls,
            method: "getLang",
            prototype: "()Ljava/lang/String;",
            args: [receiver]
        )
        let baseURL = try vm.call(
            classDescriptor: cls,
            method: "getBaseUrl",
            prototype: "()Ljava/lang/String;",
            args: [receiver]
        )
        let sourceID = try vm.call(
            classDescriptor: cls,
            method: "getId",
            prototype: "()J",
            args: [receiver]
        )
        let supportsLatest = try vm.call(
            classDescriptor: cls,
            method: "getSupportsLatest",
            prototype: "()Z",
            args: [receiver]
        )
        let filterList = try vm.call(
            classDescriptor: cls,
            method: "getFilterList",
            prototype: "()Leu/kanade/tachiyomi/source/model/FilterList;",
            args: [receiver]
        )

        XCTAssertEqual(vmStringValue(name), "TuttoAnimeManga")
        XCTAssertEqual(vmStringValue(language), "it")
        XCTAssertEqual(vmStringValue(baseURL), "https://tuttoanimemanga.net")
        guard case let .long(id) = sourceID,
              case let .int(rawSupportsLatest) = supportsLatest else {
            return XCTFail("expected long source ID")
        }
        XCTAssertEqual(id, 2_102_507_871_480_604_746)
        XCTAssertEqual(rawSupportsLatest, 1)
        let filters = try XCTUnwrap(HostBridge.sourceFilters(from: filterList))
        XCTAssertTrue(filters.isEmpty)
    }

    /// MangaDex 1.4.212: the factory entry class's REAL constructor executes
    /// (invoke-direct Object.<init> + return-void). Its getters are iget-based
    /// (instance state from the host HttpSource superclass) — that is the M2/M3
    /// frontier, honestly out of scope for this test.
    func testMangaDexConstructorExecutes() throws {
        let (vm, manifest) = try loadVM("mangadex")
        let cls = "L" + (manifest.resolvedSourceClass ?? "").replacingOccurrences(of: ".", with: "/") + ";"
        let obj = try vm.instantiate(classDescriptor: cls)
        guard case let .obj(o) = obj, o.dexType == cls else {
            return XCTFail("expected instance of \(cls)")
        }
    }

    /// Akuma 1.4.10 (27-source multisrc): execute the real factory constructor
    /// and require a real object, rather than treating any VM error as success.
    func testAkumaConstructorExecutes() throws {
        let (vm, manifest) = try loadVM("akuma")
        let cls = "L" + (manifest.resolvedSourceClass ?? "").replacingOccurrences(of: ".", with: "/") + ";"
        let obj = try vm.instantiate(classDescriptor: cls)
        guard case let .obj(o) = obj, o.dexType == cls else {
            return XCTFail("expected instance of \(cls)")
        }
    }
}
