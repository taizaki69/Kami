import Foundation
import XCTest
@testable import MihonCompatKit

/// Exact authenticated APK execution with deterministic offline transports.
/// Corpus membership alone does not grant trust or downloaded-source admission.
final class MangaPandaRuntimeTests: XCTestCase {
    private actor RejectingTransport: CompatHTTPTransport {
        nonisolated let sourceID = "mangapanda-locked-offline-research"
        func execute(_ request: CompatHTTPRequest) async throws -> CompatHTTPResponse {
            XCTFail("Construction and metadata must not dispatch HTTP")
            throw CompatHTTPTransportError.invalidResponse
        }
    }
    private actor CatalogTransport: CompatHTTPTransport {
        nonisolated let sourceID = "mangapanda-locked-offline-research"
        private(set) var requests: [CompatHTTPRequest] = []
        private let suspendRequest: Int?
        private let holdCancellation: Bool
        private var heldRequest: CheckedContinuation<Void, Never>?
        init(suspendFirstRequest: Bool = false, suspendRequest: Int? = nil, holdCancellation: Bool = false) {
            self.suspendRequest = suspendFirstRequest ? 1 : suspendRequest
            self.holdCancellation = holdCancellation
        }
        func releaseHeldRequest() { heldRequest?.resume(); heldRequest = nil }
        func execute(_ request: CompatHTTPRequest) async throws -> CompatHTTPResponse {
            requests.append(request)
            if requests.count == suspendRequest {
                if holdCancellation {
                    await withCheckedContinuation { heldRequest = $0 }
                    try Task.checkCancellation()
                }
                try await Task.sleep(nanoseconds: 60_000_000_000)
                throw CompatHTTPTransportError.timedOut
            }
            let url = try XCTUnwrap(URL(string: request.url))
            if ["https://mangapanda.onl/manga/offline-panda", "https://mangapanda.onl/chapter/offline-panda/chapter-2.5"].contains(request.url), request.method == "GET" {
                return .init(finalURL: request.url, statusCode: 200,
                    headers: [.init(name: "Set-Cookie", value: "mhub_access=fixture-token; Path=/; Secure")],
                    body: Array("<html>Offline manga key fixture</html>".utf8))
            }
            if request.url == "https://mangapanda.onl/search", request.method == "GET" {
                let html = #"<a class="genre-label" href="/genre/drama">Drama</a><a class="genre-label" href="/genre/action">Action</a><a class="genre-label" href="/genre/drama">Drama</a>"#
                return .init(finalURL: request.url, statusCode: 200, body: Array(html.utf8))
            }
            if url.host == "mangapanda.onl", request.method == "GET",
               url.path.hasPrefix("/chapter/martial-peak/chapter-"),
               let number = Int(url.lastPathComponent.replacingOccurrences(of: "chapter-", with: "")),
               (1_000..<3_000).contains(number) {
                return .init(finalURL: request.url, statusCode: 200,
                    headers: [.init(name: "Set-Cookie", value: "mhub_access=fixture-token; Path=/; Secure")],
                    body: Array("<html>Offline key fixture</html>".utf8))
            }
            if request.url == "https://api.mghcdn.com/graphql", request.method == "POST" {
                XCTAssertEqual(request.headers.first(where: { $0.name.lowercased() == "x-mhub-access" })?.value, "fixture-token")
                XCTAssertNil(request.headers.first(where: { $0.name.lowercased() == "cookie" }), "Website cookies must not leak to the unrelated API origin")
                guard case let .text(body, _) = request.body,
                      let json = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
                      let query = json["query"] as? String else { throw CompatHTTPTransportError.invalidResponse }
                let response: String
                if query.contains("manga(") {
                    response = #"{"data":{"manga":{"title":"Offline Panda","slug":"offline-panda","status":"ongoing","image":"panda.jpg","author":"Ada","artist":"Ben","genres":"Action, Drama","description":"Offline description","alternativeTitle":"Other Panda; Another Panda","chapters":[{"number":1,"title":"Arrival","date":"2026-10-01T12:00:00Z"},{"number":2.5,"title":"Interlude","date":"2026-10-02T12:00:00Z"}]}}}"#
                } else if query.contains("chapter(") {
                    let pages = #"{"p":"offline-panda/chapter-2.5/","i":["1.jpg","2.jpg"]}"#
                    response = String(decoding: try JSONSerialization.data(withJSONObject: ["data": ["chapter": ["pages": pages, "mangaID": 42, "number": 2.5]]]), as: UTF8.self)
                } else {
                    XCTAssertTrue(query.contains("search("))
                    response = #"{"data":{"search":{"rows":[{"title":"Offline Panda","slug":"offline-panda","image":"panda.jpg"}]}}}"#
                }
                return .init(finalURL: request.url, statusCode: 200, headers: [.init(name: "Content-Type", value: "application/json")], body: Array(response.utf8))
            }
            if request.url == "https://api.ipify.org?format=json", request.method == "GET" {
                XCTAssertNil(request.headers.first(where: { $0.name.lowercased() == "cookie" }))
                return .init(finalURL: request.url, statusCode: 200, body: Array(#"{"ip":"192.0.2.1"}"#.utf8))
            }
            if request.url == "https://mangapanda.onl/action/logHistory2/offline-panda/2.5?browserID=192.0.2.1", request.method == "GET" {
                XCTAssertTrue(request.headers.contains(where: { $0.name.lowercased() == "cookie" && $0.value.contains("recently=") }))
                return .init(finalURL: request.url, statusCode: 200, body: Array("OK".utf8))
            }
            if request.url == "https://imgx.mghcdn.com/offline-panda/chapter-2.5/1.jpg", request.method == "GET" {
                XCTAssertNil(request.headers.first(where: { $0.name.lowercased() == "cookie" }))
                return .init(finalURL: request.url, statusCode: 200,
                    headers: [.init(name: "Content-Type", value: "image/png")], body: Self.imageBytes)
            }
            XCTFail("Unexpected offline fixture request: \(request.method) \(request.url)")
            throw CompatHTTPTransportError.invalidResponse
        }
        static let imageBytes = Array(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Z084AAAAASUVORK5CYII=")!)
    }
    private func apkBytes() throws -> [UInt8] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bytes = [UInt8](try Data(contentsOf: root.appendingPathComponent("Tests/corpus/measurement/mangapandaonl.apk")))
        return bytes
    }
    private func fixture() throws -> (ZipArchive, DexFile) {
        let bytes = try apkBytes()
        _ = try XCTUnwrap(bytes.count <= 64 * 1024 * 1024 && APKSignatureVerifier.apkSHA256(bytes)
            == "00ba5d0cfd65132b6feffee60b7c8d5eca23c4ce4bd5687c7908e6c9f15a3166" ? true : nil)
        let signature = try APKSignatureVerifier().verify(apkBytes: bytes)
        _ = try XCTUnwrap(signature.contains(fingerprint: "9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2") ? true : nil)
        let plan = try XCTUnwrap(InterpretedExtensionPlanInspector().inspect(apkBytes: bytes).plan)
        XCTAssertEqual(plan.packageName, "eu.kanade.tachiyomi.extension.en.mangapandaonl")
        XCTAssertEqual(plan.versionName, "1.6.36")
        let archive = try ZipArchive(bytes)
        return (archive, try DexFile(archive.data(named: "classes.dex")))
    }
    func testExactConstructionAndMetadataWithoutTransport() throws {
        let (archive, dex) = try fixture()
        let bridge = HostBridge.minimal(transport: RejectingTransport(), resources: try .localization(from: archive))
        let vm = DexInterpreter(dex: dex, bridge: bridge, maxInstructions: 100_000)
        let receiver = try vm.instantiate(classDescriptor: "Leu/kanade/tachiyomi/extension/en/mangapandaonl/ExtensionGenerated;")
        let id = try vm.callVirtualEntry(receiver: receiver, method: "getId", prototype: "()J", args: [receiver])
        guard case let .long(value) = id else { return XCTFail("Expected long source identity") }
        XCTAssertEqual(value, Int64(0x6a52d2d1fc303a8e))
        XCTAssertEqual(vmStringValue(try vm.callVirtualEntry(receiver: receiver, method: "getLang", prototype: "()Ljava/lang/String;", args: [receiver])), "en")
    }

    func testPopularThroughExactSourceWrapper() async throws {
        let (archive, dex) = try fixture()
        let transport = CatalogTransport()
        let bridge = HostBridge.minimal(transport: transport, resources: try .localization(from: archive))
        let vm = DexInterpreter(dex: dex, bridge: bridge, maxInstructions: 100_000)
        let receiver = try vm.instantiate(classDescriptor: "Leu/kanade/tachiyomi/extension/en/mangapandaonl/ExtensionGenerated;")
        let result = try await vm.callVirtualEntryAsync(receiver: receiver, method: "getPopularManga",
            prototype: "(ILkotlin/coroutines/Continuation;)Ljava/lang/Object;", args: [receiver, .int(1), .null])
        let page = try XCTUnwrap(HostBridge.mangasPageCompat(from: result))
        XCTAssertEqual(page.mangas.map(\.title), ["Offline Panda"])
        XCTAssertEqual(page.mangas.map(\.url), ["/manga/offline-panda"])
        XCTAssertFalse(page.hasNextPage)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testCancellationDuringKeyRefreshDoesNotPoisonSourceMutex() async throws {
        let (archive, dex) = try fixture()
        let transport = CatalogTransport(suspendFirstRequest: true)
        let bridge = HostBridge.minimal(transport: transport, transportPolicy: .init(requestTimeoutSeconds: 1), resources: try .localization(from: archive))
        let vm = DexInterpreter(dex: dex, bridge: bridge, maxInstructions: 100_000)
        let receiver = try vm.instantiate(classDescriptor: "Leu/kanade/tachiyomi/extension/en/mangapandaonl/ExtensionGenerated;")
        let task = Task {
            try await vm.callVirtualEntryAsync(receiver: receiver, method: "getPopularManga",
                prototype: "(ILkotlin/coroutines/Continuation;)Ljava/lang/Object;", args: [receiver, .int(1), .null])
        }
        for _ in 0..<500 {
            if await !transport.requests.isEmpty { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let started = await transport.requests
        XCTAssertEqual(started.count, 1)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation during refresh") }
        catch { guard case VMError.cancelled = error else { return XCTFail("\(error)") } }
        let result = try await vm.callVirtualEntryAsync(receiver: receiver, method: "getPopularManga",
            prototype: "(ILkotlin/coroutines/Continuation;)Ljava/lang/Object;", args: [receiver, .int(1), .null])
        XCTAssertEqual(HostBridge.mangasPageCompat(from: result)?.mangas.map(\.title), ["Offline Panda"])
        let retried = await transport.requests
        XCTAssertEqual(retried.count, 3)
    }

    func testLatestSearchAndMangaUpdateThroughExactSourceWrappers() async throws {
        let (archive, dex) = try fixture()
        let transport = CatalogTransport()
        let bridge = HostBridge.minimal(transport: transport, resources: try .localization(from: archive))
        let vm = DexInterpreter(dex: dex, bridge: bridge, maxInstructions: 200_000)
        let receiver = try vm.instantiate(classDescriptor: "Leu/kanade/tachiyomi/extension/en/mangapandaonl/ExtensionGenerated;")
        let filters = try vm.callVirtualEntry(receiver: receiver, method: "getFilterList",
            prototype: "()Leu/kanade/tachiyomi/source/model/FilterList;", args: [receiver])
        XCTAssertFalse(try XCTUnwrap(HostBridge.sourceFilters(from: filters)).isEmpty)
        let latest = try await vm.callVirtualEntryAsync(receiver: receiver, method: "getLatestUpdates",
            prototype: "(ILkotlin/coroutines/Continuation;)Ljava/lang/Object;", args: [receiver, .int(2), .null])
        XCTAssertEqual(HostBridge.mangasPageCompat(from: latest)?.mangas.map(\.title), ["Offline Panda"])
        let search = try await vm.callVirtualEntryAsync(receiver: receiver, method: "getSearchManga",
            prototype: "(ILjava/lang/String;Leu/kanade/tachiyomi/source/model/FilterList;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;",
            args: [receiver, .int(1), HostBridge.string("Panda"), filters, .null])
        let manga = try XCTUnwrap(HostBridge.mangasPageCompat(from: search)?.mangas.first)
        let update = try await vm.callVirtualEntryAsync(receiver: receiver, method: "getMangaUpdate",
            prototype: "(Leu/kanade/tachiyomi/source/model/SManga;Ljava/util/List;ZZLkotlin/coroutines/Continuation;)Ljava/lang/Object;",
            args: [receiver, HostBridge.mangaValue(from: manga), HostBridge.emptyListValue(), .int(1), .int(1), .null])
        let converted = try XCTUnwrap(HostBridge.mangaUpdateCompat(from: update))
        XCTAssertEqual(converted.manga.author, "Ada")
        XCTAssertEqual(converted.chapters.map(\.chapterNumber), [2.5, 1])
        XCTAssertEqual(converted.chapters.map(\.name), ["Chapter 2.5 - Interlude", "Chapter 1 - Arrival"])
        let chapter = try XCTUnwrap(converted.chapters.first)
        let result = try await vm.callVirtualEntryAsync(receiver: receiver, method: "getPageList",
            prototype: "(Leu/kanade/tachiyomi/source/model/SChapter;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;",
            args: [receiver, HostBridge.chapterValue(from: chapter), .null])
        XCTAssertEqual(HostBridge.pagesCompat(from: result)?.map(\.imageURL), [
            "https://imgx.mghcdn.com/offline-panda/chapter-2.5/1.jpg",
            "https://imgx.mghcdn.com/offline-panda/chapter-2.5/2.jpg",
        ])
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 7)
        let page = try XCTUnwrap(HostBridge.pagesCompat(from: result)?.first)
        // This APK inherits HttpSource's ordinary page URL/header behavior;
        // its own configured client still executes for the reader image.
        let headersValue = try XCTUnwrap(bridge.resolve(class: "Leu/kanade/tachiyomi/source/online/HttpSource;",
            "getHeaders", prototype: "()Lokhttp3/Headers;", isStatic: false))(vm, [receiver])
        let headers = try XCTUnwrap(HostBridge.imageHeaders(from: headersValue))
        let request = RVal.obj(ObjInstance(dexType: "Lokhttp3/Request;",
            payload: CompatHTTPRequest(url: try XCTUnwrap(page.imageURL), headers: headers.map { .init(name: $0.key, value: $0.value) }), isHost: true))
        let client = try vm.callVirtualEntry(receiver: receiver, method: "getClient",
            prototype: "()Lokhttp3/OkHttpClient;", args: [receiver])
        let image = try await bridge.executeImageRequest(requestValue: request, clientValue: client, vm: vm)
        XCTAssertEqual(image.body, CatalogTransport.imageBytes)
    }

    func testDynamicFiltersUseExactJobAndPersistedVirtualCache() async throws {
        let (archive, dex) = try fixture()
        let transport = CatalogTransport()
        let bridge = HostBridge.minimal(transport: transport, resources: try .localization(from: archive))
        let vm = DexInterpreter(dex: dex, bridge: bridge, maxInstructions: 200_000)
        let receiver = try vm.instantiate(classDescriptor: "Leu/kanade/tachiyomi/extension/en/mangapandaonl/ExtensionGenerated;")
        func getFilters() throws -> RVal {
            try vm.callVirtualEntry(receiver: receiver, method: "getFilterList",
                prototype: "()Leu/kanade/tachiyomi/source/model/FilterList;", args: [receiver])
        }
        _ = try getFilters()
        let job = try XCTUnwrap(bridge.firstPendingCoroutineJob)
        guard case let .obj(block) = job.block else { return XCTFail("Expected real DEX block") }
        XCTAssertEqual(block.dexType, "Lc1;")
        _ = try await vm.callAsync(classDescriptor: block.dexType, method: "invoke",
            prototype: "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;", args: [job.block, job.scope, .null])
        bridge.acknowledgeFirstPendingCoroutineJob()
        let value = try getFilters()
        let filters = try XCTUnwrap(HostBridge.sourceFilters(from: value))
        XCTAssertEqual(filters.map(\.name), ["Genres", "Order"])
        XCTAssertTrue(filters.contains { if case let .group(_, children) = $0 { return children.count == 2 }; return false }, "\(filters)")
        XCTAssertFalse(bridge.hasPendingCoroutineJobs)
        XCTAssertEqual(HostBridge.sourceFilters(from: try getFilters())?.count, filters.count)
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.url), ["https://mangapanda.onl/search"])
    }

    func testGuardAbortRequiresFreshSessionForMangaWrapperState() async throws {
        let (archive, dex) = try fixture()
        let transport = CatalogTransport(suspendRequest: 3)
        func session() throws -> (DexInterpreter, RVal) {
            let bridge = HostBridge.minimal(transport: transport, resources: try .localization(from: archive))
            let vm = DexInterpreter(dex: dex, bridge: bridge, maxInstructions: 200_000)
            return (vm, try vm.instantiate(classDescriptor: "Leu/kanade/tachiyomi/extension/en/mangapandaonl/ExtensionGenerated;"))
        }
        let (vm, receiver) = try session()
        let result = try await vm.callVirtualEntryAsync(receiver: receiver, method: "getPopularManga",
            prototype: "(ILkotlin/coroutines/Continuation;)Ljava/lang/Object;", args: [receiver, .int(1), .null])
        let manga = try XCTUnwrap(HostBridge.mangasPageCompat(from: result)?.mangas.first)
        func update(_ target: DexInterpreter, _ source: RVal) async throws -> RVal {
            try await target.callVirtualEntryAsync(receiver: source, method: "getMangaUpdate",
                prototype: "(Leu/kanade/tachiyomi/source/model/SManga;Ljava/util/List;ZZLkotlin/coroutines/Continuation;)Ljava/lang/Object;",
                args: [source, HostBridge.mangaValue(from: manga), HostBridge.emptyListValue(), .int(1), .int(1), .null])
        }
        let task = Task { try await update(vm, receiver) }
        for _ in 0..<500 {
            if await transport.requests.count == 3 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let started = await transport.requests
        XCTAssertEqual(started.count, 3)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected guard cancellation") }
        catch { guard case VMError.cancelled = error else { return XCTFail("\(error)") } }
        // A VM guard deliberately cannot execute arbitrary DEX catch/finally
        // code. Mutex cleanup alone cannot repair this wrapper's in-flight map.
        do { _ = try await update(vm, receiver); XCTFail("Expected stale wrapper guard") }
        catch let thrown as DEXThrowable {
            guard case let .obj(object) = thrown.value else { return XCTFail("\(thrown)") }
            XCTAssertEqual(object.dexType, "Ljava/lang/IllegalStateException;")
            XCTAssertEqual(object.payload as? String, "getMangaUpdate must not be called concurrently for same manga")
        }
        let (freshVM, freshReceiver) = try session()
        let fresh = try await update(freshVM, freshReceiver)
        XCTAssertEqual(HostBridge.mangaUpdateCompat(from: fresh)?.chapters.count, 2)
        let completed = await transport.requests
        XCTAssertEqual(completed.count, 5)
    }

    func testPinnedSourceFiltersCatalogDetailsPagesAndImageExecution() async throws {
        let transport = CatalogTransport()
        let source = try PinnedInterpretedSource.mangaPandaOnl1636(apkBytes: apkBytes(), transport: transport)
        XCTAssertEqual(source.id, 0x6a52d2d1fc303a8e)
        XCTAssertEqual(source.language, "en")
        XCTAssertEqual(source.baseURL, "https://mangapanda.onl")
        XCTAssertTrue(source.supportsLatest)
        XCTAssertTrue(source.supportsFilterFetching)
        let filters = try await source.refreshFilterList()
        XCTAssertEqual(filters.map(\.name), ["Genres", "Order"])
        var selected = filters
        for (index, filter) in filters.enumerated() {
            switch filter {
            case let .group(name, children):
                XCTAssertEqual(children.map(\.name), ["Action", "Drama"])
                selected[index] = .group(name: name, filters: children.map {
                    .checkBox(name: $0.name, state: $0.name == "Action")
                })
            case let .select(name, values, _):
                XCTAssertEqual(values, ["Popular", "Updates", "A-Z", "New", "Completed"])
                selected[index] = .select(name: name, values: values, state: 2)
            default: XCTFail("Unexpected filter")
            }
        }
        let searched = try await source.getSearchManga(page: 2, query: "Panda", filters: selected)
        let manga = try XCTUnwrap(searched.mangas.first)
        XCTAssertEqual(manga.title, "Offline Panda")
        let queries = await transport.requests.compactMap { request -> String? in
            guard case let .text(body, _) = request.body else { return nil }
            return body
        }
        let body = try XCTUnwrap(queries.last)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: String])
        let query = try XCTUnwrap(json["query"])
        XCTAssertTrue(query.contains("genre: \"action\""), query)
        XCTAssertTrue(query.contains("mod: ALPHABET"), query)
        XCTAssertTrue(query.contains("offset: 30"), query)
        let popular = try await source.getPopularManga(page: 1)
        let latest = try await source.getLatestUpdates(page: 2)
        XCTAssertEqual(popular.mangas.first?.url, manga.url)
        XCTAssertEqual(latest.mangas.first?.title, manga.title)
        let details = try await source.getMangaDetails(manga: manga)
        XCTAssertEqual(details.author, "Ada")
        let chapters = try await source.getChapterList(manga: manga)
        XCTAssertEqual(chapters.map(\.chapterNumber), [2.5, 1])
        XCTAssertEqual(chapters.map(\.url), ["/offline-panda/chapter-2.5", "/offline-panda/chapter-1.0"])
        let pages = try await source.getPageList(chapter: XCTUnwrap(chapters.first))
        XCTAssertEqual(pages.count, 2)
        let requestValue = await source.getImageRequest(page: try XCTUnwrap(pages.first))
        let request = try XCTUnwrap(requestValue)
        let response = try await request.executeSourceRequest()
        XCTAssertEqual(response?.body, CatalogTransport.imageBytes)
        XCTAssertTrue(source.compatibilityReport().findings.isEmpty)
    }

    func testPinnedCancellationRebuildsSourceAndRevokesOldImageCapabilities() async throws {
        let transport = CatalogTransport(suspendRequest: 4)
        let source = try PinnedInterpretedSource.mangaPandaOnl1636(apkBytes: apkBytes(), transport: transport)
        let previousFilters = try await source.refreshFilterList()
        let popular = try await source.getPopularManga(page: 1)
        let manga = try XCTUnwrap(popular.mangas.first)
        let page = PageCompat(index: 0, imageURL: "https://imgx.mghcdn.com/offline-panda/chapter-2.5/1.jpg")
        let oldValue = await source.getImageRequest(page: page)
        let old = try XCTUnwrap(oldValue)
        let task = Task { try await source.getMangaUpdate(manga: manga) }
        for _ in 0..<500 {
            if await transport.requests.count == 4 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let started = await transport.requests
        XCTAssertEqual(started.count, 4)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { guard case VMError.cancelled = error else { return XCTFail("\(error)") } }
        XCTAssertTrue(source.getFilterList().isEmpty)
        do { _ = try await old.executeSourceRequest(); XCTFail("Old image capability must be revoked") }
        catch { XCTAssertEqual(error as? PinnedInterpretedSourceError, .unexpectedResult(operation: "reader image request")) }
        let afterOld = await transport.requests
        XCTAssertEqual(afterOld.count, 4, "An old capability must fail before transport")
        do {
            _ = try await source.getSearchManga(page: 1, query: "Panda", filters: previousFilters)
            XCTFail("A discarded genre schema must not silently change the search")
        } catch { XCTAssertEqual(error as? PinnedInterpretedSourceError, .invalidInput(operation: "search filters")) }
        let afterOldFilters = await transport.requests
        XCTAssertEqual(afterOldFilters.count, 4)
        let retried = try await source.getMangaUpdate(manga: manga)
        XCTAssertEqual(retried.chapters.count, 2)
        XCTAssertFalse(source.getFilterList().isEmpty)
        let freshValue = await source.getImageRequest(page: page)
        let fresh = try XCTUnwrap(freshValue)
        let freshResponse = try await fresh.executeSourceRequest()
        XCTAssertEqual(freshResponse?.body, CatalogTransport.imageBytes)
        let freshFilters = try await source.refreshFilterList()
        XCTAssertEqual(freshFilters.map(\.name), previousFilters.map(\.name))
        guard case let .group(_, genres) = freshFilters.first else { return XCTFail("Expected refreshed genres") }
        XCTAssertEqual(genres.map(\.name), ["Action", "Drama"])
        let searched = try await source.getSearchManga(page: 1, query: "Panda", filters: freshFilters)
        XCTAssertEqual(searched.mangas.map(\.title), ["Offline Panda"])
    }

    func testQueuedPageRetryWaitsForCancelledTransportAndRebuildsAtEachCallbackBoundary() async throws {
        let bytes = try apkBytes()
        // Cold page execution: website cookie, GraphQL, IP callback, history
        // callback. Exercise guard unwinding at each real APK boundary.
        for suspendedRequest in 1...4 {
            let transport = CatalogTransport(suspendRequest: suspendedRequest, holdCancellation: true)
            let source = try PinnedInterpretedSource.mangaPandaOnl1636(apkBytes: bytes, transport: transport)
            let chapter = SChapterCompat(url: "/offline-panda/chapter-2.5", name: "Chapter 2.5", chapterNumber: 2.5)
            let first = Task { try await source.getPageList(chapter: chapter) }
            for _ in 0..<1_000 {
                if await transport.requests.count == suspendedRequest { break }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            let started = await transport.requests.count
            XCTAssertEqual(started, suspendedRequest)
            let queued = Task { try await source.getPageList(chapter: chapter) }
            first.cancel()
            for _ in 0..<100 { await Task.yield() }
            let whileDraining = await transport.requests.count
            XCTAssertEqual(whileDraining, started, "The queued VM must wait until cancelled host work drains")
            await transport.releaseHeldRequest()
            do { _ = try await first.value; XCTFail("Expected cancellation at request \(suspendedRequest)") }
            catch {
                guard case VMError.cancelled = error else { return XCTFail("\(error)") }
            }
            let pages = try await queued.value
            XCTAssertEqual(pages.map(\.imageURL), [
                "https://imgx.mghcdn.com/offline-panda/chapter-2.5/1.jpg",
                "https://imgx.mghcdn.com/offline-panda/chapter-2.5/2.jpg",
            ])
            let completed = await transport.requests.count
            XCTAssertEqual(completed, suspendedRequest + 4, "Retry must start from a fresh source session")
        }
    }
}
