import Foundation
import XCTest
@testable import MihonCompatKit

/// Shared by injected and URLSession-backed tests. Every operation uses the
/// registered host ABI; HTTP executes through a real synthetic DEX caller.
final class CookieBridgeFixture {
    let bridge: HostBridge
    let vm: DexInterpreter
    var client: RVal = .null

    init(transport: any CompatHTTPTransport, policy: CompatHTTPTransportPolicy = .init()) throws {
        var dex = DexBuilder()
        let awaitSuccess = dex.method(classDescriptor: "Leu/kanade/tachiyomi/network/OkHttpExtensionsKt;",
            name: "awaitSuccess", shorty: "LLL", ret: "Ljava/lang/Object;",
            parameters: ["Lokhttp3/Call;", "Lkotlin/coroutines/Continuation;"])
        dex.setClass("LCookieTest;")
        dex.addMethod(.init(name: "run", registers: 2, ins: 2, outs: 2,
            insns: Insn.invokeStatic(awaitSuccess, [0, 1]) + Insn.moveResultObject(0) + Insn.returnObjectReg(0),
            isStatic: true, returnType: "Ljava/lang/Object;", parameters: ["Lokhttp3/Call;", "Lkotlin/coroutines/Continuation;"]))
        bridge = HostBridge.minimal(transport: transport, transportPolicy: policy)
        vm = DexInterpreter(dex: try DexFile(dex.build()), bridge: bridge)
        let source = RVal.obj(ObjInstance(dexType: "LCookieTest;"))
        let helper = try invoke("Leu/kanade/tachiyomi/source/online/HttpSource;", "getNetwork", "()Leu/kanade/tachiyomi/network/NetworkHelper;", [source])
        client = try invoke("Leu/kanade/tachiyomi/network/NetworkHelper;", "getClient", "()Lokhttp3/OkHttpClient;", [helper])
    }

    @discardableResult
    func invoke(_ type: String, _ name: String, _ prototype: String, _ args: [RVal], isStatic: Bool = false) throws -> RVal {
        try XCTUnwrap(bridge.resolve(class: type, name, prototype: prototype, isStatic: isStatic))(vm, args)
    }

    func httpURL(_ url: String) throws -> RVal {
        let companion = try XCTUnwrap(bridge.staticFields["Lokhttp3/HttpUrl;->Companion"])
        return try invoke("Lokhttp3/HttpUrl$Companion;", "get", "(Ljava/lang/String;)Lokhttp3/HttpUrl;", [companion, HostBridge.string(url)])
    }

    func parse(_ header: String, url: String) throws -> RVal {
        let companion = try XCTUnwrap(bridge.staticFields["Lokhttp3/Cookie;->Companion"])
        return try invoke("Lokhttp3/Cookie$Companion;", "parse", "(Lokhttp3/HttpUrl;Ljava/lang/String;)Lokhttp3/Cookie;",
            [companion, httpURL(url), HostBridge.string(header)])
    }

    func jar() throws -> RVal { try invoke("Lokhttp3/OkHttpClient;", "cookieJar", "()Lokhttp3/CookieJar;", [client]) }

    func save(_ cookie: RVal, url: String) throws {
        let list = try invoke("Lkotlin/collections/CollectionsKt;", "listOf", "(Ljava/lang/Object;)Ljava/util/List;", [cookie], isStatic: true)
        try invoke("Lokhttp3/CookieJar;", "saveFromResponse", "(Lokhttp3/HttpUrl;Ljava/util/List;)V", [jar(), httpURL(url), list])
    }

    func cookies(url: String) throws -> [String] {
        let list = try invoke("Lokhttp3/CookieJar;", "loadForRequest", "(Lokhttp3/HttpUrl;)Ljava/util/List;", [jar(), httpURL(url)])
        guard case let .int(count) = try invoke("Ljava/util/List;", "size", "()I", [list]) else { throw VMError.verify("test list size") }
        return try (0..<count).map { index in
            let item = try invoke("Ljava/util/List;", "get", "(I)Ljava/lang/Object;", [list, .int(index)])
            return try vmStringValue(invoke("Lokhttp3/Cookie;", "name", "()Ljava/lang/String;", [item])) + "="
                + vmStringValue(invoke("Lokhttp3/Cookie;", "value", "()Ljava/lang/String;", [item]))
        }
    }

    @discardableResult
    func execute(_ request: CompatHTTPRequest) async throws -> RVal {
        let value = RVal.obj(ObjInstance(dexType: "Lokhttp3/Request;", payload: request, isHost: true))
        let call = try invoke("Lokhttp3/OkHttpClient;", "newCall", "(Lokhttp3/Request;)Lokhttp3/Call;", [client, value])
        return try await vm.callAsync(classDescriptor: "LCookieTest;", method: "run", prototype: "(Lokhttp3/Call;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;", args: [call, .null])
    }
}

final class CookieHostContractTests: XCTestCase {
    private actor Transport: CompatHTTPTransport {
        nonisolated let sourceID = "cookie-host-fixture"
        private(set) var requests: [CompatHTTPRequest] = []
        func execute(_ request: CompatHTTPRequest) async throws -> CompatHTTPResponse {
            requests.append(request)
            return .init(finalURL: request.url, statusCode: 200, headers: requests.count == 1 ? [.init(name: "Set-Cookie", value: "response=one; Path=/; Secure")] : [])
        }
    }

    func testInjectedTransportSharesDEXJarAcrossDerivedClientsAndDeletion() async throws {
        let transport = Transport(), target = "https://example.com/image"
        let fixture = try CookieBridgeFixture(transport: transport)
        let firstJar = try fixture.jar()
        try fixture.save(fixture.parse("dex=one; Path=/; Secure", url: target), url: target)
        try await fixture.execute(.init(url: target))
        XCTAssertEqual(try fixture.cookies(url: target), ["dex=one", "response=one"])
        let builder = try fixture.invoke("Lokhttp3/OkHttpClient;", "newBuilder", "()Lokhttp3/OkHttpClient$Builder;", [fixture.client])
        fixture.client = try fixture.invoke("Lokhttp3/OkHttpClient$Builder;", "build", "()Lokhttp3/OkHttpClient;", [builder])
        XCTAssertTrue(firstJar === (try fixture.jar()))
        try fixture.save(fixture.parse("dex=; Max-Age=0; Path=/", url: target), url: target)
        try await fixture.execute(.init(url: target))
        let requests = await transport.requests
        XCTAssertEqual(requests.map { $0.headers.first(where: { $0.name == "Cookie" })?.value }, ["dex=one", "response=one"])
        let isolated = try CookieBridgeFixture(transport: Transport())
        XCTAssertTrue(try isolated.cookies(url: target).isEmpty)
    }

    func testBuilderRequiresFieldsReturnsImmutableCookiesAndClampsExpiry() throws {
        let fixture = try CookieBridgeFixture(transport: Transport())
        let type = "Lokhttp3/Cookie$Builder;"
        let builder = try XCTUnwrap(fixture.bridge.objectFactories[type])(fixture.vm)
        try fixture.invoke(type, "<init>", "()V", [builder])
        XCTAssertThrowsError(try fixture.invoke(type, "build", "()Lokhttp3/Cookie;", [builder]))
        for (key, input) in [("name", "manual"), ("value", "old"), ("hostOnlyDomain", "EXAMPLE.com"), ("path", "/foo")] {
            let returned = try fixture.invoke(type, key, "(Ljava/lang/String;)Lokhttp3/Cookie$Builder;", [builder, HostBridge.string(input)])
            XCTAssertTrue(returned === builder)
        }
        let original = try fixture.invoke(type, "build", "()Lokhttp3/Cookie;", [builder])
        try fixture.invoke(type, "value", "(Ljava/lang/String;)Lokhttp3/Cookie$Builder;", [builder, HostBridge.string("new")])
        try fixture.invoke(type, "expiresAt", "(J)Lokhttp3/Cookie$Builder;", [builder, .long(Int64.max)])
        let newer = try fixture.invoke(type, "build", "()Lokhttp3/Cookie;", [builder])
        XCTAssertEqual(vmStringValue(try fixture.invoke("Lokhttp3/Cookie;", "value", "()Ljava/lang/String;", [original])), "old")
        XCTAssertEqual(vmStringValue(try fixture.invoke("Lokhttp3/Cookie;", "value", "()Ljava/lang/String;", [newer])), "new")
        guard case let .long(expiry) = try fixture.invoke("Lokhttp3/Cookie;", "expiresAt", "()J", [newer]) else { return XCTFail("Expected long expiry") }
        XCTAssertEqual(expiry, CompatHTTPCookie.maximumExpiry)
        try fixture.save(newer, url: "https://example.com/foo/bar")
        XCTAssertEqual(try fixture.cookies(url: "https://example.com/foo/bar"), ["manual=new"])
        XCTAssertTrue(try fixture.cookies(url: "https://sub.example.com/foo/bar").isEmpty)
        XCTAssertTrue(try fixture.cookies(url: "https://example.com/foobar").isEmpty)
        for (key, input) in [("name", " bad"), ("domain", "bad/host"), ("path", "no-slash"), ("value", String(repeating: "a", count: 8_193))] {
            XCTAssertThrowsError(try fixture.invoke(type, key, "(Ljava/lang/String;)Lokhttp3/Cookie$Builder;", [builder, HostBridge.string(input)]))
        }
    }

    func testInjectedTransportFailsBeforeDispatchWhenCookieExceedsHeaderBudget() async throws {
        let transport = Transport(), target = "https://example.com/"
        let fixture = try CookieBridgeFixture(transport: transport, policy: .init(maximumRequestHeaderBytes: 24))
        try fixture.save(fixture.parse("long=" + String(repeating: "x", count: 30), url: target), url: target)
        do { try await fixture.execute(.init(url: target)); XCTFail("Expected bounded rejection") }
        catch { XCTAssertTrue(error is DEXThrowable) }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testReachedKotlinTextOperationsAndNullableGeneratedDescriptor() throws {
        let fixture = try CookieBridgeFixture(transport: Transport())
        func text(_ name: String, _ inputs: [String]) throws -> String {
            let prototype = inputs.count == 1 ? "(Ljava/lang/String;)Ljava/lang/String;" : "(Ljava/lang/String;Ljava/lang/CharSequence;)Ljava/lang/String;"
            return vmStringValue(try fixture.invoke("Lkotlin/text/StringsKt;", name, prototype, inputs.map(HostBridge.string), isStatic: true))
        }
        XCTAssertEqual(try text("trimIndent", ["\r\n\t A\r\n\t   B\r\n\t\r\n\t C\r"]), "A\n  B\n\nC")
        XCTAssertEqual(try text("trimIndent", ["\n\n  A\n\n"]), "\nA\n")
        XCTAssertEqual(try text("trimIndent", ["\u{a0}A\n\u{a0}B"]), "A\nB")
        XCTAssertEqual(try text("trimIndent", ["\u{85}A\n B"]), "\u{85}A\n B")
        for (input, delimiter, expected) in [("***one***", "**", "*one*"), ("a", "a", "a"), ("abc", "", "abc"), ("🙂one🙂", "🙂", "one"), ("éoneé", "e\u{301}", "éoneé"), ("e\u{301}xe", "e", "\u{301}x")] {
            XCTAssertEqual(Array(try text("removeSurrounding", [input, delimiter]).utf16), Array(expected.utf16))
        }
        let descriptor = "Lkotlinx/serialization/internal/PluginGeneratedSerialDescriptor;"
        let value = try XCTUnwrap(fixture.bridge.objectFactories[descriptor])(fixture.vm)
        try fixture.invoke(descriptor, "<init>", "(Ljava/lang/String;Lkotlinx/serialization/internal/GeneratedSerializer;I)V", [value, HostBridge.string("NullableSerializer"), .null, .int(1)])
        try fixture.invoke(descriptor, "addElement", "(Ljava/lang/String;Z)V", [value, HostBridge.string("name"), .int(1)])
        XCTAssertEqual(vmStringValue(try fixture.invoke("Lkotlinx/serialization/descriptors/SerialDescriptor;", "getElementName", "(I)Ljava/lang/String;", [value, .int(0)])), "name")
        XCTAssertThrowsError(try fixture.invoke("Lkotlinx/serialization/descriptors/SerialDescriptor;", "getElementDescriptor", "(I)Lkotlinx/serialization/descriptors/SerialDescriptor;", [value, .int(0)]))
    }
}
