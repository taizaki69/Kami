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
            guard case let VMError.unresolvedMethod(classDescriptor, signature) = error else {
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
