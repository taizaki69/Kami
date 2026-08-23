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

    private func long(_ v: RVal) -> Int64? {
        if case let .long(i) = v { return i }
        return nil
    }

    private func float(_ v: RVal) -> Float? {
        if case let .float(f) = v { return f }
        return nil
    }

    private func double(_ v: RVal) -> Double? {
        if case let .double(d) = v { return d }
        return nil
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

    // MARK: arithmetic

    func testAddInt() throws {
        var b = DexBuilder()
        b.setClass("LTest;")
        b.addMethod(.init(name: "add", registers: 4, ins: 2, outs: 0,
                          insns: Insn.binop(0x90, 2, 2, 3) + Insn.returnReg(2), isStatic: true,
                          returnType: "I", parameters: ["I", "I"]))
        b.addMethod(.init(name: "run", registers: 2, ins: 0, outs: 2,
                          insns: Insn.const4Units(0, 3) + Insn.const4Units(1, 4)
                              + Insn.invokeStatic(0, [0, 1]) + Insn.moveResult(0)
                              + Insn.returnReg(0), isStatic: true, returnType: "I"))
        let result = try run(b, method: "run")
        XCTAssertEqual(int(result), 7)
    }

    func testSubMulDiv() throws {
        var b = DexBuilder()
        b.setClass("LTest;")
        b.addMethod(.init(name: "calc", registers: 4, ins: 0, outs: 0,
                          insns: Insn.const16Units(0, 10)
                              + Insn.const4Units(1, 3)
                              + Insn.binop(0x91, 2, 0, 1)      // sub → 7
                              + Insn.const4Units(0, 6)
                              + Insn.binop(0x92, 3, 2, 0)      // mul → 42
                              + Insn.const4Units(0, 2)
                              + Insn.binop(0x93, 1, 3, 0)      // div → 21
                              + Insn.returnReg(1),
                          isStatic: true, returnType: "I"))
        let result = try run(b, method: "calc")
        XCTAssertEqual(int(result), 21)
    }

    func testDivByZeroThrowsArithmeticException() throws {
        var b = DexBuilder()
        b.setClass("LTest;")
        b.addMethod(.init(name: "div", registers: 3, ins: 0, outs: 0,
                          insns: Insn.const4Units(0, 10)
                              + Insn.const4Units(1, 0)
                              + Insn.binop(0x93, 2, 0, 1)
                              + Insn.returnReg(2),
                          isStatic: true, returnType: "I"))
        XCTAssertThrowsError(try run(b, method: "div")) { error in
            XCTAssertTrue(error is DEXThrowable, "expected DEXThrowable, got \(error)")
        }
    }

    func testJavaIntegerDivisionOverflowDoesNotCrashHost() throws {
        var division = DexBuilder()
        division.setClass("LTest;")
        division.addMethod(.init(
            name: "divide", registers: 3, ins: 0, outs: 0,
            insns: [
                0x0014, 0x0000, 0x8000, // const v0, Int32.min
                0xf112,                 // const/4 v1, -1
                0x0293, 0x0100,         // div-int v2, v0, v1
                0x020f,
            ],
            isStatic: true,
            returnType: "I"
        ))
        XCTAssertEqual(int(try run(division, method: "divide")), .min)

        var remainder = DexBuilder()
        remainder.setClass("LTest;")
        remainder.addMethod(.init(
            name: "remainder", registers: 3, ins: 0, outs: 0,
            insns: [0x0014, 0x0000, 0x8000, 0xf112, 0x0294, 0x0100, 0x020f],
            isStatic: true,
            returnType: "I"
        ))
        XCTAssertEqual(int(try run(remainder, method: "remainder")), 0)
    }

    /// Raw 35c units from the Android instruction-format table. This is kept
    /// independent from `Insn.invokeKind` so encoder and decoder cannot share
    /// the same operand-order bug.
    func testInvoke35cUsesMethodIndexBeforeRegisterWord() throws {
        var b = DexBuilder()
        b.setClass("LTest;")
        b.addMethod(.init(
            name: "add", registers: 4, ins: 2, outs: 0,
            insns: [0x0290, 0x0302, 0x020f], // add-int v2,v2,v3; return v2
            isStatic: true,
            returnType: "I",
            parameters: ["I", "I"]
        ))
        b.addMethod(.init(
            name: "run", registers: 2, ins: 0, outs: 2,
            insns: [
                0x3012, 0x4112,             // const/4 v0,3; const/4 v1,4
                0x2071, 0x0000, 0x0010,     // invoke-static {v0,v1}, method@0
                0x000a, 0x000f,             // move-result v0; return v0
            ],
            isStatic: true,
            returnType: "I"
        ))
        XCTAssertEqual(int(try run(b, method: "run")), 7)
    }

    func testNameOnlyPublicCallRejectsOverloadAmbiguityAndExactCallSelectsPrototype() throws {
        var builder = DexBuilder()
        builder.setClass("LTest;")
        builder.addMethod(.init(
            name: "pick", registers: 1, ins: 0, outs: 0,
            insns: Insn.const4Units(0, 1) + Insn.returnReg(0),
            isStatic: true, returnType: "I"
        ))
        builder.addMethod(.init(
            name: "pick", registers: 2, ins: 1, outs: 0,
            insns: Insn.const4Units(0, 2) + Insn.returnReg(0),
            isStatic: true, returnType: "I", parameters: ["Ljava/lang/String;"]
        ))
        let dex = try DexFile(builder.build())
        let vm = DexInterpreter(dex: dex)

        XCTAssertThrowsError(try vm.call(classDescriptor: "LTest;", method: "pick")) { error in
            guard case let VMError.ambiguousMethod(_, _, candidates) = error else {
                return XCTFail("expected ambiguousMethod, got \(error)")
            }
            XCTAssertEqual(candidates, ["pick()I", "pick(Ljava/lang/String;)I"])
        }
        XCTAssertEqual(
            int(try vm.call(classDescriptor: "LTest;", method: "pick", prototype: "()I")),
            1
        )
        XCTAssertEqual(
            int(try vm.call(
                classDescriptor: "LTest;",
                method: "pick",
                prototype: "(Ljava/lang/String;)I",
                args: [HostBridge.string("Kami")]
            )),
            2
        )
    }

    func testMalformedInvokeRejectsMissingWideRegisterWord() throws {
        var builder = DexBuilder()
        let target = builder.method(
            classDescriptor: "LHost;", name: "accept", shorty: "VJ", ret: "V", parameters: ["J"]
        )
        builder.setClass("LTest;")
        builder.addMethod(.init(
            name: "run", registers: 1, ins: 0, outs: 2,
            insns: Insn.const4Units(0, 0)
                + Insn.invokeStatic(target, [0])
                + Insn.returnVoid(),
            isStatic: true
        ))

        XCTAssertThrowsError(try run(builder, method: "run")) { error in
            guard case let VMError.verify(message) = error else {
                return XCTFail("expected verification error, got \(error)")
            }
            XCTAssertTrue(message.contains("expects 2 invoke register words"), message)
        }
    }

    func testInvokeRejectsStaticInstanceMismatchForDefinedMethod() throws {
        var builder = DexBuilder()
        let objectInit = builder.method(
            classDescriptor: "Ljava/lang/Object;", name: "<init>"
        )
        builder.setClass("LTest;")
        builder.addMethod(.init(
            name: "target", registers: 1, ins: 0, outs: 0,
            insns: Insn.const4Units(0, 7) + Insn.returnReg(0),
            isStatic: true, returnType: "I"
        ))
        let testType = builder.typeIdx("LTest;")
        builder.addMethod(.init(
            name: "run", registers: 1, ins: 0, outs: 1,
            insns: Insn.newInstance(0, testType)
                + Insn.invokeDirect(objectInit, [0])
                + Insn.invokeVirtual(1, [0])
                + Insn.returnVoid(),
            isStatic: true
        ))

        XCTAssertThrowsError(try run(builder, method: "run")) { error in
            guard case let VMError.verify(message) = error else {
                return XCTFail("expected verification error, got \(error)")
            }
            XCTAssertTrue(message.contains("invoked as instance"), message)
        }
    }

    func testIncomingArgumentsOccupyLastRegisters() throws {
        var b = DexBuilder()
        b.setClass("LTest;")
        b.addMethod(.init(name: "echo", registers: 4, ins: 1, outs: 0,
                          insns: [0x030f], isStatic: true, returnType: "I", parameters: ["I"])) // return v3
        XCTAssertEqual(int(try run(b, method: "echo", args: [.int(42)])), 42)
    }

    func testClassInitializerRunsExactlyOnceBeforeStaticUse() throws {
        var builder = DexBuilder()
        builder.setClass("LTest;", staticFields: [("initializationCount", "I")])
        builder.addMethod(.init(
            name: "<clinit>", registers: 1, ins: 0, outs: 0,
            insns: Insn.sget(0, 0)
                + Insn.addLit8(0, 0, 1)
                + Insn.sput(0, 0)
                + Insn.returnVoid(),
            isStatic: true
        ))
        builder.addMethod(.init(
            name: "read", registers: 1, ins: 0, outs: 0,
            insns: Insn.sget(0, 0) + Insn.returnReg(0),
            isStatic: true, returnType: "I"
        ))
        let bytes = builder.build()
        let dex = try DexFile(bytes)
        let limitedVM = DexInterpreter(dex: dex, maxInstructions: 5)
        XCTAssertThrowsError(try limitedVM.call(
            classDescriptor: "LTest;", method: "read", prototype: "()I"
        )) { error in
            guard case VMError.budgetExceeded = error else {
                return XCTFail("expected class initialization to share the call budget, got \(error)")
            }
        }

        let vm = DexInterpreter(dex: dex)

        XCTAssertEqual(
            int(try vm.call(classDescriptor: "LTest;", method: "read", prototype: "()I")),
            1
        )
        XCTAssertEqual(
            int(try vm.call(classDescriptor: "LTest;", method: "read", prototype: "()I")),
            1,
            "<clinit> must not run again after successful initialization"
        )
    }

    func testRaw12xAndSignedConst4() throws {
        var b = DexBuilder()
        b.setClass("LTest;")
        b.addMethod(.init(name: "move", registers: 2, ins: 0, outs: 0,
                          insns: [0xf012, 0x0101, 0x010f], isStatic: true, returnType: "I"))
        XCTAssertEqual(int(try run(b, method: "move")), -1)
    }

    func testRawUnaryAndTwoAddressFormats() throws {
        var unary = DexBuilder()
        unary.setClass("LTest;")
        unary.addMethod(.init(name: "neg", registers: 2, ins: 0, outs: 0,
                              insns: [0x8012, 0x017b, 0x010f], isStatic: true, returnType: "I"))
        XCTAssertEqual(int(try run(unary, method: "neg")), 8)

        var twoAddress = DexBuilder()
        twoAddress.setClass("LTest;")
        twoAddress.addMethod(.init(name: "add", registers: 2, ins: 2, outs: 0,
                                   insns: [0x10b0, 0x000f], isStatic: true,
                                   returnType: "I", parameters: ["I", "I"]))
        XCTAssertEqual(int(try run(twoAddress, method: "add", args: [.int(12), .int(30)])), 42)
    }

    func testRawLit16ConstWide32AndFloatMultiply() throws {
        var literal = DexBuilder()
        literal.setClass("LTest;")
        literal.addMethod(.init(name: "mul", registers: 2, ins: 0, outs: 0,
                                insns: [0x2112, 0x10d2, 0x012c, 0x000f], isStatic: true,
                                returnType: "I"))
        XCTAssertEqual(int(try run(literal, method: "mul")), 600)

        var wide = DexBuilder()
        wide.setClass("LTest;")
        wide.addMethod(.init(name: "wide", registers: 2, ins: 0, outs: 0,
                             insns: [0x0017, 0x0002, 0x0001, 0x0010], isStatic: true,
                             returnType: "J"))
        XCTAssertEqual(long(try run(wide, method: "wide")), 65_538)

        var floating = DexBuilder()
        floating.setClass("LTest;")
        floating.addMethod(.init(name: "mul", registers: 3, ins: 2, outs: 0,
                                 insns: [0x00a8, 0x0201, 0x000f], isStatic: true,
                                 returnType: "F", parameters: ["F", "F"]))
        XCTAssertEqual(float(try run(floating, method: "mul", args: [.float(1.5), .float(4)])), 6)
    }

    func testReferenceBranchesUseIdentityNotStringPayload() throws {
        var b = DexBuilder()
        b.setClass("LTest;")
        b.addMethod(.init(
            name: "same", registers: 3, ins: 2, outs: 0,
            insns: [0x0012, 0x2132, 0x0003, 0x000f, 0x1012, 0x000f],
            isStatic: true,
            returnType: "I",
            parameters: ["Ljava/lang/Object;", "Ljava/lang/Object;"]
        ))
        let first = HostBridge.string("same")
        let second = HostBridge.string("same")
        XCTAssertEqual(int(try run(b, method: "same", args: [first, second])), 0)
        XCTAssertEqual(int(try run(b, method: "same", args: [first, first])), 1)
    }

    func testMalformedSwitchPayloadIsCatchable() throws {
        var b = DexBuilder()
        b.setClass("LTest;")
        b.addMethod(.init(name: "switch", registers: 1, ins: 0, outs: 0,
                          insns: [0x002b, 0x7fff, 0x7fff, 0x000f], isStatic: true,
                          returnType: "I"))
        XCTAssertThrowsError(try run(b, method: "switch")) { error in
            guard case let VMError.verify(message) = error else {
                return XCTFail("expected verification error, got \(error)")
            }
            XCTAssertTrue(message.contains("payload"), message)
        }
    }

    func testVerifierRejectsTruncatedInstructionBeforeExecution() throws {
        var builder = DexBuilder()
        builder.setClass("LTest;")
        builder.addMethod(.init(
            name: "truncated", registers: 1, ins: 0, outs: 0,
            insns: [0x0014, 0x0000], // const v0 requires three code units
            isStatic: true, returnType: "I"
        ))

        XCTAssertThrowsError(try run(builder, method: "truncated")) { error in
            guard case let VMError.verify(message) = error else {
                return XCTFail("expected verification error, got \(error)")
            }
            XCTAssertTrue(message.contains("truncated opcode"), message)
        }
    }

    func testVerifierRejectsBranchIntoInstructionOperand() throws {
        var builder = DexBuilder()
        builder.setClass("LTest;")
        builder.addMethod(.init(
            name: "badBranch", registers: 0, ins: 0, outs: 0,
            insns: [
                0x0029, 0x0001, // goto/16 +1 targets its own offset operand
                0x000e,         // return-void
            ],
            isStatic: true
        ))

        XCTAssertThrowsError(try run(builder, method: "badBranch")) { error in
            guard case let VMError.verify(message) = error else {
                return XCTFail("expected verification error, got \(error)")
            }
            XCTAssertTrue(message.contains("non-instruction pc 1"), message)
        }
    }

    func testVerifierRejectsForbiddenZeroBranchOffsets() throws {
        var shortGoto = DexBuilder()
        shortGoto.setClass("LTest;")
        shortGoto.addMethod(.init(
            name: "shortGoto", registers: 0, ins: 0, outs: 0,
            insns: [0x0028, 0x000e], isStatic: true
        ))
        XCTAssertThrowsError(try run(shortGoto, method: "shortGoto")) { error in
            guard case let VMError.verify(message) = error else {
                return XCTFail("expected verification error, got \(error)")
            }
            XCTAssertTrue(message.contains("forbidden zero offset"), message)
        }

        var conditional = DexBuilder()
        conditional.setClass("LTest;")
        conditional.addMethod(.init(
            name: "conditional", registers: 1, ins: 0, outs: 0,
            insns: [0x0038, 0x0000, 0x000e], isStatic: true
        ))
        XCTAssertThrowsError(try run(conditional, method: "conditional")) { error in
            guard case let VMError.verify(message) = error else {
                return XCTFail("expected verification error, got \(error)")
            }
            XCTAssertTrue(message.contains("forbidden zero offset"), message)
        }
    }

    func testVerifierRejectsInvalidMoveResultControlFlow() throws {
        var misplaced = DexBuilder()
        misplaced.setClass("LTest;")
        misplaced.addMethod(.init(
            name: "misplacedResult", registers: 1, ins: 0, outs: 0,
            insns: [0x000a, 0x000e], isStatic: true
        ))
        XCTAssertThrowsError(try run(misplaced, method: "misplacedResult")) { error in
            guard case let VMError.verify(message) = error else {
                return XCTFail("expected verification error, got \(error)")
            }
            XCTAssertTrue(message.contains("is not immediately after a matching producer"), message)
        }

        var branchTarget = DexBuilder()
        branchTarget.setClass("LTest;")
        branchTarget.addMethod(.init(
            name: "branchResult", registers: 1, ins: 0, outs: 0,
            insns: [
                0x0428,                   // pc 0: goto +4
                0x0071, 0x0000, 0x0000,   // pc 1: invoke-static method@0
                0x000a,                   // pc 4: valid adjacent move-result
                0x000e,
            ],
            isStatic: true
        ))
        XCTAssertThrowsError(try run(branchTarget, method: "branchResult")) { error in
            guard case let VMError.verify(message) = error else {
                return XCTFail("expected verification error, got \(error)")
            }
            XCTAssertTrue(message.contains("targets move-result pc 4"), message)
        }
    }

    func testVerifierRejectsOversizedOutsRegisterWindow() throws {
        var builder = DexBuilder()
        builder.setClass("LTest;")
        builder.addMethod(.init(
            name: "badOuts", registers: 1, ins: 0, outs: 6,
            insns: [0x000e], isStatic: true
        ))

        XCTAssertThrowsError(try run(builder, method: "badOuts")) { error in
            guard case let VMError.verify(message) = error else {
                return XCTFail("expected verification error, got \(error)")
            }
            XCTAssertTrue(message.contains("outs_size 6 exceeds registers_size 1"), message)
        }
    }

    func testRegisterVerifierRejectsOutOfBoundsOperandInDeadCode() throws {
        var builder = DexBuilder()
        builder.setClass("LTest;")
        builder.addMethod(.init(
            name: "deadRegister", registers: 1, ins: 0, outs: 0,
            insns: [
                0x0328,       // pc 0: goto pc 3
                0x0002, 0x0001, // pc 1: move/from16 v0, v1 (dead, but invalid)
                0x000e,
            ],
            isStatic: true
        ))

        XCTAssertThrowsError(try run(builder, method: "deadRegister")) { error in
            guard case let VMError.verify(message) = error else {
                return XCTFail("expected verification error, got \(error)")
            }
            XCTAssertTrue(message.contains("register v1 at pc 1 is outside"), message)
        }
    }

    func testRegisterVerifierRejectsUndefinedReturn() throws {
        var builder = DexBuilder()
        builder.setClass("LTest;")
        builder.addMethod(.init(
            name: "undefinedReturn", registers: 1, ins: 0, outs: 0,
            insns: [0x000f], isStatic: true, returnType: "I"
        ))

        XCTAssertThrowsError(try run(builder, method: "undefinedReturn")) { error in
            guard case let VMError.verify(message) = error else {
                return XCTFail("expected verification error, got \(error)")
            }
            XCTAssertTrue(message.contains("return value v0"), message)
            XCTAssertTrue(message.contains("undefined"), message)
        }
    }

    func testRegisterVerifierRejectsConflictingJoin() throws {
        var builder = DexBuilder()
        let stringIndex = builder.string("Kami")
        builder.setClass("LTest;")
        builder.addMethod(.init(
            name: "conflictingJoin", registers: 2, ins: 0, outs: 0,
            insns: [
                0x0112,                   // pc 0: const/4 v1, 0
                0x0138, 0x0004,           // pc 1: if-eqz v1, pc 5
                0x1012,                   // pc 3: const/4 v0, 1
                0x0328,                   // pc 4: goto pc 7
                0x001a, UInt16(stringIndex), // pc 5: const-string v0
                0x0011,                   // pc 7: return-object v0
            ],
            isStatic: true, returnType: "Ljava/lang/Object;"
        ))

        XCTAssertThrowsError(try run(builder, method: "conflictingJoin")) { error in
            guard case let VMError.verify(message) = error else {
                return XCTFail("expected verification error, got \(error)")
            }
            XCTAssertTrue(message.contains("return value v0"), message)
            XCTAssertTrue(message.contains("conflict"), message)
        }
    }

    func testRegisterVerifierMergesZeroWithReference() throws {
        var builder = DexBuilder()
        let stringIndex = builder.string("Kami")
        builder.setClass("LTest;")
        builder.addMethod(.init(
            name: "nullableJoin", registers: 2, ins: 0, outs: 0,
            insns: [
                0x0112,                   // pc 0: const/4 v1, 0
                0x0138, 0x0004,           // pc 1: if-eqz v1, pc 5
                0x0012,                   // pc 3: const/4 v0, 0 (null-compatible)
                0x0328,                   // pc 4: goto pc 7
                0x001a, UInt16(stringIndex), // pc 5: const-string v0
                0x0011,                   // pc 7: return-object v0
            ],
            isStatic: true, returnType: "Ljava/lang/Object;"
        ))

        XCTAssertEqual(vmStringValue(try run(builder, method: "nullableJoin")), "Kami")
    }

    func testRegisterVerifierRejectsMoveResultCategoryMismatch() throws {
        var builder = DexBuilder()
        let target = builder.method(
            classDescriptor: "LHost;", name: "object", shorty: "L",
            ret: "Ljava/lang/Object;"
        )
        builder.setClass("LTest;")
        builder.addMethod(.init(
            name: "badResult", registers: 1, ins: 0, outs: 0,
            insns: Insn.invokeStatic(target, []) + Insn.moveResult(0) + Insn.returnVoid(),
            isStatic: true
        ))

        XCTAssertThrowsError(try run(builder, method: "badResult")) { error in
            guard case let VMError.verify(message) = error else {
                return XCTFail("expected verification error, got \(error)")
            }
            XCTAssertTrue(message.contains("does not match result Ljava/lang/Object;"), message)
        }
    }

    func testRegisterVerifierRejectsInvokeArgumentCategoryMismatch() throws {
        var builder = DexBuilder()
        let target = builder.method(
            classDescriptor: "LHost;", name: "accept", shorty: "VL", ret: "V",
            parameters: ["Ljava/lang/Object;"]
        )
        builder.setClass("LTest;")
        builder.addMethod(.init(
            name: "badArgument", registers: 1, ins: 0, outs: 1,
            insns: Insn.const4Units(0, 1)
                + Insn.invokeStatic(target, [0])
                + Insn.returnVoid(),
            isStatic: true
        ))

        XCTAssertThrowsError(try run(builder, method: "badArgument")) { error in
            guard case let VMError.verify(message) = error else {
                return XCTFail("expected verification error, got \(error)")
            }
            XCTAssertTrue(message.contains("invoke argument 0 v0"), message)
            XCTAssertTrue(message.contains("expected initialized reference"), message)
        }
    }

    func testRegisterVerifierRejectsClobberedWidePair() throws {
        var builder = DexBuilder()
        builder.setClass("LTest;")
        builder.addMethod(.init(
            name: "clobberedWide", registers: 2, ins: 0, outs: 0,
            insns: [
                0x0016, 0x0001, // const-wide/16 v0, 1
                0x0112,         // const/4 v1, 0; clobbers the high half
                0x0010,         // return-wide v0
            ],
            isStatic: true, returnType: "J"
        ))

        XCTAssertThrowsError(try run(builder, method: "clobberedWide")) { error in
            guard case let VMError.verify(message) = error else {
                return XCTFail("expected verification error, got \(error)")
            }
            XCTAssertTrue(message.contains("return value v0"), message)
            XCTAssertTrue(message.contains("expected wide pair"), message)
        }
    }

    func testRegisterVerifierRejectsFloatInIntegerOpcode() throws {
        var builder = DexBuilder()
        builder.setClass("LTest;")
        builder.addMethod(.init(
            name: "floatAsInt", registers: 2, ins: 0, outs: 0,
            insns: Insn.const4Units(0, 1)
                + [0x0082] // int-to-float v0, v0
                + Insn.const4Units(1, 2)
                + Insn.binop(0x90, 0, 0, 1) // add-int v0, v0, v1
                + Insn.returnReg(0),
            isStatic: true, returnType: "I"
        ))

        XCTAssertThrowsError(try run(builder, method: "floatAsInt")) { error in
            guard case let VMError.verify(message) = error else {
                return XCTFail("expected verification error, got \(error)")
            }
            XCTAssertTrue(message.contains("binary lhs v0"), message)
            XCTAssertTrue(message.contains("has float, expected integral"), message)
        }
    }

    func testRegisterVerifierDistinguishesLongAndDoublePairs() throws {
        var builder = DexBuilder()
        builder.setClass("LTest;")
        builder.addMethod(.init(
            name: "longAsDouble", registers: 3, ins: 0, outs: 0,
            insns: Insn.const4Units(0, 1)
                + [0x0181] // int-to-long v1, v0
                + [0x0110], // return-wide v1
            isStatic: true, returnType: "D"
        ))

        XCTAssertThrowsError(try run(builder, method: "longAsDouble")) { error in
            guard case let VMError.verify(message) = error else {
                return XCTFail("expected verification error, got \(error)")
            }
            XCTAssertTrue(message.contains("return value v1"), message)
            XCTAssertTrue(message.contains("has long-low, expected double pair"), message)
        }
    }

    func testRegisterVerifierAllowsPolymorphicNumericConstants() throws {
        var builder = DexBuilder()
        builder.setClass("LTest;")
        builder.addMethod(.init(
            name: "floatConstants", registers: 2, ins: 0, outs: 0,
            insns: Insn.const4Units(0, 0)
                + Insn.const4Units(1, 0)
                + Insn.binop(0xa6, 0, 0, 1) // add-float
                + Insn.returnReg(0),
            isStatic: true, returnType: "F"
        ))
        builder.addMethod(.init(
            name: "doubleConstants", registers: 4, ins: 0, outs: 0,
            insns: [
                0x0016, 0x0000, // const-wide/16 v0, 0
                0x0216, 0x0000, // const-wide/16 v2, 0
                0x00ab, 0x0200, // add-double v0, v0, v2
                0x0010,         // return-wide v0
            ],
            isStatic: true, returnType: "D"
        ))

        XCTAssertEqual(float(try run(builder, method: "floatConstants")), 0)
        XCTAssertEqual(double(try run(builder, method: "doubleConstants")), 0)
    }

    func testRegisterVerifierTracksConversionOutputType() throws {
        var builder = DexBuilder()
        builder.setClass("LTest;")
        builder.addMethod(.init(
            name: "convertedDouble", registers: 3, ins: 0, outs: 0,
            insns: Insn.const4Units(0, 1)
                + [0x0183] // int-to-double v1, v0
                + [0x0110], // return-wide v1
            isStatic: true, returnType: "D"
        ))

        XCTAssertEqual(double(try run(builder, method: "convertedDouble")), 1)
    }

    func testRegisterVerifierRejectsUninitializedReturn() throws {
        var builder = DexBuilder()
        builder.setClass("LTest;")
        let testType = builder.typeIdx("LTest;")
        builder.addMethod(.init(
            name: "uninitializedReturn", registers: 1, ins: 0, outs: 0,
            insns: Insn.newInstance(0, testType) + Insn.returnObjectReg(0),
            isStatic: true, returnType: "LTest;"
        ))

        XCTAssertThrowsError(try run(builder, method: "uninitializedReturn")) { error in
            guard case let VMError.verify(message) = error else {
                return XCTFail("expected verification error, got \(error)")
            }
            XCTAssertTrue(message.contains("return value v0"), message)
            XCTAssertTrue(message.contains("uninitialized LTest;@0"), message)
        }
    }

    func testRegisterVerifierConstructorInitializesEveryAlias() throws {
        var builder = DexBuilder()
        let objectInit = builder.method(
            classDescriptor: "Ljava/lang/Object;", name: "<init>"
        )
        builder.setClass("LTest;")
        let testType = builder.typeIdx("LTest;")
        builder.addMethod(.init(
            name: "initializedAlias", registers: 2, ins: 0, outs: 1,
            insns: Insn.newInstance(0, testType)
                + [0x0107] // move-object v1, v0
                + Insn.invokeDirect(objectInit, [1])
                + Insn.returnObjectReg(0),
            isStatic: true, returnType: "LTest;"
        ))

        guard case let .obj(object) = try run(builder, method: "initializedAlias") else {
            return XCTFail("expected object result")
        }
        XCTAssertEqual(object.dexType, "LTest;")
    }

    func testRegisterVerifierRejectsConstructorOnInitializedReference() throws {
        var builder = DexBuilder()
        let objectInit = builder.method(
            classDescriptor: "Ljava/lang/Object;", name: "<init>"
        )
        let text = builder.string("already initialized")
        builder.setClass("LTest;")
        builder.addMethod(.init(
            name: "doubleInit", registers: 1, ins: 0, outs: 1,
            insns: Insn.constString(0, text)
                + Insn.invokeDirect(objectInit, [0])
                + Insn.returnVoid(),
            isStatic: true
        ))

        XCTAssertThrowsError(try run(builder, method: "doubleInit")) { error in
            guard case let VMError.verify(message) = error else {
                return XCTFail("expected verification error, got \(error)")
            }
            XCTAssertTrue(message.contains("expected uninitialized constructor receiver"), message)
        }
    }

    func testRegisterVerifierRejectsConstructorReturnBeforeSuperCall() throws {
        var builder = DexBuilder()
        builder.setClass("LTest;", superclass: "Ljava/lang/Object;")
        builder.addMethod(.init(
            name: "<init>", registers: 1, ins: 1, outs: 0,
            insns: Insn.returnVoid(),
            isStatic: false
        ))
        let dex = try DexFile(builder.build())
        let vm = DexInterpreter(dex: dex)

        XCTAssertThrowsError(try vm.instantiate(classDescriptor: "LTest;")) { error in
            guard case let VMError.verify(message) = error else {
                return XCTFail("expected verification error, got \(error)")
            }
            XCTAssertTrue(message.contains("before initializing this"), message)
        }
    }

    func testRegisterVerifierRejectsInitializedUninitializedMerge() throws {
        var builder = DexBuilder()
        let objectInit = builder.method(
            classDescriptor: "Ljava/lang/Object;", name: "<init>"
        )
        builder.setClass("LTest;")
        let testType = builder.typeIdx("LTest;")
        builder.addMethod(.init(
            name: "partialInit", registers: 2, ins: 0, outs: 1,
            insns: Insn.newInstance(0, testType) // pc 0...1
                + Insn.const4Units(1, 0)         // pc 2
                + Insn.ifEqz(1, 5)              // pc 3...4 -> pc 8
                + Insn.invokeDirect(objectInit, [0]) // pc 5...7
                + Insn.returnObjectReg(0),       // pc 8
            isStatic: true, returnType: "LTest;"
        ))

        XCTAssertThrowsError(try run(builder, method: "partialInit")) { error in
            guard case let VMError.verify(message) = error else {
                return XCTFail("expected verification error, got \(error)")
            }
            XCTAssertTrue(message.contains("return value v0"), message)
            XCTAssertTrue(
                message.contains("uninitialized") || message.contains("conflict"),
                message
            )
        }
    }

    func testRegisterVerifierPropagatesExceptionEdges() throws {
        var builder = DexBuilder()
        let target = builder.method(classDescriptor: "LHost;", name: "mayThrow")
        builder.setClass("LTest;")
        builder.addMethod(.init(
            name: "handlerState", registers: 1, ins: 0, outs: 0,
            insns: Insn.invokeStatic(target, [])
                + Insn.const4Units(0, 1)
                + Insn.returnReg(0)
                + Insn.returnReg(0),
            isStatic: true, returnType: "I",
            triesCount: 1,
            tryItems: tryItem(start: 0, count: 3, handlerOffset: 1)
                + [0x01, 0x00, 0x05]
        ))

        XCTAssertThrowsError(try run(builder, method: "handlerState")) { error in
            guard case let VMError.verify(message) = error else {
                return XCTFail("expected verification error, got \(error)")
            }
            XCTAssertTrue(message.contains("return value v0 at pc 5"), message)
            XCTAssertTrue(message.contains("undefined"), message)
        }
    }

    func testAOSPBinaryOpcodeOrderingAcrossTypes() throws {
        var integer = DexBuilder()
        integer.setClass("LTest;")
        integer.addMethod(.init(
            name: "and", registers: 3, ins: 0, outs: 0,
            insns: Insn.const4Units(0, 6)
                + Insn.const4Units(1, 3)
                + Insn.binop(0x95, 2, 0, 1)
                + Insn.returnReg(2),
            isStatic: true, returnType: "I"
        ))
        XCTAssertEqual(int(try run(integer, method: "and")), 2)

        var wide = DexBuilder()
        wide.setClass("LTest;")
        wide.addMethod(.init(
            name: "addLong", registers: 6, ins: 0, outs: 0,
            insns: [0x0016, 10, 0x0216, 5]
                + Insn.binop(0x9b, 4, 0, 2)
                + [0x0410],
            isStatic: true, returnType: "J"
        ))
        XCTAssertEqual(long(try run(wide, method: "addLong")), 15)

        var floating = DexBuilder()
        floating.setClass("LTest;")
        floating.addMethod(.init(
            name: "multiplyFloat", registers: 3, ins: 2, outs: 0,
            insns: Insn.binop(0xa8, 0, 1, 2) + Insn.returnReg(0),
            isStatic: true, returnType: "F", parameters: ["F", "F"]
        ))
        XCTAssertEqual(
            float(try run(floating, method: "multiplyFloat", args: [.float(1.5), .float(4)])),
            6
        )

        var doublePrecision = DexBuilder()
        doublePrecision.setClass("LTest;")
        doublePrecision.addMethod(.init(
            name: "subtractDouble", registers: 6, ins: 4, outs: 0,
            insns: Insn.binop(0xac, 0, 2, 4) + [0x0010],
            isStatic: true, returnType: "D", parameters: ["D", "D"]
        ))
        XCTAssertEqual(
            double(try run(
                doublePrecision,
                method: "subtractDouble",
                args: [.double(8.5), .double(3)]
            )),
            5.5
        )

        var twoAddress = DexBuilder()
        twoAddress.setClass("LTest;")
        twoAddress.addMethod(.init(
            name: "andTwoAddress", registers: 2, ins: 2, outs: 0,
            insns: [0x10b5, 0x000f],
            isStatic: true, returnType: "I", parameters: ["I", "I"]
        ))
        XCTAssertEqual(
            int(try run(twoAddress, method: "andTwoAddress", args: [.int(6), .int(3)])),
            2
        )
    }

    func testVerifierAcceptsAlignedPackedSwitchAndChecksCaseTargets() throws {
        var builder = DexBuilder()
        builder.setClass("LTest;")
        builder.addMethod(.init(
            name: "packed", registers: 1, ins: 0, outs: 0,
            insns: [
                0x1012,                   // pc 0: const/4 v0, 1
                0x002b, 0x0005, 0x0000,   // pc 1: packed-switch v0, +5
                0x0012,                   // pc 4: const/4 v0, 0
                0x000f,                   // pc 5: return v0
                0x0100, 0x0001,           // pc 6: packed payload, one case
                0x0001, 0x0000,           // first key = 1
                0x000b, 0x0000,           // target = switch pc + 11 = pc 12
                0x7012,                   // pc 12: const/4 v0, 7
                0x000f,                   // pc 13: return v0
            ],
            isStatic: true, returnType: "I"
        ))

        XCTAssertEqual(int(try run(builder, method: "packed")), 7)
    }

    func testVerifierRejectsSwitchCaseTargetInsidePayload() throws {
        var builder = DexBuilder()
        builder.setClass("LTest;")
        builder.addMethod(.init(
            name: "badCase", registers: 1, ins: 0, outs: 0,
            insns: [
                0x1012,
                0x002b, 0x0005, 0x0000,
                0x0012,
                0x000f,
                0x0100, 0x0001,
                0x0001, 0x0000,
                0x0006, 0x0000, // switch pc + 6 = pc 7, inside the payload
                0x7012,
                0x000f,
            ],
            isStatic: true, returnType: "I"
        ))

        XCTAssertThrowsError(try run(builder, method: "badCase")) { error in
            guard case let VMError.verify(message) = error else {
                return XCTFail("expected verification error, got \(error)")
            }
            XCTAssertTrue(message.contains("packed-switch case"), message)
            XCTAssertTrue(message.contains("non-instruction pc 7"), message)
        }
    }

    func testVerifierRejectsFallthroughIntoPayload() throws {
        var builder = DexBuilder()
        builder.setClass("LTest;")
        builder.addMethod(.init(
            name: "badFallthrough", registers: 1, ins: 0, outs: 0,
            insns: [
                0x0013, 0x0000,       // pc 0: const/16 v0, 0
                0x0300, 0x0001,       // pc 2: empty array-data payload
                0x0000, 0x0000,
                0x000e,               // pc 6: return-void
            ],
            isStatic: true
        ))

        XCTAssertThrowsError(try run(builder, method: "badFallthrough")) { error in
            guard case let VMError.verify(message) = error else {
                return XCTFail("expected verification error, got \(error)")
            }
            XCTAssertTrue(message.contains("falls through to non-instruction pc 2"), message)
        }
    }

    func testVerifierRejectsUnalignedPayload() throws {
        var builder = DexBuilder()
        builder.setClass("LTest;")
        builder.addMethod(.init(
            name: "unalignedPayload", registers: 0, ins: 0, outs: 0,
            insns: [
                0x0528,                   // pc 0: goto +5
                0x0100, 0x0000,           // pc 1: packed payload at an odd address
                0x0000, 0x0000,
                0x000e,                   // pc 5: return-void
            ],
            isStatic: true
        ))

        XCTAssertThrowsError(try run(builder, method: "unalignedPayload")) { error in
            guard case let VMError.verify(message) = error else {
                return XCTFail("expected verification error, got \(error)")
            }
            XCTAssertTrue(message.contains("unaligned payload at pc 1"), message)
        }
    }

    func testVerifierRejectsWrongPayloadFamily() throws {
        var builder = DexBuilder()
        builder.setClass("LTest;")
        builder.addMethod(.init(
            name: "wrongPayload", registers: 1, ins: 0, outs: 0,
            insns: [
                0x002b, 0x0004, 0x0000,   // pc 0: packed-switch v0, +4
                0x000e,                   // pc 3: return-void fallthrough
                0x0300, 0x0001,           // pc 4: empty array-data payload
                0x0000, 0x0000,
            ],
            isStatic: true
        ))

        XCTAssertThrowsError(try run(builder, method: "wrongPayload")) { error in
            guard case let VMError.verify(message) = error else {
                return XCTFail("expected verification error, got \(error)")
            }
            XCTAssertTrue(message.contains("does not reference a matching payload"), message)
        }
    }

    func testVerifierRejectsUnsortedSparseSwitchKeys() throws {
        var builder = DexBuilder()
        builder.setClass("LTest;")
        builder.addMethod(.init(
            name: "unsortedSparse", registers: 1, ins: 0, outs: 0,
            insns: [
                0x002c, 0x0004, 0x0000,   // pc 0: sparse-switch v0, +4
                0x000e,                   // pc 3: return-void fallthrough/target
                0x0200, 0x0002,           // pc 4: two sparse cases
                0x0002, 0x0000,           // key 2
                0x0001, 0x0000,           // key 1 (invalid ordering)
                0x0003, 0x0000,           // both cases target pc 3
                0x0003, 0x0000,
            ],
            isStatic: true
        ))

        XCTAssertThrowsError(try run(builder, method: "unsortedSparse")) { error in
            guard case let VMError.verify(message) = error else {
                return XCTFail("expected verification error, got \(error)")
            }
            XCTAssertTrue(message.contains("sparse-switch keys are not strictly increasing"), message)
        }
    }

    func testVerifierRejectsInvalidArrayDataElementWidth() throws {
        var builder = DexBuilder()
        builder.setClass("LTest;")
        builder.addMethod(.init(
            name: "badArrayPayload", registers: 1, ins: 0, outs: 0,
            insns: [
                0x0026, 0x0004, 0x0000,   // pc 0: fill-array-data v0, +4
                0x000e,                   // pc 3: return-void fallthrough
                0x0300, 0x0003,           // pc 4: illegal three-byte elements
                0x0000, 0x0000,
            ],
            isStatic: true
        ))

        XCTAssertThrowsError(try run(builder, method: "badArrayPayload")) { error in
            guard case let VMError.verify(message) = error else {
                return XCTFail("expected verification error, got \(error)")
            }
            XCTAssertTrue(message.contains("element width 3"), message)
        }
    }

    func testVerifiedTypedExceptionHandlerExecutes() throws {
        var builder = DexBuilder()
        let exceptionType = builder.type("Ljava/lang/RuntimeException;")
        let objectInit = builder.method(
            classDescriptor: "Ljava/lang/Object;", name: "<init>"
        )
        builder.setClass("LTest;")
        let handlers = [UInt8(1), UInt8(1)]
            + DexBuilder.ULEB.encode(UInt64(exceptionType))
            + DexBuilder.ULEB.encode(8)
        let instructions: [UInt16] = Insn.newInstance(0, exceptionType) // pc 0...1
            + Insn.invokeDirect(objectInit, [0])                       // pc 2...4
            + Insn.throwReg(0)                                         // pc 5
            + Insn.const4Units(0, 0)                                   // pc 6
            + Insn.returnReg(0)                                        // pc 7
            + [0x010d]                                                  // pc 8: move-exception v1
            + Insn.const4Units(0, 7)                                   // pc 9
            + Insn.returnReg(0)                                        // pc 10
        let tryItems = tryItem(start: 5, count: 1, handlerOffset: 1) + handlers
        builder.addMethod(.init(
            name: "typedCatch", registers: 2, ins: 0, outs: 1,
            insns: instructions,
            isStatic: true, returnType: "I",
            triesCount: 1,
            tryItems: tryItems
        ))

        XCTAssertEqual(int(try run(builder, method: "typedCatch")), 7)
    }

    func testVerifiedCatchAllExceptionHandlerExecutes() throws {
        var builder = DexBuilder()
        builder.setClass("LTest;")
        builder.addMethod(.init(
            name: "catchAll", registers: 2, ins: 0, outs: 0,
            insns: [
                0x0012, // pc 0: const/4 v0, 0
                0x0027, // pc 1: throw v0
                0x0012, // pc 2: normal result 0
                0x000f, // pc 3: return v0
                0x010d, // pc 4: move-exception v1
                0x7012, // pc 5: caught result 7
                0x000f, // pc 6: return v0
                0x010d, // pc 7: valid but unreferenced encoded handler
                0x000e,
            ],
            isStatic: true, returnType: "I",
            triesCount: 1,
            tryItems: tryItem(start: 1, count: 1, handlerOffset: 1)
                + [0x02, 0x00, 0x04, 0x00, 0x07]
        ))

        XCTAssertEqual(int(try run(builder, method: "catchAll")), 7)
    }

    func testVerifierRejectsTryRangeThatSplitsInstruction() throws {
        var builder = DexBuilder()
        builder.setClass("LTest;")
        builder.addMethod(.init(
            name: "splitTry", registers: 1, ins: 0, outs: 0,
            insns: [
                0x0013, 0x0000, // pc 0: const/16 occupies pc 0...1
                0x000e,         // pc 2: return-void
                0x000d,         // pc 3: move-exception v0
                0x000e,
            ],
            isStatic: true,
            triesCount: 1,
            tryItems: tryItem(start: 0, count: 1, handlerOffset: 1)
                + [0x01, 0x00, 0x03]
        ))

        XCTAssertThrowsError(try run(builder, method: "splitTry")) { error in
            guard case let VMError.verify(message) = error else {
                return XCTFail("expected verification error, got \(error)")
            }
            XCTAssertTrue(message.contains("splits an instruction or payload"), message)
        }
    }

    func testVerifierRejectsOverlappingTryItems() throws {
        var builder = DexBuilder()
        builder.setClass("LTest;")
        let items = tryItem(start: 0, count: 2, handlerOffset: 1)
            + tryItem(start: 1, count: 1, handlerOffset: 1)
        builder.addMethod(.init(
            name: "overlappingTries", registers: 1, ins: 0, outs: 0,
            insns: [0x0000, 0x0000, 0x000e, 0x000d, 0x000e],
            isStatic: true,
            triesCount: 2,
            tryItems: items + [0x01, 0x00, 0x03]
        ))

        XCTAssertThrowsError(try run(builder, method: "overlappingTries")) { error in
            guard case let VMError.verify(message) = error else {
                return XCTFail("expected verification error, got \(error)")
            }
            XCTAssertTrue(message.contains("unsorted or overlapping"), message)
        }
    }

    func testVerifierRejectsInvalidCatchTypeAndHandlerOffset() throws {
        let instructions: [UInt16] = [0x0012, 0x0027, 0x000e, 0x000d, 0x000e]

        var badType = DexBuilder()
        badType.setClass("LTest;")
        badType.addMethod(.init(
            name: "badType", registers: 1, ins: 0, outs: 0,
            insns: instructions, isStatic: true,
            triesCount: 1,
            tryItems: tryItem(start: 1, count: 1, handlerOffset: 1)
                + [0x01, 0x01, 0x7f, 0x03]
        ))
        XCTAssertThrowsError(try run(badType, method: "badType")) { error in
            guard case let VMError.verify(message) = error else {
                return XCTFail("expected verification error, got \(error)")
            }
            XCTAssertTrue(message.contains("invalid type index 127"), message)
        }

        var badOffset = DexBuilder()
        badOffset.setClass("LTest;")
        badOffset.addMethod(.init(
            name: "badOffset", registers: 1, ins: 0, outs: 0,
            insns: instructions, isStatic: true,
            triesCount: 1,
            tryItems: tryItem(start: 1, count: 1, handlerOffset: 2)
                + [0x01, 0x00, 0x03]
        ))
        XCTAssertThrowsError(try run(badOffset, method: "badOffset")) { error in
            guard case let VMError.verify(message) = error else {
                return XCTFail("expected verification error, got \(error)")
            }
            XCTAssertTrue(message.contains("invalid handler offset 2"), message)
        }
    }

    func testVerifierAppliesMoveExceptionHandlerEntryRules() throws {
        var ignoredException = DexBuilder()
        ignoredException.setClass("LTest;")
        ignoredException.addMethod(.init(
            name: "ignoredException", registers: 1, ins: 0, outs: 0,
            insns: [0x0012, 0x0027, 0x000e], isStatic: true,
            triesCount: 1,
            tryItems: tryItem(start: 1, count: 1, handlerOffset: 1)
                + [0x01, 0x00, 0x02]
        ))
        XCTAssertNoThrow(try run(ignoredException, method: "ignoredException"))

        var resultHandler = DexBuilder()
        resultHandler.setClass("LTest;")
        resultHandler.addMethod(.init(
            name: "resultHandler", registers: 1, ins: 0, outs: 0,
            insns: [0x0027, 0x0071, 0x0000, 0x0000, 0x000a, 0x000e],
            isStatic: true,
            triesCount: 1,
            tryItems: tryItem(start: 0, count: 1, handlerOffset: 1)
                + [0x01, 0x00, 0x04]
        ))
        XCTAssertThrowsError(try run(resultHandler, method: "resultHandler")) { error in
            guard case let VMError.verify(message) = error else {
                return XCTFail("expected verification error, got \(error)")
            }
            XCTAssertTrue(message.contains("begins with move-result"), message)
        }

        var strayMove = DexBuilder()
        strayMove.setClass("LTest;")
        strayMove.addMethod(.init(
            name: "strayMove", registers: 1, ins: 0, outs: 0,
            insns: [0x000d, 0x000e], isStatic: true
        ))
        XCTAssertThrowsError(try run(strayMove, method: "strayMove")) { error in
            guard case let VMError.verify(message) = error else {
                return XCTFail("expected verification error, got \(error)")
            }
            XCTAssertTrue(message.contains("is not an exception handler entry"), message)
        }

        var entryHandler = DexBuilder()
        entryHandler.setClass("LTest;")
        entryHandler.addMethod(.init(
            name: "entryHandler", registers: 1, ins: 0, outs: 0,
            insns: [0x000d, 0x0027, 0x000e], isStatic: true,
            triesCount: 1,
            tryItems: tryItem(start: 1, count: 1, handlerOffset: 1)
                + [0x01, 0x00, 0x00]
        ))
        XCTAssertThrowsError(try run(entryHandler, method: "entryHandler")) { error in
            guard case let VMError.verify(message) = error else {
                return XCTFail("expected verification error, got \(error)")
            }
            XCTAssertTrue(message.contains("may not start at method entry pc 0"), message)
        }
    }

    func testVerifierRejectsOrdinaryControlFlowIntoMoveException() throws {
        var builder = DexBuilder()
        builder.setClass("LTest;")
        builder.addMethod(.init(
            name: "branchToHandler", registers: 1, ins: 0, outs: 0,
            insns: [0x0328, 0x0027, 0x000e, 0x000d, 0x000e],
            isStatic: true,
            triesCount: 1,
            tryItems: tryItem(start: 1, count: 1, handlerOffset: 1)
                + [0x01, 0x00, 0x03]
        ))

        XCTAssertThrowsError(try run(builder, method: "branchToHandler")) { error in
            guard case let VMError.verify(message) = error else {
                return XCTFail("expected verification error, got \(error)")
            }
            XCTAssertTrue(message.contains("targets move-exception pc 3"), message)
        }

        var fallthroughBuilder = DexBuilder()
        fallthroughBuilder.setClass("LTest;")
        fallthroughBuilder.addMethod(.init(
            name: "fallthroughToHandler", registers: 1, ins: 0, outs: 0,
            insns: [0x0027, 0x0000, 0x000d, 0x000e],
            isStatic: true,
            triesCount: 1,
            tryItems: tryItem(start: 0, count: 1, handlerOffset: 1)
                + [0x01, 0x00, 0x02]
        ))
        XCTAssertThrowsError(try run(fallthroughBuilder, method: "fallthroughToHandler")) { error in
            guard case let VMError.verify(message) = error else {
                return XCTFail("expected verification error, got \(error)")
            }
            XCTAssertTrue(message.contains("falls through into move-exception handler pc 2"), message)
        }

        var ordinaryHandler = DexBuilder()
        ordinaryHandler.setClass("LTest;")
        ordinaryHandler.addMethod(.init(
            name: "ordinaryHandler", registers: 1, ins: 0, outs: 0,
            insns: [0x0328, 0x0027, 0x000e, 0x0000, 0x000e],
            isStatic: true,
            triesCount: 1,
            tryItems: tryItem(start: 1, count: 1, handlerOffset: 1)
                + [0x01, 0x00, 0x03]
        ))
        XCTAssertNoThrow(try run(ordinaryHandler, method: "ordinaryHandler"))
    }

    func testVerifierRejectsMalformedExceptionTableEncoding() throws {
        let instructions: [UInt16] = [0x0012, 0x0027, 0x000e, 0x000d, 0x000e]

        var emptyHandlers = DexBuilder()
        emptyHandlers.setClass("LTest;")
        emptyHandlers.addMethod(.init(
            name: "emptyHandlers", registers: 1, ins: 0, outs: 0,
            insns: instructions, isStatic: true,
            triesCount: 1,
            tryItems: tryItem(start: 1, count: 1, handlerOffset: 1) + [0x00]
        ))
        XCTAssertThrowsError(try run(emptyHandlers, method: "emptyHandlers")) { error in
            guard case let VMError.verify(message) = error else {
                return XCTFail("expected verification error, got \(error)")
            }
            XCTAssertTrue(message.contains("outside 1...65535"), message)
        }

        var badPadding = DexBuilder()
        badPadding.setClass("LTest;")
        badPadding.addMethod(.init(
            name: "badPadding", registers: 1, ins: 0, outs: 0,
            insns: instructions, isStatic: true,
            triesCount: 1, tryPadding: 1,
            tryItems: tryItem(start: 1, count: 1, handlerOffset: 1)
                + [0x01, 0x00, 0x03]
        ))
        XCTAssertThrowsError(try run(badPadding, method: "badPadding")) { error in
            guard case let VMError.verify(message) = error else {
                return XCTFail("expected verification error, got \(error)")
            }
            XCTAssertTrue(message.contains("nonzero try-table padding"), message)
        }

        var overlongCount = DexBuilder()
        overlongCount.setClass("LTest;")
        overlongCount.addMethod(.init(
            name: "overlongCount", registers: 1, ins: 0, outs: 0,
            insns: instructions, isStatic: true,
            triesCount: 1,
            tryItems: tryItem(start: 1, count: 1, handlerOffset: 1)
                + [UInt8](repeating: 0x80, count: 10)
        ))
        XCTAssertThrowsError(try run(overlongCount, method: "overlongCount")) { error in
            guard case let VMError.verify(message) = error else {
                return XCTFail("expected verification error, got \(error)")
            }
            XCTAssertTrue(message.contains("malformed exception table"), message)
        }

        let outside32 = [UInt8](arrayLiteral: 0x80, 0x80, 0x80, 0x80, 0x10)
        var wideSignedSize = DexBuilder()
        wideSignedSize.setClass("LTest;")
        wideSignedSize.addMethod(.init(
            name: "wideSignedSize", registers: 1, ins: 0, outs: 0,
            insns: instructions, isStatic: true,
            triesCount: 1,
            tryItems: tryItem(start: 1, count: 1, handlerOffset: 1)
                + [0x01] + outside32
        ))
        XCTAssertThrowsError(try run(wideSignedSize, method: "wideSignedSize")) { error in
            guard case let VMError.verify(message) = error else {
                return XCTFail("expected verification error, got \(error)")
            }
            XCTAssertTrue(message.contains("size is outside SLEB32"), message)
        }

        var wideAddress = DexBuilder()
        wideAddress.setClass("LTest;")
        wideAddress.addMethod(.init(
            name: "wideAddress", registers: 1, ins: 0, outs: 0,
            insns: instructions, isStatic: true,
            triesCount: 1,
            tryItems: tryItem(start: 1, count: 1, handlerOffset: 1)
                + [0x01, 0x00] + outside32
        ))
        XCTAssertThrowsError(try run(wideAddress, method: "wideAddress")) { error in
            guard case let VMError.verify(message) = error else {
                return XCTFail("expected verification error, got \(error)")
            }
            XCTAssertTrue(message.contains("address is outside ULEB32"), message)
        }
    }

    // MARK: constants & strings

    func testConst16Negative() throws {
        var b = DexBuilder()
        b.setClass("LTest;")
        b.addMethod(.init(name: "neg", registers: 1, ins: 0, outs: 0,
                          insns: Insn.const16Units(0, -1234) + Insn.returnReg(0),
                          isStatic: true, returnType: "I"))
        XCTAssertEqual(int(try run(b, method: "neg")), -1234)
    }

    func testConstString() throws {
        var b = DexBuilder()
        b.string("https://batcave.com")
        b.setClass("LTest;")
        b.addMethod(.init(name: "url", registers: 1, ins: 0, outs: 0,
                          insns: Insn.constString(0, 0) + Insn.returnObjectReg(0),
                          isStatic: true, returnType: "Ljava/lang/String;"))
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
        b.addMethod(.init(name: "branch", registers: 1, ins: 0, outs: 0,
                          insns: insns, isStatic: true, returnType: "I"))
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
        b.addMethod(.init(name: "sum", registers: 3, ins: 0, outs: 0,
                          insns: insns, isStatic: true, returnType: "I"))
        XCTAssertEqual(int(try run(b, method: "sum")), 55)
    }

    // MARK: invocation

    func testInvokeVirtualSelectsOverrideFromRuntimeReceiver() throws {
        var builder = DexBuilder()
        let baseValue = builder.method(
            classDescriptor: "LBase;", name: "value", shorty: "I", ret: "I"
        )
        let objectInit = builder.method(
            classDescriptor: "Ljava/lang/Object;", name: "<init>"
        )
        builder.setClass("LChild;", superclass: "LBase;")
        let childType = builder.typeIdx("LChild;")
        builder.addMethod(.init(
            name: "value", registers: 2, ins: 1, outs: 0,
            insns: Insn.const4Units(0, 7) + Insn.returnReg(0),
            isStatic: false, returnType: "I"
        ))
        builder.addMethod(.init(
            name: "run", registers: 1, ins: 0, outs: 1,
            insns: Insn.newInstance(0, childType)
                + Insn.invokeDirect(objectInit, [0])
                + Insn.invokeVirtual(baseValue, [0])
                + Insn.moveResult(0)
                + Insn.returnReg(0),
            isStatic: true, returnType: "I"
        ))

        let dex = try DexFile(builder.build())
        let vm = DexInterpreter(dex: dex)
        XCTAssertEqual(
            int(try vm.call(classDescriptor: "LChild;", method: "run")),
            7
        )
    }

    func testInvokeInterfaceSelectsImplementationFromRuntimeReceiver() throws {
        var builder = DexBuilder()
        let interfaceValue = builder.method(
            classDescriptor: "LValue;", name: "value", shorty: "I", ret: "I"
        )
        let objectInit = builder.method(
            classDescriptor: "Ljava/lang/Object;", name: "<init>"
        )
        builder.setClass("LImplementation;", interfaces: ["LValue;"])
        let implementationType = builder.typeIdx("LImplementation;")
        builder.addMethod(.init(
            name: "value", registers: 2, ins: 1, outs: 0,
            insns: Insn.const16Units(0, 9) + Insn.returnReg(0),
            isStatic: false, returnType: "I"
        ))
        builder.addMethod(.init(
            name: "run", registers: 1, ins: 0, outs: 1,
            insns: Insn.newInstance(0, implementationType)
                + Insn.invokeDirect(objectInit, [0])
                + Insn.invokeInterface(interfaceValue, [0])
                + Insn.moveResult(0)
                + Insn.returnReg(0),
            isStatic: true, returnType: "I"
        ))

        let dex = try DexFile(builder.build())
        let vm = DexInterpreter(dex: dex)
        XCTAssertEqual(
            int(try vm.call(classDescriptor: "LImplementation;", method: "run")),
            9
        )
    }

    func testInstanceMethodAndField() throws {
        var b = DexBuilder()
        let objectInit = b.method(
            classDescriptor: "Ljava/lang/Object;", name: "<init>"
        )
        b.setClass("LTest;", fields: [("value", "I")])
        b.addMethod(.init(name: "getValue", registers: 2, ins: 1, outs: 0,
                          insns: Insn.iget(0, 1, 0) + Insn.returnReg(0), isStatic: false,
                          returnType: "I"))
        let testTypeIdx = b.typeIdx("LTest;")
        b.addMethod(.init(name: "run", registers: 3, ins: 0, outs: 1,
                          insns: Insn.newInstance(0, testTypeIdx)
                              + Insn.invokeDirect(objectInit, [0])
                              + Insn.const16Units(1, 42)
                              + Insn.iput(1, 0, 0)
                              + Insn.invokeVirtual(1, [0])
                              + Insn.moveResult(1)
                              + Insn.returnReg(1),
                          isStatic: true, returnType: "I"))
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
                          isStatic: true, returnType: "I"))
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
                          isStatic: true, returnType: "I"))
        XCTAssertThrowsError(try run(b, method: "oob")) { error in
            XCTAssertTrue(error is DEXThrowable)
        }
    }

    // MARK: host bridge

    func testHostBridgeDispatchesByPrototypeAndStaticness() throws {
        var builder = DexBuilder()
        let target = builder.method(classDescriptor: "LHost;", name: "value", shorty: "I", ret: "I")
        builder.setClass("LTest;")
        builder.addMethod(.init(
            name: "run", registers: 1, ins: 0, outs: 0,
            insns: Insn.invokeStatic(target, [])
                + Insn.moveResult(0)
                + Insn.returnReg(0),
            isStatic: true, returnType: "I"
        ))
        let dex = try DexFile(builder.build())
        let bridge = HostBridge()
        bridge.register(class: "LHost;", "value", prototype: "()I", isStatic: true) { _, _ in .int(7) }
        bridge.register(class: "LHost;", "value", prototype: "(I)I", isStatic: true) { _, _ in .int(99) }
        let vm = DexInterpreter(dex: dex, bridge: bridge)
        XCTAssertEqual(int(try vm.call(classDescriptor: "LTest;", method: "run")), 7)

        let wrongKind = HostBridge()
        wrongKind.register(class: "LHost;", "value", prototype: "()I", isStatic: false) { _, _ in .int(8) }
        let wrongVM = DexInterpreter(dex: dex, bridge: wrongKind)
        XCTAssertThrowsError(try wrongVM.call(classDescriptor: "LTest;", method: "run")) { error in
            guard case let VMError.unresolvedMethod(_, signature) = error else {
                return XCTFail("expected unresolvedMethod, got \(error)")
            }
            XCTAssertEqual(signature, "value()I")
        }
    }

    func testStringBuilderViaHostBridge() throws {
        var b = DexBuilder()
        b.type("Ljava/lang/StringBuilder;")
        b.setClass("LTest;")
        let sbType = b.typeIdx("Ljava/lang/StringBuilder;")
        b.method(
            classDescriptor: "Ljava/lang/StringBuilder;",
            name: "append",
            shorty: "LL",
            ret: "Ljava/lang/StringBuilder;",
            parameters: ["Ljava/lang/String;"]
        )
        b.method(
            classDescriptor: "Ljava/lang/StringBuilder;",
            name: "toString",
            shorty: "L",
            ret: "Ljava/lang/String;"
        )
        let appendIdx = 0
        let toStringIdx = 1
        let constructorIdx = b.method(
            classDescriptor: "Ljava/lang/StringBuilder;", name: "<init>"
        )
        b.addMethod(.init(name: "greet", registers: 2, ins: 0, outs: 2,
                          insns: Insn.newInstance(0, sbType)
                              + Insn.invokeDirect(constructorIdx, [0])
                              + Insn.constString(1, b.string("Kami"))
                              + Insn.invokeVirtual(appendIdx, [0, 1])
                              + Insn.moveResultObject(0)
                              + Insn.invokeVirtual(toStringIdx, [0])
                              + Insn.moveResultObject(0)
                              + Insn.returnObjectReg(0),
                          isStatic: true, returnType: "Ljava/lang/String;"))
        XCTAssertEqual(vmStringValue(try run(b, method: "greet")), "Kami")
    }

    func testNegativeStringIndexThrowsInsteadOfIndexingHostArray() throws {
        var b = DexBuilder()
        let charAt = b.method(
            classDescriptor: "Ljava/lang/String;",
            name: "charAt",
            shorty: "CI",
            ret: "C",
            parameters: ["I"]
        )
        let text = b.string("A")
        b.setClass("LTest;")
        b.addMethod(.init(
            name: "badCharAt", registers: 2, ins: 0, outs: 2,
            insns: Insn.constString(0, text)
                + Insn.const4Units(1, -1)
                + Insn.invokeVirtual(charAt, [0, 1])
                + Insn.moveResult(0)
                + Insn.returnReg(0),
            isStatic: true,
            returnType: "C"
        ))
        XCTAssertThrowsError(try run(b, method: "badCharAt")) { error in
            XCTAssertTrue(error is DEXThrowable, "expected DEXThrowable, got \(error)")
        }
    }

    // MARK: budget

    func testRunawayLoopHitsBudget() throws {
        var b = DexBuilder()
        b.setClass("LTest;")
        // `goto/32` is the one AOSP branch form that permits a zero-offset spin.
        b.addMethod(.init(name: "spin", registers: 1, ins: 0, outs: 0,
                          insns: [0x002a, 0x0000, 0x0000], isStatic: true))
        let dex = try DexFile(b.build())
        let vm = DexInterpreter(dex: dex, maxInstructions: 10_000)
        XCTAssertThrowsError(try vm.call(classDescriptor: "LTest;", method: "spin")) { error in
            guard case let VMError.budgetExceeded(limit) = error else {
                return XCTFail("expected budgetExceeded, got \(error)")
            }
            XCTAssertEqual(limit, 10_000)
        }
    }

    func testRecursiveCallsShareOneInstructionBudget() throws {
        var b = DexBuilder()
        b.setClass("LTest;")
        b.addMethod(.init(name: "recurse", registers: 0, ins: 0, outs: 0,
                          insns: [0x0071, 0x0000, 0x0000, 0x000e], isStatic: true))
        let dex = try DexFile(b.build())
        let vm = DexInterpreter(dex: dex, maxInstructions: 16)
        vm.maxCallDepth = 48
        XCTAssertThrowsError(try vm.call(classDescriptor: "LTest;", method: "recurse")) { error in
            guard case let VMError.budgetExceeded(limit) = error else {
                return XCTFail("expected shared budgetExceeded, got \(error)")
            }
            XCTAssertEqual(limit, 16)
        }
    }

    // MARK: instantiation

    func testConstructorRuns() throws {
        var b = DexBuilder()
        b.setClass("LTest;", fields: [("x", "I")])
        b.method(classDescriptor: "LTest;", name: "<init>", shorty: "V", ret: "V")
        b.method(classDescriptor: "LTest;", name: "get", shorty: "I", ret: "I")
        let objectInit = b.method(
            classDescriptor: "Ljava/lang/Object;", name: "<init>"
        )
        // Incoming arguments occupy the final ins_size register words: v1=this.
        b.addMethod(.init(name: "<init>", registers: 2, ins: 1, outs: 1,
                          insns: Insn.const4Units(0, 7)
                              + Insn.iput(0, 1, 0)
                              + Insn.invokeDirect(objectInit, [1])
                              + Insn.returnVoid(),
                          isStatic: false))
        b.addMethod(.init(name: "get", registers: 2, ins: 1, outs: 0,
                          insns: Insn.iget(0, 1, 0) + Insn.returnReg(0), isStatic: false,
                          returnType: "I"))
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
