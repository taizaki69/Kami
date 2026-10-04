import XCTest
@testable import MihonCompatKit

final class SourceRequestScopeTests: XCTestCase {
    private actor Gate {
        private var value: CheckedContinuation<Int, Never>?
        private var entered = false
        private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
        private(set) var wasCancelled = false

        func wait() async -> Int {
            let result = await withCheckedContinuation { continuation in
                value = continuation
                entered = true
                for waiter in enteredWaiters { waiter.resume() }
                enteredWaiters.removeAll()
            }
            wasCancelled = Task.isCancelled
            return result
        }

        func waitUntilEntered() async {
            if entered { return }
            await withCheckedContinuation { enteredWaiters.append($0) }
        }

        func release() { value?.resume(returning: 7); value = nil }
    }

    func testRevocationCancelsInFlightWorkAndRejectsItsLateValue() async throws {
        let scope = SourceRequestScope()
        let gate = Gate()
        let task = Task { try await scope.perform { await gate.wait() } }
        await gate.waitUntilEntered()
        scope.revoke()
        await gate.release()
        do {
            _ = try await task.value
            XCTFail("A revoked source must not publish a late result")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let cancelled = await gate.wasCancelled
        XCTAssertTrue(cancelled)
        XCTAssertFalse(scope.isActive)
        do {
            _ = try await scope.perform { XCTFail("Revoked work must not start"); return 0 }
            XCTFail("Revoked scope accepted work")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testOperationLimitDoesNotInvalidateAnActiveRequestAndCapacityRecovers() async throws {
        let scope = SourceRequestScope(maximumOperations: 1)
        let gate = Gate()
        let first = Task { try await scope.perform { await gate.wait() } }
        await gate.waitUntilEntered()
        do {
            _ = try await scope.perform { XCTFail("Excess work must not start"); return 0 }
            XCTFail("Expected the operation limit")
        } catch {
            XCTAssertEqual(error as? SourceRequestScope.Failure, .tooManyOperations)
        }
        XCTAssertTrue(scope.isActive)
        await gate.release()
        let result = try await first.value
        XCTAssertEqual(result, 7)
        let recovered = try await scope.perform { 9 }
        XCTAssertEqual(recovered, 9)
    }

    func testCallerCancellationCancelsItsChildWithoutRevokingOtherRequests() async throws {
        let scope = SourceRequestScope()
        let gate = Gate()
        let task = Task { try await scope.perform { await gate.wait() } }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.release()
        do {
            _ = try await task.value
            XCTFail("Cancelled caller must not receive the value")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let cancelled = await gate.wasCancelled
        XCTAssertTrue(cancelled)
        XCTAssertTrue(scope.isActive)
        let next = try await scope.perform { 3 }
        XCTAssertEqual(next, 3)
    }

    func testRetainedImageExecutorRespectsRevocationAndKeepsItsIdentity() async throws {
        let id = UUID()
        let scope = SourceRequestScope()
        let request = try ImageRequest(url: "https://images.invalid/page.png",
            headers: ["Referer": "https://source.invalid"], sourceExecutionID: id) {
                CompatHTTPResponse(finalURL: "https://images.invalid/page.png", statusCode: 200, body: [1])
            }.scoped(to: scope)
        XCTAssertEqual(request.sourceExecutionID, id)
        XCTAssertEqual(request.requestScopeID, scope.id)
        let sameLifetime = try request.scoped(to: scope)
        XCTAssertEqual(sameLifetime.requestScopeID, request.requestScopeID)
        XCTAssertEqual(sameLifetime.sourceExecutionID, request.sourceExecutionID)
        XCTAssertThrowsError(try request.scoped(to: SourceRequestScope())) {
            XCTAssertEqual($0 as? SourceRequestScope.Failure, .differentLifetime)
        }
        XCTAssertEqual(request.headers["Referer"], "https://source.invalid")
        let response = try await request.executeSourceRequest()
        XCTAssertEqual(response?.body, [1])
        scope.revoke()
        XCTAssertThrowsError(try request.scoped(to: SourceRequestScope())) {
            XCTAssertTrue($0 is CancellationError)
        }
        do {
            _ = try await request.executeSourceRequest()
            XCTFail("Retained capability must be revoked")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }
}
