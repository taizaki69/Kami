import XCTest
@testable import MihonCompatKit

final class CompatHTTPRequestTests: XCTestCase {
    private func makeVM() throws -> (DexInterpreter, HostBridge) {
        var builder = DexBuilder()
        builder.setClass("LTest;")
        builder.addMethod(.init(
            name: "noop",
            registers: 0,
            ins: 0,
            outs: 0,
            insns: [0x000e],
            isStatic: true
        ))
        let bridge = HostBridge.minimal()
        return (DexInterpreter(dex: try DexFile(builder.build()), bridge: bridge), bridge)
    }

    private func invoke(_ bridge: HostBridge, _ vm: DexInterpreter,
                        class descriptor: String, _ name: String,
                        prototype: String, isStatic: Bool = false,
                        args: [RVal]) throws -> RVal {
        let method = try XCTUnwrap(bridge.resolve(
            class: descriptor,
            name,
            prototype: prototype,
            isStatic: isStatic
        ))
        return try method(vm, args)
    }

    func testHostBridgeBuildsTransportNeutralBoundedRequest() throws {
        let (vm, bridge) = try makeVM()
        let source = RVal.obj(ObjInstance(dexType: "LTestSource;"))

        let urlCompanion = try XCTUnwrap(bridge.staticFields["Lokhttp3/HttpUrl;->Companion"])
        let url = try invoke(
            bridge, vm,
            class: "Lokhttp3/HttpUrl$Companion;", "get",
            prototype: "(Ljava/lang/String;)Lokhttp3/HttpUrl;",
            args: [urlCompanion, HostBridge.string("https://example.test/manga?page=1")]
        )

        let headerBuilder = try invoke(
            bridge, vm,
            class: "Leu/kanade/tachiyomi/source/online/HttpSource;", "headersBuilder",
            prototype: "()Lokhttp3/Headers$Builder;",
            args: [source]
        )
        _ = try invoke(
            bridge, vm,
            class: "Lokhttp3/Headers$Builder;", "set",
            prototype: "(Ljava/lang/String;Ljava/lang/String;)Lokhttp3/Headers$Builder;",
            args: [headerBuilder, HostBridge.string("Accept"), HostBridge.string("text/html")]
        )
        let headers = try invoke(
            bridge, vm,
            class: "Lokhttp3/Headers$Builder;", "build",
            prototype: "()Lokhttp3/Headers;",
            args: [headerBuilder]
        )

        let formBuilder = RVal.obj(ObjInstance(dexType: "Lokhttp3/FormBody$Builder;", isHost: true))
        _ = try invoke(
            bridge, vm,
            class: "Lokhttp3/FormBody$Builder;", "<init>",
            prototype: "(Ljava/nio/charset/Charset;ILkotlin/jvm/internal/DefaultConstructorMarker;)V",
            args: [formBuilder, .null, .int(1), .null]
        )
        _ = try invoke(
            bridge, vm,
            class: "Lokhttp3/FormBody$Builder;", "add",
            prototype: "(Ljava/lang/String;Ljava/lang/String;)Lokhttp3/FormBody$Builder;",
            args: [formBuilder, HostBridge.string("page"), HostBridge.string("1")]
        )
        let body = try invoke(
            bridge, vm,
            class: "Lokhttp3/FormBody$Builder;", "build",
            prototype: "()Lokhttp3/FormBody;",
            args: [formBuilder]
        )

        let secondsUnit = try XCTUnwrap(bridge.staticFields["Lkotlin/time/DurationUnit;->SECONDS"])
        let duration = try invoke(
            bridge, vm,
            class: "Lkotlin/time/DurationKt;", "toDuration",
            prototype: "(ILkotlin/time/DurationUnit;)J",
            isStatic: true,
            args: [.int(30), secondsUnit]
        )
        let cacheBuilder = RVal.obj(ObjInstance(dexType: "Lokhttp3/CacheControl$Builder;", isHost: true))
        _ = try invoke(
            bridge, vm,
            class: "Lokhttp3/CacheControl$Builder;", "<init>",
            prototype: "()V",
            args: [cacheBuilder]
        )
        _ = try invoke(
            bridge, vm,
            class: "Lokhttp3/CacheControl$Builder;", "maxAge-LRDsOJo",
            prototype: "(J)Lokhttp3/CacheControl$Builder;",
            args: [cacheBuilder, duration]
        )
        let cache = try invoke(
            bridge, vm,
            class: "Lokhttp3/CacheControl$Builder;", "build",
            prototype: "()Lokhttp3/CacheControl;",
            args: [cacheBuilder]
        )

        let requestBuilder = RVal.obj(ObjInstance(dexType: "Lokhttp3/Request$Builder;", isHost: true))
        _ = try invoke(
            bridge, vm,
            class: "Lokhttp3/Request$Builder;", "<init>",
            prototype: "()V",
            args: [requestBuilder]
        )
        for (name, prototype, argument) in [
            ("url", "(Lokhttp3/HttpUrl;)Lokhttp3/Request$Builder;", url),
            ("headers", "(Lokhttp3/Headers;)Lokhttp3/Request$Builder;", headers),
            ("cacheControl", "(Lokhttp3/CacheControl;)Lokhttp3/Request$Builder;", cache),
            ("post", "(Lokhttp3/RequestBody;)Lokhttp3/Request$Builder;", body),
        ] {
            _ = try invoke(
                bridge, vm,
                class: "Lokhttp3/Request$Builder;", name,
                prototype: prototype,
                args: [requestBuilder, argument]
            )
        }
        let request = try invoke(
            bridge, vm,
            class: "Lokhttp3/Request$Builder;", "build",
            prototype: "()Lokhttp3/Request;",
            args: [requestBuilder]
        )

        let helper = try invoke(
            bridge, vm,
            class: "Leu/kanade/tachiyomi/source/online/HttpSource;", "getNetwork",
            prototype: "()Leu/kanade/tachiyomi/network/NetworkHelper;",
            args: [source]
        )
        let client = try invoke(
            bridge, vm,
            class: "Leu/kanade/tachiyomi/network/NetworkHelper;", "getClient",
            prototype: "()Lokhttp3/OkHttpClient;",
            args: [helper]
        )
        _ = try invoke(
            bridge, vm,
            class: "Lokhttp3/OkHttpClient;", "newCall",
            prototype: "(Lokhttp3/Request;)Lokhttp3/Call;",
            args: [client, request]
        )

        XCTAssertEqual(bridge.lastPreparedRequest, CompatHTTPRequest(
            url: "https://example.test/manga?page=1",
            method: "POST",
            headers: [CompatHTTPHeader(name: "Accept", value: "text/html")],
            body: .form(fields: [CompatHTTPFormField(name: "page", value: "1")]),
            cachePolicy: CompatHTTPCachePolicy(maxAgeSeconds: 30)
        ))
    }

    func testHostBridgeRejectsMalformedRequestInputs() throws {
        let (vm, bridge) = try makeVM()
        let urlCompanion = try XCTUnwrap(bridge.staticFields["Lokhttp3/HttpUrl;->Companion"])
        XCTAssertThrowsError(try invoke(
            bridge, vm,
            class: "Lokhttp3/HttpUrl$Companion;", "get",
            prototype: "(Ljava/lang/String;)Lokhttp3/HttpUrl;",
            args: [urlCompanion, HostBridge.string("file:///private/secret")]
        ))

        let source = RVal.obj(ObjInstance(dexType: "LTestSource;"))
        let headerBuilder = try invoke(
            bridge, vm,
            class: "Leu/kanade/tachiyomi/source/online/HttpSource;", "headersBuilder",
            prototype: "()Lokhttp3/Headers$Builder;",
            args: [source]
        )
        XCTAssertThrowsError(try invoke(
            bridge, vm,
            class: "Lokhttp3/Headers$Builder;", "set",
            prototype: "(Ljava/lang/String;Ljava/lang/String;)Lokhttp3/Headers$Builder;",
            args: [headerBuilder, HostBridge.string("X-Test"), HostBridge.string("ok\r\nInjected: yes")]
        ))

        let formBuilder = RVal.obj(ObjInstance(dexType: "Lokhttp3/FormBody$Builder;", isHost: true))
        _ = try invoke(
            bridge, vm,
            class: "Lokhttp3/FormBody$Builder;", "<init>",
            prototype: "(Ljava/nio/charset/Charset;ILkotlin/jvm/internal/DefaultConstructorMarker;)V",
            args: [formBuilder, .null, .int(1), .null]
        )
        XCTAssertThrowsError(try invoke(
            bridge, vm,
            class: "Lokhttp3/FormBody$Builder;", "add",
            prototype: "(Ljava/lang/String;Ljava/lang/String;)Lokhttp3/FormBody$Builder;",
            args: [formBuilder, HostBridge.string("payload"), HostBridge.string(String(repeating: "x", count: 1_048_577))]
        ))
        XCTAssertNil(bridge.lastPreparedRequest)
    }

    func testURLFormEncoderMatchesJavaUTF8SemanticsAndIsBounded() throws {
        let (vm, bridge) = try makeVM()
        let encoded = try invoke(
            bridge, vm,
            class: "Ljava/net/URLEncoder;", "encode",
            prototype: "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;",
            isStatic: true,
            args: [HostBridge.string("A b+c/é~*"), HostBridge.string("UTF-8")]
        )
        XCTAssertEqual(vmStringValue(encoded), "A+b%2Bc%2F%C3%A9%7E*")

        XCTAssertThrowsError(try invoke(
            bridge, vm,
            class: "Ljava/net/URLEncoder;", "encode",
            prototype: "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;",
            isStatic: true,
            args: [HostBridge.string("value"), HostBridge.string("UTF-16")]
        ))
        XCTAssertThrowsError(try invoke(
            bridge, vm,
            class: "Ljava/net/URLEncoder;", "encode",
            prototype: "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;",
            isStatic: true,
            args: [HostBridge.string(String(repeating: "x", count: 8_193)), HostBridge.string("UTF-8")]
        ))
    }
}
