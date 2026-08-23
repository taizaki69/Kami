import XCTest
@testable import MihonCompatKit

final class AsyncInterpreterTests: XCTestCase {
    private func int(_ value: RVal) -> Int32? {
        guard case let .int(result) = value else { return nil }
        return result
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

    private func tryItem(start: Int, count: Int, handlerOffset: Int) -> [UInt8] {
        let start = UInt32(start)
        let count = UInt16(count)
        let handlerOffset = UInt16(handlerOffset)
        return [
            UInt8(start & 0xff), UInt8(start >> 8 & 0xff),
            UInt8(start >> 16 & 0xff), UInt8(start >> 24),
            UInt8(count & 0xff), UInt8(count >> 8),
            UInt8(handlerOffset & 0xff), UInt8(handlerOffset >> 8),
        ]
    }

    func testAsyncHostInvocationResumesNestedDexFrames() async throws {
        var builder = DexBuilder()
        let fetch = builder.method(
            classDescriptor: "LAsyncHost;",
            name: "fetch",
            shorty: "L",
            ret: "Ljava/lang/String;"
        )
        let length = builder.method(
            classDescriptor: "Ljava/lang/String;",
            name: "length",
            shorty: "I",
            ret: "I"
        )
        builder.setClass("LTest;")
        let inner = builder.addMethod(.init(
            name: "inner", registers: 1, ins: 0, outs: 0,
            insns: Insn.invokeStatic(fetch, [])
                + Insn.moveResultObject(0)
                + Insn.returnObjectReg(0),
            isStatic: true,
            returnType: "Ljava/lang/String;"
        ))
        builder.addMethod(.init(
            name: "run", registers: 1, ins: 0, outs: 1,
            insns: Insn.invokeStatic(inner, [])
                + Insn.moveResultObject(0)
                + Insn.invokeVirtual(length, [0])
                + Insn.moveResult(0)
                + Insn.returnReg(0),
            isStatic: true,
            returnType: "I"
        ))

        let bridge = HostBridge.minimal()
        bridge.registerAsync(
            class: "LAsyncHost;",
            "fetch",
            prototype: "()Ljava/lang/String;",
            isStatic: true
        ) { _, _ in
            await Task.yield()
            return HostBridge.string("Kami")
        }
        let vm = DexInterpreter(dex: try DexFile(builder.build()), bridge: bridge)

        XCTAssertThrowsError(try vm.call(classDescriptor: "LTest;", method: "run")) { error in
            guard case let VMError.asyncExecutionRequired(classDescriptor, signature) = error else {
                return XCTFail("expected async entry-point diagnostic, got \(error)")
            }
            XCTAssertEqual(classDescriptor, "LAsyncHost;")
            XCTAssertEqual(signature, "fetch()Ljava/lang/String;")
        }
        let result = try await vm.callAsync(classDescriptor: "LTest;", method: "run")
        XCTAssertEqual(int(result), 4)
    }

    func testAsyncDexThrowableReentersTypedHandlerAtInvoke() async throws {
        var builder = DexBuilder()
        let exceptionType = builder.type("Ljava/io/IOException;")
        let fetch = builder.method(
            classDescriptor: "LAsyncHost;",
            name: "fetch",
            shorty: "L",
            ret: "Ljava/lang/Object;"
        )
        builder.setClass("LTest;")
        let handlers = [UInt8(1), UInt8(1)]
            + DexBuilder.ULEB.encode(UInt64(exceptionType))
            + DexBuilder.ULEB.encode(6)
        builder.addMethod(.init(
            name: "run", registers: 2, ins: 0, outs: 0,
            insns: Insn.invokeStatic(fetch, [])
                + Insn.moveResultObject(0)
                + Insn.const4Units(0, 0)
                + Insn.returnReg(0)
                + [0x010d]
                + Insn.const4Units(0, 7)
                + Insn.returnReg(0),
            isStatic: true,
            returnType: "I",
            triesCount: 1,
            tryItems: tryItem(start: 0, count: 3, handlerOffset: 1) + handlers
        ))

        let bridge = HostBridge.minimal()
        bridge.registerAsync(
            class: "LAsyncHost;",
            "fetch",
            prototype: "()Ljava/lang/Object;",
            isStatic: true
        ) { _, _ in
            await Task.yield()
            throw DEXThrowable(.obj(ObjInstance(
                dexType: "Ljava/io/IOException;",
                payload: "redacted transport failure",
                isHost: true
            )))
        }
        let vm = DexInterpreter(dex: try DexFile(builder.build()), bridge: bridge)

        let result = try await vm.callAsync(classDescriptor: "LTest;", method: "run")
        XCTAssertEqual(int(result), 7)
    }

    func testAsyncEntryPropagatesSwiftTaskCancellation() async throws {
        var builder = DexBuilder()
        let wait = builder.method(
            classDescriptor: "LAsyncHost;",
            name: "wait",
            shorty: "L",
            ret: "Ljava/lang/Object;"
        )
        builder.setClass("LTest;")
        builder.addMethod(.init(
            name: "run", registers: 1, ins: 0, outs: 0,
            insns: Insn.invokeStatic(wait, [])
                + Insn.moveResultObject(0)
                + Insn.returnObjectReg(0),
            isStatic: true,
            returnType: "Ljava/lang/Object;"
        ))
        let bridge = HostBridge.minimal()
        bridge.registerAsync(
            class: "LAsyncHost;",
            "wait",
            prototype: "()Ljava/lang/Object;",
            isStatic: true
        ) { _, _ in
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return .null
        }
        let vm = DexInterpreter(dex: try DexFile(builder.build()), bridge: bridge)
        let task = Task {
            try await vm.callAsync(classDescriptor: "LTest;", method: "run")
        }
        await Task.yield()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch let error as VMError {
            guard case .cancelled = error else {
                return XCTFail("expected VM cancellation, got \(error)")
            }
        }
    }

    func testAwaitSuccessUsesInjectedTransportAndModelsBoundedResponseBody() async throws {
        let response = CompatHTTPResponse(
            finalURL: "https://example.test/final",
            statusCode: 203,
            headers: [
                CompatHTTPHeader(name: "Content-Type", value: "text/plain; charset=iso-8859-1"),
                CompatHTTPHeader(name: "X-Test", value: "yes"),
            ],
            body: [0x63, 0x61, 0x66, 0xe9]
        )
        let transport = RecordingTransport(sourceID: "test-source", response: response)
        var builder = DexBuilder()
        let awaitSuccess = builder.method(
            classDescriptor: "Leu/kanade/tachiyomi/network/OkHttpExtensionsKt;",
            name: "awaitSuccess",
            shorty: "LLL",
            ret: "Ljava/lang/Object;",
            parameters: ["Lokhttp3/Call;", "Lkotlin/coroutines/Continuation;"]
        )
        builder.setClass("LTest;")
        builder.addMethod(.init(
            name: "run", registers: 2, ins: 2, outs: 2,
            insns: Insn.invokeStatic(awaitSuccess, [0, 1])
                + Insn.moveResultObject(0)
                + Insn.returnObjectReg(0),
            isStatic: true,
            returnType: "Ljava/lang/Object;",
            parameters: ["Lokhttp3/Call;", "Lkotlin/coroutines/Continuation;"]
        ))

        let bridge = HostBridge.minimal(transport: transport)
        let vm = DexInterpreter(dex: try DexFile(builder.build()), bridge: bridge)
        let request = CompatHTTPRequest(url: "https://example.test/start")
        let source = RVal.obj(ObjInstance(dexType: "LTestSource;"))
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
        let requestValue = RVal.obj(ObjInstance(
            dexType: "Lokhttp3/Request;",
            payload: request,
            isHost: true
        ))
        let call = try invoke(
            bridge, vm,
            class: "Lokhttp3/OkHttpClient;", "newCall",
            prototype: "(Lokhttp3/Request;)Lokhttp3/Call;",
            args: [client, requestValue]
        )

        let responseValue = try await vm.callAsync(
            classDescriptor: "LTest;",
            method: "run",
            prototype: "(Lokhttp3/Call;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;",
            args: [call, .null]
        )
        let requests = await transport.requests()
        XCTAssertEqual(requests, [request])
        XCTAssertEqual(int(try invoke(
            bridge, vm, class: "Lokhttp3/Response;", "code",
            prototype: "()I", args: [responseValue]
        )), 203)
        XCTAssertEqual(vmStringValue(try invoke(
            bridge, vm, class: "Lokhttp3/Response;", "header",
            prototype: "(Ljava/lang/String;)Ljava/lang/String;",
            args: [responseValue, HostBridge.string("x-test")]
        )), "yes")
        let body = try invoke(
            bridge, vm, class: "Lokhttp3/Response;", "body",
            prototype: "()Lokhttp3/ResponseBody;", args: [responseValue]
        )
        XCTAssertEqual(try invoke(
            bridge, vm, class: "Lokhttp3/ResponseBody;", "contentLength",
            prototype: "()J", args: [body]
        ).longValue, 4)
        XCTAssertEqual(vmStringValue(try invoke(
            bridge, vm, class: "Lokhttp3/ResponseBody;", "string",
            prototype: "()Ljava/lang/String;", args: [body]
        )), "café")
        XCTAssertThrowsError(try invoke(
            bridge, vm, class: "Lokhttp3/ResponseBody;", "string",
            prototype: "()Ljava/lang/String;", args: [body]
        ))
    }

    private actor RecordingTransport: CompatHTTPTransport {
        nonisolated let sourceID: String
        private let response: CompatHTTPResponse
        private var recorded: [CompatHTTPRequest] = []

        init(sourceID: String, response: CompatHTTPResponse) {
            self.sourceID = sourceID
            self.response = response
        }

        func execute(_ request: CompatHTTPRequest) async throws -> CompatHTTPResponse {
            recorded.append(request)
            await Task.yield()
            return response
        }

        func requests() -> [CompatHTTPRequest] {
            recorded
        }
    }
}

private extension RVal {
    var longValue: Int64? {
        guard case let .long(value) = self else { return nil }
        return value
    }
}
