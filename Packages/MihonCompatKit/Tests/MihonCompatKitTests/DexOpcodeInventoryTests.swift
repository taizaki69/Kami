import XCTest
@testable import MihonCompatKit

final class DexOpcodeInventoryTests: XCTestCase {
    private struct StoredEntry {
        let name: String
        let payload: [UInt8]
        let crc32: UInt32
        let localHeaderOffset: UInt32
    }

    func testInstructionBoundariesAndPayloadBodiesAreNotCounted() throws {
        let dex = makeDex(
            descriptor: "LBoundary;",
            method: "scan",
            registers: 1,
            insns: [
                0x0013, 0x00fa,             // const/16 v0; operand resembles opcode fa
                0x0026, 0x0004, 0x0000,     // fill-array-data v0, payload at pc 6
                0x000e,                     // return-void
                0x0300, 0x0001,             // array-data, one-byte elements
                0x0004, 0x0000,             // four elements
                0x00fa, 0xfffc,             // payload bytes resemble fa/fc/ff
            ]
        )
        let report = try DexOpcodeInventory().analyze(apk: makeStoredZip([
            (name: "classes.dex", payload: dex),
        ]))

        XCTAssertEqual(report.dexCount, 1)
        XCTAssertEqual(report.codeMethodCount, 1)
        XCTAssertEqual(report.instructionCount, 3)
        XCTAssertEqual(report.opcodes.map(\.opcode), [0x0e, 0x13, 0x26])
        XCTAssertNil(report.opcodes.first { $0.opcode == 0x00 })
        XCTAssertNil(report.opcodes.first { $0.opcode == 0xfa })
        XCTAssertNil(report.opcodes.first { $0.opcode == 0xfc })
        XCTAssertNil(report.opcodes.first { $0.opcode == 0xff })
        XCTAssertEqual(report.opcodes.first { $0.opcode == 0x13 }?.examples.first?.address, 0)
        XCTAssertEqual(report.opcodes.first { $0.opcode == 0x26 }?.examples.first?.address, 2)
        XCTAssertEqual(report.opcodes.first { $0.opcode == 0x0e }?.examples.first?.address, 5)
    }

    func testParsedButUnexecutedDex038OpcodesAreReportedHonestly() throws {
        let dex = makeDex(
            descriptor: "LDynamic;",
            method: "constants",
            version: 38,
            registers: 2,
            insns: [
                0x00fe, 0x0000, // const-method-handle v0, method_handle@0
                0x01ff, 0x0000, // const-method-type v1, proto@0
                0x000e,
            ]
        )
        let report = try DexOpcodeInventory().analyze(apk: makeStoredZip([
            (name: "classes.dex", payload: dex),
        ]))

        XCTAssertEqual(report.dexFiles.map(\.version), [38])
        for opcode: UInt8 in [0xfe, 0xff] {
            let summary = try XCTUnwrap(report.opcodes.first { $0.opcode == opcode })
            XCTAssertTrue(summary.structurallyDecoded)
            XCTAssertTrue(summary.registerVerified)
            XCTAssertFalse(summary.executable)
        }
        XCTAssertEqual(DexOpcodeInventory.name(for: 0xfe), "const-method-handle")
        XCTAssertEqual(DexOpcodeInventory.name(for: 0xff), "const-method-type")
    }

    func testMultiDexAndExampleOrderingAreDeterministic() throws {
        var primary = DexBuilder()
        primary.setClass("LA;")
        primary.addMethod(.init(
            name: "z", registers: 1, ins: 0, outs: 0,
            insns: Insn.const4Units(0, 1) + Insn.returnVoid(), isStatic: true
        ))
        primary.addMethod(.init(
            name: "a", registers: 1, ins: 0, outs: 0,
            insns: Insn.const4Units(0, 2) + Insn.returnVoid(), isStatic: true
        ))
        let secondary = makeDex(
            descriptor: "LB;", method: "b", registers: 1,
            insns: Insn.const4Units(0, 3) + Insn.returnVoid()
        )
        let tenth = makeDex(
            descriptor: "LC;", method: "c", registers: 1,
            insns: Insn.const4Units(0, 4) + Insn.returnVoid()
        )

        let apk = makeStoredZip([
            (name: "classes10.dex", payload: tenth),
            (name: "assets/ignored.dex", payload: tenth),
            (name: "classes2.dex", payload: secondary),
            (name: "classes.dex", payload: primary.build()),
        ])
        let report = try DexOpcodeInventory(maximumExamplesPerOpcode: 20).analyze(apk: apk)

        XCTAssertEqual(report.dexFiles.map(\.name), ["classes.dex", "classes2.dex", "classes10.dex"])
        XCTAssertEqual(report.dexFiles.map(\.codeMethodCount), [2, 1, 1])
        XCTAssertEqual(report.opcodes.map(\.opcode), [0x0e, 0x12])
        let constants = try XCTUnwrap(report.opcodes.first { $0.opcode == 0x12 })
        XCTAssertEqual(constants.instructionCount, 4)
        XCTAssertEqual(constants.methodCount, 4)
        XCTAssertEqual(constants.examples.map { $0.dexName + ":" + $0.methodSignature }, [
            "classes.dex:a()V",
            "classes.dex:z()V",
            "classes2.dex:b()V",
            "classes10.dex:c()V",
        ])
    }

    private func makeDex(
        descriptor: String,
        method: String,
        version: Int = 35,
        registers: Int,
        insns: [UInt16]
    ) -> [UInt8] {
        var builder = DexBuilder(version: version)
        builder.setClass(descriptor)
        builder.addMethod(.init(
            name: method,
            registers: registers,
            ins: 0,
            outs: 0,
            insns: insns,
            isStatic: true
        ))
        return builder.build()
    }

    private func makeStoredZip(_ inputs: [(name: String, payload: [UInt8])]) -> [UInt8] {
        var bytes: [UInt8] = []
        var entries: [StoredEntry] = []

        for input in inputs {
            let nameBytes = Array(input.name.utf8)
            let checksum = crc32(input.payload)
            let offset = UInt32(bytes.count)
            appendU32(0x0403_4b50, to: &bytes)
            appendU16(20, to: &bytes)
            appendU16(0, to: &bytes)
            appendU16(0, to: &bytes)
            appendU16(0, to: &bytes)
            appendU16(0, to: &bytes)
            appendU32(checksum, to: &bytes)
            appendU32(UInt32(input.payload.count), to: &bytes)
            appendU32(UInt32(input.payload.count), to: &bytes)
            appendU16(UInt16(nameBytes.count), to: &bytes)
            appendU16(0, to: &bytes)
            bytes += nameBytes + input.payload
            entries.append(StoredEntry(
                name: input.name,
                payload: input.payload,
                crc32: checksum,
                localHeaderOffset: offset
            ))
        }

        let centralOffset = UInt32(bytes.count)
        for entry in entries {
            let nameBytes = Array(entry.name.utf8)
            appendU32(0x0201_4b50, to: &bytes)
            appendU16(20, to: &bytes)
            appendU16(20, to: &bytes)
            appendU16(0, to: &bytes)
            appendU16(0, to: &bytes)
            appendU16(0, to: &bytes)
            appendU16(0, to: &bytes)
            appendU32(entry.crc32, to: &bytes)
            appendU32(UInt32(entry.payload.count), to: &bytes)
            appendU32(UInt32(entry.payload.count), to: &bytes)
            appendU16(UInt16(nameBytes.count), to: &bytes)
            appendU16(0, to: &bytes)
            appendU16(0, to: &bytes)
            appendU16(0, to: &bytes)
            appendU16(0, to: &bytes)
            appendU32(0, to: &bytes)
            appendU32(entry.localHeaderOffset, to: &bytes)
            bytes += nameBytes
        }
        let centralSize = UInt32(bytes.count) - centralOffset

        appendU32(0x0605_4b50, to: &bytes)
        appendU16(0, to: &bytes)
        appendU16(0, to: &bytes)
        appendU16(UInt16(entries.count), to: &bytes)
        appendU16(UInt16(entries.count), to: &bytes)
        appendU32(centralSize, to: &bytes)
        appendU32(centralOffset, to: &bytes)
        appendU16(0, to: &bytes)
        return bytes
    }

    private func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xedb8_8320)
            }
        }
        return ~crc
    }

    private func appendU16(_ value: UInt16, to bytes: inout [UInt8]) {
        bytes.append(UInt8(value & 0xff))
        bytes.append(UInt8(value >> 8))
    }

    private func appendU32(_ value: UInt32, to bytes: inout [UInt8]) {
        appendU16(UInt16(value & 0xffff), to: &bytes)
        appendU16(UInt16(value >> 16), to: &bytes)
    }
}
