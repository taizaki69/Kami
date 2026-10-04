import Foundation
import XCTest
@testable import MihonCompatKit

final class FoolSlideBoundaryTests: XCTestCase {
    private static let profile = "foolslide-1.6.6"
    private static let package = "eu.kanade.tachiyomi.extension.all.foolslidecustomizable"

    private actor RecordingTransport: CompatHTTPTransport {
        nonisolated let sourceID = "foolslide-boundary-test"
        private var requests: [CompatHTTPRequest] = []

        func execute(_ request: CompatHTTPRequest) async throws -> CompatHTTPResponse {
            requests.append(request)
            XCTFail("a rejected boundary input must not reach transport")
            return CompatHTTPResponse(finalURL: request.url, statusCode: 500)
        }

        func requestCount() -> Int { requests.count }
    }

    private func apkBytes(_ path: String = "measurement/foolslidecustomizable.apk") throws -> [UInt8] {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let url = root.appendingPathComponent("Tests/corpus/" + path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("locked corpus APK absent; run scripts/fetch_corpus.sh")
        }
        return [UInt8](try Data(contentsOf: url))
    }

    private func configuredPreferences() throws -> InterpretedExtensionPreferences {
        try .init(
            strings: [
                "overrideBaseUrl": "https://foolslide.test",
                "defaultBaseUrl": "https://127.0.0.1",
            ],
            booleans: ["adult": false]
        )
    }

    func testExactProfileIdentityDoesNotAuthorizeAnotherRelease() {
        XCTAssertEqual(InterpretedExtensionProfileCatalog.expectedSourceIDs(
            packageName: Self.package, versionName: "1.6.6", versionCode: 6
        ), [6_351_052_922_295_965_587])

        for identity in [
            (Self.package, "1.6.7", Int64(7)),
            (Self.package, "1.6.6", Int64(7)),
            (Self.package + ".other", "1.6.6", Int64(6)),
        ] {
            XCTAssertFalse(InterpretedExtensionProfileCatalog.supports(
                packageName: identity.0, versionName: identity.1, versionCode: identity.2
            ))
            XCTAssertNil(InterpretedExtensionProfileCatalog.expectedSourceIDs(
                packageName: identity.0, versionName: identity.1, versionCode: identity.2
            ))
        }
    }

    func testTamperingAndAnotherSignedProfileFailBeforeTransport() async throws {
        let transport = RecordingTransport()
        var tampered = try apkBytes()
        tampered[tampered.count / 2] ^= 0x01
        for bytes in [tampered, try apkBytes("batcave.apk")] {
            XCTAssertThrowsError(try PinnedInterpretedSource.foolSlideCustomizable166(
                apkBytes: bytes,
                transport: transport,
                preferences: configuredPreferences()
            )) { error in
                XCTAssertEqual(error as? PinnedInterpretedSourceError,
                               .apkDigestMismatch(profile: Self.profile))
            }
        }
        let count = await transport.requestCount()
        XCTAssertEqual(count, 0)
    }

    func testEmptyAndOversizedAPKsFailAtTheSizeGate() async throws {
        let transport = RecordingTransport()
        for bytes in [[], [UInt8](repeating: 0, count: 64 * 1024 * 1024 + 1)] {
            XCTAssertThrowsError(try PinnedInterpretedSource.foolSlideCustomizable166(
                apkBytes: bytes,
                transport: transport,
                preferences: configuredPreferences()
            )) { error in
                XCTAssertEqual(error as? PinnedInterpretedSourceError,
                               .invalidAPKSize(profile: Self.profile))
            }
        }
        let count = await transport.requestCount()
        XCTAssertEqual(count, 0)
    }

    func testURLPreferencesRejectMalformedAuthorityAndRequestComponents() async throws {
        let bytes = try apkBytes()
        let transport = RecordingTransport()
        let invalidURLs = [
            "", "https://", "https:///reader", "https://?missing-host",
            "http://foolslide.test", "file:///reader",
            "https://user:password@foolslide.test", "https://user@foolslide.test",
            "https://foolslide.test/?token=value", "https://foolslide.test/#fragment",
            "https://foolslide.test/\nreader", "https://foolslide.test/\u{00}reader",
        ]
        for key in ["overrideBaseUrl", "defaultBaseUrl"] {
            for url in invalidURLs {
                var strings = try configuredPreferences().strings
                strings[key] = url
                let preferences = try InterpretedExtensionPreferences(strings: strings)
                XCTAssertThrowsError(try PinnedInterpretedSource.foolSlideCustomizable166(
                    apkBytes: bytes, transport: transport, preferences: preferences
                ), "must reject \(key) with an invalid URL") { error in
                    XCTAssertEqual(error as? PinnedInterpretedSourceError,
                                   .invalidPreferences(profile: Self.profile))
                }
            }
        }
        let count = await transport.requestCount()
        XCTAssertEqual(count, 0)
    }

    func testPreferencesCannotIntroduceUnmeasuredKeysOrScalarTypes() async throws {
        let bytes = try apkBytes()
        let transport = RecordingTransport()
        let invalid = [
            try InterpretedExtensionPreferences(strings: ["unexpected": "value"]),
            try InterpretedExtensionPreferences(booleans: ["unexpected": true]),
            try InterpretedExtensionPreferences(strings: ["adult": "false"]),
            try InterpretedExtensionPreferences(booleans: ["overrideBaseUrl": true]),
        ]
        for preferences in invalid {
            XCTAssertThrowsError(try PinnedInterpretedSource.foolSlideCustomizable166(
                apkBytes: bytes, transport: transport, preferences: preferences
            )) { error in
                XCTAssertEqual(error as? PinnedInterpretedSourceError,
                               .invalidPreferences(profile: Self.profile))
            }
        }
        let count = await transport.requestCount()
        XCTAssertEqual(count, 0)
    }

    func testInvalidSourceInputsAndUnmeasuredFiltersFailBeforeTransport() async throws {
        let transport = RecordingTransport()
        let source = try PinnedInterpretedSource.foolSlideCustomizable166(
            apkBytes: apkBytes(), transport: transport, preferences: configuredPreferences()
        )
        do {
            _ = try await source.getSearchManga(page: 1, query: "term", filters: [.header("unmeasured")])
            XCTFail("expected a filter rejection")
        } catch {
            XCTAssertEqual(error as? PinnedInterpretedSourceError,
                           .unsupportedOperation("filtered search"))
        }
        do {
            _ = try await source.getSearchManga(
                page: 1, query: String(repeating: "x", count: 4_097), filters: []
            )
            XCTFail("expected an oversized query rejection")
        } catch {
            XCTAssertEqual(error as? PinnedInterpretedSourceError, .invalidInput(operation: "search"))
        }
        do {
            _ = try await source.getMangaDetails(manga: SMangaCompat(url: "", title: ""))
            XCTFail("expected an empty manga URL rejection")
        } catch {
            XCTAssertEqual(error as? PinnedInterpretedSourceError,
                           .invalidInput(operation: "manga update"))
        }
        do {
            _ = try await source.getPageList(chapter: SChapterCompat(
                url: String(repeating: "x", count: 8_193), name: "chapter"
            ))
            XCTFail("expected an oversized chapter URL rejection")
        } catch {
            XCTAssertEqual(error as? PinnedInterpretedSourceError, .invalidInput(operation: "page list"))
        }
        for url in [
            "http://images.test/page.jpg", "file:///page.jpg",
            "https://user:password@images.test/page.jpg",
            "https://images.test/" + String(repeating: "x", count: 8_193),
        ] {
            let request = await source.getImageRequest(page: PageCompat(index: 0, imageURL: url))
            XCTAssertNil(request)
        }
        let count = await transport.requestCount()
        XCTAssertEqual(count, 0)
        XCTAssertTrue(source.compatibilityReport().findings.isEmpty)
    }

    func testDetachedElementsConsumeTheSharedNodeBudget() throws {
        let (vm, bridge) = try makeVM(htmlPolicy: .init(maximumNodes: 6))
        let document = try parse("", vm: vm, bridge: bridge)
        guard case let .obj(object) = document,
              let box = object.payload as? CompatHTMLElementBox else {
            return XCTFail("expected a document context")
        }
        let remaining = 6 - box.context.nodeCount
        XCTAssertGreaterThan(remaining, 0)
        for _ in 0..<remaining {
            _ = try createElement(document, tag: "a", vm: vm, bridge: bridge)
        }
        assertHTMLLimit(.tooManyNodes(limit: 6)) {
            try self.createElement(document, tag: "a", vm: vm, bridge: bridge)
        }
    }

    func testAttributeMutationSharesGlobalBudgetAndReplacementDoesNotConsumeIt() throws {
        let (vm, bridge) = try makeVM(htmlPolicy: .init(
            maximumAttributes: 2, maximumAttributesPerElement: 4
        ))
        let document = try parse(#"<p data-first="initial"></p>"#, vm: vm, bridge: bridge)
        let paragraph = try selectFirst(document, query: "p", vm: vm, bridge: bridge)
        _ = try setAttribute(paragraph, key: "data-second", value: "accepted", vm: vm, bridge: bridge)
        for value in ["replacement", "again"] {
            _ = try setAttribute(paragraph, key: "data-first", value: value, vm: vm, bridge: bridge)
        }
        let detached = try createElement(document, tag: "a", vm: vm, bridge: bridge)
        assertHTMLLimit(.tooManyAttributes(limit: 2)) {
            try self.setAttribute(detached, key: "data-third", value: "rejected", vm: vm, bridge: bridge)
        }
        XCTAssertEqual(try attribute(detached, key: "data-third", vm: vm, bridge: bridge), "")
        XCTAssertEqual(try attribute(paragraph, key: "data-first", vm: vm, bridge: bridge), "again")
    }

    func testAttributeMutationRejectsOversizedValuesAndPerElementOverflowAtomically() throws {
        let (vm, bridge) = try makeVM(htmlPolicy: .init(
            maximumAttributesPerElement: 1, maximumExtractedStringBytes: 4
        ))
        let document = try parse(#"<p a="old"></p>"#, vm: vm, bridge: bridge)
        let paragraph = try selectFirst(document, query: "p", vm: vm, bridge: bridge)
        _ = try setAttribute(paragraph, key: "a", value: "four", vm: vm, bridge: bridge)
        XCTAssertThrowsError(try setAttribute(
            paragraph, key: "a", value: "large", vm: vm, bridge: bridge
        ))
        assertHTMLLimit(.tooManyAttributesOnElement(limit: 1)) {
            try self.setAttribute(paragraph, key: "b", value: "new", vm: vm, bridge: bridge)
        }
        XCTAssertEqual(try attribute(paragraph, key: "a", vm: vm, bridge: bridge), "four")
        XCTAssertEqual(try attribute(paragraph, key: "b", vm: vm, bridge: bridge), "")
    }

    func testTextSiblingAndDocumentSerializationCannotExceedStringLimit() throws {
        let (vm, bridge) = try makeVM(htmlPolicy: .init(maximumExtractedStringBytes: 4))
        let document = try parse("<b>A</b>abcdef", vm: vm, bridge: bridge)
        let bold = try selectFirst(document, query: "b", vm: vm, bridge: bridge)
        let sibling = try invoke(bridge, vm, class: "Lorg/jsoup/nodes/Element;", "nextSibling",
                                 prototype: "()Lorg/jsoup/nodes/Node;", args: [bold])
        assertHTMLLimit(.extractedStringTooLarge(limit: 4)) {
            try self.invoke(bridge, vm, class: "Lorg/jsoup/nodes/TextNode;", "text",
                            prototype: "()Ljava/lang/String;", args: [sibling])
        }
        assertHTMLLimit(.extractedStringTooLarge(limit: 4)) {
            try self.invoke(bridge, vm, class: "Lorg/jsoup/nodes/Document;", "toString",
                            prototype: "()Ljava/lang/String;", args: [document])
        }
    }

    func testDetachedElementCannotResetSelectorBudget() throws {
        let (vm, bridge) = try makeVM(htmlPolicy: .init(maximumSelectorWork: 6))
        let document = try parse("<p>ok</p>", vm: vm, bridge: bridge)
        _ = try selectFirst(document, query: "p", vm: vm, bridge: bridge)
        let detached = try createElement(document, tag: "a", vm: vm, bridge: bridge)
        assertHTMLLimit(.selectorBudgetExceeded(limit: 6)) {
            try self.invoke(bridge, vm, class: "Lorg/jsoup/nodes/Element;", "select",
                            prototype: "(Ljava/lang/String;)Lorg/jsoup/select/Elements;",
                            args: [detached, HostBridge.string("a")])
        }
    }

    func testHTMLMutationBudgetAccumulatesAcrossAttributeReplacement() throws {
        let (vm, bridge) = try makeVM(htmlPolicy: .init(maximumMutationBytes: 4))
        let document = try parse("", vm: vm, bridge: bridge)
        let detached = try createElement(document, tag: "a", vm: vm, bridge: bridge)
        _ = try setAttribute(detached, key: "x", value: "ok", vm: vm, bridge: bridge)
        assertHTMLLimit(.mutationBudgetExceeded(limit: 4)) {
            try self.setAttribute(detached, key: "x", value: "no", vm: vm, bridge: bridge)
        }
        XCTAssertEqual(try attribute(detached, key: "x", vm: vm, bridge: bridge), "ok")
    }

    func testRejectedRequestMethodLeavesThePriorRequestIntact() throws {
        let (vm, bridge) = try makeVM()
        let builder = RVal.obj(ObjInstance(dexType: "Lokhttp3/Request$Builder;", isHost: true))
        _ = try invoke(bridge, vm, class: "Lokhttp3/Request$Builder;", "<init>",
                       prototype: "()V", args: [builder])
        let companion = try XCTUnwrap(bridge.staticFields["Lokhttp3/HttpUrl;->Companion"])
        let url = try invoke(bridge, vm, class: "Lokhttp3/HttpUrl$Companion;", "get",
                             prototype: "(Ljava/lang/String;)Lokhttp3/HttpUrl;",
                             args: [companion, HostBridge.string("https://foolslide.test/reader")])
        _ = try invoke(bridge, vm, class: "Lokhttp3/Request$Builder;", "url",
                       prototype: "(Lokhttp3/HttpUrl;)Lokhttp3/Request$Builder;", args: [builder, url])
        let body = RVal.obj(ObjInstance(
            dexType: "Lokhttp3/RequestBody;",
            payload: CompatHTTPRequestBody.text(value: "body", mediaType: "text/plain"), isHost: true
        ))
        for (method, invalidBody) in [
            ("DELETE", HostBridge.string("not a RequestBody")),
            ("GET", body), ("HEAD", body), ("POST", RVal.null),
            ("INVALID METHOD", RVal.null),
        ] {
            XCTAssertThrowsError(try invoke(bridge, vm, class: "Lokhttp3/Request$Builder;", "method",
                                           prototype: "(Ljava/lang/String;Lokhttp3/RequestBody;)Lokhttp3/Request$Builder;",
                                           args: [builder, HostBridge.string(method), invalidBody]))
            let request = try invoke(bridge, vm, class: "Lokhttp3/Request$Builder;", "build",
                                     prototype: "()Lokhttp3/Request;", args: [builder])
            guard case let .obj(object) = request,
                  let projected = object.payload as? CompatHTTPRequest else {
                return XCTFail("expected a bounded request projection")
            }
            XCTAssertEqual(projected.method, "GET")
            XCTAssertNil(projected.body)
            XCTAssertEqual(projected.url, "https://foolslide.test/reader")
        }
    }

    private func makeVM(htmlPolicy: CompatHTMLPolicy = .init()) throws -> (DexInterpreter, HostBridge) {
        var builder = DexBuilder()
        builder.setClass("LFoolSlideBoundary;")
        builder.addMethod(.init(name: "noop", registers: 0, ins: 0, outs: 0,
                                insns: [0x000e], isStatic: true))
        let bridge = HostBridge.minimal(htmlPolicy: htmlPolicy)
        return (DexInterpreter(dex: try DexFile(builder.build()), bridge: bridge), bridge)
    }

    private func invoke(_ bridge: HostBridge, _ vm: DexInterpreter, class descriptor: String,
                        _ name: String, prototype: String, isStatic: Bool = false,
                        args: [RVal]) throws -> RVal {
        let method = try XCTUnwrap(bridge.resolve(class: descriptor, name,
                                                 prototype: prototype, isStatic: isStatic))
        return try method(vm, args)
    }

    private func parse(_ html: String, vm: DexInterpreter, bridge: HostBridge) throws -> RVal {
        try invoke(bridge, vm, class: "Lorg/jsoup/Jsoup;", "parseBodyFragment",
                   prototype: "(Ljava/lang/String;Ljava/lang/String;)Lorg/jsoup/nodes/Document;",
                   isStatic: true, args: [HostBridge.string(html), HostBridge.string("https://foolslide.test")])
    }

    private func selectFirst(_ document: RVal, query: String,
                             vm: DexInterpreter, bridge: HostBridge) throws -> RVal {
        try invoke(bridge, vm, class: "Lorg/jsoup/nodes/Document;", "selectFirst",
                   prototype: "(Ljava/lang/String;)Lorg/jsoup/nodes/Element;",
                   args: [document, HostBridge.string(query)])
    }

    private func createElement(_ document: RVal, tag: String,
                              vm: DexInterpreter, bridge: HostBridge) throws -> RVal {
        try invoke(bridge, vm, class: "Lorg/jsoup/nodes/Document;", "createElement",
                   prototype: "(Ljava/lang/String;)Lorg/jsoup/nodes/Element;",
                   args: [document, HostBridge.string(tag)])
    }

    private func setAttribute(_ element: RVal, key: String, value: String,
                             vm: DexInterpreter, bridge: HostBridge) throws -> RVal {
        try invoke(bridge, vm, class: "Lorg/jsoup/nodes/Element;", "attr",
                   prototype: "(Ljava/lang/String;Ljava/lang/String;)Lorg/jsoup/nodes/Element;",
                   args: [element, HostBridge.string(key), HostBridge.string(value)])
    }

    private func attribute(_ element: RVal, key: String,
                          vm: DexInterpreter, bridge: HostBridge) throws -> String {
        vmStringValue(try invoke(bridge, vm, class: "Lorg/jsoup/nodes/Element;", "attr",
                                prototype: "(Ljava/lang/String;)Ljava/lang/String;",
                                args: [element, HostBridge.string(key)]))
    }

    private func assertHTMLLimit(_ expected: CompatHTMLError, file: StaticString = #filePath,
                                 line: UInt = #line, _ body: () throws -> RVal) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard let throwable = error as? DEXThrowable,
                  case let .obj(object) = throwable.value else {
                return XCTFail("expected a typed HTML boundary throwable", file: file, line: line)
            }
            XCTAssertEqual(object.dexType, "Ljava/lang/IllegalArgumentException;", file: file, line: line)
            XCTAssertEqual(object.payload as? String, expected.description, file: file, line: line)
        }
    }
}
