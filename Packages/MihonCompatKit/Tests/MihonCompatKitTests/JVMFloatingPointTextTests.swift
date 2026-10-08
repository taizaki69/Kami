import XCTest
@testable import MihonCompatKit

final class JVMFloatingPointTextTests: XCTestCase {
    func testFloatNotationAndBothReachedHostABIs() throws {
        let cases: [(Float, String)] = [
            (0, "0.0"), (-0.0, "-0.0"), (1, "1.0"), (2.5, "2.5"),
            (0.001, "0.001"), (0.0001, "1.0E-4"), (1_000_000, "1000000.0"),
            (10_000_000, "1.0E7"), (-1.25e12, "-1.25E12"),
            (.leastNonzeroMagnitude, "1.4E-45"), (.greatestFiniteMagnitude, "3.4028235E38"),
            (.infinity, "Infinity"), (-.infinity, "-Infinity"), (.nan, "NaN"),
        ]
        var builder = DexBuilder()
        builder.setClass("LTest;")
        let bridge = HostBridge.minimal()
        defer { bridge.retire() }
        let vm = DexInterpreter(dex: try DexFile(builder.build()), bridge: bridge)
        let valueOf = try XCTUnwrap(bridge.resolve(class: "Ljava/lang/String;", "valueOf", prototype: "(F)Ljava/lang/String;", isStatic: true))
        let constructor = try XCTUnwrap(bridge.resolve(class: "Ljava/lang/StringBuilder;", "<init>", prototype: "()V", isStatic: false))
        let append = try XCTUnwrap(bridge.resolve(class: "Ljava/lang/StringBuilder;", "append", prototype: "(F)Ljava/lang/StringBuilder;", isStatic: false))
        let toString = try XCTUnwrap(bridge.resolve(class: "Ljava/lang/StringBuilder;", "toString", prototype: "()Ljava/lang/String;", isStatic: false))
        for (value, expected) in cases {
            XCTAssertEqual(vmStringValue(try valueOf(vm, [.float(value)])), expected)
            let target = RVal.obj(ObjInstance(dexType: "Ljava/lang/StringBuilder;", isHost: true))
            _ = try constructor(vm, [target])
            _ = try append(vm, [target, .float(value)])
            XCTAssertEqual(vmStringValue(try toString(vm, [target])), expected)
        }
    }

    func testDoubleBoundariesAndFiniteBitPatternsRoundTrip() {
        for (value, text): (Double, String) in [
            (-0.0, "-0.0"), (0.001, "0.001"), (0.0001, "1.0E-4"),
            (1e7, "1.0E7"), (.leastNonzeroMagnitude, "4.9E-324"),
            (.greatestFiniteMagnitude, "1.7976931348623157E308"),
        ] { XCTAssertEqual(JVMFloatingPointText.string(value), text) }
        var bits: UInt64 = 0x12345678
        for _ in 0..<8_192 {
            bits = bits &* 6_364_136_223_846_793_005 &+ 1
            let float = Float(bitPattern: UInt32(truncatingIfNeeded: bits))
            if float.isFinite {
                let text = JVMFloatingPointText.string(float)
                XCTAssertEqual(Float(text)?.bitPattern, float.bitPattern)
                XCTAssertLessThan(text.count, 30)
            }
            let double = Double(bitPattern: bits)
            if double.isFinite {
                let text = JVMFloatingPointText.string(double)
                XCTAssertEqual(Double(text)?.bitPattern, double.bitPattern)
                XCTAssertLessThan(text.count, 30)
            }
        }
    }
}
