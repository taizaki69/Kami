import XCTest
@testable import MihonCompatKit

/// Controlled-DEX execution tests (mission §30). Every test builds a real
/// DEX image with `DexBuilder`, parses it with `DexFile`, and executes with
/// `DexInterpreter` — proving actual bytecode execution, not parser output.
final class InterpreterTests: XCTestCase {
    private func run(_ builder: DexBuilder, method: String, args: [RVal] = []) throws -> RVal {
        var builder = builder
        let dex = try DexFile(builder.build())
        let vm = DexInterpreter(dex: dex)
        return try vm.call(classDescriptor: "LTest;", method: method, args: args)
    }

    private func int(_ v: RVal) -> Int32? {
        if case let .int(i) = v { return i }
        return nil
    }

    // MARK: arithmetic

    func testAddInt() throws {
        var b = DexBuilder()
        b.setClass("LTest;")
        b.addMethod(.init(name: "add", registers: 4, ins: 2, outs: 0,
                          insns: Insn.binop(0x90, 2, 0, 1) + Insn.returnReg(2), isStatic: true))
        b.addMethod(.init(name: "run", registers: 2, ins: 0, outs: 2,
                          insns: Insn.const4Units(0, 3) + Insn.const4Units(1, 4)
                              + Insn.invokeStatic(0, [0, 1]) + Insn.moveResult(0)
                              + Insn.returnReg(0), isStatic: true))
        let result = try run(b, method: "run")
        XCTAssertEqual(int(result), 7)
    }

    func testSubMulDiv() throws {
        var b = DexBuilder()
        b.setClass("LTest;")
        b.addMethod(.init(name: "calc", registers: 4, ins: 0, outs: 0,
                          insns: Insn.const4Units(0, 10)
                              + Insn.const4Units(1, 3)
                              + Insn.binop(0x94, 2, 0, 1)      // sub → 7
                              + Insn.const4Units(0, 6)
                              + Insn.binop(0x98, 3, 2, 0)      // mul → 42
                              + Insn.const4Units(0, 2)
                              + Insn.binop(0x9c, 1, 3, 0)      // div → 21
                              + Insn.returnReg(1),
                          isStatic: true))
        let result = try run(b, method: "calc")
        XCTAssertEqual(int(result), 21)
    }

    func testDivByZeroThrowsArithmeticException() throws {
        var b = DexBuilder()
        b.setClass("LTest;")
        b.addMethod(.init(name: "div", registers: 3, ins: 0, outs: 0,
                          insns: Insn.const4Units(0, 10)
                              + Insn.const4Units(1, 0)
                              + Insn.binop(0x9c, 2, 0, 1)
                              + Insn.returnReg(2),
                          isStatic: true))
        XCTAssertThrowsError(try run(b, method: "div")) { error in
            XCTAssertTrue(error is DEXThrowable, "expected DEXThrowable, got \(error)")
        }
    }

    // MARK: constants & strings

    func testConst16Negative() throws {
        var b = DexBuilder()
        b.setClass("LTest;")
        b.addMethod(.init(name: "neg", registers: 1, ins: 0, outs: 0,
                          insns: Insn.const16Units(0, -1234) + Insn.returnReg(0),
                          isStatic: true))
        XCTAssertEqual(int(try run(b, method: "neg")), -1234)
    }

    func testConstString() throws {
        var b = DexBuilder()
        b.string("https://batcave.com")
        b.setClass("LTest;")
        b.addMethod(.init(name: "url", registers: 1, ins: 0, outs: 0,
                          insns: Insn.constString(0, 0) + Insn.returnObjectReg(0),
                          isStatic: true))
        let result = try run(b, method: "url")
        XCTAssertEqual(vmStringValue(result), "https://batcave.com")
    }

    // MARK: control flow

    func testBranch() throws {
        var b = DexBuilder()
        b.setClass("LTest;")
        // const4 v0,1 ; if-nez v0,+3 → return ; const4 v0,0 ; return v0
        let insns: [UInt16] = Insn.const4Units(0, 1)
            + Insn.ifNez(0, 3)
            + Insn.const4Units(0, 0)
            + Insn.returnReg(0)
        b.addMethod(.init(name: "branch", registers: 1, ins: 0, outs: 0, insns: insns, isStatic: true))
        XCTAssertEqual(int(try run(b, method: "branch")), 1)
    }

    func testLoopSum() throws {
        var b = DexBuilder()
        b.setClass("LTest;")
        // v0 = 0 (sum), v1 = 1 (i); loop: if v1 > 10 goto end; sum += i; i++;
        // goto loop; end: return sum
        // Layout (pc units):
        // 0: const4 v0, 0        (1u)
        // 1: const4 v1, 1        (1u)
        // 2: const4 v2, 10       (1u)
        // 3: if-le v1, v2, +6 → pc 9+6=... careful math below
        // using if-lt inverse: if v1 >= 10 (if-ge) goto end
        let loop: [UInt16] =
            Insn.const4Units(0, 0)          // 0
            + Insn.const4Units(1, 1)        // 1
            + Insn.const16Units(2, 10)      // 2-3
            + Insn.ifLt(1, 2, 6)            // 4-5: if v1 < 10 → body at 4+... offset relative to THIS insn
            + Insn.returnReg(0)             // 6: end → wait, adjust below
        _ = loop
        // Simpler encoding, computed carefully:
        // pc0: const/4 v0, 0
        // pc1: const/4 v1, 1
        // pc2: const/16 v2, #10           (2 units)
        // pc4: if-ge v1, v2, +4           (2 units) → target = 4+4 = 8
        // pc6: add-int/lit8 v0, v0, #1    (2 units)
        // ... but we want sum += i (variable), so use add-int v0, v0, v1 (3 units) → adjust
        // Full rewrite with explicit units:
        var insns: [UInt16] = []
        insns += Insn.const4Units(0, 0)          // pc0
        insns += Insn.const4Units(1, 1)          // pc1
        insns += Insn.const16Units(2, 11)        // pc2-3 (sum while i < 11 → 1..10)
        // pc4: if-ge v1, v2, +7 (2 units) → target pc 11 (return)
        insns += [0x35 | UInt16(2 << 12) | UInt16(1 << 8), 7]
        // pc6: add-int v0, v0, v1 (3 units)
        insns += Insn.binop(0x90, 0, 0, 1)
        // pc9: add-int/lit8 v1, v1, #1 (2 units)
        insns += Insn.addLit8(1, 1, 1)
        // pc10: goto -6 (1 unit) → back to pc4
        insns += Insn.goto(-6)
        // pc12: return v0
        insns += Insn.returnReg(0)
        b.addMethod(.init(name: "sum", registers: 3, ins: 0, outs: 0, insns: insns, isStatic: true))
        XCTAssertEqual(int(try run(b, method: "sum")), 55)
    }

    // MARK: invocation

    func testInstanceMethodAndField() throws {
        var b = DexBuilder()
        b.setClass("LTest;", fields: [("value", "I")])
        b.addMethod(.init(name: "getValue", registers: 2, ins: 1, outs: 0,
                          insns: Insn.iget(0, 0, 0) + Insn.returnReg(0), isStatic: false))
        let testTypeIdx = b.typeIdx("LTest;")
        b.addMethod(.init(name: "run", registers: 3, ins: 0, outs: 1,
                          insns: Insn.newInstance(0, testTypeIdx)
                              + Insn.const16Units(1, 42)
                              + Insn.iput(1, 0, 0)
                              + Insn.invokeVirtual(0, [0])
                              + Insn.moveResult(1)
                              + Insn.returnReg(1),
                          isStatic: true))
        let dexBytes = b.build()
        let dex = try DexFile(dexBytes)
        let vm = DexInterpreter(dex: dex)
        let result = try vm.call(classDescriptor: "LTest;", method: "run")
        XCTAssertEqual(int(result), 42)
    }

    // MARK: arrays

    func testArrayWriteReadLength() throws {
        var b = DexBuilder()
        b.type("[I")
        b.setClass("LTest;")
        let arrTypeIdx = b.typeIdx("[I")
        b.addMethod(.init(name: "arr", registers: 4, ins: 0, outs: 0,
                          insns: Insn.const4Units(0, 3)
                              + Insn.newArray(1, 0, arrTypeIdx)
                              + Insn.const4Units(2, 1)
                              + Insn.const16Units(3, 1234)
                              + Insn.aput(3, 1, 2)
                              + Insn.aget(0, 1, 2)
                              + Insn.returnReg(0),
                          isStatic: true))
        XCTAssertEqual(int(try run(b, method: "arr")), 1234)
    }

    func testArrayOutOfBoundsThrows() throws {
        var b = DexBuilder()
        b.type("[I")
        b.setClass("LTest;")
        let arrTypeIdx = b.typeIdx("[I")
        b.addMethod(.init(name: "oob", registers: 3, ins: 0, outs: 0,
                          insns: Insn.const4Units(0, 1)
                              + Insn.newArray(1, 0, arrTypeIdx)
                              + Insn.const4Units(2, 5)
                              + Insn.aget(0, 1, 2)
                              + Insn.returnReg(0),
                          isStatic: true))
        XCTAssertThrowsError(try run(b, method: "oob")) { error in
            XCTAssertTrue(error is DEXThrowable)
        }
    }

    // MARK: host bridge

    func testStringBuilderViaHostBridge() throws {
        var b = DexBuilder()
        b.type("Ljava/lang/StringBuilder;")
        b.setClass("LTest;")
        let sbType = b.typeIdx("Ljava/lang/StringBuilder;")
        b.method(classDescriptor: "Ljava/lang/StringBuilder;", name: "append", shorty: "LL", ret: "L")
        b.method(classDescriptor: "Ljava/lang/StringBuilder;", name: "toString", shorty: "L", ret: "L")
        let appendIdx = 0
        let toStringIdx = 1
        b.addMethod(.init(name: "greet", registers: 2, ins: 0, outs: 2,
                          insns: Insn.newInstance(0, sbType)
                              + Insn.constString(1, b.string("Kami"))
                              + Insn.invokeVirtual(appendIdx, [0, 1])
                              + Insn.moveResult(0)
                              + Insn.invokeVirtual(toStringIdx, [0])
                              + Insn.moveResult(0)
                              + Insn.returnObjectReg(0),
                          isStatic: true))
        XCTAssertEqual(vmStringValue(try run(b, method: "greet")), "Kami")
    }

    // MARK: budget

    func testRunawayLoopHitsBudget() throws {
        var b = DexBuilder()
        b.setClass("LTest;")
        // infinite loop: pc0 goto 0
        b.addMethod(.init(name: "spin", registers: 1, ins: 0, outs: 0,
                          insns: Insn.goto(0), isStatic: true))
        let dex = try DexFile(b.build())
        let vm = DexInterpreter(dex: dex, maxInstructions: 10_000)
        XCTAssertThrowsError(try vm.call(classDescriptor: "LTest;", method: "spin")) { error in
            guard case let VMError.budgetExceeded(limit) = error else {
                return XCTFail("expected budgetExceeded, got \(error)")
            }
            XCTAssertEqual(limit, 10_000)
        }
    }

    // MARK: instantiation

    func testConstructorRuns() throws {
        var b = DexBuilder()
        b.setClass("LTest;", fields: [("x", "I")])
        b.method(classDescriptor: "LTest;", name: "<init>", shorty: "V", ret: "V")
        b.method(classDescriptor: "LTest;", name: "get", shorty: "I", ret: "I")
        // <init>(v0=this): iput #7 → v0.x ; return-void
        b.addMethod(.init(name: "<init>", registers: 2, ins: 1, outs: 0,
                          insns: Insn.const4Units(1, 7)
                              + Insn.iput(1, 0, 0)
                              + Insn.returnVoid(),
                          isStatic: false))
        b.addMethod(.init(name: "get", registers: 2, ins: 1, outs: 0,
                          insns: Insn.iget(0, 0, 0) + Insn.returnReg(0), isStatic: false))
        let dex = try DexFile(b.build())
        let vm = DexInterpreter(dex: dex)
        let obj = try vm.instantiate(classDescriptor: "LTest;")
        guard case let .obj(o) = obj else { return XCTFail("expected object") }
        guard case let .int(x)? = o.fields["x"] else { return XCTFail("expected int field") }
        XCTAssertEqual(x, 7)
        let got = try vm.call(classDescriptor: "LTest;", method: "get", args: [obj])
        XCTAssertEqual(int(got), 7)
    }
}

extension DexBuilder {
    /// Index of a type descriptor (registering if needed).
    mutating func typeIdx(_ descriptor: String) -> Int {
        type(descriptor)
    }
}
