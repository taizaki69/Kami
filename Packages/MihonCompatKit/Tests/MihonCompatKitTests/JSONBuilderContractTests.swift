import Foundation
import XCTest
@testable import MihonCompatKit

final class JSONBuilderContractTests: XCTestCase {
    private let builderType = "Lkotlinx/serialization/json/JsonObjectBuilder;"
    private let helpers = "Lkotlinx/serialization/json/JsonElementBuildersKt;"

    private func fixture(limit: Int = 1024, loopingAction: Bool = false) throws -> (HostBridge, DexInterpreter) {
        var dex = DexBuilder()
        let put = dex.method(classDescriptor: helpers, name: "put", shorty: "LLLL", ret: "Lkotlinx/serialization/json/JsonElement;",
            parameters: [builderType, "Ljava/lang/String;", "Ljava/lang/String;"])
        let unit = dex.field(classDescriptor: "Lkotlin/Unit;", name: "INSTANCE", typeDescriptor: "Lkotlin/Unit;")
        let builderIndex = dex.type(builderType)
        let key = dex.string("inner"), value = dex.string("value")
        dex.setClass("LJSONAction;", interfaces: ["Lkotlin/jvm/functions/Function1;"])
        var instructions: [UInt16]
        if loopingAction {
            instructions = [0x0000, 0xff28]
        } else {
            instructions = [0x031f, UInt16(builderIndex)]
            instructions += Insn.constString(0, key)
            instructions += Insn.constString(1, value)
            instructions += Insn.invokeStatic(put, [3, 0, 1])
            instructions += Insn.sget(0, unit, object: true)
            instructions += Insn.returnObjectReg(0)
        }
        dex.addMethod(.init(name: "invoke", registers: 4, ins: 2, outs: 3, insns: instructions, isStatic: false,
            returnType: "Ljava/lang/Object;", parameters: ["Ljava/lang/Object;"], isVirtual: true))
        let bridge = HostBridge.minimal(htmlPolicy: .init(maximumExtractedStringBytes: limit))
        return (bridge, DexInterpreter(dex: try DexFile(dex.build()), bridge: bridge, maxInstructions: 100))
    }

    func testPutReturnsPreviousValueAndBoundedReplacementReclaimsOldCost() throws {
        let (bridge, vm) = try fixture(limit: 32)
        let builder = try XCTUnwrap(bridge.objectFactories[builderType])(vm)
        func put(_ value: RVal, type: String) throws -> RVal {
            try XCTUnwrap(bridge.resolve(class: helpers, "put",
                prototype: "(\(builderType)Ljava/lang/String;\(type))Lkotlinx/serialization/json/JsonElement;", isStatic: true))(
                    vm, [builder, HostBridge.string("key"), value])
        }
        func rendered() throws -> String {
            let object = try XCTUnwrap(bridge.resolve(class: builderType, "build", prototype: "()Lkotlinx/serialization/json/JsonObject;", isStatic: false))(vm, [builder])
            return vmStringValue(try XCTUnwrap(bridge.resolve(class: "Lkotlinx/serialization/json/JsonObject;", "toString", prototype: "()Ljava/lang/String;", isStatic: false))(vm, [object]))
        }
        XCTAssertTrue(try put(HostBridge.string("first"), type: "Ljava/lang/String;").isNull)
        let previous = try put(.int(7), type: "Ljava/lang/Number;")
        guard case let .obj(previousObject) = previous else { return XCTFail("Expected old JSON string") }
        XCTAssertEqual(previousObject.dexType, "Lkotlinx/serialization/json/JsonPrimitive;")
        XCTAssertEqual(try rendered(), #"{"key":7}"#)
        // Repeated number replacement used to accumulate phantom byte costs.
        for index in 0..<100 { _ = try put(.int(Int32(index)), type: "Ljava/lang/Number;") }
        XCTAssertEqual(try rendered(), #"{"key":99}"#)
        XCTAssertThrowsError(try put(HostBridge.string(String(repeating: "\n", count: 20)), type: "Ljava/lang/String;"))
        XCTAssertEqual(try rendered(), #"{"key":99}"#, "Rejected writes leave the old value intact")
        _ = try put(.null, type: "Ljava/lang/String;")
        XCTAssertEqual(try rendered(), #"{"key":null}"#)
        let nonfinite: [RVal] = [
            .float(.nan), .float(.infinity), .float(-.infinity),
            .double(.nan), .double(.infinity), .double(-.infinity),
            .obj(ObjInstance(dexType: "Ljava/lang/Float;", payload: Float.infinity, isHost: true)),
            .obj(ObjInstance(dexType: "Ljava/lang/Double;", payload: Double.nan, isHost: true)),
        ]
        for value in nonfinite {
            XCTAssertThrowsError(try put(value, type: "Ljava/lang/Number;")) {
                guard let thrown = $0 as? DEXThrowable, case let .obj(object) = thrown.value else { return XCTFail("\($0)") }
                XCTAssertEqual(object.dexType, "Lkotlinx/serialization/SerializationException;")
            }
            XCTAssertEqual(try rendered(), #"{"key":null}"#)
        }
        _ = try put(.long(.max), type: "Ljava/lang/Number;")
        XCTAssertEqual(try rendered(), #"{"key":9223372036854775807}"#, "Finite validation must preserve exact integers")
    }

    func testNestedBuilderRunsRealDEXAndCommitsAtomicallyWithinSharedBudget() throws {
        for (limit, looping, succeeds) in [(128, false, true), (16, false, false), (128, true, false)] {
            let (bridge, vm) = try fixture(limit: limit, loopingAction: looping)
            let builder = try XCTUnwrap(bridge.objectFactories[builderType])(vm)
            let action = RVal.obj(ObjInstance(dexType: "LJSONAction;"))
            let put = try XCTUnwrap(bridge.resolve(class: helpers, "putJsonObject",
                prototype: "(\(builderType)Ljava/lang/String;Lkotlin/jvm/functions/Function1;)Lkotlinx/serialization/json/JsonElement;", isStatic: true))
            do {
                let result = try put(vm, [builder, HostBridge.string("outer"), action])
                XCTAssertTrue(result.isNull)
                XCTAssertTrue(succeeds)
            } catch {
                XCTAssertFalse(succeeds, "\(error)")
                if looping { guard case VMError.budgetExceeded = error else { return XCTFail("\(error)") } }
            }
            let object = try XCTUnwrap(bridge.resolve(class: builderType, "build", prototype: "()Lkotlinx/serialization/json/JsonObject;", isStatic: false))(vm, [builder])
            let rendered = try XCTUnwrap(bridge.resolve(class: "Lkotlinx/serialization/json/JsonObject;", "toString", prototype: "()Ljava/lang/String;", isStatic: false))(vm, [object])
            XCTAssertEqual(vmStringValue(rendered), succeeds ? #"{"outer":{"inner":"value"}}"# : "{}")
            if succeeds {
                let old = try put(vm, [builder, HostBridge.string("outer"), action])
                guard case let .obj(oldObject) = old else { return XCTFail("Expected old object") }
                XCTAssertEqual(oldObject.dexType, "Lkotlinx/serialization/json/JsonObject;")
            }
        }
    }
}
