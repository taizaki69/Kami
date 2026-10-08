import XCTest
@testable import MihonCompatKit

final class HTTPCallbackContractTests: XCTestCase {
    private actor Transport: CompatHTTPTransport {
        enum Outcome { case success, ioFailure, guardFailure }
        nonisolated let sourceID = "callback-contract"
        let outcome: Outcome
        init(_ outcome: Outcome) { self.outcome = outcome }
        func execute(_ request: CompatHTTPRequest) async throws -> CompatHTTPResponse {
            switch outcome {
            case .success: return .init(finalURL: request.url, statusCode: 200)
            case .ioFailure: throw CompatHTTPTransportError.invalidResponse
            case .guardFailure: throw VMError.verify("test guard")
            }
        }
    }

    private final class Fixture {
        let vm: DexInterpreter
        let call: RVal
        let callback = RVal.obj(ObjInstance(dexType: "LCallback;"))
        var responses = 0, failures = 0
        var responseError: Error?
        var failureValue: RVal?

        init(_ outcome: Transport.Outcome, loop: Bool = false) throws {
            var dex = DexBuilder()
            let enqueue = dex.method(classDescriptor: "Lokhttp3/Call;", name: "enqueue", shorty: "VL", ret: "V", parameters: ["Lokhttp3/Callback;"])
            let success = dex.method(classDescriptor: "LCallbackObserver;", name: "success", shorty: "V", ret: "V")
            let failure = dex.method(classDescriptor: "LCallbackObserver;", name: "failure", shorty: "VL", ret: "V", parameters: ["Ljava/io/IOException;"])
            dex.setClass("LCaller;")
            dex.addMethod(.init(name: "run", registers: 2, ins: 2, outs: 2,
                insns: Insn.invokeInterface(enqueue, [0, 1]) + Insn.returnVoid(), isStatic: true,
                parameters: ["Lokhttp3/Call;", "Lokhttp3/Callback;"]))
            dex.setClass("LCallback;", interfaces: ["Lokhttp3/Callback;"])
            dex.addMethod(.init(name: "onResponse", registers: 3, ins: 3, outs: 0,
                insns: loop ? [0x0000, 0xff28] : Insn.invokeStatic(success, []) + Insn.returnVoid(), isStatic: false,
                parameters: ["Lokhttp3/Call;", "Lokhttp3/Response;"]))
            dex.addMethod(.init(name: "onFailure", registers: 3, ins: 3, outs: 1,
                insns: Insn.invokeStatic(failure, [2]) + Insn.returnVoid(), isStatic: false,
                parameters: ["Lokhttp3/Call;", "Ljava/io/IOException;"]))
            let bridge = HostBridge.minimal(transport: Transport(outcome))
            let vm = DexInterpreter(dex: try DexFile(dex.build()), bridge: bridge, maxInstructions: 50)
            self.vm = vm
            func invoke(_ type: String, _ name: String, _ proto: String, _ args: [RVal]) throws -> RVal {
                try XCTUnwrap(bridge.resolve(class: type, name, prototype: proto, isStatic: false))(vm, args)
            }
            let helper = try invoke("Leu/kanade/tachiyomi/source/online/HttpSource;", "getNetwork", "()Leu/kanade/tachiyomi/network/NetworkHelper;", [.obj(ObjInstance(dexType: "LCaller;"))])
            let client = try invoke("Leu/kanade/tachiyomi/network/NetworkHelper;", "getClient", "()Lokhttp3/OkHttpClient;", [helper])
            let request = RVal.obj(ObjInstance(dexType: "Lokhttp3/Request;", payload: CompatHTTPRequest(url: "https://example.test/"), isHost: true))
            call = try invoke("Lokhttp3/OkHttpClient;", "newCall", "(Lokhttp3/Request;)Lokhttp3/Call;", [client, request])
            bridge.register(class: "LCallbackObserver;", "success", prototype: "()V", isStatic: true) { [weak self] _, _ in
                self?.responses += 1
                if let error = self?.responseError { throw error }
                return .null
            }
            bridge.register(class: "LCallbackObserver;", "failure", prototype: "(Ljava/io/IOException;)V", isStatic: true) { [weak self] _, args in
                self?.failures += 1
                self?.failureValue = args.first
                return .null
            }
        }

        func run() async throws {
            _ = try await vm.callAsync(classDescriptor: "LCaller;", method: "run",
                prototype: "(Lokhttp3/Call;Lokhttp3/Callback;)V", args: [call, callback])
        }
    }

    func testSuccessAndIOFailureDeliverExactlyOneMatchingCallback() async throws {
        let success = try Fixture(.success)
        try await success.run()
        XCTAssertEqual(success.responses, 1); XCTAssertEqual(success.failures, 0)
        let failure = try Fixture(.ioFailure)
        try await failure.run()
        XCTAssertEqual(failure.responses, 0); XCTAssertEqual(failure.failures, 1)
        guard case let .obj(error) = failure.failureValue else { return XCTFail("Missing original IOException") }
        XCTAssertEqual(error.dexType, "Ljava/io/IOException;")
        XCTAssertEqual(error.payload as? String, CompatHTTPTransportError.invalidResponse.description)
    }

    func testCallbackExceptionIsNotDeliveredAgainAsNetworkFailure() async throws {
        let fixture = try Fixture(.success)
        let error = RVal.obj(ObjInstance(dexType: "Ljava/io/IOException;", payload: "callback failure", isHost: true))
        fixture.responseError = DEXThrowable(error)
        do { try await fixture.run(); XCTFail("Expected callback exception") }
        catch let thrown as DEXThrowable { XCTAssertTrue(thrown.value === error) }
        XCTAssertEqual(fixture.responses, 1); XCTAssertEqual(fixture.failures, 0)
    }

    func testTransportAndCallbackGuardsCannotBecomeRecoverableIOFailures() async throws {
        let transport = try Fixture(.guardFailure)
        do { try await transport.run(); XCTFail("Expected VM guard") }
        catch { guard case VMError.verify("test guard") = error else { return XCTFail("\(error)") } }
        XCTAssertEqual(transport.responses, 0); XCTAssertEqual(transport.failures, 0)
        let callback = try Fixture(.success, loop: true)
        do { try await callback.run(); XCTFail("Expected shared budget exhaustion") }
        catch { guard case VMError.budgetExceeded = error else { return XCTFail("\(error)") } }
        XCTAssertEqual(callback.failures, 0)
    }
}
