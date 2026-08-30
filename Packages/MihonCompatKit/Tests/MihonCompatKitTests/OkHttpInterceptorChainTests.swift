import XCTest
@testable import MihonCompatKit

final class OkHttpInterceptorChainTests: XCTestCase {
    private struct PassThroughSpec {
        let descriptor: String
        let label: String?
        let burnInstructions: Int

        init(_ descriptor: String, label: String? = nil, burnInstructions: Int = 0) {
            self.descriptor = descriptor
            self.label = label
            self.burnInstructions = burnInstructions
        }
    }

    private func invoke(
        _ bridge: HostBridge,
        _ vm: DexInterpreter,
        class descriptor: String,
        _ name: String,
        prototype: String,
        isStatic: Bool = false,
        args: [RVal]
    ) throws -> RVal {
        let method = try XCTUnwrap(bridge.resolve(
            class: descriptor,
            name,
            prototype: prototype,
            isStatic: isStatic
        ))
        return try method(vm, args)
    }

    private func addAwaitRunners(_ builder: inout DexBuilder) {
        let awaitMethod = builder.method(
            classDescriptor: "Leu/kanade/tachiyomi/network/OkHttpExtensionsKt;",
            name: "await",
            shorty: "LLL",
            ret: "Ljava/lang/Object;",
            parameters: ["Lokhttp3/Call;", "Lkotlin/coroutines/Continuation;"]
        )
        let awaitSuccess = builder.method(
            classDescriptor: "Leu/kanade/tachiyomi/network/OkHttpExtensionsKt;",
            name: "awaitSuccess",
            shorty: "LLL",
            ret: "Ljava/lang/Object;",
            parameters: ["Lokhttp3/Call;", "Lkotlin/coroutines/Continuation;"]
        )
        builder.setClass("LRunner;")
        builder.addMethod(.init(
            name: "runAwait", registers: 2, ins: 2, outs: 2,
            insns: Insn.invokeStatic(awaitMethod, [0, 1])
                + Insn.moveResultObject(0)
                + Insn.returnObjectReg(0),
            isStatic: true,
            returnType: "Ljava/lang/Object;",
            parameters: ["Lokhttp3/Call;", "Lkotlin/coroutines/Continuation;"]
        ))
        builder.addMethod(.init(
            name: "runAwaitSuccess", registers: 2, ins: 2, outs: 2,
            insns: Insn.invokeStatic(awaitSuccess, [0, 1])
                + Insn.moveResultObject(0)
                + Insn.returnObjectReg(0),
            isStatic: true,
            returnType: "Ljava/lang/Object;",
            parameters: ["Lokhttp3/Call;", "Lkotlin/coroutines/Continuation;"]
        ))
    }

    private func passThroughDEX(_ specs: [PassThroughSpec]) throws -> DexFile {
        var builder = DexBuilder()
        let request = builder.method(
            classDescriptor: "Lokhttp3/Interceptor$Chain;",
            name: "request",
            shorty: "L",
            ret: "Lokhttp3/Request;"
        )
        let proceed = builder.method(
            classDescriptor: "Lokhttp3/Interceptor$Chain;",
            name: "proceed",
            shorty: "LL",
            ret: "Lokhttp3/Response;",
            parameters: ["Lokhttp3/Request;"]
        )
        let record = builder.method(
            classDescriptor: "LTrace;",
            name: "record",
            shorty: "VL",
            parameters: ["Ljava/lang/String;"]
        )
        for spec in specs {
            let down: Int?
            let up: Int?
            if let label = spec.label {
                down = builder.string("\(label)-down")
                up = builder.string("\(label)-up")
            } else {
                down = nil
                up = nil
            }
            var instructions = Array(repeating: UInt16(0), count: spec.burnInstructions)
            if let down {
                instructions += Insn.constString(0, down)
                    + Insn.invokeStatic(record, [0])
            }
            instructions += Insn.invokeInterface(request, [3])
                + Insn.moveResultObject(0)
                + Insn.invokeInterface(proceed, [3, 0])
                + Insn.moveResultObject(0)
            if let up {
                instructions += Insn.constString(1, up)
                    + Insn.invokeStatic(record, [1])
            }
            instructions += Insn.returnObjectReg(0)
            builder.setClass(
                spec.descriptor,
                superclass: "Ljava/lang/Object;",
                interfaces: ["Lokhttp3/Interceptor;"]
            )
            builder.addMethod(.init(
                name: "intercept", registers: 4, ins: 2, outs: 2,
                insns: instructions,
                isStatic: false,
                returnType: "Lokhttp3/Response;",
                parameters: ["Lokhttp3/Interceptor$Chain;"]
            ))
        }
        addAwaitRunners(&builder)
        return try DexFile(builder.build())
    }

    private func doubleProceedDEX() throws -> DexFile {
        var builder = DexBuilder()
        let request = builder.method(
            classDescriptor: "Lokhttp3/Interceptor$Chain;",
            name: "request",
            shorty: "L",
            ret: "Lokhttp3/Request;"
        )
        let proceed = builder.method(
            classDescriptor: "Lokhttp3/Interceptor$Chain;",
            name: "proceed",
            shorty: "LL",
            ret: "Lokhttp3/Response;",
            parameters: ["Lokhttp3/Request;"]
        )
        builder.setClass(
            "LDoubleProceed;",
            superclass: "Ljava/lang/Object;",
            interfaces: ["Lokhttp3/Interceptor;"]
        )
        builder.addMethod(.init(
            name: "intercept", registers: 4, ins: 2, outs: 2,
            insns: Insn.invokeInterface(request, [3])
                + Insn.moveResultObject(0)
                + Insn.invokeInterface(proceed, [3, 0])
                + Insn.moveResultObject(1)
                + Insn.invokeInterface(proceed, [3, 0])
                + Insn.moveResultObject(1)
                + Insn.returnObjectReg(1),
            isStatic: false,
            returnType: "Lokhttp3/Response;",
            parameters: ["Lokhttp3/Interceptor$Chain;"]
        ))
        addAwaitRunners(&builder)
        return try DexFile(builder.build())
    }

    private func rewritingDEX(code: Int16) throws -> DexFile {
        var builder = DexBuilder()
        let request = builder.method(
            classDescriptor: "Lokhttp3/Interceptor$Chain;",
            name: "request",
            shorty: "L",
            ret: "Lokhttp3/Request;"
        )
        let proceed = builder.method(
            classDescriptor: "Lokhttp3/Interceptor$Chain;",
            name: "proceed",
            shorty: "LL",
            ret: "Lokhttp3/Response;",
            parameters: ["Lokhttp3/Request;"]
        )
        let newBuilder = builder.method(
            classDescriptor: "Lokhttp3/Response;",
            name: "newBuilder",
            shorty: "L",
            ret: "Lokhttp3/Response$Builder;"
        )
        let setCode = builder.method(
            classDescriptor: "Lokhttp3/Response$Builder;",
            name: "code",
            shorty: "LI",
            ret: "Lokhttp3/Response$Builder;",
            parameters: ["I"]
        )
        let build = builder.method(
            classDescriptor: "Lokhttp3/Response$Builder;",
            name: "build",
            shorty: "L",
            ret: "Lokhttp3/Response;"
        )
        builder.setClass(
            "LRewriteCode;",
            superclass: "Ljava/lang/Object;",
            interfaces: ["Lokhttp3/Interceptor;"]
        )
        builder.addMethod(.init(
            name: "intercept", registers: 4, ins: 2, outs: 2,
            insns: Insn.invokeInterface(request, [3])
                + Insn.moveResultObject(0)
                + Insn.invokeInterface(proceed, [3, 0])
                + Insn.moveResultObject(0)
                + Insn.invokeVirtual(newBuilder, [0])
                + Insn.moveResultObject(0)
                + Insn.const16Units(1, code)
                + Insn.invokeVirtual(setCode, [0, 1])
                + Insn.moveResultObject(0)
                + Insn.invokeVirtual(build, [0])
                + Insn.moveResultObject(0)
                + Insn.returnObjectReg(0),
            isStatic: false,
            returnType: "Lokhttp3/Response;",
            parameters: ["Lokhttp3/Interceptor$Chain;"]
        ))
        addAwaitRunners(&builder)
        return try DexFile(builder.build())
    }

    private func baseClient(_ bridge: HostBridge, _ vm: DexInterpreter) throws -> RVal {
        let source = RVal.obj(ObjInstance(dexType: "LTestSource;"))
        let helper = try invoke(
            bridge, vm,
            class: "Leu/kanade/tachiyomi/source/online/HttpSource;", "getNetwork",
            prototype: "()Leu/kanade/tachiyomi/network/NetworkHelper;",
            args: [source]
        )
        return try invoke(
            bridge, vm,
            class: "Leu/kanade/tachiyomi/network/NetworkHelper;", "getClient",
            prototype: "()Lokhttp3/OkHttpClient;",
            args: [helper]
        )
    }

    private func client(
        _ bridge: HostBridge,
        _ vm: DexInterpreter,
        application: [RVal] = [],
        network: [RVal] = []
    ) throws -> RVal {
        let base = try baseClient(bridge, vm)
        let builder = try invoke(
            bridge, vm, class: "Lokhttp3/OkHttpClient;", "newBuilder",
            prototype: "()Lokhttp3/OkHttpClient$Builder;", args: [base]
        )
        for interceptor in application {
            _ = try invoke(
                bridge, vm, class: "Lokhttp3/OkHttpClient$Builder;", "addInterceptor",
                prototype: "(Lokhttp3/Interceptor;)Lokhttp3/OkHttpClient$Builder;",
                args: [builder, interceptor]
            )
        }
        for interceptor in network {
            _ = try invoke(
                bridge, vm, class: "Lokhttp3/OkHttpClient$Builder;", "addNetworkInterceptor",
                prototype: "(Lokhttp3/Interceptor;)Lokhttp3/OkHttpClient$Builder;",
                args: [builder, interceptor]
            )
        }
        return try invoke(
            bridge, vm, class: "Lokhttp3/OkHttpClient$Builder;", "build",
            prototype: "()Lokhttp3/OkHttpClient;", args: [builder]
        )
    }

    private func call(
        _ bridge: HostBridge,
        _ vm: DexInterpreter,
        client: RVal,
        request: RVal
    ) throws -> RVal {
        try invoke(
            bridge, vm, class: "Lokhttp3/OkHttpClient;", "newCall",
            prototype: "(Lokhttp3/Request;)Lokhttp3/Call;",
            args: [client, request]
        )
    }

    private func run(_ vm: DexInterpreter, call: RVal, success: Bool = false) async throws -> RVal {
        try await vm.callAsync(
            classDescriptor: "LRunner;",
            method: success ? "runAwaitSuccess" : "runAwait",
            prototype: "(Lokhttp3/Call;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;",
            args: [call, .null]
        )
    }

    private func requestValue(
        url: String = "https://example.test/start",
        fields: [String: RVal] = [:]
    ) -> RVal {
        .obj(ObjInstance(
            dexType: "Lokhttp3/Request;",
            fields: fields,
            payload: CompatHTTPRequest(url: url),
            isHost: true
        ))
    }

    private func integer(_ value: RVal) -> Int32? {
        guard case let .int(number) = value else { return nil }
        return number
    }

    private func bytes(_ value: RVal) -> [UInt8]? {
        guard case let .arr(array) = value, array.elemDescriptor == "B" else { return nil }
        var result: [UInt8] = []
        for element in array.elements {
            guard case let .int(byte) = element else { return nil }
            result.append(UInt8(truncatingIfNeeded: byte))
        }
        return result
    }

    private func throwableDescriptor(_ error: Error) -> String? {
        guard let thrown = error as? DEXThrowable,
              case let .obj(object) = thrown.value else { return nil }
        return object.dexType
    }

    func testApplicationAndNetworkInterceptorsRunInOrderAndPreserveRequestIdentityAndTags() async throws {
        let transport = RecordingTransport(response: CompatHTTPResponse(
            finalURL: "https://example.test/final",
            statusCode: 200,
            body: [1]
        ))
        let dex = try passThroughDEX([
            PassThroughSpec("LApplicationInterceptor;", label: "application"),
            PassThroughSpec("LNetworkInterceptor;", label: "network"),
        ])
        let bridge = HostBridge.minimal(transport: transport)
        var trace: [String] = []
        bridge.register(
            class: "LTrace;", "record",
            prototype: "(Ljava/lang/String;)V", isStatic: true
        ) { _, args in
            trace.append(vmStringValue(args[0]))
            return .null
        }
        let vm = DexInterpreter(dex: dex, bridge: bridge)
        let application = RVal.obj(ObjInstance(dexType: "LApplicationInterceptor;"))
        let network = RVal.obj(ObjInstance(dexType: "LNetworkInterceptor;"))
        let configuredClient = try client(
            bridge, vm, application: [application], network: [network]
        )
        let firstTag = RVal.obj(ObjInstance(dexType: "LFirstTag;"))
        let secondTag = RVal.obj(ObjInstance(dexType: "LSecondTag;"))
        let request = requestValue(fields: [
            "tag:LFirstTag;": firstTag,
            "tag:LSecondTag;": secondTag,
        ])
        let response = try await run(
            vm,
            call: try call(bridge, vm, client: configuredClient, request: request)
        )

        XCTAssertEqual(trace, [
            "application-down", "network-down", "network-up", "application-up",
        ])
        let transportedRequests = await transport.requests()
        XCTAssertEqual(transportedRequests, [CompatHTTPRequest(
            url: "https://example.test/start"
        )])
        let responseRequest = try invoke(
            bridge, vm, class: "Lokhttp3/Response;", "request",
            prototype: "()Lokhttp3/Request;", args: [response]
        )
        XCTAssertTrue(responseRequest === request)
        for (descriptor, expected) in [("LFirstTag;", firstTag), ("LSecondTag;", secondTag)] {
            let classValue = RVal.obj(ObjInstance(
                dexType: "Ljava/lang/Class;", payload: descriptor, isHost: true
            ))
            let actual = try invoke(
                bridge, vm, class: "Lokhttp3/Request;", "tag",
                prototype: "(Ljava/lang/Class;)Ljava/lang/Object;",
                args: [responseRequest, classValue]
            )
            XCTAssertTrue(actual === expected)
        }
    }

    func testResponseBuilderDefaultHeaderRedirectsAndReplacementBodyPreserveRequest() async throws {
        let policy = CompatHTTPTransportPolicy(maximumResponseBodyBytes: 4)
        let transport = RecordingTransport(response: CompatHTTPResponse(
            finalURL: "https://example.test/final",
            statusCode: 302,
            headers: [
                CompatHTTPHeader(name: "X-Replace", value: "old"),
                CompatHTTPHeader(name: "x-replace", value: "newer"),
                CompatHTTPHeader(name: "X-Keep", value: "kept"),
            ],
            body: [9, 8, 7, 6]
        ))
        let bridge = HostBridge.minimal(transport: transport, transportPolicy: policy)
        let vm = DexInterpreter(dex: try passThroughDEX([]), bridge: bridge)
        let request = requestValue()
        let response = try await run(
            vm,
            call: try call(bridge, vm, client: try client(bridge, vm), request: request)
        )

        XCTAssertEqual(integer(try invoke(
            bridge, vm, class: "Lokhttp3/Response;", "isRedirect",
            prototype: "()Z", args: [response]
        )), 1)
        XCTAssertEqual(vmStringValue(try invoke(
            bridge, vm, class: "Lokhttp3/Response;", "header$default",
            prototype: "(Lokhttp3/Response;Ljava/lang/String;Ljava/lang/String;ILjava/lang/Object;)Ljava/lang/String;",
            isStatic: true,
            args: [response, HostBridge.string("x-keep"), HostBridge.string("fallback"), .int(0), .null]
        )), "kept")
        XCTAssertEqual(vmStringValue(try invoke(
            bridge, vm, class: "Lokhttp3/Response;", "header$default",
            prototype: "(Lokhttp3/Response;Ljava/lang/String;Ljava/lang/String;ILjava/lang/Object;)Ljava/lang/String;",
            isStatic: true,
            args: [response, HostBridge.string("missing"), HostBridge.string("fallback"), .int(0), .null]
        )), "fallback")
        XCTAssertTrue(try invoke(
            bridge, vm, class: "Lokhttp3/Response;", "header$default",
            prototype: "(Lokhttp3/Response;Ljava/lang/String;Ljava/lang/String;ILjava/lang/Object;)Ljava/lang/String;",
            isStatic: true,
            args: [response, HostBridge.string("missing"), HostBridge.string("ignored"), .int(2), .null]
        ).isNull)

        let companion = RVal.obj(ObjInstance(
            dexType: "Lokhttp3/ResponseBody$Companion;", isHost: true
        ))
        let replacementBody = try invoke(
            bridge, vm, class: "Lokhttp3/ResponseBody$Companion;", "create",
            prototype: "([BLokhttp3/MediaType;)Lokhttp3/ResponseBody;",
            args: [
                companion,
                .arr(ArrInstance(elemDescriptor: "B", elements: [.int(1), .int(2), .int(3)])),
                .null,
            ]
        )
        XCTAssertThrowsError(try invoke(
            bridge, vm, class: "Lokhttp3/ResponseBody$Companion;", "create",
            prototype: "([BLokhttp3/MediaType;)Lokhttp3/ResponseBody;",
            args: [
                companion,
                .arr(ArrInstance(
                    elemDescriptor: "B",
                    elements: [.int(1), .int(2), .int(3), .int(4), .int(5)]
                )),
                .null,
            ]
        ))

        let responseBuilder = try invoke(
            bridge, vm, class: "Lokhttp3/Response;", "newBuilder",
            prototype: "()Lokhttp3/Response$Builder;", args: [response]
        )
        _ = try invoke(
            bridge, vm, class: "Lokhttp3/Response$Builder;", "code",
            prototype: "(I)Lokhttp3/Response$Builder;", args: [responseBuilder, .int(404)]
        )
        _ = try invoke(
            bridge, vm, class: "Lokhttp3/Response$Builder;", "header",
            prototype: "(Ljava/lang/String;Ljava/lang/String;)Lokhttp3/Response$Builder;",
            args: [responseBuilder, HostBridge.string("X-Replace"), HostBridge.string("replacement")]
        )
        _ = try invoke(
            bridge, vm, class: "Lokhttp3/Response$Builder;", "body",
            prototype: "(Lokhttp3/ResponseBody;)Lokhttp3/Response$Builder;",
            args: [responseBuilder, replacementBody]
        )
        let rebuilt = try invoke(
            bridge, vm, class: "Lokhttp3/Response$Builder;", "build",
            prototype: "()Lokhttp3/Response;", args: [responseBuilder]
        )
        XCTAssertEqual(integer(try invoke(
            bridge, vm, class: "Lokhttp3/Response;", "code",
            prototype: "()I", args: [rebuilt]
        )), 404)
        XCTAssertEqual(integer(try invoke(
            bridge, vm, class: "Lokhttp3/Response;", "isRedirect",
            prototype: "()Z", args: [rebuilt]
        )), 0)
        XCTAssertEqual(vmStringValue(try invoke(
            bridge, vm, class: "Lokhttp3/Response;", "header",
            prototype: "(Ljava/lang/String;)Ljava/lang/String;",
            args: [rebuilt, HostBridge.string("x-replace")]
        )), "replacement")
        XCTAssertEqual(vmStringValue(try invoke(
            bridge, vm, class: "Lokhttp3/Response;", "header",
            prototype: "(Ljava/lang/String;)Ljava/lang/String;",
            args: [rebuilt, HostBridge.string("x-keep")]
        )), "kept")
        let headers = try invoke(
            bridge, vm, class: "Lokhttp3/Response;", "headers",
            prototype: "()Lokhttp3/Headers;", args: [rebuilt]
        )
        XCTAssertEqual(integer(try invoke(
            bridge, vm, class: "Lokhttp3/Headers;", "size",
            prototype: "()I", args: [headers]
        )), 2)
        XCTAssertTrue(try invoke(
            bridge, vm, class: "Lokhttp3/Response;", "request",
            prototype: "()Lokhttp3/Request;", args: [rebuilt]
        ) === request)
        let body = try invoke(
            bridge, vm, class: "Lokhttp3/Response;", "body",
            prototype: "()Lokhttp3/ResponseBody;", args: [rebuilt]
        )
        XCTAssertEqual(bytes(try invoke(
            bridge, vm, class: "Lokhttp3/ResponseBody;", "bytes",
            prototype: "()[B", args: [body]
        )), [1, 2, 3])

        let redirectCodes: [Int32: Int32] = [
            299: 0, 300: 1, 301: 1, 302: 1, 303: 1,
            304: 0, 307: 1, 308: 1, 309: 0,
        ]
        for (code, expected) in redirectCodes {
            let builder = try invoke(
                bridge, vm, class: "Lokhttp3/Response;", "newBuilder",
                prototype: "()Lokhttp3/Response$Builder;", args: [response]
            )
            _ = try invoke(
                bridge, vm, class: "Lokhttp3/Response$Builder;", "code",
                prototype: "(I)Lokhttp3/Response$Builder;", args: [builder, .int(code)]
            )
            let candidate = try invoke(
                bridge, vm, class: "Lokhttp3/Response$Builder;", "build",
                prototype: "()Lokhttp3/Response;", args: [builder]
            )
            XCTAssertEqual(integer(try invoke(
                bridge, vm, class: "Lokhttp3/Response;", "isRedirect",
                prototype: "()Z", args: [candidate]
            )), expected, "unexpected redirect classification for \(code)")
        }
    }

    func testProceedIsOneShotAndTransportExecutesOnlyOnce() async throws {
        let transport = RecordingTransport(response: CompatHTTPResponse(
            finalURL: "https://example.test/final", statusCode: 200
        ))
        let bridge = HostBridge.minimal(transport: transport)
        let vm = DexInterpreter(dex: try doubleProceedDEX(), bridge: bridge)
        let configuredClient = try client(
            bridge,
            vm,
            application: [RVal.obj(ObjInstance(dexType: "LDoubleProceed;"))]
        )
        do {
            _ = try await run(
                vm,
                call: try call(
                    bridge, vm, client: configuredClient, request: requestValue()
                )
            )
            XCTFail("expected a second proceed call to fail")
        } catch {
            XCTAssertEqual(throwableDescriptor(error), "Ljava/lang/IllegalStateException;")
        }
        let requestCount = await transport.requests().count
        XCTAssertEqual(requestCount, 1)
    }

    func testClientRejectsMoreThanThirtyTwoTotalInterceptors() throws {
        let bridge = HostBridge.minimal()
        let vm = DexInterpreter(dex: try passThroughDEX([]), bridge: bridge)
        let builder = try invoke(
            bridge, vm, class: "Lokhttp3/OkHttpClient;", "newBuilder",
            prototype: "()Lokhttp3/OkHttpClient$Builder;",
            args: [try baseClient(bridge, vm)]
        )
        let interceptor = RVal.obj(ObjInstance(dexType: "LUnusedInterceptor;"))
        for _ in 0..<29 {
            _ = try invoke(
                bridge, vm, class: "Lokhttp3/OkHttpClient$Builder;", "addInterceptor",
                prototype: "(Lokhttp3/Interceptor;)Lokhttp3/OkHttpClient$Builder;",
                args: [builder, interceptor]
            )
        }
        _ = try invoke(
            bridge, vm, class: "Lokhttp3/OkHttpClient$Builder;", "build",
            prototype: "()Lokhttp3/OkHttpClient;", args: [builder]
        )
        XCTAssertThrowsError(try invoke(
            bridge, vm, class: "Lokhttp3/OkHttpClient$Builder;", "addNetworkInterceptor",
            prototype: "(Lokhttp3/Interceptor;)Lokhttp3/OkHttpClient$Builder;",
            args: [builder, interceptor]
        )) { error in
            XCTAssertEqual(self.throwableDescriptor(error), "Ljava/lang/IllegalStateException;")
        }

        let interceptors = try invoke(
            bridge, vm, class: "Lokhttp3/OkHttpClient$Builder;", "interceptors",
            prototype: "()Ljava/util/List;", args: [builder]
        )
        _ = try invoke(
            bridge, vm, class: "Ljava/util/List;", "add",
            prototype: "(Ljava/lang/Object;)Z", args: [interceptors, interceptor]
        )
        XCTAssertThrowsError(try invoke(
            bridge, vm, class: "Lokhttp3/OkHttpClient$Builder;", "build",
            prototype: "()Lokhttp3/OkHttpClient;", args: [builder]
        )) { error in
            XCTAssertEqual(self.throwableDescriptor(error), "Ljava/lang/IllegalStateException;")
        }
    }

    func testNestedInterceptorsShareTheOuterInstructionBudget() async throws {
        let transport = RecordingTransport(response: CompatHTTPResponse(
            finalURL: "https://example.test/final", statusCode: 200
        ))
        let dex = try passThroughDEX([
            PassThroughSpec("LBurnA;", burnInstructions: 12),
            PassThroughSpec("LBurnB;", burnInstructions: 12),
        ])
        let bridge = HostBridge.minimal(transport: transport)
        let vm = DexInterpreter(dex: dex, bridge: bridge, maxInstructions: 28)
        let first = RVal.obj(ObjInstance(dexType: "LBurnA;"))
        let second = RVal.obj(ObjInstance(dexType: "LBurnB;"))

        let oneInterceptorClient = try client(bridge, vm, application: [first])
        _ = try await run(
            vm,
            call: try call(
                bridge, vm, client: oneInterceptorClient, request: requestValue()
            )
        )
        let twoInterceptorClient = try client(bridge, vm, application: [first, second])
        do {
            _ = try await run(
                vm,
                call: try call(
                    bridge, vm, client: twoInterceptorClient, request: requestValue()
                )
            )
            XCTFail("expected the shared outer instruction budget to be exhausted")
        } catch let error as VMError {
            guard case .budgetExceeded(limit: 28) = error else {
                return XCTFail("expected a shared budget failure, got \(error)")
            }
        }
        let requestCount = await transport.requests().count
        XCTAssertEqual(requestCount, 1)
    }

    func testAwaitAndAwaitSuccessApplyStatusAfterTheCompleteChain() async throws {
        let transport = RecordingTransport(response: CompatHTTPResponse(
            finalURL: "https://example.test/final", statusCode: 404
        ))
        let bridge = HostBridge.minimal(transport: transport)
        let vm = DexInterpreter(dex: try rewritingDEX(code: 204), bridge: bridge)
        let request = requestValue()
        let plainClient = try client(bridge, vm)
        let awaited = try await run(
            vm,
            call: try call(bridge, vm, client: plainClient, request: request)
        )
        XCTAssertEqual(integer(try invoke(
            bridge, vm, class: "Lokhttp3/Response;", "code",
            prototype: "()I", args: [awaited]
        )), 404)
        do {
            _ = try await run(
                vm,
                call: try call(bridge, vm, client: plainClient, request: request),
                success: true
            )
            XCTFail("awaitSuccess must reject the terminal 404")
        } catch {
            XCTAssertEqual(
                throwableDescriptor(error),
                "Leu/kanade/tachiyomi/network/HttpException;"
            )
        }

        let rewritingClient = try client(
            bridge,
            vm,
            application: [RVal.obj(ObjInstance(dexType: "LRewriteCode;"))]
        )
        let rewritten = try await run(
            vm,
            call: try call(bridge, vm, client: rewritingClient, request: request),
            success: true
        )
        XCTAssertEqual(integer(try invoke(
            bridge, vm, class: "Lokhttp3/Response;", "code",
            prototype: "()I", args: [rewritten]
        )), 204)
    }

    func testTaskCancellationStopsAnInFlightInterceptorChainAndMarksTheCall() async throws {
        let transport = RecordingTransport(
            response: CompatHTTPResponse(
                finalURL: "https://example.test/final", statusCode: 200
            ),
            delayNanoseconds: 60_000_000_000
        )
        let bridge = HostBridge.minimal(transport: transport)
        let vm = DexInterpreter(
            dex: try passThroughDEX([PassThroughSpec("LCancellable;")]),
            bridge: bridge
        )
        let configuredClient = try client(
            bridge,
            vm,
            application: [RVal.obj(ObjInstance(dexType: "LCancellable;"))]
        )
        let callValue = try call(
            bridge, vm, client: configuredClient, request: requestValue()
        )
        let task = Task { try await run(vm, call: callValue) }
        for _ in 0..<100 {
            if !(await transport.requests()).isEmpty { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let startedRequestCount = await transport.requestCount()
        XCTAssertEqual(startedRequestCount, 1)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch let error as VMError {
            guard case .cancelled = error else {
                return XCTFail("expected VM cancellation, got \(error)")
            }
        }
        XCTAssertEqual(integer(try invoke(
            bridge, vm, class: "Lokhttp3/Call;", "isCanceled",
            prototype: "()Z", args: [callValue]
        )), 1)
        let requestCount = await transport.requests().count
        XCTAssertEqual(requestCount, 1)
    }

    private actor RecordingTransport: CompatHTTPTransport {
        nonisolated let sourceID = "interceptor-chain-tests"
        private let response: CompatHTTPResponse
        private let delayNanoseconds: UInt64
        private var recorded: [CompatHTTPRequest] = []

        init(response: CompatHTTPResponse, delayNanoseconds: UInt64 = 0) {
            self.response = response
            self.delayNanoseconds = delayNanoseconds
        }

        func execute(_ request: CompatHTTPRequest) async throws -> CompatHTTPResponse {
            recorded.append(request)
            if delayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } else {
                await Task.yield()
            }
            return response
        }

        func requests() -> [CompatHTTPRequest] {
            recorded
        }

        func requestCount() -> Int {
            recorded.count
        }
    }
}
