import XCTest
@testable import MihonCompatKit

final class CoroutineMutexTests: XCTestCase {
    private func owner() -> HostCoroutineMutex.Owner { .init(NSObject()) }

    func testOwnerIdentityNonReentrancyAndNullUnlock() throws {
        let mutex = HostCoroutineMutex(locked: false)
        let reference = NSObject()
        let first = HostCoroutineMutex.Owner(reference)
        let same = HostCoroutineMutex.Owner(reference)
        let other = owner()
        XCTAssertFalse(mutex.isLocked)
        XCTAssertTrue(try mutex.tryLock(owner: first))
        XCTAssertTrue(mutex.holdsLock(owner: same))
        XCTAssertFalse(mutex.holdsLock(owner: other))
        XCTAssertThrowsError(try mutex.tryLock(owner: same)) { XCTAssertEqual($0 as? HostCoroutineMutex.Failure, .alreadyOwned) }
        XCTAssertThrowsError(try mutex.beginLock(owner: same)) { XCTAssertEqual($0 as? HostCoroutineMutex.Failure, .alreadyOwned) }
        XCTAssertFalse(try mutex.tryLock(owner: other))
        XCTAssertThrowsError(try mutex.unlock(owner: other)) { XCTAssertEqual($0 as? HostCoroutineMutex.Failure, .wrongOwner) }
        XCTAssertTrue(mutex.isLocked)
        try mutex.unlock(owner: nil)
        XCTAssertFalse(mutex.isLocked)
        XCTAssertThrowsError(try mutex.unlock(owner: first)) { XCTAssertEqual($0 as? HostCoroutineMutex.Failure, .notLocked) }
    }

    func testFIFOAndPromptCancellationAfterHandoffCannotReleaseLaterHolder() throws {
        let mutex = HostCoroutineMutex(locked: true)
        let first = try mutex.beginLock(owner: owner())
        let second = try mutex.beginLock(owner: owner())
        let third = try mutex.beginLock(owner: nil)
        XCTAssertFalse(first.immediate)
        XCTAssertFalse(second.immediate)
        XCTAssertFalse(third.immediate)
        XCTAssertFalse(mutex.hasAcquired(first.ticket))
        try mutex.unlock(owner: nil)
        XCTAssertTrue(mutex.hasAcquired(first.ticket))
        XCTAssertFalse(try mutex.tryLock(owner: nil), "A new caller must not steal a queued permit")
        mutex.cancel(first.ticket)
        XCTAssertTrue(mutex.hasAcquired(second.ticket))
        mutex.cancel(first.ticket)
        XCTAssertTrue(mutex.hasAcquired(second.ticket), "An old cancellation must not release a new holder")
        mutex.cancel(third.ticket)
        try mutex.unlock(owner: nil)
        XCTAssertFalse(mutex.isLocked)
        XCTAssertEqual(mutex.waitingCount, 0)
    }

    func testNullOwnerStillExcludesAndWaiterCapacityRecoversAfterCancellation() throws {
        let mutex = HostCoroutineMutex(locked: false, maximumWaiters: 2)
        XCTAssertTrue(try mutex.tryLock(owner: nil))
        XCTAssertFalse(try mutex.tryLock(owner: nil))
        let one = try mutex.beginLock(owner: nil)
        let two = try mutex.beginLock(owner: nil)
        XCTAssertThrowsError(try mutex.beginLock(owner: nil)) { XCTAssertEqual($0 as? HostCoroutineMutex.Failure, .tooManyWaiters) }
        mutex.cancel(one.ticket)
        let three = try mutex.beginLock(owner: nil)
        try mutex.unlock(owner: nil)
        XCTAssertTrue(mutex.hasAcquired(two.ticket))
        XCTAssertFalse(mutex.hasAcquired(three.ticket))
        try mutex.unlock(owner: nil)
        XCTAssertTrue(mutex.hasAcquired(three.ticket))
        try mutex.unlock(owner: nil)
        XCTAssertFalse(mutex.isLocked)
    }

    func testBoundedWaitLeavesOriginalLockIntactAndRemovesWaiter() async throws {
        let mutex = HostCoroutineMutex(locked: true)
        do {
            try await mutex.lock(owner: nil, maximumWaitNanoseconds: 1_000_000, cancelled: { false })
            XCTFail("A contended mutex must not succeed without unlock")
        } catch { XCTAssertEqual(error as? HostCoroutineMutex.Failure, .timedOut) }
        XCTAssertTrue(mutex.isLocked)
        XCTAssertEqual(mutex.waitingCount, 0)
        try mutex.unlock(owner: nil)
        XCTAssertTrue(try mutex.tryLock(owner: nil))
    }

    func testTaskCancellationDrainsQueuedAcquisition() async throws {
        let mutex = HostCoroutineMutex(locked: true)
        let task = Task {
            try await mutex.lock(owner: nil, maximumWaitNanoseconds: 1_000_000_000, cancelled: { false })
        }
        for _ in 0..<200 where mutex.waitingCount == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(mutex.waitingCount, 1)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { guard case VMError.cancelled = error else { return XCTFail("\(error)") } }
        XCTAssertEqual(mutex.waitingCount, 0)
        XCTAssertTrue(mutex.isLocked)
        try mutex.unlock(owner: nil)
    }

    func testVMCancellationDuringHandoffReleasesAcquiredPermit() async throws {
        let mutex = HostCoroutineMutex(locked: true)
        var checks = 0
        do {
            try await mutex.lock(owner: nil, maximumWaitNanoseconds: 1_000_000_000) {
                checks += 1
                if checks == 1 { try? mutex.unlock(owner: nil); return false }
                return true
            }
            XCTFail("Cancellation during handoff must precede the critical section")
        } catch { guard case VMError.cancelled = error else { return XCTFail("\(error)") } }
        XCTAssertFalse(mutex.isLocked)
        XCTAssertEqual(mutex.waitingCount, 0)
        XCTAssertTrue(try mutex.tryLock(owner: nil))
    }

    func testSuspendedCallerAcquiresAfterUnlock() async throws {
        let mutex = HostCoroutineMutex(locked: true)
        let token = owner()
        let task = Task {
            try await mutex.lock(owner: token, maximumWaitNanoseconds: 1_000_000_000, cancelled: { false })
        }
        for _ in 0..<200 where mutex.waitingCount == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(mutex.waitingCount, 1)
        XCTAssertFalse(mutex.holdsLock(owner: token))
        try mutex.unlock(owner: nil)
        _ = try await task.value
        XCTAssertTrue(mutex.holdsLock(owner: token))
        try mutex.unlock(owner: token)
        XCTAssertFalse(mutex.isLocked)
    }

    func testFactoryMaskAndRealDexSuspendResumeReturnUnitAndUnlock() async throws {
        let descriptor = "Lkotlinx/coroutines/sync/Mutex;"
        var builder = DexBuilder()
        let factory = builder.method(classDescriptor: "Lkotlinx/coroutines/sync/MutexKt;", name: "Mutex$default",
            shorty: "LZIL", ret: descriptor, parameters: ["Z", "I", "Ljava/lang/Object;"])
        let lock = builder.method(classDescriptor: descriptor, name: "lock", shorty: "LLL", ret: "Ljava/lang/Object;",
            parameters: ["Ljava/lang/Object;", "Lkotlin/coroutines/Continuation;"])
        let unlock = builder.method(classDescriptor: descriptor, name: "unlock", shorty: "VL", ret: "V", parameters: ["Ljava/lang/Object;"])
        builder.setClass("LTest;")
        builder.addMethod(.init(name: "run", registers: 5, ins: 0, outs: 3,
            insns: Insn.const4Units(0, 1) + Insn.const4Units(1, 1) + Insn.const4Units(2, 0)
                + Insn.invokeStatic(factory, [0, 1, 2]) + Insn.moveResultObject(3)
                + Insn.invokeInterface(lock, [3, 2, 2]) + Insn.moveResultObject(4)
                + Insn.invokeInterface(unlock, [3, 2]) + Insn.returnObjectReg(4),
            isStatic: true, returnType: "Ljava/lang/Object;"))
        let bridge = HostBridge.minimal()
        let vm = DexInterpreter(dex: try DexFile(builder.build()), bridge: bridge, maxInstructions: 100)
        let result = try await vm.callAsync(classDescriptor: "LTest;", method: "run")
        XCTAssertTrue(result === bridge.staticFields["Lkotlin/Unit;->INSTANCE"]!)
        let factoryMethod = try XCTUnwrap(bridge.resolve(class: "Lkotlinx/coroutines/sync/MutexKt;", "Mutex$default",
            prototype: "(ZILjava/lang/Object;)Lkotlinx/coroutines/sync/Mutex;", isStatic: true))
        let locked = try factoryMethod(vm, [.int(1), .int(0), .null])
        guard case let .obj(object) = locked, let mutex = object.payload as? HostCoroutineMutex else { return XCTFail("Expected mutex") }
        XCTAssertTrue(mutex.isLocked)
        let unlockMethod = try XCTUnwrap(bridge.resolve(class: descriptor, "unlock", prototype: "(Ljava/lang/Object;)V", isStatic: false))
        _ = try unlockMethod(vm, [locked, .null])
        XCTAssertThrowsError(try unlockMethod(vm, [locked, .null])) {
            guard let error = $0 as? DEXThrowable, case let .obj(value) = error.value else { return XCTFail("Expected typed exception") }
            XCTAssertEqual(value.dexType, "Ljava/lang/IllegalStateException;")
        }
    }

    func testActualDEXBudgetCleanupPreservesNormalAndThrownCrossEntryLockLifetimes() async throws {
        let descriptor = "Lkotlinx/coroutines/sync/Mutex;"
        var builder = DexBuilder()
        let lock = builder.method(classDescriptor: descriptor, name: "lock", shorty: "LLL", ret: "Ljava/lang/Object;",
            parameters: ["Ljava/lang/Object;", "Lkotlin/coroutines/Continuation;"])
        builder.setClass("LTest;")
        let acquire = Insn.const4Units(0, 0) + Insn.invokeInterface(lock, [1, 0, 0])
        for (name, code) in [
            ("hold", acquire + [0x000e]),
            ("abort", acquire + [0x0000, 0xff28]),
            ("throwNull", acquire + [0x0027]),
            ("spin", [UInt16(0x0000), 0xff28]),
        ] {
            builder.addMethod(.init(name: name, registers: 2, ins: 1, outs: 3,
                insns: code, isStatic: true, parameters: [descriptor]))
        }
        let bridge = HostBridge.minimal()
        defer { bridge.retire() }
        let vm = DexInterpreter(dex: try DexFile(builder.build()), bridge: bridge, maxInstructions: 64)
        let mutex = HostCoroutineMutex(locked: false)
        let value = RVal.obj(ObjInstance(dexType: descriptor, payload: mutex, isHost: true))
        func expectBudget(_ method: String) async throws {
            do { try await vm.callAsync(classDescriptor: "LTest;", method: method, args: [value]); XCTFail("Expected budget failure") }
            catch { guard case VMError.budgetExceeded(limit: 64) = error else { return XCTFail("\(error)") } }
        }
        try await expectBudget("abort")
        XCTAssertFalse(mutex.isLocked, "A guard must release the permit acquired by its session")
        try await vm.callAsync(classDescriptor: "LTest;", method: "hold", args: [value])
        XCTAssertTrue(mutex.isLocked, "Normal return may deliberately retain a Kotlin mutex")
        try await expectBudget("spin")
        XCTAssertTrue(mutex.isLocked, "An unrelated later guard cannot release an earlier permit")
        try mutex.unlock(owner: nil)
        do { try await vm.callAsync(classDescriptor: "LTest;", method: "throwNull", args: [value]); XCTFail("Expected DEX exception") }
        catch { XCTAssertTrue(error is DEXThrowable) }
        XCTAssertTrue(mutex.isLocked, "Ordinary DEX exceptions leave lock cleanup to the DEX finally block")
        try mutex.unlock(owner: nil)
    }
}
